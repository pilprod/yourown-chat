import { readFile } from "node:fs/promises";
import https from "node:https";

const NAME = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;

function requiredEnv(env, name) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function parseWorkloads(value) {
  const result = new Map();
  for (const entry of value.split(",")) {
    const [pipeline, workloadsText, ...extra] = entry.split("=");
    if (!pipeline || !workloadsText || extra.length > 0 || !NAME.test(pipeline)) {
      throw new Error(
        "GOOGLE_CLOUD_DEPLOY_DEV_WORKLOADS must use pipeline=namespace/deployment|namespace/deployment entries",
      );
    }
    const workloads = workloadsText.split("|").map((workload) => {
      const [namespace, deployment, ...workloadExtra] = workload.split("/");
      if (
        !namespace ||
        !deployment ||
        workloadExtra.length > 0 ||
        !NAME.test(namespace) ||
        !NAME.test(deployment)
      ) {
        throw new Error(`Invalid dev workload mapping for pipeline ${pipeline}`);
      }
      return { namespace, deployment };
    });
    result.set(pipeline, workloads);
  }
  return result;
}

function defaultSleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function inClusterRequest({
  method = "GET",
  path,
  body,
  host,
  port,
  tokenFile,
  caFile,
}) {
  const [token, ca] = await Promise.all([
    readFile(tokenFile, "utf8"),
    readFile(caFile),
  ]);
  return new Promise((resolve, reject) => {
    const request = https.request(
      {
        method,
        host,
        port,
        path,
        ca,
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${token.trim()}`,
          ...(body
            ? { "Content-Type": "application/merge-patch+json" }
            : {}),
        },
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let payload = {};
          if (text) {
            try {
              payload = JSON.parse(text);
            } catch {
              reject(
                new Error(
                  `Kubernetes ${method} ${path} returned non-JSON (${response.statusCode}): ${text.slice(0, 256)}`,
                ),
              );
              return;
            }
          }
          if (
            response.statusCode === undefined ||
            response.statusCode < 200 ||
            response.statusCode >= 300
          ) {
            reject(
              new Error(
                `Kubernetes ${method} ${path} failed (${response.statusCode}): ${payload.message ?? text}`,
              ),
            );
            return;
          }
          resolve(payload);
        });
      },
    );
    request.on("error", reject);
    if (body) request.write(JSON.stringify(body));
    request.end();
  });
}

export class KubernetesScaleClient {
  constructor({
    workloads,
    host,
    port = 443,
    tokenFile,
    caFile,
    requestImpl = inClusterRequest,
    sleep = defaultSleep,
    pollAttempts = 30,
    pollIntervalMs = 1000,
  }) {
    this.workloads = workloads;
    this.host = host;
    this.port = port;
    this.tokenFile = tokenFile;
    this.caFile = caFile;
    this.requestImpl = requestImpl;
    this.sleep = sleep;
    this.pollAttempts = pollAttempts;
    this.pollIntervalMs = pollIntervalMs;
  }

  pipelineWorkloads(pipeline) {
    const workloads = this.workloads.get(pipeline);
    if (!workloads) {
      throw new Error(`No dev cleanup workload allowlist for pipeline ${pipeline}`);
    }
    return workloads;
  }

  async request(method, namespace, deployment, body) {
    return this.requestImpl({
      method,
      path: `/apis/apps/v1/namespaces/${namespace}/deployments/${deployment}/scale`,
      body,
      host: this.host,
      port: this.port,
      tokenFile: this.tokenFile,
      caFile: this.caFile,
    });
  }

  summarize(workload, scale) {
    return {
      namespace: workload.namespace,
      deployment: workload.deployment,
      desired_replicas: scale.spec?.replicas ?? null,
      observed_replicas: scale.status?.replicas ?? 0,
    };
  }

  async inspect(pipeline) {
    return {
      pipeline,
      workloads: await Promise.all(
        this.pipelineWorkloads(pipeline).map(async (workload) =>
          this.summarize(
            workload,
            await this.request(
              "GET",
              workload.namespace,
              workload.deployment,
            ),
          ),
        ),
      ),
    };
  }

  async scaleToZero(pipeline) {
    const workloads = this.pipelineWorkloads(pipeline);
    for (const workload of workloads) {
      await this.request("PATCH", workload.namespace, workload.deployment, {
        spec: { replicas: 0 },
      });
    }

    for (let attempt = 0; attempt < this.pollAttempts; attempt += 1) {
      const status = await this.inspect(pipeline);
      if (
        status.workloads.every(
          ({ desired_replicas, observed_replicas }) =>
            desired_replicas === 0 && observed_replicas === 0,
        )
      ) {
        return { ...status, scaled_to_zero: true };
      }
      if (attempt + 1 < this.pollAttempts) {
        await this.sleep(this.pollIntervalMs);
      }
    }
    throw new Error(
      `Timed out waiting for ${pipeline} dev workloads to scale to zero`,
    );
  }
}

export function kubernetesScaleClientFromEnv(env = process.env, options = {}) {
  const enabled =
    (env.GOOGLE_CLOUD_DEPLOY_CLEANUP_ENABLED ?? "false").toLowerCase() ===
    "true";
  if (!enabled) return null;
  return new KubernetesScaleClient({
    workloads: parseWorkloads(
      requiredEnv(env, "GOOGLE_CLOUD_DEPLOY_DEV_WORKLOADS"),
    ),
    host: requiredEnv(env, "KUBERNETES_SERVICE_HOST"),
    port: Number(env.KUBERNETES_SERVICE_PORT_HTTPS ?? 443),
    tokenFile:
      env.KUBERNETES_SERVICEACCOUNT_TOKEN_FILE ??
      "/var/run/secrets/kubernetes.io/serviceaccount/token",
    caFile:
      env.KUBERNETES_SERVICEACCOUNT_CA_FILE ??
      "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
    ...options,
  });
}
