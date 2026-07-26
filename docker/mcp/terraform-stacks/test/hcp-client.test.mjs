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
          {
            id: "st-cloudflare1",
            attributes: {
              name: "cloudflare",
              "working-directory": "terraform/cloudflare",
              "updated-at": "2026-07-25T00:00:00Z",
              "vcs-repo": {
                identifier: "pilprod/yourown-chat",
                branch: "main",
                "trigger-disabled": false,
              },
            },
            relationships: {
              project: {
                data: { id: "prj-yourownchat1", type: "projects" },
              },
            },
          },
          { id: "st-untrusted1", attributes: { name: "untrusted" } },
        ],
      });
    }
    if (
      path === "/api/v2/stacks/st-cloudflare1" &&
      (options.method ?? "GET") === "GET"
    ) {
      return jsonResponse({
        data: {
          id: "st-cloudflare1",
          attributes: {
            name: "cloudflare",
            description: "Cloudflare",
            "working-directory": "terraform/cloudflare",
            "updated-at": "2026-07-25T00:00:00Z",
            "speculative-enabled": false,
            "vcs-repo": {
              identifier: "pilprod/yourown-chat",
              branch: "main",
              "trigger-disabled": false,
            },
          },
          relationships: {
            project: {
              data: { id: "prj-yourownchat1", type: "projects" },
            },
          },
        },
      });
    }
    if (path === "/api/v2/stacks" && options.method === "POST") {
      const body = JSON.parse(options.body);
      return jsonResponse(
        {
          data: {
            id: "st-newstack1",
            attributes: body.data.attributes,
            relationships: body.data.relationships,
          },
        },
        201,
      );
    }
    if (
      path === "/api/v2/stacks/st-newstack1/fetch-latest-from-vcs" &&
      options.method === "POST"
    ) {
      return new Response(null, { status: 204 });
    }
    if (
      path === "/api/v2/stacks/st-cloudflare1" &&
      options.method === "PATCH"
    ) {
      const body = JSON.parse(options.body);
      return jsonResponse({
        data: {
          id: "st-cloudflare1",
          attributes: {
            ...body.data.attributes,
            "updated-at": "2026-07-25T01:00:00Z",
          },
        },
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
    allowedProjectIds: ["prj-yourownchat1"],
    allowedRepositories: ["pilprod/yourown-chat"],
    allowedWorkingDirectoryPrefixes: ["terraform/"],
    githubAppInstallationId: "ghain-installation1",
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
  assert.equal(
    cancellation.options.headers["Content-Type"],
    "application/vnd.api+json",
  );
});

test("reads full Stack settings under the committed management policy", async () => {
  const fixture = fixtureFetch();
  const settings = await client(fixture.fetchImpl).stackSettings("cloudflare");
  assert.equal(settings["working-directory"], "terraform/cloudflare");
  assert.equal(settings.policy.approval_allowed, true);
  assert.equal(settings.policy.management_allowed, true);
});

test("previews and creates only an allowlisted VCS-backed Stack", async () => {
  const fixture = fixtureFetch();
  const input = {
    name: "agent-registry-gcp",
    description: "Google Agent Registry",
    projectId: "prj-yourownchat1",
    repository: "pilprod/yourown-chat",
    workingDirectory: "terraform/agent-registry-gcp",
    branch: "main",
    speculativeEnabled: false,
    triggerDisabled: false,
    fetchConfiguration: true,
  };
  const plan = await client(fixture.fetchImpl).planCreateStack(input);
  assert.match(plan.plan_id, /^sha256:[a-f0-9]{64}$/);
  assert.deepEqual(plan.attributes["trigger-patterns"], [
    "/terraform/agent-registry-gcp/**",
  ]);
  assert.equal(plan.approval_after_creation, true);

  const result = await client(fixture.fetchImpl).createStack({
    ...input,
    expectedPlanId: plan.plan_id,
  });
  assert.equal(result.created, true);
  assert.equal(result.fetched_configuration, true);
  assert.equal(result.approval_allowed, true);
  assert.ok(
    fixture.calls.some(
      ({ path, options }) =>
        path === "/api/v2/stacks" && options.method === "POST",
    ),
  );
  assert.ok(
    fixture.calls.some(({ path }) =>
      path.endsWith("/fetch-latest-from-vcs"),
    ),
  );
});

test("rejects stale creates and paths outside terraform", async () => {
  const fixture = fixtureFetch();
  const base = {
    name: "new-stack",
    projectId: "prj-yourownchat1",
    repository: "pilprod/yourown-chat",
    workingDirectory: "terraform/new-stack",
  };
  await assert.rejects(
    client(fixture.fetchImpl).createStack({
      ...base,
      expectedPlanId: `sha256:${"0".repeat(64)}`,
    }),
    /Refusing stale create/,
  );
  await assert.rejects(
    client(fixture.fetchImpl).planCreateStack({
      ...base,
      workingDirectory: "../private",
    }),
    /relative POSIX path/,
  );
});

test("previews and applies a constrained Stack settings update", async () => {
  const fixture = fixtureFetch();
  const input = {
    stackName: "cloudflare",
    description: "Cloudflare DNS and Zero Trust",
    speculativeEnabled: true,
    fetchConfiguration: false,
  };
  const plan = await client(fixture.fetchImpl).planUpdateStack(input);
  const result = await client(fixture.fetchImpl).updateStack({
    ...input,
    expectedPlanId: plan.plan_id,
  });
  assert.equal(result.updated, true);
  const update = fixture.calls.find(
    ({ path, options }) =>
      path === "/api/v2/stacks/st-cloudflare1" &&
      options.method === "PATCH",
  );
  assert.deepEqual(JSON.parse(update.options.body).data.attributes, {
    name: "cloudflare",
    description: "Cloudflare DNS and Zero Trust",
    "speculative-enabled": true,
  });
});
