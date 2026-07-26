import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { artifactVulnerabilityClientFromEnv } from "./artifact-vulnerability-client.mjs";
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
const security = artifactVulnerabilityClientFromEnv();

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
  ...(deployEnabled ? deployTools : []),
];
const customNames = new Set(enabledCustomTools.map((tool) => tool.name));
const duplicate = officialTools.find((tool) => customNames.has(tool.name));
if (duplicate) {
  throw new Error(`Tool name collision with Google MCP: ${duplicate.name}`);
}

async function callCustom(name, input) {
  switch (name) {
    case "google_cloud_deploy_list_releases":
      return deploy.listReleases({
        pipeline: input.pipeline,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "google_cloud_deploy_list_rollouts":
      return deploy.listRollouts({
        pipeline: input.pipeline,
        release: input.release,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "google_cloud_deploy_inspect_rollout":
      return deploy.inspectRollout(input);
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

const server = new Server(
  { name: "yourown-chat-google-cloud", version: "1.0.0" },
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

async function shutdown() {
  await observability.close();
  await server.close();
}
process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);

await server.connect(new StdioServerTransport());
