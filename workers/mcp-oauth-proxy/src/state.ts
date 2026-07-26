import type { AuthRequest } from "@cloudflare/workers-oauth-provider";
import { OAUTH_STATE_TTL_SECONDS } from "./config";

const textEncoder = new TextEncoder();

export interface UpstreamState {
  oauthRequest: AuthRequest;
  codeVerifier: string;
}

export async function createSignedState<T>(
  kv: KVNamespace,
  keyPrefix: string,
  value: T,
  secret: string,
): Promise<string> {
  const id = crypto.randomUUID();
  const signature = await sign(id, secret);
  await kv.put(`${keyPrefix}:${id}`, JSON.stringify(value), {
    expirationTtl: OAUTH_STATE_TTL_SECONDS,
  });
  return `${id}.${signature}`;
}

export async function consumeSignedState<T>(
  kv: KVNamespace,
  keyPrefix: string,
  token: string,
  secret: string,
): Promise<T> {
  const separator = token.lastIndexOf(".");
  if (separator < 1) {
    throw new Error("Invalid OAuth state");
  }

  const id = token.slice(0, separator);
  const suppliedSignature = token.slice(separator + 1);
  if (!(await verify(id, suppliedSignature, secret))) {
    throw new Error("Invalid OAuth state");
  }

  const key = `${keyPrefix}:${id}`;
  const serialized = await kv.get(key);
  if (serialized === null) {
    throw new Error("Expired or already used OAuth state");
  }
  await kv.delete(key);

  return JSON.parse(serialized) as T;
}

export async function createPkce(): Promise<{
  codeChallenge: string;
  codeVerifier: string;
}> {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const codeVerifier = base64Url(bytes);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    textEncoder.encode(codeVerifier),
  );
  return {
    codeChallenge: base64Url(new Uint8Array(digest)),
    codeVerifier,
  };
}

export function createCsrfCookie(): { cookie: string; token: string } {
  const token = crypto.randomUUID();
  return {
    token,
    cookie: `__Host-MCP_CSRF=${token}; HttpOnly; Secure; Path=/; SameSite=Lax; Max-Age=${OAUTH_STATE_TTL_SECONDS}`,
  };
}

export function validateCsrf(
  request: Request,
  supplied: string | File | null,
): string {
  if (typeof supplied !== "string") {
    throw new Error("Missing CSRF token");
  }

  const cookie = request.headers
    .get("cookie")
    ?.split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith("__Host-MCP_CSRF="));
  const stored = cookie?.slice("__Host-MCP_CSRF=".length);

  if (!stored || !timingSafeEqual(stored, supplied)) {
    throw new Error("Invalid CSRF token");
  }

  return "__Host-MCP_CSRF=; HttpOnly; Secure; Path=/; SameSite=Lax; Max-Age=0";
}

async function sign(value: string, secret: string): Promise<string> {
  if (secret.length < 32) {
    throw new Error("OAUTH_STATE_SECRET must contain at least 32 characters");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { hash: "SHA-256", name: "HMAC" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    textEncoder.encode(value),
  );
  return base64Url(new Uint8Array(signature));
}

async function verify(
  value: string,
  suppliedSignature: string,
  secret: string,
): Promise<boolean> {
  const expected = await sign(value, secret);
  return timingSafeEqual(expected, suppliedSignature);
}

function timingSafeEqual(left: string, right: string): boolean {
  const leftBytes = textEncoder.encode(left);
  const rightBytes = textEncoder.encode(right);
  if (leftBytes.length !== rightBytes.length) {
    return false;
  }

  let difference = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    difference |= leftBytes[index] ^ rightBytes[index];
  }
  return difference === 0;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/u, "");
}
