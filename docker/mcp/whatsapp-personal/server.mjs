import { randomUUID } from "node:crypto";

import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import QRCode from "qrcode";
import { z } from "zod";

import { SendGuardrails } from "./guardrails.mjs";
import { PersistentStore } from "./persistent-store.mjs";
import { WhatsAppSession } from "./whatsapp-session.mjs";

const port = Number.parseInt(process.env.PORT ?? "3000", 10);
const dataDir =
  process.env.WHATSAPP_PERSONAL_DATA_DIR ?? "/var/lib/whatsapp-personal";
const store = new PersistentStore(dataDir, {
  maximumMessages: Number.parseInt(
    process.env.WHATSAPP_PERSONAL_MESSAGE_RETENTION ?? "5000",
    10,
  ),
});
await store.load();

const session = new WhatsAppSession({
  dataDir,
  store,
  guardrails: new SendGuardrails({
    hourlyLimit: Number.parseInt(
      process.env.WHATSAPP_PERSONAL_HOURLY_LIMIT ?? "6",
      10,
    ),
    dailyLimit: Number.parseInt(
      process.env.WHATSAPP_PERSONAL_DAILY_LIMIT ?? "20",
      10,
    ),
    minimumIntervalMs:
      Number.parseInt(
        process.env.WHATSAPP_PERSONAL_MINIMUM_INTERVAL_SECONDS ?? "30",
        10,
      ) * 1000,
    maximumUnanswered: Number.parseInt(
      process.env.WHATSAPP_PERSONAL_MAXIMUM_UNANSWERED ?? "2",
      10,
    ),
  }),
});
await session.start();

function toolResult(payload) {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    structuredContent: { result: payload },
  };
}

function createServer() {
  const server = new McpServer({
    name: "yourown-chat-whatsapp-personal",
    version: "1.0.0",
  });

  server.registerTool(
    "whatsapp_personal_status",
    {
      description:
        "Read QR-session state, kill-switch state, conservative limits and current usage.",
      inputSchema: {},
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => toolResult(session.status()),
  );

  server.registerTool(
    "whatsapp_personal_get_qr",
    {
      description:
        "Return the current QR code for linking this persistent WhatsApp session.",
      inputSchema: {},
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => {
      if (!session.qr) {
        return toolResult({
          available: false,
          connection: session.connection,
          message: "No QR is currently waiting to be scanned",
        });
      }
      const dataUrl = await QRCode.toDataURL(session.qr, {
        errorCorrectionLevel: "M",
        margin: 2,
        width: 512,
      });
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              available: true,
              updated_at: session.qrUpdatedAt,
            }),
          },
          {
            type: "image",
            data: dataUrl.split(",", 2)[1],
            mimeType: "image/png",
          },
        ],
      };
    },
  );

  server.registerTool(
    "whatsapp_personal_list_conversations",
    {
      description:
        "List direct conversations observed by this linked device. Groups, broadcasts and statuses are excluded.",
      inputSchema: {
        limit: z.number().int().min(1).max(200).optional().default(50),
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ limit }) => toolResult(store.listConversations({ limit })),
  );

  server.registerTool(
    "whatsapp_personal_list_messages",
    {
      description:
        "Read bounded local message history captured by the linked device.",
      inputSchema: {
        jid: z.string().endsWith("@s.whatsapp.net").optional(),
        direction: z.enum(["inbound", "outbound"]).optional(),
        limit: z.number().int().min(1).max(200).optional().default(50),
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (filters) => toolResult(store.listMessages(filters)),
  );

  server.registerTool(
    "whatsapp_personal_send_text",
    {
      description:
        "Send one text to an existing direct dialog after all persisted guardrails pass. No bulk or broadcast operation exists.",
      inputSchema: {
        jid: z.string().endsWith("@s.whatsapp.net"),
        text: z.string().min(1).max(2000),
        confirmation: z.literal("SEND"),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async ({ jid, text }) => toolResult(await session.sendText(jid, text)),
  );

  server.registerTool(
    "whatsapp_personal_mark_read",
    {
      description:
        "Explicitly mark one locally indexed inbound message as read. Incoming messages are never marked automatically.",
      inputSchema: {
        message_id: z.string().min(1),
        confirmation: z.literal("MARK_READ"),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async ({ message_id }) => toolResult(await session.markRead(message_id)),
  );

  server.registerTool(
    "whatsapp_personal_emergency_stop",
    {
      description:
        "Persistently disconnect the linked client and block reconnects and sends.",
      inputSchema: { confirmation: z.literal("STOP") },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async () => {
      await session.emergencyStop();
      return toolResult({ stopped: true });
    },
  );

  server.registerTool(
    "whatsapp_personal_resume",
    {
      description:
        "Clear the persistent emergency stop and reconnect through the configured static proxy.",
      inputSchema: { confirmation: z.literal("RESUME") },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async () => {
      await session.resume();
      return toolResult(session.status());
    },
  );

  server.registerTool(
    "whatsapp_personal_reset_link",
    {
      description:
        "Delete only the persisted WhatsApp linked-device credential and request a new QR. Emergency stop must already be active.",
      inputSchema: { confirmation: z.literal("RESET_LINK") },
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async () => {
      await session.resetLink();
      return toolResult(session.status());
    },
  );

  return server;
}

const app = express();
app.use(express.json({ limit: "1mb" }));
const transports = new Map();

app.get("/health", (_request, response) => {
  response.json({ status: "ok", whatsapp: session.connection });
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

app.get("/mcp", async (request, response) => {
  const transport = transports.get(request.header("mcp-session-id"));
  if (!transport) {
    response.status(400).send("Invalid or missing MCP session");
    return;
  }
  await transport.handleRequest(request, response);
});

app.delete("/mcp", async (request, response) => {
  const transport = transports.get(request.header("mcp-session-id"));
  if (!transport) {
    response.status(400).send("Invalid or missing MCP session");
    return;
  }
  await transport.handleRequest(request, response);
});

app.listen(port, "0.0.0.0", () => {
  console.log(`WhatsApp Personal MCP listening on 0.0.0.0:${port}`);
});
