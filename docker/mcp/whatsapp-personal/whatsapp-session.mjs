import { join } from "node:path";
import { rm } from "node:fs/promises";

import makeWASocket, {
  Browsers,
  DisconnectReason,
  jidNormalizedUser,
  proto,
  useMultiFileAuthState,
} from "@whiskeysockets/baileys";
import { HttpsProxyAgent } from "https-proxy-agent";
import pino from "pino";
import { SocksProxyAgent } from "socks-proxy-agent";

import { SendGuardrails } from "./guardrails.mjs";
import { readSecretEnv } from "./secret-env.mjs";

function proxyAgent(proxyUrl) {
  const parsed = new URL(proxyUrl);
  const effectivePort =
    parsed.port || (parsed.protocol === "https:" ? "443" : "");
  if (effectivePort !== "443") {
    throw new Error(
      "Static proxy must listen on TCP 443 to match the namespace egress policy",
    );
  }
  if (/^socks5h?:\/\//.test(proxyUrl)) {
    return new SocksProxyAgent(proxyUrl);
  }
  if (/^https?:\/\//.test(proxyUrl)) {
    return new HttpsProxyAgent(proxyUrl);
  }
  throw new Error("Proxy URL must use socks5, socks5h, http, or https");
}

function statusCode(error) {
  return (
    error?.output?.statusCode ??
    error?.data?.statusCode ??
    error?.statusCode ??
    null
  );
}

function messageText(content) {
  return (
    content?.conversation ??
    content?.extendedTextMessage?.text ??
    content?.imageMessage?.caption ??
    content?.videoMessage?.caption ??
    content?.documentMessage?.caption ??
    null
  );
}

function serializeMessage(message) {
  const jid = jidNormalizedUser(message.key.remoteJid);
  const direction = message.key.fromMe ? "outbound" : "inbound";
  return {
    id: message.key.id,
    peer: jid,
    direction,
    timestamp: new Date(
      Number(message.messageTimestamp ?? Math.floor(Date.now() / 1000)) * 1000,
    ).toISOString(),
    push_name: message.pushName ?? null,
    text: messageText(message.message),
    key: message.key,
  };
}

export class WhatsAppSession {
  constructor({
    dataDir,
    store,
    guardrails = new SendGuardrails(),
    environment = process.env,
  }) {
    this.dataDir = dataDir;
    this.store = store;
    this.guardrails = guardrails;
    this.environment = environment;
    this.socket = null;
    this.connection = "disconnected";
    this.qr = null;
    this.qrUpdatedAt = null;
    this.lastError = null;
    this.reconnectAttempt = 0;
    this.reconnectTimer = null;
    this.openedAt = null;
    this.sendChain = Promise.resolve();
    this.logger = pino({ level: "silent" });
  }

  async start() {
    if (this.environment.WHATSAPP_PERSONAL_CONNECT_ENABLED === "false") {
      this.connection = "disabled";
      return;
    }
    if (this.store.state.stopped) {
      this.connection = "stopped";
      return;
    }
    await this.connect();
  }

  proxyUrl() {
    const value = readSecretEnv(
      "WHATSAPP_PERSONAL_PROXY_URL",
      this.environment,
    );
    if (!value || value.startsWith("REPLACE_ME_")) {
      throw new Error("WHATSAPP_PERSONAL_PROXY_URL is not configured");
    }
    return value;
  }

  async connect() {
    if (this.environment.WHATSAPP_PERSONAL_CONNECT_ENABLED === "false") {
      this.connection = "disabled";
      return;
    }
    clearTimeout(this.reconnectTimer);
    this.connection = "connecting";
    this.lastError = null;
    try {
      const agent = proxyAgent(this.proxyUrl());
      const { state, saveCreds } = await useMultiFileAuthState(
        join(this.dataDir, "auth"),
      );
      const socket = makeWASocket({
        auth: state,
        agent,
        fetchAgent: agent,
        browser: Browsers.ubuntu("yourown-chat"),
        logger: this.logger,
        markOnlineOnConnect: false,
        printQRInTerminal: false,
        syncFullHistory: false,
        shouldSyncHistoryMessage: ({ syncType }) =>
          syncType !== proto.HistorySync.HistorySyncType.FULL,
      });
      this.socket = socket;
      socket.ev.on("creds.update", saveCreds);
      socket.ev.on("connection.update", (update) =>
        this.onConnectionUpdate(update),
      );
      socket.ev.on("messages.upsert", ({ messages }) =>
        this.recordMessages(messages),
      );
      socket.ev.on("messaging-history.set", ({ messages }) =>
        this.recordMessages(messages),
      );
    } catch (error) {
      this.connection = "configuration_error";
      this.lastError = error.message;
      await this.store.audit("connection_error", {
        category: "configuration",
      });
    }
  }

  async onConnectionUpdate({ connection, lastDisconnect, qr }) {
    if (qr) {
      this.qr = qr;
      this.qrUpdatedAt = new Date().toISOString();
      this.connection = "awaiting_qr";
    }
    if (connection === "open") {
      this.connection = "connected";
      this.qr = null;
      this.openedAt = Date.now();
      await this.store.setLinkedAtIfMissing();
      await this.store.audit("connection_open");
    }
    if (connection !== "close") {
      return;
    }

    const code = statusCode(lastDisconnect?.error);
    if (this.openedAt && Date.now() - this.openedAt >= 30 * 60_000) {
      this.reconnectAttempt = 0;
    }
    this.openedAt = null;
    this.socket = null;
    this.lastError = code ? `WhatsApp disconnected with status ${code}` : "Disconnected";
    await this.store.audit("connection_close", { status_code: code });

    if (
      this.store.state.stopped ||
      code === DisconnectReason.loggedOut ||
      code === DisconnectReason.forbidden
    ) {
      this.connection = code === DisconnectReason.loggedOut ? "logged_out" : "stopped";
      if (code === DisconnectReason.forbidden) {
        await this.store.setStopped(true);
      }
      return;
    }

    this.connection = "reconnecting";
    const delay = Math.min(600_000, 30_000 * 2 ** this.reconnectAttempt);
    this.reconnectAttempt += 1;
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
  }

  async recordMessages(messages) {
    for (const message of messages) {
      if (
        !message.message ||
        !message.key.remoteJid ||
        message.key.remoteJid === "status@broadcast" ||
        message.key.remoteJid.endsWith("@broadcast") ||
        message.key.remoteJid.endsWith("@g.us")
      ) {
        continue;
      }
      await this.store.recordMessage(serializeMessage(message));
    }
  }

  status() {
    const effectiveLimits = this.guardrails.limits(this.store.state.linked_at);
    return {
      connection: this.connection,
      linked: Boolean(this.socket?.user),
      qr_available: Boolean(this.qr),
      qr_updated_at: this.qrUpdatedAt,
      stopped: this.store.state.stopped,
      linked_at: this.store.state.linked_at,
      warmup_active: effectiveLimits.warmup,
      last_error: this.lastError,
      limits: {
        hourly: effectiveLimits.hourly,
        daily: effectiveLimits.daily,
        minimum_interval_seconds:
          this.guardrails.minimumIntervalMs / 1000,
        maximum_unanswered: this.guardrails.maximumUnanswered,
      },
      usage: {
        last_hour: this.store.recentSends(60 * 60_000).length,
        last_day: this.store.recentSends(24 * 60 * 60_000).length,
      },
    };
  }

  async sendText(jid, text) {
    const operation = this.sendChain.then(() => this.performSendText(jid, text));
    this.sendChain = operation.catch(() => {});
    return operation;
  }

  async performSendText(jid, text) {
    if (this.store.state.stopped) {
      throw new Error("Emergency stop is active");
    }
    if (this.connection !== "connected" || !this.socket) {
      throw new Error("WhatsApp session is not connected");
    }
    if (!jid.endsWith("@s.whatsapp.net")) {
      throw new Error("Only individual WhatsApp dialogs are supported");
    }

    this.guardrails.check({
      peer: this.store.peer(jid),
      sends: this.store.state.sends,
      linkedAt: this.store.state.linked_at,
    });
    const result = await this.socket.sendMessage(jid, { text });
    await this.store.recordSend(jid, serializeMessage(result));
    return { id: result.key.id, peer: jid, accepted: true };
  }

  async markRead(messageId) {
    const message = this.store.getMessage(messageId);
    if (!message || message.direction !== "inbound") {
      throw new Error(`Inbound message ${messageId} was not found`);
    }
    if (this.connection !== "connected" || !this.socket) {
      throw new Error("WhatsApp session is not connected");
    }
    await this.socket.readMessages([message.key]);
    await this.store.audit("mark_read");
    return { id: messageId, read: true };
  }

  async emergencyStop() {
    await this.store.setStopped(true);
    clearTimeout(this.reconnectTimer);
    this.connection = "stopped";
    this.qr = null;
    this.socket?.end(new Error("Manual emergency stop"));
    this.socket = null;
  }

  async resume() {
    await this.store.setStopped(false);
    await this.connect();
  }

  async resetLink() {
    if (!["logged_out", "stopped"].includes(this.connection)) {
      throw new Error(
        "Activate the emergency stop before resetting a linked session",
      );
    }
    if (this.socket) {
      throw new Error("WhatsApp socket must be disconnected before reset");
    }
    await rm(join(this.dataDir, "auth"), { recursive: true, force: true });
    await this.store.audit("link_reset");
    await this.store.setStopped(false);
    await this.connect();
  }
}
