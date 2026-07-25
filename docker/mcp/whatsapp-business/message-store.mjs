import { randomUUID } from "node:crypto";
import {
  mkdir,
  readFile,
  rename,
  writeFile,
} from "node:fs/promises";
import { dirname } from "node:path";

function isoFromUnixSeconds(value) {
  const seconds = Number.parseInt(value, 10);
  return Number.isFinite(seconds)
    ? new Date(seconds * 1000).toISOString()
    : new Date().toISOString();
}

function messageText(message) {
  if (message.type === "text") {
    return message.text?.body;
  }
  if (message.type === "button") {
    return message.button?.text;
  }
  if (message.type === "interactive") {
    return (
      message.interactive?.button_reply?.title ??
      message.interactive?.list_reply?.title
    );
  }
  return message[message.type]?.caption;
}

export function messagesFromWebhook(payload, receivedAt = new Date().toISOString()) {
  const messages = [];
  for (const entry of payload?.entry ?? []) {
    for (const change of entry?.changes ?? []) {
      if (change?.field !== "messages") {
        continue;
      }
      const value = change.value ?? {};
      const contacts = new Map(
        (value.contacts ?? []).map((contact) => [contact.wa_id, contact]),
      );
      for (const message of value.messages ?? []) {
        const contact = contacts.get(message.from);
        messages.push({
          id: message.id,
          direction: "inbound",
          from: message.from,
          to: value.metadata?.display_phone_number,
          phone_number_id: value.metadata?.phone_number_id,
          contact_name: contact?.profile?.name,
          type: message.type,
          text: messageText(message),
          timestamp: isoFromUnixSeconds(message.timestamp),
          received_at: receivedAt,
          context: message.context,
          payload: message,
        });
      }
    }
  }
  return messages.filter((message) => message.id);
}

export class MessageStore {
  constructor(path, { maxMessages = 5000 } = {}) {
    this.path = path;
    this.maxMessages = maxMessages;
    this.queue = Promise.resolve();
  }

  async init() {
    await mkdir(dirname(this.path), { recursive: true });
    try {
      await readFile(this.path, "utf8");
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw error;
      }
      await this.#write([]);
    }
  }

  async #read() {
    const content = await readFile(this.path, "utf8");
    const parsed = JSON.parse(content);
    return Array.isArray(parsed) ? parsed : [];
  }

  async #write(messages) {
    const temporaryPath = `${this.path}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(messages)}\n`, {
      mode: 0o600,
    });
    await rename(temporaryPath, this.path);
  }

  async #mutate(callback) {
    const operation = this.queue.then(async () => {
      const messages = await this.#read();
      const result = callback(messages);
      await this.#write(messages.slice(-this.maxMessages));
      return result;
    });
    this.queue = operation.catch(() => {});
    return operation;
  }

  async ingestWebhook(payload) {
    const incoming = messagesFromWebhook(payload);
    return this.#mutate((messages) => {
      const positions = new Map(messages.map((message, index) => [message.id, index]));
      for (const message of incoming) {
        const position = positions.get(message.id);
        if (position === undefined) {
          positions.set(message.id, messages.length);
          messages.push(message);
        } else {
          messages[position] = { ...messages[position], ...message };
        }
      }
      return incoming.length;
    });
  }

  async recordOutbound(message) {
    return this.#mutate((messages) => {
      const position = messages.findIndex(({ id }) => id === message.id);
      if (position === -1) {
        messages.push(message);
      } else {
        messages[position] = { ...messages[position], ...message };
      }
      return message;
    });
  }

  async list({ from, direction, since, limit = 50 } = {}) {
    await this.queue;
    const messages = await this.#read();
    return messages
      .filter((message) => !from || message.from === from)
      .filter((message) => !direction || message.direction === direction)
      .filter((message) => !since || message.timestamp >= since)
      .slice(-limit)
      .reverse();
  }

  async get(id) {
    await this.queue;
    const messages = await this.#read();
    return messages.find((message) => message.id === id);
  }
}
