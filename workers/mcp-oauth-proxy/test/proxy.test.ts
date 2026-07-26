import { describe, expect, it } from "vitest";
import { createPortalRequest } from "../src/proxy";

describe("Portal proxy", () => {
  it("replaces client credentials with the Portal service identity", async () => {
    const incoming = new Request(
      "https://mcp.yourown.chat/mcp?session=one",
      {
        body: JSON.stringify({ jsonrpc: "2.0", method: "ping" }),
        headers: {
          Authorization: "Bearer end-user-oauth-token",
          Cookie: "private=session",
          "CF-Access-Client-Id": "attacker",
          "CF-Access-Client-Secret": "attacker",
          "Content-Type": "application/json",
          "Mcp-Session-Id": "mcp-session",
        },
        method: "POST",
      },
    );

    const upstream = createPortalRequest(incoming, {
      PORTAL_ORIGIN_URL: "https://mcp-origin.yourown.chat/mcp",
      PORTAL_SERVICE_TOKEN_ID: "service-id",
      PORTAL_SERVICE_TOKEN_SECRET: "service-secret",
    });

    expect(upstream.url).toBe(
      "https://mcp-origin.yourown.chat/mcp?session=one",
    );
    expect(upstream.headers.get("authorization")).toBeNull();
    expect(upstream.headers.get("cookie")).toBeNull();
    expect(upstream.headers.get("cf-access-client-id")).toBe("service-id");
    expect(upstream.headers.get("cf-access-client-secret")).toBe(
      "service-secret",
    );
    expect(upstream.headers.get("mcp-session-id")).toBe("mcp-session");
    expect(await upstream.text()).toContain('"method":"ping"');
  });
});
