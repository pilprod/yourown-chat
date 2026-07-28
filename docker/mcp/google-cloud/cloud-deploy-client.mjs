import { createHash } from "node:crypto";

import { GoogleAuth } from "google-auth-library";

const API_ROOT = "https://clouddeploy.googleapis.com/v1";
const NAME = /^[a-z][a-z0-9-]{0,62}$/;

function requiredEnv(env, name) {
  const value = env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function parsePipelineTargets(value) {
  const result = new Map();
  for (const entry of value.split(",")) {
    const [pipeline, targetsText, ...extra] = entry.split("=");
    if (!pipeline || !targetsText || extra.length > 0 || !NAME.test(pipeline)) {
      throw new Error(
        "GOOGLE_CLOUD_DEPLOY_PIPELINE_TARGETS must use pipeline=target|target entries",
      );
    }
    const targets = targetsText.split("|");
    if (targets.some((target) => !NAME.test(target))) {
      throw new Error(`Invalid target allowlist for pipeline ${pipeline}`);
    }
    result.set(pipeline, new Set(targets));
  }
  return result;
}

function canonical(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonical).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function planId(value) {
  return `sha256:${createHash("sha256").update(canonical(value)).digest("hex")}`;
}

function basename(resourceName) {
  return resourceName?.split("/").at(-1) ?? null;
}

function summarizeRelease(release) {
  return {
    name: basename(release.name),
    resource_name: release.name,
    create_time: release.createTime,
    render_state: release.renderState,
    abandoned: release.abandoned ?? false,
    etag: release.etag,
    labels: release.labels ?? {},
  };
}

function summarizeRollout(rollout) {
  return {
    name: basename(rollout.name),
    resource_name: rollout.name,
    target_id: rollout.targetId,
    state: rollout.state,
    approval_state: rollout.approvalState,
    create_time: rollout.createTime,
    deploy_start_time: rollout.deployStartTime,
    deploy_end_time: rollout.deployEndTime,
    failure_reason: rollout.failureReason,
    etag: rollout.etag,
    phases: rollout.phases ?? [],
    annotations: rollout.annotations ?? {},
  };
}

function summarizeJobRun(jobRun) {
  return {
    name: basename(jobRun.name),
    resource_name: jobRun.name,
    uid: jobRun.uid,
    state: jobRun.state,
    create_time: jobRun.createTime,
    start_time: jobRun.startTime,
    end_time: jobRun.endTime,
    phase_id: jobRun.phaseId,
    job_id: jobRun.jobId,
    etag: jobRun.etag,
    deploy_job_run: jobRun.deployJobRun,
    verify_job_run: jobRun.verifyJobRun,
    predeploy_job_run: jobRun.predeployJobRun,
    postdeploy_job_run: jobRun.postdeployJobRun,
    create_child_rollout_job_run: jobRun.createChildRolloutJobRun,
    advance_child_rollout_job_run: jobRun.advanceChildRolloutJobRun,
  };
}

export class CloudDeployClient {
  constructor({
    project,
    location,
    pipelineTargets,
    auth = new GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/cloud-platform"],
    }),
    fetchImpl = fetch,
  }) {
    this.project = project;
    this.location = location;
    this.pipelineTargets = pipelineTargets;
    this.auth = auth;
    this.fetchImpl = fetchImpl;
  }

  assertPipeline(pipeline) {
    if (!NAME.test(pipeline) || !this.pipelineTargets.has(pipeline)) {
      throw new Error(`Pipeline ${pipeline} is not allowlisted`);
    }
  }

  assertTarget(pipeline, target) {
    this.assertPipeline(pipeline);
    if (!NAME.test(target) || !this.pipelineTargets.get(pipeline).has(target)) {
      throw new Error(`Target ${target} is not allowlisted for ${pipeline}`);
    }
  }

  assertName(kind, value) {
    if (!NAME.test(value)) {
      throw new Error(`Invalid ${kind}: ${value}`);
    }
  }

  pipelinePath(pipeline) {
    this.assertPipeline(pipeline);
    return `projects/${this.project}/locations/${this.location}/deliveryPipelines/${pipeline}`;
  }

  releasePath(pipeline, release) {
    this.assertName("release", release);
    return `${this.pipelinePath(pipeline)}/releases/${release}`;
  }

  rolloutPath(pipeline, release, rollout) {
    this.assertName("rollout", rollout);
    return `${this.releasePath(pipeline, release)}/rollouts/${rollout}`;
  }

  jobRunPath(pipeline, release, rollout, jobRun) {
    this.assertName("job run", jobRun);
    return `${this.rolloutPath(pipeline, release, rollout)}/jobRuns/${jobRun}`;
  }

  async request(path, { method = "GET", query, body } = {}) {
    const url = new URL(`${API_ROOT}/${path}`);
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
    let payload = {};
    if (text) {
      try {
        payload = JSON.parse(text);
      } catch {
        throw new Error(
          `Cloud Deploy ${method} ${url.pathname} returned non-JSON (${response.status}, ${response.headers.get("content-type") ?? "unknown content type"}): ${text.slice(0, 256)}`,
        );
      }
    }
    if (!response.ok) {
      throw new Error(
        `Cloud Deploy ${method} ${url.pathname} failed (${response.status}): ${
          payload.error?.message ?? text
        }`,
      );
    }
    return payload;
  }

  async listReleases({ pipeline, pageSize = 20, pageToken } = {}) {
    const payload = await this.request(`${this.pipelinePath(pipeline)}/releases`, {
      query: {
        pageSize: Math.min(Math.max(pageSize, 1), 100),
        pageToken,
      },
    });
    return {
      // Cloud Deploy's list endpoints currently reject createTime/orderBy
      // even though many Google APIs accept it. Preserve deterministic
      // newest-first output by sorting the returned page locally.
      releases: (payload.releases ?? [])
        .map(summarizeRelease)
        .sort((left, right) =>
          (right.create_time ?? "").localeCompare(left.create_time ?? ""),
        ),
      next_page_token: payload.nextPageToken,
    };
  }

  async getRelease(pipeline, release) {
    return this.request(this.releasePath(pipeline, release));
  }

  async inspectRelease({ pipeline, release }) {
    const value = await this.getRelease(pipeline, release);
    return {
      ...summarizeRelease(value),
      description: value.description,
      annotations: value.annotations ?? {},
      target_artifacts: value.targetArtifacts ?? {},
      deploy_parameters: value.deployParameters ?? [],
      skaffold_config_uri: value.skaffoldConfigUri,
      skaffold_config_path: value.skaffoldConfigPath,
      build_artifacts: value.buildArtifacts ?? [],
      delivery_pipeline_snapshot: value.deliveryPipelineSnapshot,
      target_snapshots: value.targetSnapshots ?? [],
      render_start_time: value.renderStartTime,
      render_end_time: value.renderEndTime,
      condition: value.condition,
    };
  }

  async listRollouts({
    pipeline,
    release,
    pageSize = 20,
    pageToken,
  } = {}) {
    const payload = await this.request(
      `${this.releasePath(pipeline, release)}/rollouts`,
      {
        query: {
          pageSize: Math.min(Math.max(pageSize, 1), 100),
          pageToken,
        },
      },
    );
    return {
      rollouts: (payload.rollouts ?? [])
        .map(summarizeRollout)
        .sort((left, right) =>
          (right.create_time ?? "").localeCompare(left.create_time ?? ""),
        ),
      next_page_token: payload.nextPageToken,
    };
  }

  async inspectRollout({ pipeline, release, rollout }) {
    return summarizeRollout(
      await this.request(this.rolloutPath(pipeline, release, rollout)),
    );
  }

  async listJobRuns({
    pipeline,
    release,
    rollout,
    pageSize = 50,
    pageToken,
  }) {
    const payload = await this.request(
      `${this.rolloutPath(pipeline, release, rollout)}/jobRuns`,
      {
        query: {
          pageSize: Math.min(Math.max(pageSize, 1), 100),
          pageToken,
        },
      },
    );
    return {
      job_runs: (payload.jobRuns ?? []).map(summarizeJobRun),
      next_page_token: payload.nextPageToken,
    };
  }

  async inspectJobRun({ pipeline, release, rollout, jobRun }) {
    return summarizeJobRun(
      await this.request(this.jobRunPath(pipeline, release, rollout, jobRun)),
    );
  }

  async planPromote({ pipeline, release, target }) {
    this.assertTarget(pipeline, target);
    const currentRelease = await this.getRelease(pipeline, release);
    if (currentRelease.abandoned || currentRelease.renderState !== "SUCCEEDED") {
      throw new Error(
        `Release ${release} is not promotable: render=${currentRelease.renderState}, abandoned=${currentRelease.abandoned ?? false}`,
      );
    }
    const releaseChannel =
      currentRelease.annotations?.["release-channel"] ?? "legacy";
    if (target.endsWith("-prod") && releaseChannel === "experimental") {
      throw new Error(
        `Release ${release} is dev-only (release-channel=experimental) and cannot be promoted to ${target}`,
      );
    }

    const rollouts = await this.listRollouts({
      pipeline,
      release,
      pageSize: 100,
    });
    const targetRollouts = rollouts.rollouts.filter(
      (rollout) => rollout.target_id === target,
    );
    const blockingStates = new Set([
      "PENDING_APPROVAL",
      "PENDING",
      "IN_PROGRESS",
      "SUCCEEDED",
    ]);
    const existing = targetRollouts.find((rollout) =>
      blockingStates.has(rollout.state),
    );
    if (existing) {
      throw new Error(
        `Release ${release} already has rollout ${existing.name} for ${target} in state ${existing.state}`,
      );
    }

    const prefix = `${release}-to-${target}-`;
    const nextSequence =
      targetRollouts.reduce((max, rollout) => {
        if (!rollout.name.startsWith(prefix)) return max;
        const value = Number.parseInt(rollout.name.slice(prefix.length), 10);
        return Number.isFinite(value) ? Math.max(max, value) : max;
      }, 0) + 1;
    const rolloutId = `${prefix}${String(nextSequence).padStart(4, "0")}`;
    const plan = {
      action: "promote",
      project: this.project,
      location: this.location,
      pipeline,
      release,
      release_etag: currentRelease.etag,
      target,
      rollout_id: rolloutId,
    };
    return { ...plan, plan_id: planId(plan) };
  }

  async promote({
    pipeline,
    release,
    target,
    expectedPlanId,
    reason,
  }) {
    const plan = await this.planPromote({ pipeline, release, target });
    if (plan.plan_id !== expectedPlanId) {
      throw new Error(
        `Promotion plan changed: expected ${expectedPlanId}, current ${plan.plan_id}`,
      );
    }
    const payload = await this.request(
      `${this.releasePath(pipeline, release)}/rollouts`,
      {
        method: "POST",
        query: {
          rolloutId: plan.rollout_id,
        },
        body: {
          targetId: target,
          annotations: {
            "yourown-chat-mcp-reason": reason.slice(0, 256),
          },
          labels: {
            managed_by: "yourown_chat_mcp",
          },
        },
      },
    );
    return { plan, result: payload };
  }

  async approve({
    pipeline,
    release,
    rollout,
    expectedEtag,
    reason,
  }) {
    const current = await this.inspectRollout({ pipeline, release, rollout });
    this.assertTarget(pipeline, current.target_id);
    if (current.etag !== expectedEtag) {
      throw new Error(
        `Rollout etag changed: expected ${expectedEtag}, current ${current.etag}`,
      );
    }
    if (
      current.approval_state !== "NEEDS_APPROVAL" &&
      current.approval_state !== "PENDING_APPROVAL"
    ) {
      throw new Error(
        `Rollout ${rollout} is not waiting for approval: ${current.approval_state}`,
      );
    }
    await this.request(`${current.resource_name}:approve`, {
      method: "POST",
      body: { approved: true },
    });
    return {
      approved: true,
      rollout: current.resource_name,
      target: current.target_id,
      inspected_etag: expectedEtag,
      reason,
    };
  }

  async reject({
    pipeline,
    release,
    rollout,
    expectedEtag,
    reason,
  }) {
    const current = await this.inspectRollout({ pipeline, release, rollout });
    this.assertTarget(pipeline, current.target_id);
    if (!current.target_id.endsWith("-prod")) {
      throw new Error(
        `Only production approval rollouts may be rejected: ${current.target_id}`,
      );
    }
    if (current.etag !== expectedEtag) {
      throw new Error(
        `Rollout etag changed: expected ${expectedEtag}, current ${current.etag}`,
      );
    }
    if (
      current.approval_state !== "NEEDS_APPROVAL" &&
      current.approval_state !== "PENDING_APPROVAL"
    ) {
      throw new Error(
        `Rollout ${rollout} is not waiting for approval: ${current.approval_state}`,
      );
    }
    await this.request(`${current.resource_name}:approve`, {
      method: "POST",
      body: { approved: false },
    });
    return {
      approved: false,
      rejected: true,
      rollout: current.resource_name,
      target: current.target_id,
      inspected_etag: expectedEtag,
      reason,
    };
  }

  async planRollback({
    pipeline,
    target,
    rolloutId,
    release,
  }) {
    this.assertTarget(pipeline, target);
    this.assertName("rollback rollout", rolloutId);
    if (release !== undefined) this.assertName("release", release);
    const request = {
      targetId: target,
      rolloutId,
      ...(release ? { releaseId: release } : {}),
      validateOnly: true,
    };
    const validation = await this.request(
      `${this.pipelinePath(pipeline)}:rollbackTarget`,
      { method: "POST", body: request },
    );
    const plan = {
      action: "rollback",
      project: this.project,
      location: this.location,
      pipeline,
      target,
      rollout_id: rolloutId,
      requested_release: release ?? null,
      rollback_config: validation.rollbackConfig,
    };
    return { ...plan, plan_id: planId(plan) };
  }

  async rollback({
    pipeline,
    target,
    rolloutId,
    release,
    expectedPlanId,
    reason,
  }) {
    const plan = await this.planRollback({
      pipeline,
      target,
      rolloutId,
      release,
    });
    if (plan.plan_id !== expectedPlanId) {
      throw new Error(
        `Rollback plan changed: expected ${expectedPlanId}, current ${plan.plan_id}`,
      );
    }
    const result = await this.request(
      `${this.pipelinePath(pipeline)}:rollbackTarget`,
      {
        method: "POST",
        body: {
          targetId: target,
          rolloutId,
          ...(release ? { releaseId: release } : {}),
        },
      },
    );
    return {
      plan,
      reason,
      result,
    };
  }
}

export function cloudDeployClientFromEnv(env = process.env, options = {}) {
  const project = requiredEnv(env, "GOOGLE_CLOUD_DEPLOY_PROJECT");
  const location = requiredEnv(env, "GOOGLE_CLOUD_DEPLOY_LOCATION");
  if (!NAME.test(project) || !NAME.test(location)) {
    throw new Error("Invalid Cloud Deploy project or location");
  }
  const pipelineTargets = parsePipelineTargets(
    requiredEnv(env, "GOOGLE_CLOUD_DEPLOY_PIPELINE_TARGETS"),
  );
  return new CloudDeployClient({
    project,
    location,
    pipelineTargets,
    ...options,
  });
}
