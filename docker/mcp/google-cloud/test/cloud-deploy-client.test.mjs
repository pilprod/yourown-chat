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

test("list endpoints sort each page locally without unsupported orderBy", async () => {
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
            releases: [
              {
                name: "projects/p/locations/l/deliveryPipelines/mcp/releases/older",
                createTime: "2026-07-25T00:00:00Z",
              },
              {
                name: "projects/p/locations/l/deliveryPipelines/mcp/releases/newer",
                createTime: "2026-07-26T00:00:00Z",
              },
            ],
          },
        },
      ],
      calls,
    ),
  });

  const result = await client.listReleases({ pipeline: "mcp", pageSize: 5 });
  assert.deepEqual(
    result.releases.map((release) => release.name),
    ["newer", "older"],
  );
  assert.doesNotMatch(calls[0].url, /orderBy/);
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

test("promotion creates a rollout through the current Cloud Deploy API", async () => {
  const calls = [];
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch(
      [
        { body: { renderState: "SUCCEEDED", etag: "release-etag" } },
        { body: { rollouts: [] } },
        { body: { name: "operations/promote" } },
      ],
      calls,
    ),
  });

  const expected = await new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch([
      { body: { renderState: "SUCCEEDED", etag: "release-etag" } },
      { body: { rollouts: [] } },
    ]),
  }).planPromote({
    pipeline: "mcp",
    release: "mcp-1-0-0",
    target: "mcp-prod",
  });

  const result = await client.promote({
    pipeline: "mcp",
    release: "mcp-1-0-0",
    target: "mcp-prod",
    expectedPlanId: expected.plan_id,
    reason: "release smoke passed",
  });

  assert.equal(result.result.name, "operations/promote");
  assert.equal(calls[2].method, "POST");
  assert.match(
    calls[2].url,
    /\/releases\/mcp-1-0-0\/rollouts\?rolloutId=mcp-1-0-0-to-mcp-prod-0001$/,
  );
  assert.equal(calls[2].body.targetId, "mcp-prod");
  assert.equal(calls[2].body.rolloutId, undefined);
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

test("release and job-run inspection expose frozen delivery details", async () => {
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch([
      {
        body: {
          name: "projects/p/locations/l/deliveryPipelines/mcp/releases/mcp-1",
          renderState: "SUCCEEDED",
          targetArtifacts: { "mcp-prod": { manifestPath: "stable.yaml" } },
          deployParameters: [{ values: { image: "digest" } }],
        },
      },
      {
        body: {
          jobRuns: [
            {
              name: "projects/p/locations/l/deliveryPipelines/mcp/releases/mcp-1/rollouts/rollout-1/jobRuns/job-1",
              state: "SUCCEEDED",
              phaseId: "stable",
              jobId: "verify",
              verifyJobRun: { build: "projects/p/locations/l/builds/build-1" },
            },
          ],
        },
      },
    ]),
  });
  const release = await client.inspectRelease({
    pipeline: "mcp",
    release: "mcp-1",
  });
  assert.equal(release.target_artifacts["mcp-prod"].manifestPath, "stable.yaml");
  const jobs = await client.listJobRuns({
    pipeline: "mcp",
    release: "mcp-1",
    rollout: "rollout-1",
  });
  assert.equal(jobs.job_runs[0].job_id, "verify");
  assert.equal(jobs.job_runs[0].state, "SUCCEEDED");
});

test("rollback requires a freshly validated exact plan", async () => {
  const validation = {
    rollbackConfig: {
      rollout: {
        name: "projects/p/locations/l/deliveryPipelines/mcp/releases/mcp-previous/rollouts/rb-mcp-prod-01",
        targetId: "mcp-prod",
      },
      startingPhaseId: "stable",
    },
  };
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch([
      { body: validation },
      { body: validation },
      { body: { rollbackConfig: validation.rollbackConfig } },
    ]),
  });
  const plan = await client.planRollback({
    pipeline: "mcp",
    target: "mcp-prod",
    rolloutId: "rb-mcp-prod-01",
  });
  assert.match(plan.plan_id, /^sha256:[a-f0-9]{64}$/);
  const result = await client.rollback({
    pipeline: "mcp",
    target: "mcp-prod",
    rolloutId: "rb-mcp-prod-01",
    expectedPlanId: plan.plan_id,
    reason: "restore last successful release",
  });
  assert.equal(result.plan.plan_id, plan.plan_id);
  assert.equal(result.result.rollbackConfig.startingPhaseId, "stable");
});

test("rollback refuses a stale plan hash", async () => {
  const client = new CloudDeployClient({
    project: "yourown-chat",
    location: "europe-west3",
    pipelineTargets,
    auth,
    fetchImpl: sequenceFetch([
      {
        body: {
          rollbackConfig: {
            rollout: { targetId: "mcp-prod" },
          },
        },
      },
    ]),
  });
  await assert.rejects(
    client.rollback({
      pipeline: "mcp",
      target: "mcp-prod",
      rolloutId: "rb-mcp-prod-02",
      expectedPlanId: `sha256:${"0".repeat(64)}`,
      reason: "restore last successful release",
    }),
    /Rollback plan changed/,
  );
});
