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

function diagnosticMetadata(resource) {
  const summary = resourceSummary(resource);
  return {
    id: summary.id,
    severity: summary.severity ?? "unknown",
    content_omitted: true,
  };
}

function planDescriptionSummary(value, maxResources = 5_000) {
  let plan = value;
  if (typeof plan === "string") {
    try {
      plan = JSON.parse(plan);
    } catch {
      return {
        format: "sanitized-action-summary-v1",
        unavailable:
          "The plan description was not valid JSON; the raw artifact was omitted.",
      };
    }
  }

  if (!plan || typeof plan !== "object" || Array.isArray(plan)) {
    return {
      format: "sanitized-action-summary-v1",
      unavailable:
        "The plan description had an unsupported shape; the raw artifact was omitted.",
    };
  }

  const components = Array.isArray(plan.components)
    ? plan.components.map((component) => ({
        address: component.address,
        component_address: component.component_address,
        actions: component.actions ?? [],
        complete: component.complete,
      }))
    : [];

  const resourceInstances = Array.isArray(plan.resource_instances)
    ? plan.resource_instances
    : [];
  const resourceChanges = resourceInstances
    .slice(0, maxResources)
    .map((resource) => ({
      component_instance_address: resource.component_instance_address,
      address: resource.address,
      mode: resource.mode,
      type: resource.type,
      provider_name: resource.provider_name,
      resource_name: resource.resource_name,
      index: resource.index,
      action_reason: resource.action_reason,
      actions: resource.change?.actions ?? [],
    }));

  const outputEntries = Array.isArray(plan.output_changes)
    ? plan.output_changes.map((output) => [output.address, output])
    : Object.entries(plan.output_changes ?? {});
  const outputChanges = outputEntries.map(([address, output]) => ({
    address,
    actions: output?.change?.actions ?? output?.actions ?? [],
  }));

  return {
    format: "sanitized-action-summary-v1",
    applyable: plan.applyable,
    plan_mode: plan.plan_mode,
    components,
    resource_changes: resourceChanges,
    resource_change_count: resourceInstances.length,
    resource_changes_truncated: resourceInstances.length > maxResources,
    output_changes: outputChanges,
    values_omitted: true,
  };
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

  async allStacks() {
    const payload = await this.request(
      `organizations/${encodeURIComponent(this.organization)}/stacks?page%5Bsize%5D=100`,
    );
    return payload.data;
  }

  stackPolicy(stack) {
    const summary = resourceSummary(stack);
    const repository = summary["vcs-repo"]?.identifier;
    const projectId = summary.relationships?.project?.id;
    const workingDirectory = summary["working-directory"] ?? "";
    const directoryAllowed = workingDirectory
      ? this.allowedWorkingDirectoryPrefixes.some((prefix) =>
          workingDirectory === prefix.replace(/\/+$/, "") ||
          workingDirectory.startsWith(
            `${prefix.replace(/\/+$/, "")}/`,
          ),
        )
      : false;
    const managementAllowed =
      this.allowedProjectIds.has(projectId) &&
      this.allowedRepositories.has(repository) &&
      directoryAllowed;
    return {
      approval_allowed:
        this.allowedStackNames.has(summary.name) && managementAllowed,
      management_allowed: managementAllowed,
    };
  }

  async listStacks() {
    return (await this.allStacks())
      .map((stack) => ({
        ...resourceSummary(stack),
        policy: this.stackPolicy(stack),
      }))
      .filter(
        ({ policy }) =>
          policy.approval_allowed || policy.management_allowed,
      )
      .sort((left, right) => left.name.localeCompare(right.name));
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
        normalized === prefix.replace(/\/+$/, "") ||
        normalized.startsWith(`${prefix.replace(/\/+$/, "")}/`),
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
    const policy = this.stackPolicy(payload.data);
    if (!policy.approval_allowed && !policy.management_allowed) {
      throw new Error(`Stack ${stackName} is outside the committed management policy`);
    }
    return {
      ...settings,
      policy,
    };
  }

  async listConfigurations({
    stackName,
    pageNumber = 1,
    pageSize = 20,
  }) {
    const stack = await this.requireAllowedStack(stackName);
    const boundedPage = Math.max(1, pageNumber);
    const boundedSize = Math.min(Math.max(1, pageSize), 100);
    const payload = await this.request(
      `stacks/${stack.id}/stack-configurations?` +
        `page%5Bnumber%5D=${boundedPage}&page%5Bsize%5D=${boundedSize}`,
    );
    return {
      stack: stackName,
      configurations: payload.data.map(resourceSummary),
      pagination: payload.meta?.pagination ?? null,
    };
  }

  async inspectConfiguration(stackName, configurationId) {
    assertId(configurationId, "stc", "configuration_id");
    const stack = await this.requireAllowedStack(stackName);
    const configuration = await this.request(
      `stack-configurations/${configurationId}`,
    );
    if (configuration.data.relationships?.stack?.data?.id !== stack.id) {
      throw new Error(
        `Stack configuration ${configurationId} does not belong to ${stackName}`,
      );
    }
    const [diagnostics, deploymentGroups] = await Promise.all([
      this.request(
        `stack-configurations/${configurationId}/stack-diagnostics?page%5Bsize%5D=100`,
      ),
      this.request(
        `stack-configurations/${configurationId}/stack-deployment-group-summaries?page%5Bsize%5D=100`,
      ),
    ]);
    return {
      stack: stackName,
      configuration: resourceSummary(configuration.data),
      diagnostics: diagnostics.data.map(resourceSummary),
      deployment_groups: deploymentGroups.data.map(resourceSummary),
    };
  }

  async latestConfigurationIdentity(stackName) {
    const stack = await this.stackSettings(stackName);
    const payload = await this.request(
      `stacks/${stack.id}/stack-configurations?` +
        "page%5Bnumber%5D=1&page%5Bsize%5D=1",
    );
    const latest = payload.data[0]
      ? resourceSummary(payload.data[0])
      : null;
    return latest
      ? {
          id: latest.id,
          sequence_number: latest["sequence-number"],
          status: latest.status,
        }
      : null;
  }

  async planCreateConfiguration({
    stackName,
    source,
    speculative = false,
    destroyAll = false,
  }) {
    if (!["fetch", "reuse"].includes(source)) {
      throw new Error("configuration source must be fetch or reuse");
    }
    if (destroyAll && (source !== "reuse" || speculative)) {
      throw new Error(
        "destroy-all requires source=reuse and speculative=false",
      );
    }
    const current = await this.stackSettings(stackName);
    if (!current.policy.management_allowed) {
      throw new Error(`Stack ${stackName} is not management-allowed`);
    }
    const latestConfiguration =
      await this.latestConfigurationIdentity(stackName);
    if (source === "reuse" && !latestConfiguration) {
      throw new Error(
        `Stack ${stackName} has no configuration available for reuse`,
      );
    }
    const plan = {
      operation: destroyAll
        ? "destroy_all_stack_configuration"
        : "create_stack_configuration",
      organization: this.organization,
      stack_id: current.id,
      stack_name: current.name,
      source,
      attributes: {
        speculative,
        "destroy-all": destroyAll,
      },
      expected_latest_configuration: latestConfiguration,
    };
    return { ...plan, plan_id: planId(plan) };
  }

  async createConfiguration({ expectedPlanId, ...inputs }) {
    const plan = await this.planCreateConfiguration(inputs);
    if (plan.plan_id !== expectedPlanId) {
      throw new Error(
        `Refusing stale configuration creation: plan is ${plan.plan_id}, expected ${expectedPlanId}`,
      );
    }
    const payload = await this.request(
      `stacks/${plan.stack_id}/stack-configurations?source=${plan.source}`,
      {
        method: "POST",
        body: {
          data: {
            type: "stack-configurations",
            attributes: plan.attributes,
          },
        },
      },
    );
    return {
      created: true,
      stack: plan.stack_name,
      source: plan.source,
      destroy_all: plan.attributes["destroy-all"],
      configuration: resourceSummary(payload.data),
      plan_id: expectedPlanId,
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

  async planDeleteStack({ stackName }) {
    const current = await this.stackSettings(stackName);
    if (!current.policy.management_allowed) {
      throw new Error(`Stack ${stackName} is not management-allowed`);
    }
    const deployments = await this.deployments(current.id);
    if (deployments.length !== 0) {
      throw new Error(
        `Stack ${stackName} still contains ${deployments.length} deployment(s); destroy them before deletion`,
      );
    }
    const latestConfiguration =
      await this.latestConfigurationIdentity(stackName);
    const plan = {
      operation: "delete_empty_stack",
      organization: this.organization,
      stack_id: current.id,
      stack_name: current.name,
      expected_updated_at: current["updated-at"],
      expected_latest_configuration: latestConfiguration,
      deployment_count: 0,
    };
    return { ...plan, plan_id: planId(plan) };
  }

  async deleteStack({ stackName, expectedPlanId }) {
    const plan = await this.planDeleteStack({ stackName });
    if (plan.plan_id !== expectedPlanId) {
      throw new Error(
        `Refusing stale Stack deletion: plan is ${plan.plan_id}, expected ${expectedPlanId}`,
      );
    }
    await this.request(`stacks/${plan.stack_id}`, { method: "DELETE" });
    return {
      deleted: true,
      stack: plan.stack_name,
      stack_id: plan.stack_id,
      deployment_count: 0,
      plan_id: expectedPlanId,
    };
  }

  async requireAllowedStack(stackName) {
    if (!this.allowedStackNames.has(stackName)) {
      throw new Error(`Stack ${stackName} is not in TFE_STACK_ALLOWLIST`);
    }
    const stack = await this.stackSettings(stackName);
    if (!stack.policy.approval_allowed) {
      throw new Error(
        `Allowed Stack ${stackName} is outside the committed project, repository, or directory policy`,
      );
    }
    return { id: stack.id, name: stack.name };
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
            planDescription = planDescriptionSummary(
              await this.request(
                `stack-deployment-steps/${step.id}/artifacts?name=plan-description`,
                { accept: "text/plain, application/json" },
              ),
            );
          } catch {
            planDescription = {
              format: "sanitized-action-summary-v1",
              unavailable: "The sanitized plan summary could not be retrieved.",
            };
          }
        }
        return {
          ...resourceSummary(step),
          diagnostics: diagnosticsPayload.data.map(diagnosticMetadata),
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

    const existingApproval =
      inspection.run.relationships?.["stack-approval"]?.id;
    if (existingApproval) {
      // A run-level approval can be created only once. Stacks may produce
      // another operator-gated convergence plan after an apply; advance that
      // exact reviewed step instead of trying to recreate the run approval.
      await this.request(
        `stack-deployment-steps/${pendingPlan.id}/advance`,
        { method: "POST" },
      );
    } else {
      await this.request(
        `stack-deployment-runs/${runId}/approve-all-plans?all_plans=false`,
        {
          method: "POST",
          body: { reason },
        },
      );
    }

    return {
      approved: true,
      stack: stackName,
      run_id: runId,
      configuration_id: configurationId,
      approved_plan_step_id: pendingPlan.id,
      approval_scope: existingApproval ? "step" : "run",
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
