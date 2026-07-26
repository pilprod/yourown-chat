import { randomUUID } from "node:crypto";

import express from "express";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  CallToolRequestSchema,
  isInitializeRequest,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { artifactVulnerabilityClientFromEnv } from "./artifact-vulnerability-client.mjs";
import { cloudBuildClientFromEnv } from "./cloud-build-client.mjs";
import { cloudDeployClientFromEnv } from "./cloud-deploy-client.mjs";
import { toolError, toolResult } from "./tool-result.mjs";

const childTransport = new StdioClientTransport({
  command: process.env.OBSERVABILITY_MCP_COMMAND ?? "node",
  args: [
    process.env.OBSERVABILITY_MCP_ENTRYPOINT ??
      "/app/node_modules/@google-cloud/observability-mcp/dist/bundle.js",
  ],
  stderr: "inherit",
});
const observability = new Client(
  { name: "yourown-chat-google-cloud-aggregator", version: "1.0.0" },
  { capabilities: {} },
);
await observability.connect(childTransport);
const officialTools = (await observability.listTools()).tools;

const deployEnabled =
  (process.env.GOOGLE_CLOUD_DEPLOY_ENABLED ?? "true").toLowerCase() === "true";
const deploy = deployEnabled ? cloudDeployClientFromEnv() : null;
const builds = deployEnabled ? cloudBuildClientFromEnv() : null;
const security = artifactVulnerabilityClientFromEnv();

const buildTools = [
  {
    name: "google_cloud_build_list_builds",
    description:
      "List recent regional Cloud Build executions with status, trigger substitutions, source, images and per-step state.",
    inputSchema: {
      type: "object",
      properties: {
        page_size: { type: "integer", minimum: 1, maximum: 100, default: 20 },
        page_token: { type: "string" },
      },
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_build_inspect_build",
    description:
      "Inspect one Cloud Build execution, including every step, timing, source provenance, produced images, warnings and failure information.",
    inputSchema: {
      type: "object",
      properties: {
        build_id: { type: "string" },
      },
      required: ["build_id"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_build_list_build_logs",
    description:
      "Read ordered Cloud Logging entries for one Cloud Build execution, including text, JSON/proto payloads, severity and timestamps.",
    inputSchema: {
      type: "object",
      properties: {
        build_id: { type: "string" },
        page_size: {
          type: "integer",
          minimum: 1,
          maximum: 1000,
          default: 200,
        },
        page_token: { type: "string" },
      },
      required: ["build_id"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
];

const deployTools = [
  {
    name: "google_cloud_deploy_list_releases",
    description:
      "List recent releases from an explicitly allowlisted yourown-chat Cloud Deploy pipeline.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        page_size: { type: "integer", minimum: 1, maximum: 100, default: 20 },
        page_token: { type: "string" },
      },
      required: ["pipeline"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_inspect_release",
    description:
      "Inspect a frozen Cloud Deploy release, including target artifacts, deploy parameters, image artifacts, render condition and pipeline/target snapshots.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
      },
      required: ["pipeline", "release"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_list_rollouts",
    description:
      "List rollout state for one release in an explicitly allowlisted yourown-chat Cloud Deploy pipeline.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
        page_size: { type: "integer", minimum: 1, maximum: 50, default: 20 },
        page_token: { type: "string" },
      },
      required: ["pipeline", "release"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_inspect_rollout",
    description:
      "Inspect one rollout, including target, approval state, phases, failure reason and etag. Always inspect immediately before approval.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
        rollout: { type: "string" },
      },
      required: ["pipeline", "release", "rollout"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_list_job_runs",
    description:
      "List deploy, verify, predeploy and postdeploy job runs for one rollout with their exact states and execution details.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
        rollout: { type: "string" },
        page_size: { type: "integer", minimum: 1, maximum: 100, default: 50 },
        page_token: { type: "string" },
      },
      required: ["pipeline", "release", "rollout"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_inspect_job_run",
    description:
      "Inspect one Cloud Deploy job run, including deploy/verify/custom-action failure causes, build identifiers and execution timestamps.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
        rollout: { type: "string" },
        job_run: { type: "string" },
      },
      required: ["pipeline", "release", "rollout", "job_run"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_plan_promote",
    description:
      "Validate and preview promotion of one rendered release to an allowlisted target. Makes no changes and returns the exact plan hash required by promote.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
        target: { type: "string" },
      },
      required: ["pipeline", "release", "target"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_promote",
    description:
      "Promote exactly the previously previewed release to an allowlisted target. Requires the exact plan hash and PROMOTE confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
        target: { type: "string" },
        expected_plan_id: {
          type: "string",
          pattern: "^sha256:[a-f0-9]{64}$",
        },
        reason: { type: "string", minLength: 8, maxLength: 500 },
        confirmation: { type: "string", const: "PROMOTE" },
      },
      required: [
        "pipeline",
        "release",
        "target",
        "expected_plan_id",
        "reason",
        "confirmation",
      ],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_approve_rollout",
    description:
      "Approve one allowlisted rollout only after inspection. Requires its exact current etag and APPROVE confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
        rollout: { type: "string" },
        expected_etag: { type: "string", minLength: 1 },
        reason: { type: "string", minLength: 8, maxLength: 500 },
        confirmation: { type: "string", const: "APPROVE" },
      },
      required: [
        "pipeline",
        "release",
        "rollout",
        "expected_etag",
        "reason",
        "confirmation",
      ],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_plan_rollback",
    description:
      "Validate a Cloud Deploy rollback without changing the target. Returns the exact validated release/configuration and plan hash required by rollback.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        target: { type: "string" },
        rollout_id: {
          type: "string",
          description:
            "Caller-selected unique rollout ID, for example rb-mattermost-prod-20260726-01.",
        },
        release: {
          type: "string",
          description:
            "Optional exact previous release. Omit to use Cloud Deploy's last successful release for the target.",
        },
      },
      required: ["pipeline", "target", "rollout_id"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_deploy_rollback",
    description:
      "Create the exact previously validated Cloud Deploy rollback rollout. Requires the plan hash and ROLLBACK confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        target: { type: "string" },
        rollout_id: { type: "string" },
        release: { type: "string" },
        expected_plan_id: {
          type: "string",
          pattern: "^sha256:[a-f0-9]{64}$",
        },
        reason: { type: "string", minLength: 8, maxLength: 500 },
        confirmation: { type: "string", const: "ROLLBACK" },
      },
      required: [
        "pipeline",
        "target",
        "rollout_id",
        "expected_plan_id",
        "reason",
        "confirmation",
      ],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: true,
    },
  },
];

const securityTools = [
  {
    name: "google_cloud_security_list_images",
    description:
      "List immutable Docker images in an allowlisted Artifact Registry repository, with tags, size, timestamps, scan status, and vulnerability counts by severity for every image.",
    inputSchema: {
      type: "object",
      properties: {
        repository: { type: "string" },
        page_size: { type: "integer", minimum: 1, maximum: 100, default: 20 },
        page_token: { type: "string" },
        include_vulnerability_summary: { type: "boolean", default: true },
      },
      required: ["repository"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_security_list_vulnerabilities",
    description:
      "Return full Artifact Analysis vulnerability occurrences for one immutable image digest, including CVE/GHSA ID, effective severity, CVSS score, affected/fixed package versions, remediation, timestamps, and raw occurrence metadata.",
    inputSchema: {
      type: "object",
      properties: {
        repository: { type: "string" },
        image_uri: {
          type: "string",
          description:
            "Immutable Artifact Registry URI ending in @sha256:<64 hex characters>, as returned by google_cloud_security_list_images.",
        },
        page_size: {
          type: "integer",
          minimum: 1,
          maximum: 200,
          default: 100,
        },
        page_token: { type: "string" },
        severity: {
          type: "string",
          enum: [
            "SEVERITY_UNSPECIFIED",
            "MINIMAL",
            "LOW",
            "MEDIUM",
            "HIGH",
            "CRITICAL",
          ],
        },
        fix_available_only: { type: "boolean", default: false },
      },
      required: ["repository", "image_uri"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
  {
    name: "google_cloud_security_get_vulnerability",
    description:
      "Get the complete Artifact Analysis occurrence and its provider Note for one vulnerability. The Note adds the full advisory description, CVSS vectors, related URLs, affected versions, and remediation metadata available from Google.",
    inputSchema: {
      type: "object",
      properties: {
        occurrence_name: {
          type: "string",
          description:
            "Full projects/<configured-project>/occurrences/<id> name returned by google_cloud_security_list_vulnerabilities.",
        },
      },
      required: ["occurrence_name"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
];

const enabledCustomTools = [
  ...securityTools,
  ...(deployEnabled ? [...buildTools, ...deployTools] : []),
];
const customNames = new Set(enabledCustomTools.map((tool) => tool.name));
const duplicate = officialTools.find((tool) => customNames.has(tool.name));
if (duplicate) {
  throw new Error(`Tool name collision with Google MCP: ${duplicate.name}`);
}

async function callCustom(name, input) {
  switch (name) {
    case "google_cloud_build_list_builds":
      return builds.listBuilds({
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "google_cloud_build_inspect_build":
      return builds.inspectBuild({ buildId: input.build_id });
    case "google_cloud_build_list_build_logs":
      return builds.listBuildLogs({
        buildId: input.build_id,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "google_cloud_deploy_list_releases":
      return deploy.listReleases({
        pipeline: input.pipeline,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "google_cloud_deploy_inspect_release":
      return deploy.inspectRelease(input);
    case "google_cloud_deploy_list_rollouts":
      return deploy.listRollouts({
        pipeline: input.pipeline,
        release: input.release,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "google_cloud_deploy_inspect_rollout":
      return deploy.inspectRollout(input);
    case "google_cloud_deploy_list_job_runs":
      return deploy.listJobRuns({
        pipeline: input.pipeline,
        release: input.release,
        rollout: input.rollout,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "google_cloud_deploy_inspect_job_run":
      return deploy.inspectJobRun({
        pipeline: input.pipeline,
        release: input.release,
        rollout: input.rollout,
        jobRun: input.job_run,
      });
    case "google_cloud_deploy_plan_promote":
      return deploy.planPromote(input);
    case "google_cloud_deploy_promote":
      return deploy.promote({
        pipeline: input.pipeline,
        release: input.release,
        target: input.target,
        expectedPlanId: input.expected_plan_id,
        reason: input.reason,
      });
    case "google_cloud_deploy_approve_rollout":
      return deploy.approve({
        pipeline: input.pipeline,
        release: input.release,
        rollout: input.rollout,
        expectedEtag: input.expected_etag,
        reason: input.reason,
      });
    case "google_cloud_deploy_plan_rollback":
      return deploy.planRollback({
        pipeline: input.pipeline,
        target: input.target,
        rolloutId: input.rollout_id,
        release: input.release,
      });
    case "google_cloud_deploy_rollback":
      return deploy.rollback({
        pipeline: input.pipeline,
        target: input.target,
        rolloutId: input.rollout_id,
        release: input.release,
        expectedPlanId: input.expected_plan_id,
        reason: input.reason,
      });
    case "google_cloud_security_list_images":
      return security.listImages({
        repository: input.repository,
        pageSize: input.page_size,
        pageToken: input.page_token,
        includeVulnerabilitySummary:
          input.include_vulnerability_summary ?? true,
      });
    case "google_cloud_security_list_vulnerabilities":
      return security.listVulnerabilities({
        repository: input.repository,
        imageUri: input.image_uri,
        pageSize: input.page_size,
        pageToken: input.page_token,
        severity: input.severity,
        fixAvailableOnly: input.fix_available_only,
      });
    case "google_cloud_security_get_vulnerability":
      return security.getVulnerability({
        occurrenceName: input.occurrence_name,
      });
    default:
      throw new Error(`Unknown custom tool: ${name}`);
  }
}

function createServer() {
  const server = new Server(
    { name: "yourown-chat-google-cloud", version: "1.1.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [...officialTools, ...enabledCustomTools],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    try {
      if (customNames.has(request.params.name)) {
        return toolResult(
          await callCustom(request.params.name, request.params.arguments ?? {}),
        );
      }
      return observability.callTool({
        name: request.params.name,
        arguments: request.params.arguments ?? {},
      });
    } catch (error) {
      return toolError(error);
    }
  });

  return server;
}

const sessions = new Map();
let httpListener;
let stdioServer;
let shuttingDown = false;

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  const listenerClosed = httpListener
    ? new Promise((resolve) => httpListener.close(resolve))
    : Promise.resolve();
  for (const { transport } of sessions.values()) {
    await transport.close();
  }
  sessions.clear();
  await stdioServer?.close();
  await observability.close();
  await listenerClosed;
}
process.once("SIGTERM", () => void shutdown());
process.once("SIGINT", () => void shutdown());

if ((process.env.MCP_TRANSPORT ?? "http") === "stdio") {
  stdioServer = createServer();
  await stdioServer.connect(new StdioServerTransport());
} else {
  const port = Number.parseInt(process.env.PORT ?? "8080", 10);
  const app = express();
  app.use(express.json({ limit: "1mb" }));

  app.get("/healthz", (_request, response) => {
    response.json({ status: "ok", sessions: sessions.size });
  });

  app.post("/mcp", async (request, response) => {
    try {
      const sessionId = request.header("mcp-session-id");
      let session = sessionId ? sessions.get(sessionId) : undefined;

      if (!session && !sessionId && isInitializeRequest(request.body)) {
        const server = createServer();
        const transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: () => randomUUID(),
          onsessioninitialized: (initializedSessionId) => {
            sessions.set(initializedSessionId, { server, transport });
          },
        });
        transport.onclose = () => {
          if (transport.sessionId) {
            sessions.delete(transport.sessionId);
          }
        };
        await server.connect(transport);
        session = { server, transport };
      }

      if (!session) {
        response.status(400).json({
          jsonrpc: "2.0",
          error: { code: -32000, message: "Invalid or missing MCP session" },
          id: null,
        });
        return;
      }

      await session.transport.handleRequest(request, response, request.body);
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
      const session = sessionId ? sessions.get(sessionId) : undefined;
      if (!session) {
        response.status(400).send("Invalid or missing MCP session");
        return;
      }
      await session.transport.handleRequest(request, response);
      if (method === "delete") {
        sessions.delete(sessionId);
      }
    });
  }

  httpListener = app.listen(port, "0.0.0.0", () => {
    console.log(`Google Cloud MCP listening on 0.0.0.0:${port}`);
  });
}
