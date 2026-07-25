import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  eventsFromWebhook,
  MessageStore,
  messagesFromWebhook,
} from "../message-store.mjs";

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
  const message = messagesFromWebhook(
    webhook,
    "2026-07-25T00:00:00.000Z",
  )[0];
  assert.equal(message.id, "wamid.inbound-1");
  assert.equal(message.direction, "inbound");
  assert.equal(message.source, "cloud_api");
  assert.equal(message.historical, false);
  assert.equal(message.from, "15551112222");
  assert.equal(message.to, "15550000000");
  assert.equal(message.peer, "15551112222");
  assert.equal(message.contact_name, "Ada");
  assert.equal(message.text, "Hello");
  assert.equal(message.timestamp, "2026-07-25T00:00:00.000Z");
});

test("persists, deduplicates, filters, and bounds messages", async () => {
  const directory = mkdtempSync(join(tmpdir(), "whatsapp-store-"));
  const path = join(directory, "messages.json");
  const store = new MessageStore(path, { maxMessages: 2 });

  try {
    await store.init();
    assert.deepEqual(await store.ingestWebhook(webhook), {
      messages: 1,
      statuses: 0,
    });
    assert.deepEqual(await store.ingestWebhook(webhook), {
      messages: 1,
      statuses: 0,
    });
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

test("indexes WhatsApp Business app echoes and Coexistence history", () => {
  const payload = {
    entry: [{
      changes: [
        {
          field: "smb_message_echoes",
          value: {
            metadata: {
              display_phone_number: "15550000000",
              phone_number_id: "phone-1",
            },
            message_echoes: [{
              id: "wamid.phone-1",
              to: "15551112222",
              timestamp: "1784937660",
              type: "text",
              text: { body: "Sent from phone" },
            }],
          },
        },
        {
          field: "history",
          value: {
            metadata: {
              display_phone_number: "15550000000",
              phone_number_id: "phone-1",
            },
            history: [{
              phase: 1,
              chunk_order: 2,
              progress: 50,
              threads: [{
                id: "15551112222",
                messages: [
                  {
                    id: "wamid.history-in",
                    from: "15551112222",
                    timestamp: "1784937600",
                    type: "text",
                    text: { body: "Earlier inbound" },
                    history_context: { status: "read" },
                  },
                  {
                    id: "wamid.history-out",
                    from: "15550000000",
                    to: "15551112222",
                    timestamp: "1784937630",
                    type: "text",
                    text: { body: "Earlier outbound" },
                    history_context: { status: "delivered" },
                  },
                ],
              }],
            }],
          },
        },
      ],
    }],
  };

  const { messages } = eventsFromWebhook(
    payload,
    "2026-07-25T00:10:00.000Z",
  );
  assert.equal(messages.length, 3);
  assert.deepEqual(
    messages.map(({ id, direction, source, historical, status }) => ({
      id,
      direction,
      source,
      historical,
      status,
    })),
    [
      {
        id: "wamid.phone-1",
        direction: "outbound",
        source: "business_app",
        historical: false,
        status: undefined,
      },
      {
        id: "wamid.history-in",
        direction: "inbound",
        source: "history",
        historical: true,
        status: "read",
      },
      {
        id: "wamid.history-out",
        direction: "outbound",
        source: "history",
        historical: true,
        status: "delivered",
      },
    ],
  );
  assert.equal(messages[1].history_metadata.phase, 1);
  assert.equal(messages[1].read_at, "2026-07-25T00:00:00.000Z");
});

test("merges delivery statuses and builds conversation unread counts", async () => {
  const directory = mkdtempSync(join(tmpdir(), "whatsapp-status-store-"));
  const path = join(directory, "messages.json");
  const store = new MessageStore(path);
  const statusWebhook = {
    entry: [{
      changes: [{
        field: "messages",
        value: {
          statuses: [{
            id: "wamid.outbound-1",
            status: "read",
            timestamp: "1784937720",
            recipient_id: "15551112222",
          }],
        },
      }],
    }],
  };

  try {
    await store.init();
    await store.ingestWebhook(webhook);
    await store.recordOutbound({
      id: "wamid.outbound-1",
      direction: "outbound",
      source: "cloud_api",
      to: "15551112222",
      peer: "15551112222",
      type: "text",
      text: "Reply",
      timestamp: "2026-07-25T00:01:00.000Z",
    });
    assert.deepEqual(await store.ingestWebhook(statusWebhook), {
      messages: 0,
      statuses: 1,
    });

    const outbound = await store.get("wamid.outbound-1");
    assert.equal(outbound.status, "read");
    assert.equal(outbound.read_at, "2026-07-25T00:02:00.000Z");
    assert.equal(outbound.status_history.length, 1);

    await store.ingestWebhook({
      entry: [{
        changes: [{
          field: "messages",
          value: {
            statuses: [{
              id: "wamid.outbound-1",
              status: "delivered",
              timestamp: "1784937660",
              recipient_id: "15551112222",
            }],
          },
        }],
      }],
    });
    assert.equal((await store.get("wamid.outbound-1")).status, "read");
    assert.equal(
      (await store.get("wamid.outbound-1")).status_history.length,
      2,
    );

    let conversations = await store.conversations();
    assert.equal(conversations.length, 1);
    assert.equal(conversations[0].unread_count, 1);
    assert.equal(conversations[0].message_count, 2);

    await store.updateStatus("wamid.inbound-1", "read");
    conversations = await store.conversations();
    assert.equal(conversations[0].unread_count, 0);
  } finally {
    rmSync(directory, { recursive: true });
  }
});
