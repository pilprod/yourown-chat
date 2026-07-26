import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

test("aggregator exposes official observability and guarded deploy tools", async () => {
  const server = fileURLToPath(new URL("../server.mjs", import.meta.url));
  const observability = fileURLToPath(
    new URL(
      "../node_modules/@google-cloud/observability-mcp/dist/bundle.js",
      import.meta.url,
    ),
  );
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [server],
    env: {
      ...process.env,
      OBSERVABILITY_MCP_COMMAND: process.execPath,
      OBSERVABILITY_MCP_ENTRYPOINT: observability,
      GOOGLE_CLOUD_DEPLOY_PROJECT: "yourown-chat",
      GOOGLE_CLOUD_DEPLOY_LOCATION: "europe-west3",
      GOOGLE_CLOUD_DEPLOY_PIPELINE_TARGETS:
        "mattermost=mattermost-dev|mattermost-prod,mcp=mcp-dev|mcp-prod",
    },
    stderr: "pipe",
  });
  const client = new Client(
    { name: "aggregator-test", version: "1.0.0" },
    { capabilities: {} },
  );

  try {
    await client.connect(transport);
    const names = new Set((await client.listTools()).tools.map((tool) => tool.name));
    assert(names.has("list_log_entries"));
    assert(names.has("google_cloud_deploy_list_releases"));
    assert(names.has("google_cloud_deploy_plan_promote"));
    assert(names.has("google_cloud_deploy_approve_rollout"));
  } finally {
    await client.close();
  }
});

test("dev mode omits lifecycle tools entirely", async () => {
  const server = fileURLToPath(new URL("../server.mjs", import.meta.url));
  const observability = fileURLToPath(
    new URL(
      "../node_modules/@google-cloud/observability-mcp/dist/bundle.js",
      import.meta.url,
    ),
  );
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [server],
    env: {
      ...process.env,
      OBSERVABILITY_MCP_COMMAND: process.execPath,
      OBSERVABILITY_MCP_ENTRYPOINT: observability,
      GOOGLE_CLOUD_DEPLOY_ENABLED: "false",
    },
    stderr: "pipe",
  });
  const client = new Client(
    { name: "aggregator-dev-test", version: "1.0.0" },
    { capabilities: {} },
  );

  try {
    await client.connect(transport);
    const names = new Set((await client.listTools()).tools.map((tool) => tool.name));
    assert(names.has("list_log_entries"));
    assert(!names.has("google_cloud_deploy_list_releases"));
    assert(!names.has("google_cloud_deploy_approve_rollout"));
  } finally {
    await client.close();
  }
});
