import { createHash } from "node:crypto";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

const EMPTY_STATE = {
  version: 1,
  stopped: false,
  linked_at: null,
  messages: [],
  peers: {},
  sends: [],
};

function peerHash(jid) {
  return createHash("sha256").update(jid).digest("hex").slice(0, 16);
}

export class PersistentStore {
  constructor(dataDir, { maximumMessages = 5000 } = {}) {
    this.statePath = join(dataDir, "state.json");
    this.auditPath = join(dataDir, "audit.jsonl");
    this.maximumMessages = maximumMessages;
    this.state = structuredClone(EMPTY_STATE);
    this.writeChain = Promise.resolve();
  }

  async load() {
    await mkdir(dirname(this.statePath), { recursive: true });
    try {
      this.state = {
        ...structuredClone(EMPTY_STATE),
        ...JSON.parse(await readFile(this.statePath, "utf8")),
      };
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw error;
      }
    }
    return this.state;
  }

  async mutate(callback) {
    this.writeChain = this.writeChain.then(async () => {
      await callback(this.state);
      const temporaryPath = `${this.statePath}.tmp`;
      await writeFile(temporaryPath, JSON.stringify(this.state), {
        mode: 0o600,
      });
      await rename(temporaryPath, this.statePath);
    });
    await this.writeChain;
  }

  async audit(event, details = {}) {
    const entry = {
      at: new Date().toISOString(),
      event,
      ...details,
    };
    await appendFile(this.auditPath, `${JSON.stringify(entry)}\n`, {
      mode: 0o600,
    });
  }

  async setStopped(stopped) {
    await this.mutate((state) => {
      state.stopped = stopped;
    });
    await this.audit(stopped ? "emergency_stop" : "manual_resume");
  }

  async setLinkedAtIfMissing() {
    await this.mutate((state) => {
      state.linked_at ??= new Date().toISOString();
    });
  }

  async recordMessage(message) {
    await this.mutate((state) => {
      const existing = state.messages.findIndex(({ id }) => id === message.id);
      if (existing >= 0) {
        state.messages[existing] = message;
        return;
      }

      state.messages.push(message);
      state.messages = state.messages.slice(-this.maximumMessages);

      const peer = state.peers[message.peer] ?? {
        jid: message.peer,
        name: message.push_name ?? null,
        inbound_count: 0,
        outbound_count: 0,
        unanswered_outbound: 0,
      };
      if (message.direction === "inbound") {
        peer.inbound_count += 1;
        peer.unanswered_outbound = 0;
        peer.last_inbound_at = message.timestamp;
      } else {
        peer.outbound_count += 1;
        peer.unanswered_outbound += 1;
        peer.last_outbound_at = message.timestamp;
      }
      peer.name = message.push_name ?? peer.name;
      state.peers[message.peer] = peer;
    });
  }

  async recordSend(jid, message) {
    const at = new Date().toISOString();
    await this.mutate((state) => {
      state.sends.push({ at, peer: jid });
      state.sends = state.sends.filter(
        ({ at: sentAt }) => Date.now() - Date.parse(sentAt) < 24 * 60 * 60_000,
      );
    });
    await this.recordMessage(message);
    await this.audit("send_text", {
      peer: peerHash(jid),
      hourly_count: this.recentSends(60 * 60_000).length,
      daily_count: this.recentSends(24 * 60 * 60_000).length,
    });
  }

  recentSends(windowMs) {
    const now = Date.now();
    return this.state.sends.filter(({ at }) => now - Date.parse(at) < windowMs);
  }

  peer(jid) {
    return this.state.peers[jid];
  }

  listMessages({ jid, direction, limit = 50 } = {}) {
    return this.state.messages
      .filter((message) => !jid || message.peer === jid)
      .filter((message) => !direction || message.direction === direction)
      .slice(-limit)
      .reverse();
  }

  getMessage(id) {
    return this.state.messages.find((message) => message.id === id);
  }

  listConversations({ limit = 50 } = {}) {
    return Object.values(this.state.peers)
      .sort((left, right) =>
        String(
          right.last_inbound_at ?? right.last_outbound_at ?? "",
        ).localeCompare(
          String(left.last_inbound_at ?? left.last_outbound_at ?? ""),
        ),
      )
      .slice(0, limit);
  }
}
