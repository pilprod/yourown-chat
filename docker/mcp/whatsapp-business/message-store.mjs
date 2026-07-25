import { randomUUID } from "node:crypto";
import {
  mkdir,
  readFile,
  rename,
  writeFile,
} from "node:fs/promises";
import { dirname } from "node:path";

function isoFromUnixSeconds(value, fallback = new Date().toISOString()) {
  const seconds = Number.parseInt(value, 10);
  return Number.isFinite(seconds)
    ? new Date(seconds * 1000).toISOString()
    : fallback;
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

function samePhone(left, right) {
  if (!left || !right) {
    return false;
  }
  return String(left).replace(/\D/g, "") === String(right).replace(/\D/g, "");
}

function normalizeMessage(
  message,
  {
    metadata = {},
    contacts = new Map(),
    direction,
    source,
    historical = false,
    threadPhone,
    receivedAt,
    historyMetadata,
  },
) {
  const businessNumber = metadata.display_phone_number;
  const resolvedDirection =
    direction ??
    (samePhone(message.from, businessNumber) ? "outbound" : "inbound");
  const peer =
    resolvedDirection === "outbound"
      ? message.to ?? threadPhone
      : message.from ?? threadPhone;
  const status = message.history_context?.status?.toLowerCase();

  return {
    id: message.id,
    direction: resolvedDirection,
    source,
    historical,
    from:
      message.from ??
      (resolvedDirection === "outbound" ? businessNumber : threadPhone),
    to:
      message.to ??
      (resolvedDirection === "outbound" ? threadPhone : businessNumber),
    peer,
    phone_number_id: metadata.phone_number_id,
    contact_name: contacts.get(peer)?.profile?.name,
    type: message.type,
    text: messageText(message),
    timestamp: isoFromUnixSeconds(message.timestamp, receivedAt),
    received_at: receivedAt,
    status,
    status_at: status
      ? isoFromUnixSeconds(message.timestamp, receivedAt)
      : undefined,
    read_at:
      status === "read"
        ? isoFromUnixSeconds(message.timestamp, receivedAt)
        : undefined,
    context: message.context,
    history_context: message.history_context,
    history_metadata: historyMetadata,
    payload: message,
  };
}

function historyMessages(value, receivedAt) {
  const messages = [];
  for (const history of value.history ?? []) {
    const historyMetadata = {
      phase: history.phase,
      chunk_order: history.chunk_order,
      progress: history.progress,
    };
    for (const thread of history.threads ?? []) {
      const threadPhone =
        thread.id ?? thread.wa_id ?? thread.phone_number ?? thread.contact?.wa_id;
      for (const message of thread.messages ?? []) {
        messages.push(
          normalizeMessage(message, {
            metadata: value.metadata,
            source: "history",
            historical: true,
            threadPhone,
            receivedAt,
            historyMetadata,
          }),
        );
      }
    }
  }
  return messages;
}

export function eventsFromWebhook(
  payload,
  receivedAt = new Date().toISOString(),
) {
  const messages = [];
  const statuses = [];

  for (const entry of payload?.entry ?? []) {
    for (const change of entry?.changes ?? []) {
      const value = change.value ?? {};
      const contacts = new Map(
        (value.contacts ?? []).map((contact) => [contact.wa_id, contact]),
      );

      if (change.field === "messages") {
        for (const message of value.messages ?? []) {
          messages.push(
            normalizeMessage(message, {
              metadata: value.metadata,
              contacts,
              direction: "inbound",
              source: "cloud_api",
              receivedAt,
            }),
          );
        }
        for (const status of value.statuses ?? []) {
          statuses.push({
            id: status.id,
            status: status.status?.toLowerCase(),
            status_at: isoFromUnixSeconds(status.timestamp, receivedAt),
            recipient_id: status.recipient_id,
            conversation: status.conversation,
            pricing: status.pricing,
            errors: status.errors,
            payload: status,
          });
        }
      } else if (change.field === "smb_message_echoes") {
        for (const message of value.messages ?? value.message_echoes ?? []) {
          messages.push(
            normalizeMessage(message, {
              metadata: value.metadata,
              contacts,
              direction: "outbound",
              source: "business_app",
              receivedAt,
            }),
          );
        }
      } else if (change.field === "history") {
        messages.push(...historyMessages(value, receivedAt));
      }
    }
  }

  return {
    messages: messages.filter((message) => message.id),
    statuses: statuses.filter((status) => status.id && status.status),
  };
}

// Kept as a small compatibility helper for existing callers and tests.
export function messagesFromWebhook(payload, receivedAt) {
  return eventsFromWebhook(payload, receivedAt).messages;
}

function mergeStatus(message, update) {
  const history = [
    ...(message.status_history ?? []),
    {
      status: update.status,
      at: update.status_at,
      errors: update.errors,
    },
  ].filter(
    (event, index, values) =>
      values.findIndex(
        (candidate) =>
          candidate.status === event.status && candidate.at === event.at,
      ) === index,
  );

  const useUpdate =
    !message.status_at ||
    !update.status_at ||
    update.status_at >= message.status_at;

  return {
    ...message,
    status: useUpdate ? update.status : message.status,
    status_at: useUpdate ? update.status_at : message.status_at,
    read_at:
      update.status === "read"
        ? update.status_at
        : message.read_at,
    recipient_id: update.recipient_id ?? message.recipient_id,
    conversation: update.conversation ?? message.conversation,
    pricing: update.pricing ?? message.pricing,
    errors: update.errors ?? message.errors,
    status_history: history,
  };
}

function mergeDefined(current, update) {
  return {
    ...current,
    ...Object.fromEntries(
      Object.entries(update).filter(([, value]) => value !== undefined),
    ),
    source:
      current.historical === false && update.historical
        ? current.source
        : update.source ?? current.source,
    historical:
      current.historical === false ? false : update.historical,
    received_at: current.received_at ?? update.received_at,
  };
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
      const retainedMessages = messages
        .sort((left, right) =>
          String(left.timestamp).localeCompare(String(right.timestamp)),
        )
        .slice(-this.maxMessages);
      await this.#write(retainedMessages);
      return result;
    });
    this.queue = operation.catch(() => {});
    return operation;
  }

  async ingestWebhook(payload) {
    const events = eventsFromWebhook(payload);
    return this.#mutate((messages) => {
      const positions = new Map(
        messages.map((message, index) => [message.id, index]),
      );

      for (const message of events.messages) {
        const position = positions.get(message.id);
        if (position === undefined) {
          positions.set(message.id, messages.length);
          messages.push(message);
        } else {
          messages[position] = mergeDefined(messages[position], message);
        }
      }

      for (const status of events.statuses) {
        const position = positions.get(status.id);
        if (position === undefined) {
          positions.set(status.id, messages.length);
          messages.push(
            mergeStatus(
              {
                id: status.id,
                direction: "outbound",
                source: "cloud_api_status",
                to: status.recipient_id,
                peer: status.recipient_id,
                type: "unknown",
                timestamp: status.status_at,
                received_at: status.status_at,
              },
              status,
            ),
          );
        } else {
          messages[position] = mergeStatus(messages[position], status);
        }
      }

      return {
        messages: events.messages.length,
        statuses: events.statuses.length,
      };
    });
  }

  async recordOutbound(message) {
    return this.#mutate((messages) => {
      const position = messages.findIndex(({ id }) => id === message.id);
      if (position === -1) {
        messages.push(message);
      } else {
        messages[position] = mergeDefined(messages[position], message);
      }
      return message;
    });
  }

  async updateStatus(id, status, at = new Date().toISOString()) {
    return this.#mutate((messages) => {
      const position = messages.findIndex((message) => message.id === id);
      if (position === -1) {
        return undefined;
      }
      messages[position] = mergeStatus(messages[position], {
        id,
        status,
        status_at: at,
      });
      return messages[position];
    });
  }

  async list({
    phone,
    from,
    direction,
    source,
    status,
    since,
    limit = 50,
  } = {}) {
    await this.queue;
    const messages = await this.#read();
    return messages
      .filter(
        (message) =>
          !phone ||
          samePhone(message.peer, phone) ||
          samePhone(message.from, phone) ||
          samePhone(message.to, phone),
      )
      .filter((message) => !from || samePhone(message.from, from))
      .filter((message) => !direction || message.direction === direction)
      .filter((message) => !source || message.source === source)
      .filter((message) => !status || message.status === status)
      .filter((message) => !since || message.timestamp >= since)
      .sort((left, right) =>
        String(right.timestamp).localeCompare(String(left.timestamp)),
      )
      .slice(0, limit);
  }

  async conversations({ limit = 50 } = {}) {
    const messages = await this.list({ limit: this.maxMessages });
    const conversations = new Map();
    for (const message of messages) {
      if (!message.peer) {
        continue;
      }
      const current = conversations.get(message.peer) ?? {
        phone: message.peer,
        contact_name: message.contact_name,
        latest_message: message,
        message_count: 0,
        unread_count: 0,
        sources: [],
      };
      current.contact_name ??= message.contact_name;
      current.message_count += 1;
      if (
        message.direction === "inbound" &&
        message.status !== "read" &&
        !message.read_at
      ) {
        current.unread_count += 1;
      }
      current.sources = [
        ...new Set([...current.sources, message.source].filter(Boolean)),
      ];
      conversations.set(message.peer, current);
    }
    return [...conversations.values()].slice(0, limit);
  }

  async get(id) {
    await this.queue;
    const messages = await this.#read();
    return messages.find((message) => message.id === id);
  }
}
