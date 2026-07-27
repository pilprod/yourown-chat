import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { test } from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

async function waitForHealth(url, child) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`server exited before becoming healthy: ${child.exitCode}`);
    }
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch {
      // The server has not bound its socket yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("server did not become healthy");
}

test("tools expose concise titles and explicit safety annotations", async () => {
  const storeDirectory = await mkdtemp(
    join(tmpdir(), "whatsapp-business-metadata-"),
  );
  const port = 32000 + Math.floor(Math.random() * 1000);
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      PORT: String(port),
      WHATSAPP_MESSAGE_STORE: join(storeDirectory, "messages.json"),
    },
    stdio: "pipe",
  });
  const client = new Client({
    name: "metadata-test",
    version: "1.0.0",
  });

  try {
    await waitForHealth(`http://127.0.0.1:${port}/health`, child);
    await client.connect(
      new StreamableHTTPClientTransport(
        new URL(`http://127.0.0.1:${port}/mcp`),
      ),
    );
    const tools = (await client.listTools()).tools;
    assert.equal(tools.length, 10);
    assert(
      tools.every(
        (tool) =>
          tool.title &&
          tool.annotations?.title === tool.title &&
          typeof tool.annotations.readOnlyHint === "boolean" &&
          typeof tool.annotations.destructiveHint === "boolean",
      ),
    );

    const list = tools.find((tool) => tool.name === "messages_list");
    assert.equal(list.title, "WhatsApp Business · Messages · List");
    assert.equal(list.annotations.readOnlyHint, true);
    assert.equal(list.annotations.destructiveHint, false);

    const send = tools.find((tool) => tool.name === "messages_send_text");
    assert.equal(send.title, "WhatsApp Business · Messages · Send text");
    assert.equal(send.annotations.readOnlyHint, false);
    assert.equal(send.annotations.destructiveHint, false);

    const markRead = tools.find(
      (tool) => tool.name === "messages_mark_read",
    );
    assert.equal(markRead.annotations.readOnlyHint, false);
    assert.equal(markRead.annotations.idempotentHint, true);
  } finally {
    await client.close().catch(() => {});
    const exited = new Promise((resolve) => child.once("exit", resolve));
    child.kill("SIGTERM");
    if (child.exitCode === null) await exited;
    await rm(storeDirectory, { recursive: true, force: true });
  }
});
