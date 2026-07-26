import { randomUUID } from "node:crypto";

import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

import { clientFromEnv } from "./hcp-client.mjs";
import { toolResult } from "./tool-result.mjs";

const port = Number.parseInt(process.env.PORT ?? "3000", 10);
const client = clientFromEnv();

function createServer() {
  const server = new McpServer({
    name: "yourown-chat-terraform-stacks",
    version: "1.1.0",
  });

  server.registerTool(
    "terraform_stacks_get_stack_settings",
    {
      description:
        "Read one approval-allowlisted or management-policy-compliant Stack, including project, VCS and working-directory settings.",
      inputSchema: {
        stack_name: z.string().min(1),
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ stack_name }) => toolResult(await client.stackSettings(stack_name)),
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
    "terraform_stacks_plan_create",
    {
      description:
        "Validate and preview creation of one VCS-backed Stack against committed project, repository and directory policies. Makes no changes.",
      inputSchema: createInputSchema,
      annotations: {
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
    "terraform_stacks_create",
    {
      description:
        "Create exactly the previously previewed VCS-backed Stack. The plan hash and literal CREATE_STACK confirmation are mandatory. Creation never modifies the separate approval allowlist.",
      inputSchema: {
        ...createInputSchema,
        expected_plan_id: z.string().regex(/^sha256:[a-f0-9]{64}$/),
        confirmation: z.literal("CREATE_STACK"),
      },
      annotations: {
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
    "terraform_stacks_plan_update",
    {
      description:
        "Read current settings and preview a policy-constrained Stack update. Repository, project, execution mode and Stack name cannot be changed.",
      inputSchema: updateInputSchema,
      annotations: {
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
    "terraform_stacks_update",
    {
      description:
        "Apply exactly a previously previewed policy-constrained Stack update. Requires the exact plan hash and UPDATE_STACK confirmation.",
      inputSchema: {
        ...updateInputSchema,
        expected_plan_id: z.string().regex(/^sha256:[a-f0-9]{64}$/),
        confirmation: z.literal("UPDATE_STACK"),
      },
      annotations: {
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
    "terraform_stacks_list_deployment_runs",
    {
      description:
        "List deployment runs from the explicitly allowed HCP Terraform Stacks.",
      inputSchema: {
        stack_name: z.string().optional(),
        pending_only: z.boolean().optional().default(true),
      },
      annotations: {
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
    "terraform_stacks_inspect_deployment_run",
    {
      description:
        "Read a Stack deployment run, every plan/apply step, diagnostics, and plan description before approval.",
      inputSchema: {
        stack_name: z.string().min(1),
        run_id: z.string().regex(/^sdr-[A-Za-z0-9]+$/),
      },
      annotations: {
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
    "terraform_stacks_approve_deployment_run",
    {
      description:
        "Approve only the currently pending plan in one allowlisted Stack deployment run. Inspect first, then pass its exact configuration ID and APPROVE confirmation.",
      inputSchema: {
        stack_name: z.string().min(1),
        run_id: z.string().regex(/^sdr-[A-Za-z0-9]+$/),
        expected_configuration_id: z.string().regex(/^stc-[A-Za-z0-9]+$/),
        reason: z.string().min(8).max(500),
        confirmation: z.literal("APPROVE"),
      },
      annotations: {
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
    "terraform_stacks_cancel_deployment_run",
    {
      description:
        "Cancel one non-terminal deployment run belonging to an allowlisted Stack. This never force-cancels.",
      inputSchema: {
        stack_name: z.string().min(1),
        run_id: z.string().regex(/^sdr-[A-Za-z0-9]+$/),
        reason: z.string().min(8).max(500),
        confirmation: z.literal("CANCEL"),
      },
      annotations: {
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

    await transport.handleRequest(request, response, request.body);
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
