import { createHmac, timingSafeEqual } from "node:crypto";

export function verifyWebhookSignature(rawBody, signature, appSecret) {
  if (!signature?.startsWith("sha256=")) {
    return false;
  }
  const expected = createHmac("sha256", appSecret).update(rawBody).digest("hex");
  const actual = signature.slice("sha256=".length);
  if (actual.length !== expected.length) {
    return false;
  }
  return timingSafeEqual(Buffer.from(actual, "hex"), Buffer.from(expected, "hex"));
}

export function verifySubscription(query, verificationToken) {
  return (
    query["hub.mode"] === "subscribe" &&
    query["hub.verify_token"] === verificationToken &&
    typeof query["hub.challenge"] === "string"
  );
}
