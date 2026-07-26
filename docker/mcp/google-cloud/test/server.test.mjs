import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

async function unusedPort() {
  const listener = net.createServer();
  await new Promise((resolve) => listener.listen(0, "127.0.0.1", resolve));
  const { port } = listener.address();
  await new Promise((resolve) => listener.close(resolve));
  return port;
}

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
      MCP_TRANSPORT: "stdio",
      GOOGLE_CLOUD_DEPLOY_PROJECT: "yourown-chat",
      GOOGLE_CLOUD_DEPLOY_LOCATION: "europe-west3",
      GOOGLE_CLOUD_DEPLOY_PIPELINE_TARGETS:
        "mattermost=mattermost-dev|mattermost-prod,mcp=mcp-dev|mcp-prod",
      GOOGLE_CLOUD_SECURITY_LOCATION: "europe-west3",
      GOOGLE_CLOUD_SECURITY_REPOSITORIES: "docker",
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
    assert(names.has("google_cloud_build_list_builds"));
    assert(names.has("google_cloud_build_inspect_build"));
    assert(names.has("google_cloud_build_list_build_logs"));
    assert(names.has("google_cloud_deploy_list_releases"));
    assert(names.has("google_cloud_deploy_inspect_release"));
    assert(names.has("google_cloud_deploy_list_job_runs"));
    assert(names.has("google_cloud_deploy_plan_promote"));
    assert(names.has("google_cloud_deploy_approve_rollout"));
    assert(names.has("google_cloud_deploy_plan_rollback"));
    assert(names.has("google_cloud_deploy_rollback"));
    assert(names.has("google_cloud_security_list_images"));
    assert(names.has("google_cloud_security_list_vulnerabilities"));
    assert(names.has("google_cloud_security_get_vulnerability"));
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
      MCP_TRANSPORT: "stdio",
      GOOGLE_CLOUD_DEPLOY_ENABLED: "false",
      GOOGLE_CLOUD_PROJECT: "yourown-chat",
      GOOGLE_CLOUD_SECURITY_LOCATION: "europe-west3",
      GOOGLE_CLOUD_SECURITY_REPOSITORIES: "docker",
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
    assert(!names.has("google_cloud_build_list_builds"));
    assert(!names.has("google_cloud_deploy_list_releases"));
    assert(!names.has("google_cloud_deploy_approve_rollout"));
    assert(!names.has("google_cloud_deploy_rollback"));
    assert(names.has("google_cloud_security_list_images"));
    assert(names.has("google_cloud_security_get_vulnerability"));
  } finally {
    await client.close();
  }
});

test("HTTP transport shares one aggregator across concurrent sessions", async () => {
  const server = fileURLToPath(new URL("../server.mjs", import.meta.url));
  const observability = fileURLToPath(
    new URL(
      "../node_modules/@google-cloud/observability-mcp/dist/bundle.js",
      import.meta.url,
    ),
  );
  const port = await unusedPort();
  const child = spawn(process.execPath, [server], {
    env: {
      ...process.env,
      PORT: String(port),
      MCP_TRANSPORT: "http",
      OBSERVABILITY_MCP_COMMAND: process.execPath,
      OBSERVABILITY_MCP_ENTRYPOINT: observability,
      GOOGLE_CLOUD_DEPLOY_ENABLED: "false",
      GOOGLE_CLOUD_PROJECT: "yourown-chat",
      GOOGLE_CLOUD_SECURITY_LOCATION: "europe-west3",
      GOOGLE_CLOUD_SECURITY_REPOSITORIES: "docker",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  const endpoint = new URL(`http://127.0.0.1:${port}/mcp`);
  const clients = [
    new Client({ name: "http-test-a", version: "1.0.0" }),
    new Client({ name: "http-test-b", version: "1.0.0" }),
  ];

  try {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      try {
        if ((await fetch(`http://127.0.0.1:${port}/healthz`)).ok) break;
      } catch {
        // The official child is still starting.
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    await Promise.all(
      clients.map((client) =>
        client.connect(new StreamableHTTPClientTransport(endpoint)),
      ),
    );
    const toolLists = await Promise.all(clients.map((client) => client.listTools()));
    assert(toolLists.every(({ tools }) => tools.length > 0));
    const health = await fetch(`http://127.0.0.1:${port}/healthz`).then((response) =>
      response.json(),
    );
    assert.equal(health.sessions, 2);
  } finally {
    child.kill("SIGTERM");
    await new Promise((resolve) => child.once("exit", resolve));
    await Promise.all(clients.map((client) => client.close().catch(() => {})));
  }

  assert(!stderr.includes("Error:"));
});
