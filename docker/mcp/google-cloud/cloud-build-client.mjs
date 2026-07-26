import { GoogleAuth } from "google-auth-library";

const BUILD_API_ROOT = "https://cloudbuild.googleapis.com/v1";
const LOGGING_API_ROOT = "https://logging.googleapis.com/v2";
const BUILD_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const NAME = /^[a-z][a-z0-9-]{0,62}$/;

function requiredEnv(env, name, fallback) {
  const value = env[name]?.trim() || fallback?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function summarizeBuild(build) {
  return {
    id: build.id,
    resource_name: build.name,
    status: build.status,
    status_detail: build.statusDetail,
    create_time: build.createTime,
    start_time: build.startTime,
    finish_time: build.finishTime,
    queue_ttl: build.queueTtl,
    timeout: build.timeout,
    log_url: build.logUrl,
    images: build.images ?? [],
    tags: build.tags ?? [],
    substitutions: build.substitutions ?? {},
    source: build.source,
    source_provenance: build.sourceProvenance,
    steps: (build.steps ?? []).map((step) => ({
      id: step.id,
      name: step.name,
      status: step.status,
      timing: step.timing,
      exit_code: step.exitCode,
      pull_timing: step.pullTiming,
    })),
    results: build.results,
    failure_info: build.failureInfo,
    warnings: build.warnings ?? [],
  };
}

function summarizeLogEntry(entry) {
  return {
    timestamp: entry.timestamp,
    receive_timestamp: entry.receiveTimestamp,
    severity: entry.severity,
    log_name: entry.logName,
    insert_id: entry.insertId,
    text: entry.textPayload,
    json: entry.jsonPayload,
    proto: entry.protoPayload,
    labels: entry.labels ?? {},
    resource: entry.resource,
  };
}

export class CloudBuildClient {
  constructor({
    project,
    location,
    auth = new GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/cloud-platform"],
    }),
    fetchImpl = fetch,
  }) {
    if (!NAME.test(project) || !NAME.test(location)) {
      throw new Error("Invalid Cloud Build project or location");
    }
    this.project = project;
    this.location = location;
    this.auth = auth;
    this.fetchImpl = fetchImpl;
  }

  buildsPath() {
    return `projects/${this.project}/locations/${this.location}/builds`;
  }

  buildPath(buildId) {
    if (!BUILD_ID.test(buildId)) throw new Error(`Invalid build ID: ${buildId}`);
    return `${this.buildsPath()}/${buildId}`;
  }

  async request(root, path, { method = "GET", query, body } = {}) {
    const url = new URL(`${root}/${path}`);
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
    const authClient = await this.auth.getClient();
    const authHeaders = await authClient.getRequestHeaders(url.toString());
    const response = await this.fetchImpl(url, {
      method,
      headers: {
        ...Object.fromEntries(authHeaders),
        accept: "application/json",
        ...(body ? { "content-type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await response.text();
    const payload = text ? JSON.parse(text) : {};
    if (!response.ok) {
      throw new Error(
        `Google API ${method} ${url.pathname} failed (${response.status}): ${
          payload.error?.message ?? text
        }`,
      );
    }
    return payload;
  }

  async listBuilds({ pageSize = 20, pageToken } = {}) {
    const payload = await this.request(BUILD_API_ROOT, this.buildsPath(), {
      query: {
        pageSize: Math.min(Math.max(pageSize, 1), 100),
        pageToken,
      },
    });
    return {
      builds: (payload.builds ?? [])
        .map(summarizeBuild)
        .sort((left, right) =>
          (right.create_time ?? "").localeCompare(left.create_time ?? ""),
        ),
      next_page_token: payload.nextPageToken,
    };
  }

  async inspectBuild({ buildId }) {
    return summarizeBuild(
      await this.request(BUILD_API_ROOT, this.buildPath(buildId)),
    );
  }

  async listBuildLogs({ buildId, pageSize = 200, pageToken } = {}) {
    this.buildPath(buildId);
    const escapedId = buildId.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
    const payload = await this.request(LOGGING_API_ROOT, "entries:list", {
      method: "POST",
      body: {
        resourceNames: [`projects/${this.project}`],
        filter:
          'resource.type="build" AND ' +
          `resource.labels.build_id="${escapedId}"`,
        orderBy: "timestamp asc",
        pageSize: Math.min(Math.max(pageSize, 1), 1000),
        pageToken,
      },
    });
    return {
      build_id: buildId,
      entries: (payload.entries ?? []).map(summarizeLogEntry),
      next_page_token: payload.nextPageToken,
    };
  }
}

export function cloudBuildClientFromEnv(env = process.env, options = {}) {
  return new CloudBuildClient({
    project: requiredEnv(
      env,
      "GOOGLE_CLOUD_BUILD_PROJECT",
      env.GOOGLE_CLOUD_DEPLOY_PROJECT,
    ),
    location: requiredEnv(
      env,
      "GOOGLE_CLOUD_BUILD_LOCATION",
      env.GOOGLE_CLOUD_DEPLOY_LOCATION,
    ),
    ...options,
  });
}
