import assert from "node:assert/strict";
import test from "node:test";

import { GuardrailError, SendGuardrails } from "../guardrails.mjs";

const now = Date.parse("2026-07-25T12:00:00Z");

function guardrails(overrides = {}) {
  return new SendGuardrails({ now: () => now, ...overrides });
}

test("requires an existing dialog with an inbound message", () => {
  assert.throws(
    () => guardrails().check({ peer: undefined, sends: [] }),
    (error) =>
      error instanceof GuardrailError &&
      error.code === "existing_dialog_required",
  );
});

test("enforces hourly, daily, interval and unanswered limits", () => {
  const peer = { inbound_count: 1, unanswered_outbound: 0 };
  const at = (milliseconds) => new Date(now - milliseconds).toISOString();

  assert.throws(
    () =>
      guardrails({ hourlyLimit: 1 }).check({
        peer,
        sends: [{ at: at(60_000) }],
      }),
    /Hourly send limit/,
  );
  assert.throws(
    () =>
      guardrails({ dailyLimit: 1, hourlyLimit: 2 }).check({
        peer,
        sends: [{ at: at(2 * 60 * 60_000) }],
      }),
    /Daily send limit/,
  );
  assert.throws(
    () =>
      guardrails().check({
        peer,
        sends: [{ at: at(10_000) }],
      }),
    /Minimum interval/,
  );
  assert.throws(
    () =>
      guardrails().check({
        peer: { inbound_count: 1, unanswered_outbound: 2 },
        sends: [],
      }),
    /Wait for a new inbound reply/,
  );
});

test("allows one conservative send when every guardrail passes", () => {
  assert.doesNotThrow(() =>
    guardrails().check({
      peer: { inbound_count: 3, unanswered_outbound: 0 },
      sends: [],
    }),
  );
});

test("uses stricter persisted limits for the first seven linked days", () => {
  const linkedAt = new Date(now - 2 * 24 * 60 * 60_000).toISOString();
  assert.deepEqual(guardrails().limits(linkedAt), {
    warmup: true,
    hourly: 2,
    daily: 5,
  });
  assert.throws(
    () =>
      guardrails().check({
        linkedAt,
        peer: { inbound_count: 3, unanswered_outbound: 0 },
        sends: [
          { at: new Date(now - 20 * 60_000).toISOString() },
          { at: new Date(now - 10 * 60_000).toISOString() },
        ],
      }),
    /Hourly send limit/,
  );
});
