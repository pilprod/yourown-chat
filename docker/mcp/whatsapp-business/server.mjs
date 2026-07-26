import { randomUUID } from "node:crypto";

import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

import { MessageStore } from "./message-store.mjs";
import { readSecretEnv } from "./secret-env.mjs";
import { verifySubscription, verifyWebhookSignature } from "./webhook.mjs";

const port = Number.parseInt(process.env.PORT ?? "3000", 10);
const apiVersion = process.env.WHATSAPP_API_VERSION ?? "v23.0";
const graphBaseUrl = `https://graph.facebook.com/${apiVersion}`;
const messageStore = new MessageStore(
  process.env.WHATSAPP_MESSAGE_STORE ?? "/var/lib/whatsapp-mcp/messages.json",
  {
    maxMessages: Number.parseInt(
      process.env.WHATSAPP_MESSAGE_RETENTION ?? "5000",
      10,
    ),
  },
);

function requiredEnv(name) {
  const value = readSecretEnv(name);
  if (!value || value.startsWith("REPLACE_ME_")) {
    throw new Error(`${name} is not configured`);
  }
  return value;
}

async function graphRequest(path, { method = "GET", body } = {}) {
  const response = await fetch(`${graphBaseUrl}/${path.replace(/^\//, "")}`, {
    method,
    headers: {
      Authorization: `Bearer ${requiredEnv("WHATSAPP_ACCESS_TOKEN")}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  });

  const text = await response.text();
  let payload;
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    payload = { raw: text };
  }

  if (!response.ok) {
    const message =
      payload?.error?.message ?? `Meta Graph API returned HTTP ${response.status}`;
    throw new Error(message);
  }

  return payload;
}

function toolResult(payload) {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
  };
}

function outboundMessage({ id, to, type, text, payload }) {
  const timestamp = new Date().toISOString();
  return {
    id,
    direction: "outbound",
    source: "cloud_api",
    historical: false,
    from: requiredEnv("WHATSAPP_PHONE_NUMBER_ID"),
    to,
    peer: to,
    type,
    text,
    timestamp,
    received_at: timestamp,
    status: "accepted",
    status_at: timestamp,
    payload,
  };
}

async function sendAndRecord({ to, type, text, body }) {
  const result = await graphRequest(
    `${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}/messages`,
    { method: "POST", body },
  );
  const id = result?.messages?.[0]?.id;
  if (id) {
    try {
      await messageStore.recordOutbound(
        outboundMessage({ id, to, type, text, payload: body }),
      );
    } catch (error) {
      // The Graph API has already accepted the message. Do not turn a local
      // indexing failure into an apparent send failure that an agent may retry.
      console.error("Failed to index outbound WhatsApp message", error);
    }
  }
  return result;
}

const readOnlyLocal = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
};
const readOnlyExternal = {
  ...readOnlyLocal,
  openWorldHint: true,
};
const writeExternal = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: true,
};

function toolDefinition(title, description, inputSchema, annotations) {
  return {
    title,
    description,
    inputSchema,
    annotations: {
      ...annotations,
      title,
    },
  };
}

function createServer() {
  const server = new McpServer({
    name: "yourown-chat-whatsapp-business",
    version: "1.0.0",
  });

  server.registerTool(
    "whatsapp_send_text",
    toolDefinition(
      "Send text",
      "Send a text message through the official WhatsApp Business Cloud API.",
      {
        to: z
          .string()
          .min(6)
          .describe("Recipient number in international format"),
        body: z.string().min(1).max(4096),
        preview_url: z.boolean().optional().default(false),
      },
      writeExternal,
    ),
    async ({ to, body, preview_url }) =>
      toolResult(
        await sendAndRecord({
          to,
          type: "text",
          text: body,
          body: {
            messaging_product: "whatsapp",
            recipient_type: "individual",
            to,
            type: "text",
            text: { body, preview_url },
          },
        }),
      ),
  );

  server.registerTool(
    "whatsapp_send_template",
    toolDefinition(
      "Send template",
      "Send an approved WhatsApp Business message template.",
      {
        to: z.string().min(6),
        name: z.string().min(1),
        language_code: z.string().min(2).default("en_US"),
        components: z.array(z.record(z.unknown())).optional(),
      },
      writeExternal,
    ),
    async ({ to, name, language_code, components }) =>
      toolResult(
        await sendAndRecord({
          to,
          type: "template",
          text: `template:${name}`,
          body: {
            messaging_product: "whatsapp",
            to,
            type: "template",
            template: {
              name,
              language: { code: language_code },
              ...(components ? { components } : {}),
            },
          },
        }),
      ),
  );

  server.registerTool(
    "whatsapp_send_media_link",
    toolDefinition(
      "Send media link",
      "Send image, video, audio, or document media by HTTPS URL.",
      {
        to: z.string().min(6),
        media_type: z.enum(["image", "video", "audio", "document"]),
        link: z.string().url(),
        caption: z.string().max(1024).optional(),
        filename: z.string().max(240).optional(),
      },
      writeExternal,
    ),
    async ({ to, media_type, link, caption, filename }) => {
      const media = {
        link,
        ...(caption && media_type !== "audio" ? { caption } : {}),
        ...(filename && media_type === "document" ? { filename } : {}),
      };
      return toolResult(
        await sendAndRecord({
          to,
          type: media_type,
          text: caption,
          body: {
            messaging_product: "whatsapp",
            to,
            type: media_type,
            [media_type]: media,
          },
        }),
      );
    },
  );

  server.registerTool(
    "whatsapp_list_messages",
    toolDefinition(
      "List messages",
      "Read recently received and sent WhatsApp Business messages captured through the verified Meta webhook.",
      {
        phone: z
          .string()
          .min(6)
          .optional()
          .describe("Filter by either participant"),
        from: z.string().min(6).optional().describe("Filter by sender number"),
        direction: z.enum(["inbound", "outbound"]).optional(),
        source: z
          .enum(["cloud_api", "business_app", "history", "cloud_api_status"])
          .optional(),
        status: z.string().min(1).optional(),
        since: z.string().datetime().optional(),
        limit: z.number().int().min(1).max(200).optional().default(50),
      },
      readOnlyLocal,
    ),
    async (filters) => toolResult(await messageStore.list(filters)),
  );

  server.registerTool(
    "whatsapp_list_conversations",
    toolDefinition(
      "List conversations",
      "List WhatsApp conversations assembled from webhook, Coexistence history, and WhatsApp Business app echo events.",
      {
        limit: z.number().int().min(1).max(200).optional().default(50),
      },
      readOnlyLocal,
    ),
    async (filters) => toolResult(await messageStore.conversations(filters)),
  );

  server.registerTool(
    "whatsapp_get_message",
    toolDefinition(
      "Get message",
      "Read one captured WhatsApp Business message by its wamid.",
      { message_id: z.string().min(1) },
      readOnlyLocal,
    ),
    async ({ message_id }) => {
      const message = await messageStore.get(message_id);
      if (!message) {
        throw new Error(`WhatsApp message ${message_id} was not found`);
      }
      return toolResult(message);
    },
  );

  server.registerTool(
    "whatsapp_mark_message_read",
    toolDefinition(
      "Mark message read",
      "Mark a WhatsApp message as read.",
      { message_id: z.string().min(1) },
      {
        ...writeExternal,
        idempotentHint: true,
      },
    ),
    async ({ message_id }) => {
      const result = await graphRequest(
        `${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}/messages`,
        {
          method: "POST",
          body: {
            messaging_product: "whatsapp",
            status: "read",
            message_id,
          },
        },
      );
      const indexedMessage = await messageStore.updateStatus(message_id, "read");
      return toolResult({
        ...result,
        indexed: Boolean(indexedMessage),
      });
    },
  );

  server.registerTool(
    "whatsapp_get_business_profile",
    toolDefinition(
      "Get business profile",
      "Read the WhatsApp Business profile attached to the configured phone number.",
      {},
      readOnlyExternal,
    ),
    async () =>
      toolResult(
        await graphRequest(
          `${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}/whatsapp_business_profile?fields=about,address,description,email,profile_picture_url,websites,vertical`,
        ),
      ),
  );

  server.registerTool(
    "whatsapp_get_phone_number",
    toolDefinition(
      "Get phone number",
      "Read the configured WhatsApp Business phone-number metadata and quality rating.",
      {},
      readOnlyExternal,
    ),
    async () =>
      toolResult(
        await graphRequest(
          `${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}?fields=display_phone_number,verified_name,quality_rating`,
        ),
      ),
  );

  server.registerTool(
    "whatsapp_list_message_templates",
    toolDefinition(
      "List message templates",
      "List approved and pending WhatsApp Business message templates.",
      { limit: z.number().int().min(1).max(100).optional().default(25) },
      readOnlyExternal,
    ),
    async ({ limit }) =>
      toolResult(
        await graphRequest(
          `${requiredEnv("WHATSAPP_WABA_ID")}/message_templates?limit=${limit}`,
        ),
      ),
  );

  return server;
}

const app = express();

app.get("/webhooks/whatsapp", (request, response) => {
  if (
    !verifySubscription(
      request.query,
      requiredEnv("WHATSAPP_WEBHOOK_VERIFY_TOKEN"),
    )
  ) {
    response.status(403).send("Webhook verification failed");
    return;
  }
  response.status(200).send(request.query["hub.challenge"]);
});

app.post(
  "/webhooks/whatsapp",
  express.raw({
    type: "application/json",
    limit: process.env.WHATSAPP_WEBHOOK_BODY_LIMIT ?? "16mb",
  }),
  async (request, response) => {
    try {
      if (
        !verifyWebhookSignature(
          request.body,
          request.header("x-hub-signature-256"),
          requiredEnv("WHATSAPP_APP_SECRET"),
        )
      ) {
        response.status(401).send("Invalid webhook signature");
        return;
      }
      const payload = JSON.parse(request.body.toString("utf8"));
      const ingested = await messageStore.ingestWebhook(payload);
      console.log("Indexed WhatsApp webhook", ingested);
      response.sendStatus(200);
    } catch (error) {
      console.error("WhatsApp webhook failed", error);
      response.sendStatus(400);
    }
  },
);

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
        error: { code: -32603, message: "Internal server error" },
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

await messageStore.init();

const httpServer = app.listen(port, "0.0.0.0", () => {
  console.log(`WhatsApp Business MCP listening on 0.0.0.0:${port}/mcp`);
});

async function shutdown() {
  httpServer.close();
  await Promise.allSettled([...transports.values()].map((transport) => transport.close()));
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
