import assert from "node:assert/strict";
import test from "node:test";

import { HcpStacksClient } from "../hcp-client.mjs";

function jsonResponse(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/vnd.api+json" },
  });
}

function fixtureFetch({
  runStatus = "pre_deploying_pending_operator",
  planStatus = "pending_operator",
} = {}) {
  const calls = [];
  const fetchImpl = async (url, options = {}) => {
    const path = new URL(url).pathname + new URL(url).search;
    calls.push({ path, options });
    if (path.startsWith("/api/v2/organizations/papou-work/stacks")) {
      return jsonResponse({
        data: [
          { id: "st-cloudflare1", attributes: { name: "cloudflare" } },
          { id: "st-untrusted1", attributes: { name: "untrusted" } },
        ],
      });
    }
    if (path.startsWith("/api/v2/stacks/st-cloudflare1/stack-deployments?")) {
      return jsonResponse({
        data: [{ id: "std-one", attributes: { name: "yourown-chat" } }],
      });
    }
    if (
      path.startsWith(
        "/api/v2/stacks/st-cloudflare1/stack-deployments/yourown-chat/stack-deployment-runs?",
      )
    ) {
      return jsonResponse({
        data: [
          {
            id: "sdr-run1",
            attributes: {
              status: runStatus,
              deployment: "yourown-chat",
              "created-at": "2026-07-25T00:00:00Z",
            },
            relationships: {
              "stack-configuration": {
                data: { id: "stc-config1", type: "stack-configurations" },
              },
            },
          },
        ],
      });
    }
    if (path === "/api/v2/stack-deployment-runs/sdr-run1") {
      return jsonResponse({
        data: {
          id: "sdr-run1",
          attributes: { status: runStatus, deployment: "yourown-chat" },
          relationships: {
            "stack-configuration": {
              data: { id: "stc-config1", type: "stack-configurations" },
            },
          },
        },
      });
    }
    if (
      path.startsWith(
        "/api/v2/stack-deployment-runs/sdr-run1/stack-deployment-steps?",
      )
    ) {
      return jsonResponse({
        data: [
          {
            id: "sds-plan1",
            attributes: {
              status: planStatus,
              "operation-type": "plan",
            },
          },
        ],
      });
    }
    if (
      path.startsWith(
        "/api/v2/stack-deployment-steps/sds-plan1/stack-diagnostics?",
      )
    ) {
      return jsonResponse({ data: [] });
    }
    if (
      path ===
      "/api/v2/stack-deployment-steps/sds-plan1/artifacts?name=plan-description"
    ) {
      return new Response("Plan: 1 to add, 0 to change, 0 to destroy", {
        headers: { "content-type": "text/plain" },
      });
    }
    if (
      path ===
      "/api/v2/stack-deployment-runs/sdr-run1/approve-all-plans?all_plans=false"
    ) {
      return new Response(null, { status: 204 });
    }
    if (
      path === "/api/v2/stack-deployment-runs/sdr-run1/cancel?force=false"
    ) {
      return new Response(null, { status: 204 });
    }
    throw new Error(`Unexpected request ${path}`);
  };
  return { calls, fetchImpl };
}

function client(fetchImpl) {
  return new HcpStacksClient({
    token: "valid-token",
    organization: "papou-work",
    allowedStackNames: [
      "cloudflare",
      "app-gcp",
      "platform-gcp",
      "agent-registry-gcp",
    ],
    fetchImpl,
  });
}

test("lists only allowlisted Stack runs", async () => {
  const fixture = fixtureFetch();
  const runs = await client(fixture.fetchImpl).listRuns({
    stackName: "cloudflare",
  });
  assert.equal(runs.length, 1);
  assert.equal(runs[0].stack, "cloudflare");
  await assert.rejects(
    client(fixture.fetchImpl).listRuns({ stackName: "untrusted" }),
    /not in TFE_STACK_ALLOWLIST/,
  );
});

test("approves one exact run without approving future plans", async () => {
  const fixture = fixtureFetch();
  const result = await client(fixture.fetchImpl).approveRun({
    stackName: "cloudflare",
    runId: "sdr-run1",
    expectedConfigurationId: "stc-config1",
    reason: "Reviewed through MCP",
  });
  assert.equal(result.approved, true);
  assert.equal(result.all_future_plans, false);
  const approval = fixture.calls.find(({ path }) =>
    path.includes("approve-all-plans"),
  );
  assert.equal(
    approval.path,
    "/api/v2/stack-deployment-runs/sdr-run1/approve-all-plans?all_plans=false",
  );
  assert.deepEqual(JSON.parse(approval.options.body), {
    reason: "Reviewed through MCP",
  });
});

test("accepts hyphenated statuses returned by the HCP Stacks API", async () => {
  const fixture = fixtureFetch({
    runStatus: "pre-deploying-pending-operator",
    planStatus: "pending-operator",
  });
  const result = await client(fixture.fetchImpl).approveRun({
    stackName: "cloudflare",
    runId: "sdr-run1",
    expectedConfigurationId: "stc-config1",
    reason: "Reviewed through MCP",
  });

  assert.equal(result.approved, true);
});

test("refuses stale configuration IDs and non-pending runs", async () => {
  const fixture = fixtureFetch();
  await assert.rejects(
    client(fixture.fetchImpl).approveRun({
      stackName: "cloudflare",
      runId: "sdr-run1",
      expectedConfigurationId: "stc-stale1",
      reason: "Reviewed through MCP",
    }),
    /Refusing stale approval/,
  );

  const completed = fixtureFetch({ runStatus: "succeeded" });
  await assert.rejects(
    client(completed.fetchImpl).approveRun({
      stackName: "cloudflare",
      runId: "sdr-run1",
      expectedConfigurationId: "stc-config1",
      reason: "Reviewed through MCP",
    }),
    /not pending operator approval/,
  );
});

test("cancels only an allowlisted non-terminal run without force", async () => {
  const fixture = fixtureFetch();
  const result = await client(fixture.fetchImpl).cancelRun({
    stackName: "cloudflare",
    runId: "sdr-run1",
    reason: "Canceled through MCP",
  });
  assert.equal(result.canceled, true);
  assert.equal(result.forced, false);
  const cancellation = fixture.calls.find(({ path }) => path.includes("/cancel"));
  assert.equal(
    cancellation.path,
    "/api/v2/stack-deployment-runs/sdr-run1/cancel?force=false",
  );
  assert.equal(cancellation.options.body, undefined);
});
