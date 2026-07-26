import { createHash } from "node:crypto";
import { posix } from "node:path";

import { readSecretEnv } from "./secret-env.mjs";

const terminalStatuses = new Set([
  "succeeded",
  "failed",
  "canceled",
  "cancelled",
  "abandoned",
]);

const approvableStatuses = new Set([
  "pre_deploying_pending_operator",
  "deploying_pending_operator",
]);

function normalizeStatus(status) {
  return status?.replaceAll("-", "_");
}

function required(value, name) {
  if (!value || value.startsWith("REPLACE_ME_")) {
    throw new Error(`${name} is not configured`);
  }
  return value;
}

function assertId(value, prefix, name) {
  if (!new RegExp(`^${prefix}-[A-Za-z0-9]+$`).test(value)) {
    throw new Error(`${name} must be a valid ${prefix}- ID`);
  }
}

function csv(value) {
  return (value ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function planId(value) {
  return `sha256:${createHash("sha256")
    .update(JSON.stringify(value))
    .digest("hex")}`;
}

function validatedBranch(value) {
  if (
    !/^[A-Za-z0-9._/-]{1,255}$/.test(value) ||
    value.includes("..") ||
    value.startsWith("/") ||
    value.endsWith("/")
  ) {
    throw new Error("branch contains unsupported characters");
  }
  return value;
}

function resourceSummary(resource) {
  return {
    id: resource.id,
    ...resource.attributes,
    relationships: Object.fromEntries(
      Object.entries(resource.relationships ?? {})
        .filter(([, relationship]) => relationship?.data !== undefined)
        .map(([name, relationship]) => [name, relationship.data]),
    ),
  };
}

function boundedArtifact(value, maxLength = 200_000) {
  if (typeof value !== "string" || value.length <= maxLength) {
    return value;
  }
  return `${value.slice(0, maxLength)}\n\n[truncated ${value.length - maxLength} characters]`;
}

export class HcpStacksClient {
  constructor({
    token,
    address = "https://app.terraform.io",
    organization,
    allowedStackNames,
    allowedProjectIds = [],
    allowedRepositories = [],
    allowedWorkingDirectoryPrefixes = [],
    githubAppInstallationId,
    fetchImpl = fetch,
  }) {
    this.token = required(token, "TFE_TOKEN");
    this.address = new URL(address).origin;
    this.organization = required(organization, "TFE_ORGANIZATION");
    this.allowedStackNames = new Set(allowedStackNames);
    this.allowedProjectIds = new Set(allowedProjectIds);
    this.allowedRepositories = new Set(allowedRepositories);
    this.allowedWorkingDirectoryPrefixes = allowedWorkingDirectoryPrefixes;
    this.githubAppInstallationId = required(
      githubAppInstallationId,
      "TFE_STACK_GITHUB_APP_INSTALLATION_ID",
    );
    this.fetchImpl = fetchImpl;

    if (this.allowedStackNames.size === 0) {
      throw new Error("TFE_STACK_ALLOWLIST must contain at least one Stack name");
    }
    if (
      this.allowedProjectIds.size === 0 ||
      this.allowedRepositories.size === 0 ||
      this.allowedWorkingDirectoryPrefixes.length === 0
    ) {
      throw new Error(
        "Stack management project, repository, and working-directory allowlists must not be empty",
      );
    }
  }

  async request(path, { method = "GET", body, accept = "application/vnd.api+json" } = {}) {
    const response = await this.fetchImpl(
      new URL(`/api/v2/${path.replace(/^\//, "")}`, this.address),
      {
        method,
        headers: {
          Authorization: `Bearer ${this.token}`,
          Accept: accept,
          ...(method === "GET"
            ? {}
            : { "Content-Type": "application/vnd.api+json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(30_000),
      },
    );

    const text = await response.text();
    if (!response.ok) {
      let detail = text;
      try {
        const payload = JSON.parse(text);
        detail =
          payload.errors?.map((error) => error.detail ?? error.title).join("; ") ??
          text;
      } catch {
        // Preserve non-JSON upstream errors.
      }
      throw new Error(`HCP Terraform ${method} ${path} failed (${response.status}): ${detail}`);
    }

    if (!text) {
      return null;
    }
    if ((response.headers.get("content-type") ?? "").includes("json")) {
      return JSON.parse(text);
    }
    return text;
  }

  async allowedStacks() {
    const payload = await this.request(
      `organizations/${encodeURIComponent(this.organization)}/stacks?page%5Bsize%5D=100`,
    );
    return payload.data
      .filter((stack) => this.allowedStackNames.has(stack.attributes.name))
      .map((stack) => ({ id: stack.id, name: stack.attributes.name }));
  }

  async allStacks() {
    const payload = await this.request(
      `organizations/${encodeURIComponent(this.organization)}/stacks?page%5Bsize%5D=100`,
    );
    return payload.data;
  }

  async stackByName(stackName) {
    const stack = (await this.allStacks()).find(
      ({ attributes }) => attributes.name === stackName,
    );
    if (!stack) {
      throw new Error(
        `Stack ${stackName} does not exist in organization ${this.organization}`,
      );
    }
    return stack;
  }

  normalizedWorkingDirectory(value) {
    if (
      typeof value !== "string" ||
      value.startsWith("/") ||
      value.includes("\\") ||
      value.split("/").includes("..")
    ) {
      throw new Error("working_directory must be a relative POSIX path");
    }
    const normalized = posix
      .normalize(value)
      .replace(/^\.\//, "")
      .replace(/\/$/, "");
    if (
      normalized === "." ||
      !this.allowedWorkingDirectoryPrefixes.some((prefix) =>
        normalized.startsWith(prefix),
      )
    ) {
      throw new Error(
        `working_directory must start with one of: ${this.allowedWorkingDirectoryPrefixes.join(", ")}`,
      );
    }
    return normalized;
  }

  assertProject(projectId) {
    assertId(projectId, "prj", "project_id");
    if (!this.allowedProjectIds.has(projectId)) {
      throw new Error(`Project ${projectId} is not in TFE_STACK_PROJECT_ALLOWLIST`);
    }
  }

  assertRepository(repository) {
    if (!this.allowedRepositories.has(repository)) {
      throw new Error(
        `Repository ${repository} is not in TFE_STACK_REPOSITORY_ALLOWLIST`,
      );
    }
  }

  async stackSettings(stackName) {
    const listed = await this.stackByName(stackName);
    const payload = await this.request(`stacks/${listed.id}`);
    const settings = resourceSummary(payload.data);
    const repository = settings["vcs-repo"]?.identifier;
    const projectId = settings.relationships?.project?.id;
    const workingDirectory = settings["working-directory"] ?? "";

    const approvalAllowed = this.allowedStackNames.has(stackName);
    const directoryAllowed = workingDirectory
      ? this.allowedWorkingDirectoryPrefixes.some((prefix) =>
          workingDirectory.startsWith(prefix),
        )
      : approvalAllowed;
    const managementAllowed =
      this.allowedProjectIds.has(projectId) &&
      this.allowedRepositories.has(repository) &&
      directoryAllowed;
    if (!approvalAllowed && !managementAllowed) {
      throw new Error(`Stack ${stackName} is outside the committed management policy`);
    }
    return {
      ...settings,
      policy: {
        approval_allowed: approvalAllowed,
        management_allowed: managementAllowed,
      },
    };
  }

  async planCreateStack({
    name,
    description = "",
    projectId,
    repository,
    workingDirectory,
    branch = "main",
    speculativeEnabled = false,
    triggerDisabled = false,
    fetchConfiguration = true,
  }) {
    if (!/^[A-Za-z0-9_-]{1,90}$/.test(name)) {
      throw new Error("Stack name must contain only letters, digits, - and _");
    }
    this.assertProject(projectId);
    this.assertRepository(repository);
    const directory = this.normalizedWorkingDirectory(workingDirectory);
    if (
      (await this.allStacks()).some(
        ({ attributes }) => attributes.name === name,
      )
    ) {
      throw new Error(`Stack ${name} already exists`);
    }
    const validatedBranchName = validatedBranch(branch);

    const plan = {
      operation: "create_stack",
      organization: this.organization,
      project_id: projectId,
      attributes: {
        name,
        description,
        "working-directory": directory,
        "execution-mode": "remote",
        "speculative-enabled": speculativeEnabled,
        "trigger-patterns": [`${directory}/*`, `${directory}/**/*`],
        "vcs-repo": {
          identifier: repository,
          "display-identifier": repository,
          "repository-http-url": `https://github.com/${repository}`,
          "github-app-installation-id": this.githubAppInstallationId,
          "service-provider": "github",
          branch: validatedBranchName,
          "trigger-disabled": triggerDisabled,
        },
      },
      fetch_configuration: fetchConfiguration,
      approval_after_creation: this.allowedStackNames.has(name),
    };
    return { ...plan, plan_id: planId(plan) };
  }

  async createStack({ expectedPlanId, ...inputs }) {
    const plan = await this.planCreateStack(inputs);
    if (plan.plan_id !== expectedPlanId) {
      throw new Error(
        `Refusing stale create: plan is ${plan.plan_id}, expected ${expectedPlanId}`,
      );
    }
    const fetchConfiguration = plan.fetch_configuration;
    const payload = await this.request("stacks", {
      method: "POST",
      body: {
        data: {
          type: "stacks",
          attributes: plan.attributes,
          relationships: {
            project: {
              data: { type: "projects", id: plan.project_id },
            },
          },
        },
      },
    });
    if (fetchConfiguration) {
      await this.request(`stacks/${payload.data.id}/fetch-latest-from-vcs`, {
        method: "POST",
      });
    }
    return {
      created: true,
      stack: resourceSummary(payload.data),
      fetched_configuration: fetchConfiguration,
      approval_allowed: this.allowedStackNames.has(plan.attributes.name),
      plan_id: expectedPlanId,
    };
  }

  async planUpdateStack({
    stackName,
    description,
    workingDirectory,
    branch,
    speculativeEnabled,
    triggerDisabled,
    fetchConfiguration = false,
  }) {
    const current = await this.stackSettings(stackName);
    if (!current.policy.management_allowed) {
      throw new Error(`Stack ${stackName} is not management-allowed`);
    }
    const attributes = { name: current.name };
    if (description !== undefined) attributes.description = description;
    if (speculativeEnabled !== undefined) {
      attributes["speculative-enabled"] = speculativeEnabled;
    }
    if (workingDirectory !== undefined) {
      const directory = this.normalizedWorkingDirectory(workingDirectory);
      attributes["working-directory"] = directory;
      attributes["trigger-patterns"] = [
        `${directory}/*`,
        `${directory}/**/*`,
      ];
    }
    if (branch !== undefined || triggerDisabled !== undefined) {
      const vcs = current["vcs-repo"];
      attributes["vcs-repo"] = {
        identifier: vcs.identifier,
        "display-identifier": vcs["display-identifier"] ?? vcs.identifier,
        "repository-http-url":
          vcs["repository-http-url"] ?? `https://github.com/${vcs.identifier}`,
        "github-app-installation-id":
          vcs["github-app-installation-id"] ?? this.githubAppInstallationId,
        "service-provider": vcs["service-provider"] ?? "github",
        branch:
          branch === undefined ? vcs.branch ?? "main" : validatedBranch(branch),
        ...(triggerDisabled === undefined
          ? { "trigger-disabled": vcs["trigger-disabled"] ?? false }
          : { "trigger-disabled": triggerDisabled }),
      };
    }
    if (Object.keys(attributes).length === 1) {
      throw new Error("At least one Stack setting must be changed");
    }
    const plan = {
      operation: "update_stack",
      organization: this.organization,
      stack_id: current.id,
      stack_name: current.name,
      expected_updated_at: current["updated-at"],
      attributes,
      fetch_configuration: fetchConfiguration,
    };
    return { ...plan, plan_id: planId(plan) };
  }

  async updateStack({ expectedPlanId, ...inputs }) {
    const plan = await this.planUpdateStack(inputs);
    if (plan.plan_id !== expectedPlanId) {
      throw new Error(
        `Refusing stale update: plan is ${plan.plan_id}, expected ${expectedPlanId}`,
      );
    }
    const payload = await this.request(`stacks/${plan.stack_id}`, {
      method: "PATCH",
      body: {
        data: {
          type: "stacks",
          id: plan.stack_id,
          attributes: plan.attributes,
        },
      },
    });
    if (plan.fetch_configuration) {
      await this.request(`stacks/${plan.stack_id}/fetch-latest-from-vcs`, {
        method: "POST",
      });
    }
    return {
      updated: true,
      stack: resourceSummary(payload.data),
      fetched_configuration: plan.fetch_configuration,
      plan_id: expectedPlanId,
    };
  }

  async requireAllowedStack(stackName) {
    if (!this.allowedStackNames.has(stackName)) {
      throw new Error(`Stack ${stackName} is not in TFE_STACK_ALLOWLIST`);
    }
    const stack = (await this.allowedStacks()).find(({ name }) => name === stackName);
    if (!stack) {
      throw new Error(
        `Allowed Stack ${stackName} does not exist in organization ${this.organization}`,
      );
    }
    return stack;
  }

  async deployments(stackId) {
    assertId(stackId, "st", "stack_id");
    const payload = await this.request(
      `stacks/${stackId}/stack-deployments?page%5Bsize%5D=100`,
    );
    return payload.data;
  }

  async runsForStack(stackName) {
    const stack = await this.requireAllowedStack(stackName);
    const deployments = await this.deployments(stack.id);
    const runLists = await Promise.all(
      deployments.map(async (deployment) => {
        const name = deployment.attributes.name;
        const payload = await this.request(
          `stacks/${stack.id}/stack-deployments/${encodeURIComponent(name)}/stack-deployment-runs?page%5Bsize%5D=100`,
        );
        return payload.data.map((run) => ({
          stack: stack.name,
          stack_id: stack.id,
          ...resourceSummary(run),
        }));
      }),
    );
    return runLists.flat();
  }

  async listRuns({ stackName, pendingOnly = true } = {}) {
    const names = stackName ? [stackName] : [...this.allowedStackNames];
    const results = await Promise.all(
      names.map(async (name) => {
        try {
          return await this.runsForStack(name);
        } catch (error) {
          if (String(error.message).includes("does not exist")) {
            return [];
          }
          throw error;
        }
      }),
    );
    return results
      .flat()
      .filter((run) => !pendingOnly || !terminalStatuses.has(run.status))
      .sort((left, right) =>
        String(right["created-at"]).localeCompare(String(left["created-at"])),
      );
  }

  async requireRun(stackName, runId) {
    assertId(runId, "sdr", "run_id");
    const listed = (await this.runsForStack(stackName)).find(({ id }) => id === runId);
    if (!listed) {
      throw new Error(`Run ${runId} does not belong to allowed Stack ${stackName}`);
    }
    const payload = await this.request(`stack-deployment-runs/${runId}`);
    return {
      stack: stackName,
      ...resourceSummary(payload.data),
    };
  }

  async inspectRun(stackName, runId) {
    const run = await this.requireRun(stackName, runId);
    const stepsPayload = await this.request(
      `stack-deployment-runs/${runId}/stack-deployment-steps?page%5Bsize%5D=100`,
    );

    const steps = await Promise.all(
      stepsPayload.data.map(async (step) => {
        const diagnosticsPayload = await this.request(
          `stack-deployment-steps/${step.id}/stack-diagnostics?page%5Bsize%5D=100`,
        );
        let planDescription = null;
        if (step.attributes["operation-type"] === "plan") {
          try {
            planDescription = boundedArtifact(
              await this.request(
                `stack-deployment-steps/${step.id}/artifacts?name=plan-description`,
                { accept: "text/plain, application/json" },
              ),
            );
          } catch (error) {
            planDescription = { unavailable: error.message };
          }
        }
        return {
          ...resourceSummary(step),
          diagnostics: diagnosticsPayload.data.map(resourceSummary),
          plan_description: planDescription,
        };
      }),
    );

    return { run, steps };
  }

  async approveRun({
    stackName,
    runId,
    expectedConfigurationId,
    reason,
  }) {
    assertId(expectedConfigurationId, "stc", "expected_configuration_id");
    const inspection = await this.inspectRun(stackName, runId);
    const configurationId =
      inspection.run.relationships?.["stack-configuration"]?.id;

    if (configurationId !== expectedConfigurationId) {
      throw new Error(
        `Refusing stale approval: run configuration is ${configurationId}, expected ${expectedConfigurationId}`,
      );
    }
    if (!approvableStatuses.has(normalizeStatus(inspection.run.status))) {
      throw new Error(
        `Run ${runId} is ${inspection.run.status}, not pending operator approval`,
      );
    }

    const pendingPlan = inspection.steps.find(
      (step) =>
        step["operation-type"] === "plan" &&
        normalizeStatus(step.status) === "pending_operator",
    );
    if (!pendingPlan) {
      throw new Error(`Run ${runId} has no plan step pending operator approval`);
    }

    await this.request(
      `stack-deployment-runs/${runId}/approve-all-plans?all_plans=false`,
      {
        method: "POST",
        body: { reason },
      },
    );

    return {
      approved: true,
      stack: stackName,
      run_id: runId,
      configuration_id: configurationId,
      approved_plan_step_id: pendingPlan.id,
      all_future_plans: false,
      reason,
    };
  }

  async cancelRun({ stackName, runId, reason }) {
    const run = await this.requireRun(stackName, runId);
    if (terminalStatuses.has(run.status)) {
      throw new Error(`Run ${runId} is already terminal: ${run.status}`);
    }
    await this.request(`stack-deployment-runs/${runId}/cancel?force=false`, {
      method: "POST",
    });
    return {
      canceled: true,
      stack: stackName,
      run_id: runId,
      forced: false,
      reason,
    };
  }
}

export function clientFromEnv(fetchImpl = fetch) {
  return new HcpStacksClient({
    token: readSecretEnv("TFE_TOKEN"),
    address: process.env.TFE_ADDRESS,
    organization: process.env.TFE_ORGANIZATION,
    allowedStackNames: csv(process.env.TFE_STACK_ALLOWLIST),
    allowedProjectIds: csv(process.env.TFE_STACK_PROJECT_ALLOWLIST),
    allowedRepositories: csv(process.env.TFE_STACK_REPOSITORY_ALLOWLIST),
    allowedWorkingDirectoryPrefixes: csv(
      process.env.TFE_STACK_DIRECTORY_PREFIX_ALLOWLIST,
    ),
    githubAppInstallationId:
      process.env.TFE_STACK_GITHUB_APP_INSTALLATION_ID,
    fetchImpl,
  });
}
