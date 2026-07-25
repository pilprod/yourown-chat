import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { MessageStore, messagesFromWebhook } from "../message-store.mjs";

const webhook = {
  object: "whatsapp_business_account",
  entry: [{
    id: "waba-1",
    changes: [{
      field: "messages",
      value: {
        metadata: {
          display_phone_number: "15550000000",
          phone_number_id: "phone-1",
        },
        contacts: [{
          wa_id: "15551112222",
          profile: { name: "Ada" },
        }],
        messages: [{
          id: "wamid.inbound-1",
          from: "15551112222",
          timestamp: "1784937600",
          type: "text",
          text: { body: "Hello" },
        }],
      },
    }],
  }],
};

test("normalizes inbound Meta webhook messages", () => {
  assert.deepEqual(
    messagesFromWebhook(webhook, "2026-07-25T00:00:00.000Z")[0],
    {
      id: "wamid.inbound-1",
      direction: "inbound",
      from: "15551112222",
      to: "15550000000",
      phone_number_id: "phone-1",
      contact_name: "Ada",
      type: "text",
      text: "Hello",
      timestamp: "2026-07-25T00:00:00.000Z",
      received_at: "2026-07-25T00:00:00.000Z",
      context: undefined,
      payload: webhook.entry[0].changes[0].value.messages[0],
    },
  );
});

test("persists, deduplicates, filters, and bounds messages", async () => {
  const directory = mkdtempSync(join(tmpdir(), "whatsapp-store-"));
  const path = join(directory, "messages.json");
  const store = new MessageStore(path, { maxMessages: 2 });

  try {
    await store.init();
    assert.equal(await store.ingestWebhook(webhook), 1);
    assert.equal(await store.ingestWebhook(webhook), 1);
    assert.equal((await store.list()).length, 1);

    await store.recordOutbound({
      id: "wamid.outbound-1",
      direction: "outbound",
      to: "15551112222",
      type: "text",
      text: "One",
      timestamp: "2026-07-25T00:01:00.000Z",
    });
    await store.recordOutbound({
      id: "wamid.outbound-2",
      direction: "outbound",
      to: "15551112222",
      type: "text",
      text: "Two",
      timestamp: "2026-07-25T00:02:00.000Z",
    });

    assert.equal((await store.list()).length, 2);
    assert.equal(
      (await store.list({ direction: "outbound", limit: 1 }))[0].id,
      "wamid.outbound-2",
    );
    assert.equal((await store.get("wamid.inbound-1")), undefined);
  } finally {
    rmSync(directory, { recursive: true });
  }
});
