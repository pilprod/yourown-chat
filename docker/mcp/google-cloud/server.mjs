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
import { billingCostClientFromEnv } from "./billing-cost-client.mjs";
import { cloudBuildClientFromEnv } from "./cloud-build-client.mjs";
import { cloudDeployClientFromEnv } from "./cloud-deploy-client.mjs";
import { kubernetesScaleClientFromEnv } from "./kubernetes-scale-client.mjs";
import { resolveLegacyToolName } from "./tool-name-compat.mjs";
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

const observabilityTitles = {
  list_log_entries: "Logging · List entries",
  list_log_names: "Logging · List log names",
  list_buckets: "Logging · List buckets",
  list_views: "Logging · List views",
  list_sinks: "Logging · List sinks",
  list_log_scopes: "Logging · List scopes",
  list_metric_descriptors: "Monitoring · List metric descriptors",
  list_time_series: "Monitoring · List time series",
  list_alert_policies: "Monitoring · List alert policies",
  list_alerts: "Monitoring · List alerts",
  list_traces: "Trace · List traces",
  get_trace: "Trace · Get trace",
  list_group_stats: "Error Reporting · List group stats",
};

function humanize(value) {
  const words = value.split("_").filter(Boolean).join(" ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function customToolTitle(name) {
  for (const [prefix, group] of [
    ["build_", "Build"],
    ["deploy_", "Deploy"],
    ["security_", "Security"],
    ["billing_", "Billing"],
  ]) {
    if (name.startsWith(prefix)) {
      return `Google Cloud · ${group} · ${humanize(name.slice(prefix.length))}`;
    }
  }
  return `Google Cloud · ${humanize(name)}`;
}

function displayTool(tool, title, annotationDefaults = {}) {
  return {
    ...tool,
    title,
    annotations: {
      ...annotationDefaults,
      ...tool.annotations,
      title,
    },
  };
}

const exposedOfficialTools = officialTools.map((tool) =>
  displayTool(
    tool,
    `Google Cloud · ${observabilityTitles[tool.name] ?? humanize(tool.name)}`,
    {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    },
  ),
);

const deployEnabled =
  (process.env.GOOGLE_CLOUD_DEPLOY_ENABLED ?? "true").toLowerCase() === "true";
const deploy = deployEnabled ? cloudDeployClientFromEnv() : null;
const builds = deployEnabled ? cloudBuildClientFromEnv() : null;
const devScale = deployEnabled ? kubernetesScaleClientFromEnv() : null;
const security = artifactVulnerabilityClientFromEnv();
const billing = billingCostClientFromEnv();

const buildTools = [
  {
    name: "build_list_builds",
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
    name: "build_inspect_build",
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
    name: "build_list_build_logs",
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
    name: "deploy_list_releases",
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
    name: "deploy_inspect_release",
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
    name: "deploy_list_rollouts",
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
    name: "deploy_inspect_rollout",
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
    name: "deploy_list_job_runs",
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
    name: "deploy_inspect_job_run",
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
    name: "deploy_plan_promote",
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
    name: "deploy_promote",
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
    name: "deploy_approve_rollout",
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
    name: "deploy_inspect_dev_scale",
    description:
      "Inspect desired and observed replica counts for the exact allowlisted disposable dev workloads belonging to one delivery pipeline.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
      },
      required: ["pipeline"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false,
    },
  },
  {
    name: "deploy_cleanup_dev",
    description:
      "Scale the pipeline's exact RBAC-allowlisted disposable dev workloads to zero and wait until both desired and observed replicas are zero. Requires SCALE_DEV_TO_ZERO confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        reason: { type: "string", minLength: 8, maxLength: 500 },
        confirmation: { type: "string", const: "SCALE_DEV_TO_ZERO" },
      },
      required: ["pipeline", "reason", "confirmation"],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: true,
      openWorldHint: false,
    },
  },
  {
    name: "deploy_reject_rollout",
    description:
      "Scale the pipeline's exact allowlisted dev workloads to zero, verify desired and observed replicas are zero, then reject one inspected pending production rollout. Requires its exact current etag and REJECT confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline: { type: "string" },
        release: { type: "string" },
        rollout: { type: "string" },
        expected_etag: { type: "string", minLength: 1 },
        reason: { type: "string", minLength: 8, maxLength: 500 },
        confirmation: { type: "string", const: "REJECT" },
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
    name: "deploy_plan_rollback",
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
    name: "deploy_rollback",
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
    name: "security_get_scanning",
    description:
      "Read the effective vulnerability-scanning gate and API-derived state for one allowlisted Artifact Registry repository.",
    inputSchema: {
      type: "object",
      properties: {
        repository: { type: "string" },
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
    name: "security_list_images",
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
    name: "security_list_vulnerabilities",
    description:
      "Return full Artifact Analysis vulnerability occurrences for one immutable image digest, including CVE/GHSA ID, effective severity, CVSS score, affected/fixed package versions, remediation, timestamps, and raw occurrence metadata.",
    inputSchema: {
      type: "object",
      properties: {
        repository: { type: "string" },
        image_uri: {
          type: "string",
          description:
            "Immutable Artifact Registry URI ending in @sha256:<64 hex characters>, as returned by security_list_images.",
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
    name: "security_get_vulnerability",
    description:
      "Get the complete Artifact Analysis occurrence and its provider Note for one vulnerability. The Note adds the full advisory description, CVSS vectors, related URLs, affected versions, and remediation metadata available from Google.",
    inputSchema: {
      type: "object",
      properties: {
        occurrence_name: {
          type: "string",
          description:
            "Full projects/<configured-project>/occurrences/<id> name returned by security_list_vulnerabilities.",
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

const securityWriteTools = [
  {
    name: "security_set_scanning",
    description:
      "Enable or disable paid automatic vulnerability scanning for one allowlisted Artifact Registry repository. Read current state first and pass it as expected_enablement_config; client approval, an exact confirmation token and an audit reason are required.",
    inputSchema: {
      type: "object",
      properties: {
        repository: { type: "string" },
        enabled: { type: "boolean" },
        expected_enablement_config: {
          type: "string",
          enum: [
            "ENABLEMENT_CONFIG_UNSPECIFIED",
            "INHERITED",
            "DISABLED",
          ],
        },
        reason: { type: "string", minLength: 1 },
        confirmation: {
          type: "string",
          enum: ["ENABLE_SCANNING", "DISABLE_SCANNING"],
        },
      },
      required: [
        "repository",
        "enabled",
        "expected_enablement_config",
        "reason",
        "confirmation",
      ],
      additionalProperties: false,
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: true,
      openWorldHint: true,
    },
  },
];

const billingTools = [
  {
    name: "billing_get_profile",
    description:
      "Inspect the project's Cloud Billing account association and the bounded Detailed Billing Export configuration used by this MCP server.",
    inputSchema: {
      type: "object",
      properties: {},
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
    name: "billing_list_budgets",
    description:
      "List Cloud Billing budgets, scopes, periods, thresholds, forecast rules and programmatic notification settings for the linked billing account.",
    inputSchema: {
      type: "object",
      properties: {
        project_only: { type: "boolean", default: false },
        page_size: { type: "integer", minimum: 1, maximum: 100, default: 100 },
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
    name: "billing_analyze_costs",
    description:
      "Aggregate Detailed Cloud Billing Export rows server-side for a bounded date range. Reports gross, credits, net, list and effective costs plus query bytes, grouped by day, service, SKU, project, location, resource, invoice month or cost type.",
    inputSchema: {
      type: "object",
      properties: {
        start_date: {
          type: "string",
          pattern: "^\\d{4}-\\d{2}-\\d{2}$",
        },
        end_date: {
          type: "string",
          pattern: "^\\d{4}-\\d{2}-\\d{2}$",
          description: "Exclusive end date.",
        },
        group_by: {
          type: "string",
          enum: [
            "day",
            "service",
            "sku",
            "project",
            "location",
            "resource",
            "invoice_month",
            "cost_type",
          ],
          default: "service",
        },
        limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
      },
      required: ["start_date", "end_date"],
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
    name: "billing_list_recommendations",
    description:
      "Collect active cost-optimization recommendations across allowlisted Active Assist recommenders, including projected savings, priority, affected resources, operations and supporting insights. Partial API errors are returned per recommender.",
    inputSchema: {
      type: "object",
      properties: {
        state: {
          type: "string",
          enum: ["ACTIVE", "CLAIMED", "SUCCEEDED", "FAILED", "DISMISSED"],
          default: "ACTIVE",
        },
        page_size: { type: "integer", minimum: 1, maximum: 100, default: 100 },
        include_raw: { type: "boolean", default: false },
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
];

const enabledCustomTools = [
  ...securityTools,
  ...billingTools,
  ...(deployEnabled
    ? [
        ...securityWriteTools,
        ...buildTools,
        ...deployTools.filter(
          (tool) =>
            devScale ||
            ![
              "deploy_inspect_dev_scale",
              "deploy_cleanup_dev",
              "deploy_reject_rollout",
            ].includes(tool.name),
        ),
      ]
    : []),
];
const exposedCustomTools = enabledCustomTools.map((tool) =>
  displayTool(tool, customToolTitle(tool.name)),
);
const customNames = new Set(enabledCustomTools.map((tool) => tool.name));
const duplicate = officialTools.find((tool) => customNames.has(tool.name));
if (duplicate) {
  throw new Error(`Tool name collision with Google MCP: ${duplicate.name}`);
}

async function callCustom(name, input) {
  switch (name) {
    case "build_list_builds":
      return builds.listBuilds({
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "build_inspect_build":
      return builds.inspectBuild({ buildId: input.build_id });
    case "build_list_build_logs":
      return builds.listBuildLogs({
        buildId: input.build_id,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "deploy_list_releases":
      return deploy.listReleases({
        pipeline: input.pipeline,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "deploy_inspect_release":
      return deploy.inspectRelease(input);
    case "deploy_list_rollouts":
      return deploy.listRollouts({
        pipeline: input.pipeline,
        release: input.release,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "deploy_inspect_rollout":
      return deploy.inspectRollout(input);
    case "deploy_list_job_runs":
      return deploy.listJobRuns({
        pipeline: input.pipeline,
        release: input.release,
        rollout: input.rollout,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "deploy_inspect_job_run":
      return deploy.inspectJobRun({
        pipeline: input.pipeline,
        release: input.release,
        rollout: input.rollout,
        jobRun: input.job_run,
      });
    case "deploy_plan_promote":
      return deploy.planPromote(input);
    case "deploy_promote":
      return deploy.promote({
        pipeline: input.pipeline,
        release: input.release,
        target: input.target,
        expectedPlanId: input.expected_plan_id,
        reason: input.reason,
      });
    case "deploy_approve_rollout":
      return deploy.approve({
        pipeline: input.pipeline,
        release: input.release,
        rollout: input.rollout,
        expectedEtag: input.expected_etag,
        reason: input.reason,
      });
    case "deploy_inspect_dev_scale":
      return devScale.inspect(input.pipeline);
    case "deploy_cleanup_dev":
      return {
        ...(await devScale.scaleToZero(input.pipeline)),
        reason: input.reason,
      };
    case "deploy_reject_rollout": {
      // Validate the exact rollout before changing dev capacity. reject()
      // repeats the etag/state check after cleanup to close the race window.
      const current = await deploy.inspectRollout({
        pipeline: input.pipeline,
        release: input.release,
        rollout: input.rollout,
      });
      if (current.etag !== input.expected_etag) {
        throw new Error(
          `Rollout etag changed: expected ${input.expected_etag}, current ${current.etag}`,
        );
      }
      if (
        current.approval_state !== "NEEDS_APPROVAL" &&
        current.approval_state !== "PENDING_APPROVAL"
      ) {
        throw new Error(
          `Rollout ${input.rollout} is not waiting for approval: ${current.approval_state}`,
        );
      }
      if (!current.target_id.endsWith("-prod")) {
        throw new Error(
          `Only production approval rollouts may be rejected: ${current.target_id}`,
        );
      }
      const cleanup = await devScale.scaleToZero(input.pipeline);
      const rejection = await deploy.reject({
        pipeline: input.pipeline,
        release: input.release,
        rollout: input.rollout,
        expectedEtag: input.expected_etag,
        reason: input.reason,
      });
      return { cleanup, rejection };
    }
    case "deploy_plan_rollback":
      return deploy.planRollback({
        pipeline: input.pipeline,
        target: input.target,
        rolloutId: input.rollout_id,
        release: input.release,
      });
    case "deploy_rollback":
      return deploy.rollback({
        pipeline: input.pipeline,
        target: input.target,
        rolloutId: input.rollout_id,
        release: input.release,
        expectedPlanId: input.expected_plan_id,
        reason: input.reason,
      });
    case "security_get_scanning":
      return security.getScanning({ repository: input.repository });
    case "security_list_images":
      return security.listImages({
        repository: input.repository,
        pageSize: input.page_size,
        pageToken: input.page_token,
        includeVulnerabilitySummary:
          input.include_vulnerability_summary ?? true,
      });
    case "security_list_vulnerabilities":
      return security.listVulnerabilities({
        repository: input.repository,
        imageUri: input.image_uri,
        pageSize: input.page_size,
        pageToken: input.page_token,
        severity: input.severity,
        fixAvailableOnly: input.fix_available_only,
      });
    case "security_get_vulnerability":
      return security.getVulnerability({
        occurrenceName: input.occurrence_name,
      });
    case "security_set_scanning":
      return security.setScanning({
        repository: input.repository,
        enabled: input.enabled,
        expectedEnablementConfig: input.expected_enablement_config,
        reason: input.reason,
        confirmation: input.confirmation,
      });
    case "billing_get_profile":
      return billing.getBillingProfile();
    case "billing_list_budgets":
      return billing.listBudgets({
        projectOnly: input.project_only,
        pageSize: input.page_size,
        pageToken: input.page_token,
      });
    case "billing_analyze_costs":
      return billing.queryCosts({
        startDate: input.start_date,
        endDate: input.end_date,
        groupBy: input.group_by,
        limit: input.limit,
      });
    case "billing_list_recommendations":
      return billing.listRecommendations({
        state: input.state,
        pageSize: input.page_size,
        includeRaw: input.include_raw,
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
    tools: [...exposedOfficialTools, ...exposedCustomTools],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    try {
      const toolName = resolveLegacyToolName(
        request.params.name,
        "google_cloud_",
        customNames,
      );
      if (customNames.has(toolName)) {
        return toolResult(
          await callCustom(toolName, request.params.arguments ?? {}),
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
