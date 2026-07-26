import assert from "node:assert/strict";
import test from "node:test";

import {
  CloudDeployClient,
  cloudDeployClientFromEnv,
} from "../cloud-deploy-client.mjs";

const pipelineTargets = new Map([
  ["mcp", new Set(["mcp-dev", "mcp-prod"])],
]);

const auth = {
  async getClient() {
    return {
      async getRequestHeaders() {
        return new Headers({ authorization: "Bearer test" });
      },
    };
  },
};

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function sequenceFetch(responses, calls = []) {
  return async (url, options) => {
    calls.push({
      url: url.toString(),
      method: options.method,
      body: options.body ? JSON.parse(options.body) : undefined,
    });
    const next = responses.shift();
    if (!next) throw new Error(`Unexpected request: ${url}`);
    return jsonResponse(next.body, next.status ?? 200);
  };
}

test("configuration requires explicit constrained deployment scope", () => {
  assert.throws(
    () => cloudDeployClientFromEnv({}),
    /GOOGLE_CLOUD_DEPLOY_PROJECT is required/,
  );
  assert.throws(
    () =>
      cloudDeployClientFromEnv({
        GOOGLE_CLOUD_DEPLOY_PROJECT: "yourown-chat",
        GOOGLE_CLOUD_DEPLOY_LOCATION: "europe-west3",
        GOOGLE_CLOUD_DEPLOY_PIPELINE_TARGETS: "mcp=*",
      }),
    /Invalid target allowlist/,
  );
});

test("pipeline and target allowlists reject out-of-scope access", async () => {
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch([]),
  });
  await assert.rejects(
    client.listReleases({ pipeline: "other" }),
    /not allowlisted/,
  );
  await assert.rejects(
    client.planPromote({
      pipeline: "mcp",
      release: "mcp-1-0-0",
      target: "mattermost-prod",
    }),
    /not allowlisted/,
  );
});

test("promotion plan is deterministic and chooses the next rollout id", async () => {
  const fetchImpl = sequenceFetch([
    {
      body: {
        name: "projects/yourown-chat/locations/europe-west3/deliveryPipelines/mcp/releases/mcp-1-0-0",
        renderState: "SUCCEEDED",
        etag: "release-etag",
      },
    },
    {
      body: {
        rollouts: [
          {
            name: "projects/yourown-chat/locations/europe-west3/deliveryPipelines/mcp/releases/mcp-1-0-0/rollouts/mcp-1-0-0-to-mcp-prod-0002",
            targetId: "mcp-prod",
            state: "FAILED",
          },
        ],
      },
    },
  ]);
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl,
  });

  const plan = await client.planPromote({
    pipeline: "mcp",
    release: "mcp-1-0-0",
    target: "mcp-prod",
  });
  assert.equal(plan.rollout_id, "mcp-1-0-0-to-mcp-prod-0003");
  assert.match(plan.plan_id, /^sha256:[a-f0-9]{64}$/);
});

test("promotion refuses duplicate active or successful target rollout", async () => {
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch([
      {
        body: {
          renderState: "SUCCEEDED",
          etag: "release-etag",
        },
      },
      {
        body: {
          rollouts: [
            {
              name: "projects/p/locations/l/deliveryPipelines/mcp/releases/r/rollouts/existing",
              targetId: "mcp-prod",
              state: "PENDING_APPROVAL",
            },
          ],
        },
      },
    ]),
  });
  await assert.rejects(
    client.planPromote({
      pipeline: "mcp",
      release: "mcp-1-0-0",
      target: "mcp-prod",
    }),
    /already has rollout existing/,
  );
});

test("promote requires the exact freshly recomputed plan hash", async () => {
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch([
      { body: { renderState: "SUCCEEDED", etag: "release-etag" } },
      { body: { rollouts: [] } },
    ]),
  });
  await assert.rejects(
    client.promote({
      pipeline: "mcp",
      release: "mcp-1-0-0",
      target: "mcp-prod",
      expectedPlanId: `sha256:${"0".repeat(64)}`,
      reason: "release smoke passed",
    }),
    /Promotion plan changed/,
  );
});

test("approval verifies current etag and pending approval state", async () => {
  const calls = [];
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch(
      [
        {
          body: {
            name: "projects/yourown-chat/locations/europe-west3/deliveryPipelines/mcp/releases/mcp-1-0-0/rollouts/mcp-1-0-0-to-mcp-prod-0001",
            targetId: "mcp-prod",
            state: "PENDING_APPROVAL",
            approvalState: "NEEDS_APPROVAL",
            etag: "rollout-etag",
          },
        },
        { body: {} },
      ],
      calls,
    ),
  });
  const result = await client.approve({
    pipeline: "mcp",
    release: "mcp-1-0-0",
    rollout: "mcp-1-0-0-to-mcp-prod-0001",
    expectedEtag: "rollout-etag",
    reason: "reviewed successful dev rollout",
  });
  assert.equal(result.approved, true);
  assert.equal(calls[1].method, "POST");
  assert.deepEqual(calls[1].body, { approved: true });
  assert.match(calls[1].url, /:approve$/);
});
