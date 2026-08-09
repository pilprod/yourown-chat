import { randomUUID } from "node:crypto";

import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

import { clientFromEnv } from "./hcp-client.mjs";
import { normalizeLegacyToolCall } from "./tool-name-compat.mjs";
import { toolResult } from "./tool-result.mjs";

const port = Number.parseInt(process.env.PORT ?? "3000", 10);
const client = clientFromEnv();
const toolNames = new Set([
  "list_stacks",
  "get_stack_settings",
  "list_configurations",
  "inspect_configuration",
  "plan_configuration",
  "create_configuration",
  "plan_destroy_all",
  "create_destroy_all",
  "plan_create",
  "create",
  "plan_update",
  "update",
  "plan_delete",
  "delete",
  "list_deployment_runs",
  "inspect_deployment_run",
  "approve_deployment_run",
  "cancel_deployment_run",
]);

function createServer() {
  const server = new McpServer({
    name: "yourown-chat-terraform-stacks",
    version: "1.2.0",
  });

  server.registerTool(
    "list_stacks",
    {
      title: "HCP Terraform · Stacks · List",
      description:
        "List only Stacks covered by the committed approval or management policy, including their VCS, project and policy status.",
      inputSchema: {},
      annotations: {
        title: "HCP Terraform · Stacks · List",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async () => toolResult(await client.listStacks()),
  );

  server.registerTool(
    "get_stack_settings",
    {
      title: "HCP Terraform · Stacks · Get settings",
      description:
        "Read one approval-allowlisted or management-policy-compliant Stack, including project, VCS and working-directory settings.",
      inputSchema: {
        stack_name: z.string().min(1),
      },
      annotations: {
        title: "HCP Terraform · Stacks · Get settings",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name }) => toolResult(await client.stackSettings(stack_name)),
  );

  server.registerTool(
    "list_configurations",
    {
      title: "HCP Terraform · Configurations · List",
      description:
        "List prepared, pending and failed configuration versions for one allowlisted Stack, including sequence, status and VCS ingress metadata.",
      inputSchema: {
        stack_name: z.string().min(1),
        page_number: z.number().int().min(1).optional().default(1),
        page_size: z.number().int().min(1).max(100).optional().default(20),
      },
      annotations: {
        title: "HCP Terraform · Configurations · List",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name, page_number, page_size }) =>
      toolResult(
        await client.listConfigurations({
          stackName: stack_name,
          pageNumber: page_number,
          pageSize: page_size,
        }),
      ),
  );

  server.registerTool(
    "inspect_configuration",
    {
      title: "HCP Terraform · Configurations · Inspect",
      description:
        "Inspect one exact Stack configuration with its preparation diagnostics and deployment-group summaries. Use this when a fetched configuration did not create deployment runs.",
      inputSchema: {
        stack_name: z.string().min(1),
        configuration_id: z.string().regex(/^stc-[A-Za-z0-9]+$/),
      },
      annotations: {
        title: "HCP Terraform · Configurations · Inspect",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name, configuration_id }) =>
      toolResult(
        await client.inspectConfiguration(stack_name, configuration_id),
      ),
  );

  const configurationInputSchema = {
    stack_name: z.string().min(1),
    source: z.enum(["fetch", "reuse"]).optional().default("fetch"),
    speculative: z.boolean().optional().default(false),
  };

  server.registerTool(
    "plan_configuration",
    {
      title: "HCP Terraform · Configurations · Plan creation",
      description:
        "Preview fetching the latest VCS content or reusing the latest content for one management-allowed Stack. This never requests infrastructure destruction.",
      inputSchema: configurationInputSchema,
      annotations: {
        title: "HCP Terraform · Configurations · Plan creation",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name, source, speculative }) =>
      toolResult(
        await client.planCreateConfiguration({
          stackName: stack_name,
          source,
          speculative,
          destroyAll: false,
        }),
      ),
  );

  server.registerTool(
    "create_configuration",
    {
      title: "HCP Terraform · Configurations · Create",
      description:
        "Create exactly the previously previewed VCS fetch or reuse configuration. It may start plans but cannot request destroy-all and does not approve any deployment.",
      inputSchema: {
        ...configurationInputSchema,
        expected_plan_id: z.string().regex(/^sha256:[a-f0-9]{64}$/),
        confirmation: z.literal("CREATE_CONFIGURATION"),
      },
      annotations: {
        title: "HCP Terraform · Configurations · Create",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ stack_name, source, speculative, expected_plan_id }) =>
      toolResult(
        await client.createConfiguration({
          stackName: stack_name,
          source,
          speculative,
          destroyAll: false,
          expectedPlanId: expected_plan_id,
        }),
      ),
  );

  server.registerTool(
    "plan_destroy_all",
    {
      title: "HCP Terraform · Configurations · Plan destroy all",
      description:
        "Preview a new configuration that reuses the latest Stack content and requests destruction of every deployment. This only creates a guarded plan; later deployment approvals remain separate.",
      inputSchema: {
        stack_name: z.string().min(1),
      },
      annotations: {
        title: "HCP Terraform · Configurations · Plan destroy all",
        readOnlyHint: true,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name }) =>
      toolResult(
        await client.planCreateConfiguration({
          stackName: stack_name,
          source: "reuse",
          speculative: false,
          destroyAll: true,
        }),
      ),
  );

  server.registerTool(
    "create_destroy_all",
    {
      title: "HCP Terraform · Configurations · Create destroy-all plan",
      description:
        "Create exactly the previewed destroy-all Stack configuration. Requires its plan hash and DESTROY_ALL confirmation; every resulting deployment plan must still be inspected and approved separately.",
      inputSchema: {
        stack_name: z.string().min(1),
        expected_plan_id: z.string().regex(/^sha256:[a-f0-9]{64}$/),
        confirmation: z.literal("DESTROY_ALL"),
      },
      annotations: {
        title: "HCP Terraform · Configurations · Create destroy-all plan",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ stack_name, expected_plan_id }) =>
      toolResult(
        await client.createConfiguration({
          stackName: stack_name,
          source: "reuse",
          speculative: false,
          destroyAll: true,
          expectedPlanId: expected_plan_id,
        }),
      ),
  );

  const createInputSchema = {
    name: z.string().regex(/^[A-Za-z0-9_-]{1,90}$/),
    description: z.string().max(500).optional().default(""),
    project_id: z.string().regex(/^prj-[A-Za-z0-9]+$/),
    repository: z.string().regex(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/),
    working_directory: z.string().min(1).max(255),
    branch: z.string().min(1).max(255).optional().default("main"),
    speculative_enabled: z.boolean().optional().default(false),
    trigger_disabled: z.boolean().optional().default(false),
    fetch_configuration: z.boolean().optional().default(true),
  };

  server.registerTool(
    "plan_create",
    {
      title: "HCP Terraform · Stacks · Plan creation",
      description:
        "Validate and preview creation of one VCS-backed Stack against committed project, repository and directory policies. Makes no changes.",
      inputSchema: createInputSchema,
      annotations: {
        title: "HCP Terraform · Stacks · Plan creation",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async (input) =>
      toolResult(
        await client.planCreateStack({
          name: input.name,
          description: input.description,
          projectId: input.project_id,
          repository: input.repository,
          workingDirectory: input.working_directory,
          branch: input.branch,
          speculativeEnabled: input.speculative_enabled,
          triggerDisabled: input.trigger_disabled,
          fetchConfiguration: input.fetch_configuration,
        }),
      ),
  );

  server.registerTool(
    "create",
    {
      title: "HCP Terraform · Stacks · Create",
      description:
        "Create exactly the previously previewed VCS-backed Stack. The plan hash and literal CREATE_STACK confirmation are mandatory. Creation never modifies the separate approval allowlist.",
      inputSchema: {
        ...createInputSchema,
        expected_plan_id: z.string().regex(/^sha256:[a-f0-9]{64}$/),
        confirmation: z.literal("CREATE_STACK"),
      },
      annotations: {
        title: "HCP Terraform · Stacks · Create",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async (input) =>
      toolResult(
        await client.createStack({
          name: input.name,
          description: input.description,
          projectId: input.project_id,
          repository: input.repository,
          workingDirectory: input.working_directory,
          branch: input.branch,
          speculativeEnabled: input.speculative_enabled,
          triggerDisabled: input.trigger_disabled,
          fetchConfiguration: input.fetch_configuration,
          expectedPlanId: input.expected_plan_id,
        }),
      ),
  );

  const updateInputSchema = {
    stack_name: z.string().min(1),
    description: z.string().max(500).optional(),
    working_directory: z.string().min(1).max(255).optional(),
    branch: z.string().min(1).max(255).optional(),
    speculative_enabled: z.boolean().optional(),
    trigger_disabled: z.boolean().optional(),
    fetch_configuration: z.boolean().optional().default(false),
  };

  server.registerTool(
    "plan_update",
    {
      title: "HCP Terraform · Stacks · Plan update",
      description:
        "Read current settings and preview a policy-constrained Stack update. Repository, project, execution mode and Stack name cannot be changed.",
      inputSchema: updateInputSchema,
      annotations: {
        title: "HCP Terraform · Stacks · Plan update",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async (input) =>
      toolResult(
        await client.planUpdateStack({
          stackName: input.stack_name,
          description: input.description,
          workingDirectory: input.working_directory,
          branch: input.branch,
          speculativeEnabled: input.speculative_enabled,
          triggerDisabled: input.trigger_disabled,
          fetchConfiguration: input.fetch_configuration,
        }),
      ),
  );

  server.registerTool(
    "update",
    {
      title: "HCP Terraform · Stacks · Update",
      description:
        "Apply exactly a previously previewed policy-constrained Stack update. Requires the exact plan hash and UPDATE_STACK confirmation.",
      inputSchema: {
        ...updateInputSchema,
        expected_plan_id: z.string().regex(/^sha256:[a-f0-9]{64}$/),
        confirmation: z.literal("UPDATE_STACK"),
      },
      annotations: {
        title: "HCP Terraform · Stacks · Update",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async (input) =>
      toolResult(
        await client.updateStack({
          stackName: input.stack_name,
          description: input.description,
          workingDirectory: input.working_directory,
          branch: input.branch,
          speculativeEnabled: input.speculative_enabled,
          triggerDisabled: input.trigger_disabled,
          fetchConfiguration: input.fetch_configuration,
          expectedPlanId: input.expected_plan_id,
        }),
      ),
  );

  server.registerTool(
    "plan_delete",
    {
      title: "HCP Terraform · Stacks · Plan deletion",
      description:
        "Preview deletion of one management-allowed Stack. Refuses to plan while any deployment remains, preventing orphaned infrastructure.",
      inputSchema: {
        stack_name: z.string().min(1),
      },
      annotations: {
        title: "HCP Terraform · Stacks · Plan deletion",
        readOnlyHint: true,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name }) =>
      toolResult(await client.planDeleteStack({ stackName: stack_name })),
  );

  server.registerTool(
    "delete",
    {
      title: "HCP Terraform · Stacks · Delete empty Stack",
      description:
        "Delete exactly the previously previewed empty Stack. The Stack must still contain zero deployments and requires the exact plan hash plus DELETE_EMPTY_STACK confirmation.",
      inputSchema: {
        stack_name: z.string().min(1),
        expected_plan_id: z.string().regex(/^sha256:[a-f0-9]{64}$/),
        confirmation: z.literal("DELETE_EMPTY_STACK"),
      },
      annotations: {
        title: "HCP Terraform · Stacks · Delete empty Stack",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ stack_name, expected_plan_id }) =>
      toolResult(
        await client.deleteStack({
          stackName: stack_name,
          expectedPlanId: expected_plan_id,
        }),
      ),
  );

  server.registerTool(
    "list_deployment_runs",
    {
      title: "HCP Terraform · Stacks · List deployments",
      description:
        "List deployment runs from the explicitly allowed HCP Terraform Stacks.",
      inputSchema: {
        stack_name: z.string().optional(),
        pending_only: z.boolean().optional().default(true),
      },
      annotations: {
        title: "HCP Terraform · Stacks · List deployments",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name, pending_only }) =>
      toolResult(
        await client.listRuns({
          stackName: stack_name,
          pendingOnly: pending_only,
        }),
      ),
  );

  server.registerTool(
    "inspect_deployment_run",
    {
      title: "HCP Terraform · Stacks · Inspect deployment",
      description:
        "Read a Stack deployment run and a sanitized action-only plan summary before approval. Resource values and diagnostic content are always omitted.",
      inputSchema: {
        stack_name: z.string().min(1),
        run_id: z.string().regex(/^sdr-[A-Za-z0-9]+$/),
      },
      annotations: {
        title: "HCP Terraform · Stacks · Inspect deployment",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name, run_id }) =>
      toolResult(await client.inspectRun(stack_name, run_id)),
  );

  server.registerTool(
    "approve_deployment_run",
    {
      title: "HCP Terraform · Stacks · Approve deployment",
      description:
        "Approve only the currently pending plan in one allowlisted Stack deployment run, including a later convergence plan. Inspect first, then pass its exact configuration ID and APPROVE confirmation.",
      inputSchema: {
        stack_name: z.string().min(1),
        run_id: z.string().regex(/^sdr-[A-Za-z0-9]+$/),
        expected_configuration_id: z.string().regex(/^stc-[A-Za-z0-9]+$/),
        reason: z.string().min(8).max(500),
        confirmation: z.literal("APPROVE"),
      },
      annotations: {
        title: "HCP Terraform · Stacks · Approve deployment",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({
      stack_name,
      run_id,
      expected_configuration_id,
      reason,
    }) =>
      toolResult(
        await client.approveRun({
          stackName: stack_name,
          runId: run_id,
          expectedConfigurationId: expected_configuration_id,
          reason,
        }),
      ),
  );

  server.registerTool(
    "cancel_deployment_run",
    {
      title: "HCP Terraform · Stacks · Cancel deployment",
      description:
        "Cancel one non-terminal deployment run belonging to an allowlisted Stack. This never force-cancels.",
      inputSchema: {
        stack_name: z.string().min(1),
        run_id: z.string().regex(/^sdr-[A-Za-z0-9]+$/),
        reason: z.string().min(8).max(500),
        confirmation: z.literal("CANCEL"),
      },
      annotations: {
        title: "HCP Terraform · Stacks · Cancel deployment",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ stack_name, run_id, reason }) =>
      toolResult(
        await client.cancelRun({
          stackName: stack_name,
          runId: run_id,
          reason,
        }),
      ),
  );

  return server;
}

const app = express();
app.use(express.json({ limit: "1mb" }));

const transports = new Map();

app.get("/health", (_request, response) => {
  response.json({ status: "ok" });
});

app.post("/mcp", async (request, response) => {
  try {
    const sessionId = request.header("mcp-session-id");
    let transport = sessionId ? transports.get(sessionId) : undefined;

    if (!transport && !sessionId && isInitializeRequest(request.body)) {
      const server = createServer();
      transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        onsessioninitialized: (initializedSessionId) => {
          transports.set(initializedSessionId, transport);
        },
      });
      transport.onclose = () => {
        if (transport.sessionId) {
          transports.delete(transport.sessionId);
        }
      };
      await server.connect(transport);
    }

    if (!transport) {
      response.status(400).json({
        jsonrpc: "2.0",
        error: { code: -32000, message: "Invalid or missing MCP session" },
        id: null,
      });
      return;
    }

    const body = normalizeLegacyToolCall(
      request.body,
      "terraform_stacks_",
      toolNames,
    );
    await transport.handleRequest(request, response, body);
  } catch (error) {
    console.error(error);
    if (!response.headersSent) {
      response.status(500).json({
        jsonrpc: "2.0",
        error: { code: -32603, message: error.message },
        id: null,
      });
    }
  }
});

for (const method of ["get", "delete"]) {
  app[method]("/mcp", async (request, response) => {
    const sessionId = request.header("mcp-session-id");
    const transport = sessionId ? transports.get(sessionId) : undefined;
    if (!transport) {
      response.status(400).send("Invalid or missing MCP session");
      return;
    }
    await transport.handleRequest(request, response);
  });
}

app.listen(port, "0.0.0.0", () => {
  console.log(`Terraform Stacks MCP listening on 0.0.0.0:${port}`);
});
