export const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;
export const REFRESH_TOKEN_TTL_SECONDS = 14 * 24 * 60 * 60;
export const CLIENT_REGISTRATION_TTL_SECONDS = 90 * 24 * 60 * 60;
export const OAUTH_STATE_TTL_SECONDS = 10 * 60;
export const MCP_RESOURCE = "https://mcp.yourown.chat/mcp";

const HOSTED_REDIRECTS = new Map<string, string | null>([
  ["claude.ai", "/api/mcp/auth_callback"],
  ["claude.com", "/api/mcp/auth_callback"],
  ["chatgpt.com", null],
  ["playground.ai.cloudflare.com", null],
  [
    "oauth-callbacks.cloudflareaccess.com",
    "/cdn-cgi/access/outbound-oauth-callback",
  ],
]);

export function isAllowedRedirectUri(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }

  if (url.username || url.password || url.hash) {
    return false;
  }

  const hostname = url.hostname.toLowerCase();
  const isLoopback =
    hostname === "localhost" ||
    hostname === "127.0.0.1" ||
    hostname === "[::1]";

  if (isLoopback) {
    return (url.protocol === "http:" || url.protocol === "https:") && url.pathname.length > 0;
  }

  if (url.protocol !== "https:") {
    return false;
  }

  const requiredPath = HOSTED_REDIRECTS.get(hostname);
  if (requiredPath === undefined) {
    return false;
  }

  return requiredPath === null || url.pathname === requiredPath;
}

export function parseAllowedEmails(value: string): Set<string> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error("ALLOWED_EMAILS must be a JSON array");
  }

  if (!Array.isArray(parsed) || parsed.some((email) => typeof email !== "string")) {
    throw new Error("ALLOWED_EMAILS must contain only strings");
  }

  return new Set(parsed.map((email) => email.trim().toLowerCase()).filter(Boolean));
}
