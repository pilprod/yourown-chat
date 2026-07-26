export class GuardrailError extends Error {
  constructor(message, code) {
    super(message);
    this.name = "GuardrailError";
    this.code = code;
  }
}

export class SendGuardrails {
  constructor({
    hourlyLimit = 6,
    dailyLimit = 20,
    minimumIntervalMs = 30_000,
    maximumUnanswered = 2,
    warmupDays = 7,
    warmupHourlyLimit = 2,
    warmupDailyLimit = 5,
    now = () => Date.now(),
  } = {}) {
    this.hourlyLimit = hourlyLimit;
    this.dailyLimit = dailyLimit;
    this.minimumIntervalMs = minimumIntervalMs;
    this.maximumUnanswered = maximumUnanswered;
    this.warmupDays = warmupDays;
    this.warmupHourlyLimit = warmupHourlyLimit;
    this.warmupDailyLimit = warmupDailyLimit;
    this.now = now;
  }

  limits(linkedAt) {
    const warmup =
      Boolean(linkedAt) &&
      this.now() - Date.parse(linkedAt) < this.warmupDays * 24 * 60 * 60_000;
    return {
      warmup,
      hourly: warmup ? this.warmupHourlyLimit : this.hourlyLimit,
      daily: warmup ? this.warmupDailyLimit : this.dailyLimit,
    };
  }

  check({ peer, sends, linkedAt }) {
    if (!peer || peer.inbound_count < 1) {
      throw new GuardrailError(
        "Sending is allowed only to an existing dialog with a recorded inbound message",
        "existing_dialog_required",
      );
    }

    const now = this.now();
    const limits = this.limits(linkedAt);
    const hourly = sends.filter(({ at }) => now - Date.parse(at) < 60 * 60_000);
    const daily = sends.filter(({ at }) => now - Date.parse(at) < 24 * 60 * 60_000);

    if (hourly.length >= limits.hourly) {
      throw new GuardrailError("Hourly send limit reached", "hourly_limit");
    }
    if (daily.length >= limits.daily) {
      throw new GuardrailError("Daily send limit reached", "daily_limit");
    }

    const lastSend = sends.at(-1);
    if (lastSend && now - Date.parse(lastSend.at) < this.minimumIntervalMs) {
      throw new GuardrailError(
        "Minimum interval between messages has not elapsed",
        "minimum_interval",
      );
    }

    if ((peer.unanswered_outbound ?? 0) >= this.maximumUnanswered) {
      throw new GuardrailError(
        "Wait for a new inbound reply before sending again",
        "reply_required",
      );
    }
  }
}
