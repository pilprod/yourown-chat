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
    fetchImpl = fetch,
  }) {
    this.token = required(token, "TFE_TOKEN");
    this.address = new URL(address).origin;
    this.organization = required(organization, "TFE_ORGANIZATION");
    this.allowedStackNames = new Set(allowedStackNames);
    this.fetchImpl = fetchImpl;

    if (this.allowedStackNames.size === 0) {
      throw new Error("TFE_STACK_ALLOWLIST must contain at least one Stack name");
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
          ...(body === undefined
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
    if (!approvableStatuses.has(inspection.run.status)) {
      throw new Error(
        `Run ${runId} is ${inspection.run.status}, not pending operator approval`,
      );
    }

    const pendingPlan = inspection.steps.find(
      (step) =>
        step["operation-type"] === "plan" && step.status === "pending_operator",
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
    allowedStackNames: (process.env.TFE_STACK_ALLOWLIST ?? "")
      .split(",")
      .map((name) => name.trim())
      .filter(Boolean),
    fetchImpl,
  });
}
