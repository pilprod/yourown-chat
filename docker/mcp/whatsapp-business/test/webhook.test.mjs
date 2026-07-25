import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";

import {
  verifySubscription,
  verifyWebhookSignature,
} from "../webhook.mjs";

test("verifies Meta webhook challenge and rejects another token", () => {
  const query = {
    "hub.mode": "subscribe",
    "hub.verify_token": "expected-token",
    "hub.challenge": "challenge-value",
  };
  assert.equal(verifySubscription(query, "expected-token"), true);
  assert.equal(verifySubscription(query, "another-token"), false);
});

test("verifies X-Hub-Signature-256 against the raw body", () => {
  const body = Buffer.from('{"entry":[]}');
  const secret = "app-secret";
  const digest = createHmac("sha256", secret).update(body).digest("hex");

  assert.equal(
    verifyWebhookSignature(body, `sha256=${digest}`, secret),
    true,
  );
  assert.equal(
    verifyWebhookSignature(body, `sha256=${"0".repeat(64)}`, secret),
    false,
  );
});
