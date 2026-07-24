import { randomUUID } from "node:crypto";

import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

const port = Number.parseInt(process.env.PORT ?? "3000", 10);
const apiVersion = process.env.WHATSAPP_API_VERSION ?? "v23.0";
const graphBaseUrl = `https://graph.facebook.com/${apiVersion}`;

function requiredEnv(name) {
  const value = process.env[name];
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

function createServer() {
  const server = new McpServer({
    name: "yourown-chat-whatsapp-business",
    version: "1.0.0",
  });

  server.tool(
    "whatsapp_send_text",
    "Send a text message through the official WhatsApp Business Cloud API.",
    {
      to: z.string().min(6).describe("Recipient number in international format"),
      body: z.string().min(1).max(4096),
      preview_url: z.boolean().optional().default(false),
    },
    async ({ to, body, preview_url }) =>
      toolResult(
        await graphRequest(`${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}/messages`, {
          method: "POST",
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

  server.tool(
    "whatsapp_send_template",
    "Send an approved WhatsApp Business message template.",
    {
      to: z.string().min(6),
      name: z.string().min(1),
      language_code: z.string().min(2).default("en_US"),
      components: z.array(z.record(z.unknown())).optional(),
    },
    async ({ to, name, language_code, components }) =>
      toolResult(
        await graphRequest(`${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}/messages`, {
          method: "POST",
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

  server.tool(
    "whatsapp_send_media_link",
    "Send image, video, audio, or document media by HTTPS URL.",
    {
      to: z.string().min(6),
      media_type: z.enum(["image", "video", "audio", "document"]),
      link: z.string().url(),
      caption: z.string().max(1024).optional(),
      filename: z.string().max(240).optional(),
    },
    async ({ to, media_type, link, caption, filename }) => {
      const media = {
        link,
        ...(caption && media_type !== "audio" ? { caption } : {}),
        ...(filename && media_type === "document" ? { filename } : {}),
      };
      return toolResult(
        await graphRequest(`${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}/messages`, {
          method: "POST",
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

  server.tool(
    "whatsapp_mark_message_read",
    "Mark a WhatsApp message as read.",
    { message_id: z.string().min(1) },
    async ({ message_id }) =>
      toolResult(
        await graphRequest(`${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}/messages`, {
          method: "POST",
          body: {
            messaging_product: "whatsapp",
            status: "read",
            message_id,
          },
        }),
      ),
  );

  server.tool(
    "whatsapp_get_business_profile",
    "Read the WhatsApp Business profile attached to the configured phone number.",
    {},
    async () =>
      toolResult(
        await graphRequest(
          `${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}/whatsapp_business_profile?fields=about,address,description,email,profile_picture_url,websites,vertical`,
        ),
      ),
  );

  server.tool(
    "whatsapp_get_phone_number",
    "Read the configured WhatsApp Business phone-number metadata and quality rating.",
    {},
    async () =>
      toolResult(
        await graphRequest(
          `${requiredEnv("WHATSAPP_PHONE_NUMBER_ID")}?fields=display_phone_number,verified_name,quality_rating`,
        ),
      ),
  );

  server.tool(
    "whatsapp_list_message_templates",
    "List approved and pending WhatsApp Business message templates.",
    { limit: z.number().int().min(1).max(100).optional().default(25) },
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
