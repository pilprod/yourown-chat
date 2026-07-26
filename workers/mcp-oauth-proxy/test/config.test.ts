import { describe, expect, it } from "vitest";
import {
  ACCESS_TOKEN_TTL_SECONDS,
  isAllowedRedirectUri,
  parseAllowedEmails,
  REFRESH_TOKEN_TTL_SECONDS,
} from "../src/config";

describe("OAuth lifetime contract", () => {
  it("keeps access tokens short and refresh grants long", () => {
    expect(ACCESS_TOKEN_TTL_SECONDS).toBe(900);
    expect(REFRESH_TOKEN_TTL_SECONDS).toBe(1_209_600);
  });
});

describe("redirect allowlist", () => {
  it.each([
    "https://claude.ai/api/mcp/auth_callback",
    "https://claude.com/api/mcp/auth_callback",
    "https://chatgpt.com/connector_platform_oauth_redirect",
    "http://127.0.0.1:49152/callback",
    "http://localhost:1455/callback",
    "http://[::1]:3000/callback",
  ])("allows %s", (uri) => {
    expect(isAllowedRedirectUri(uri)).toBe(true);
  });

  it.each([
    "https://evil.example/callback",
    "http://claude.ai/api/mcp/auth_callback",
    "https://claude.ai/other",
    "https://user@chatgpt.com/callback",
    "javascript:alert(1)",
  ])("rejects %s", (uri) => {
    expect(isAllowedRedirectUri(uri)).toBe(false);
  });
});

describe("email allowlist", () => {
  it("normalizes configured addresses", () => {
    expect(parseAllowedEmails('[" Ilya@Papou.Email "]')).toEqual(
      new Set(["ilya@papou.email"]),
    );
  });

  it("rejects malformed configuration", () => {
    expect(() => parseAllowedEmails('{"email":"x@example.com"}')).toThrow();
  });
});
