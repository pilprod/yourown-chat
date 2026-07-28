import assert from "node:assert/strict";
import test from "node:test";

import {
  KubernetesScaleClient,
  kubernetesScaleClientFromEnv,
} from "../kubernetes-scale-client.mjs";

test("cleanup is disabled unless explicitly enabled", () => {
  assert.equal(kubernetesScaleClientFromEnv({}), null);
});

test("configuration rejects malformed or overly broad workload mappings", () => {
  assert.throws(
    () =>
      kubernetesScaleClientFromEnv({
        GOOGLE_CLOUD_DEPLOY_CLEANUP_ENABLED: "true",
        GOOGLE_CLOUD_DEPLOY_DEV_WORKLOADS: "mattermost=*/*",
        KUBERNETES_SERVICE_HOST: "10.30.0.1",
      }),
    /Invalid dev workload mapping/,
  );
});

test("scale to zero patches only allowlisted deployments and waits for zero", async () => {
  const calls = [];
  let reads = 0;
  const client = new KubernetesScaleClient({
    workloads: new Map([
      [
        "mattermost",
        [{ namespace: "dev", deployment: "dev-mattermost" }],
      ],
    ]),
    host: "10.30.0.1",
    tokenFile: "unused",
    caFile: "unused",
    sleep: async () => {},
    pollAttempts: 3,
    requestImpl: async ({ method, path, body }) => {
      calls.push({ method, path, body });
      if (method === "PATCH") {
        return { spec: { replicas: 0 }, status: { replicas: 1 } };
      }
      reads += 1;
      return {
        spec: { replicas: 0 },
        status: { replicas: reads === 1 ? 1 : 0 },
      };
    },
  });

  const result = await client.scaleToZero("mattermost");
  assert.equal(result.scaled_to_zero, true);
  assert.deepEqual(calls[0], {
    method: "PATCH",
    path: "/apis/apps/v1/namespaces/dev/deployments/dev-mattermost/scale",
    body: { spec: { replicas: 0 } },
  });
  assert.equal(result.workloads[0].observed_replicas, 0);
});

test("unknown pipelines cannot expand the cleanup scope", async () => {
  const client = new KubernetesScaleClient({
    workloads: new Map(),
    host: "10.30.0.1",
    tokenFile: "unused",
    caFile: "unused",
    requestImpl: async () => {
      throw new Error("must not be called");
    },
  });
  await assert.rejects(client.inspect("other"), /No dev cleanup workload allowlist/);
});
