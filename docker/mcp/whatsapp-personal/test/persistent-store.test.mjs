import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { PersistentStore } from "../persistent-store.mjs";

test("persists messages, peer reply state, sends and emergency stop", async () => {
  const directory = await mkdtemp(join(tmpdir(), "whatsapp-personal-"));
  const store = new PersistentStore(directory);
  await store.load();
  await store.recordMessage({
    id: "in-1",
    peer: "491234@s.whatsapp.net",
    direction: "inbound",
    timestamp: "2026-07-25T10:00:00.000Z",
    text: "hello",
    key: { id: "in-1", remoteJid: "491234@s.whatsapp.net" },
  });
  await store.setLinkedAtIfMissing();
  const linkedAt = store.state.linked_at;
  await store.setLinkedAtIfMissing();
  await store.recordSend("491234@s.whatsapp.net", {
    id: "out-1",
    peer: "491234@s.whatsapp.net",
    direction: "outbound",
    timestamp: "2026-07-25T10:01:00.000Z",
    text: "hi",
    key: { id: "out-1", remoteJid: "491234@s.whatsapp.net", fromMe: true },
  });
  // Baileys may emit the same outbound message again via messages.upsert.
  await store.recordMessage({
    id: "out-1",
    peer: "491234@s.whatsapp.net",
    direction: "outbound",
    timestamp: "2026-07-25T10:01:00.000Z",
    text: "hi",
    key: { id: "out-1", remoteJid: "491234@s.whatsapp.net", fromMe: true },
  });
  await store.setStopped(true);

  const reloaded = new PersistentStore(directory);
  await reloaded.load();
  assert.equal(reloaded.state.stopped, true);
  assert.equal(reloaded.state.linked_at, linkedAt);
  assert.equal(reloaded.listMessages().length, 2);
  assert.equal(reloaded.peer("491234@s.whatsapp.net").inbound_count, 1);
  assert.equal(
    reloaded.peer("491234@s.whatsapp.net").unanswered_outbound,
    1,
  );
  assert.equal(reloaded.state.sends.length, 1);

  const audit = await readFile(join(directory, "audit.jsonl"), "utf8");
  assert.match(audit, /send_text/);
  assert.doesNotMatch(audit, /491234@s\.whatsapp\.net/);
});
