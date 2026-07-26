import OAuthProvider, {
  type AuthRequest,
  type OAuthHelpers,
} from "@cloudflare/workers-oauth-provider";
import { describe, expect, it } from "vitest";
import {
  ACCESS_TOKEN_TTL_SECONDS,
  MCP_RESOURCE,
  REFRESH_TOKEN_TTL_SECONDS,
} from "../src/config";

interface TestEnv {
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER?: OAuthHelpers;
}

interface TokenResponse {
  access_token: string;
  expires_in: number;
  refresh_token: string;
  resource: string;
  token_type: string;
}

interface RegistrationResponse {
  client_id: string;
}

function createMemoryKv(): KVNamespace {
  const values = new Map<string, string>();
  return {
    delete: async (key: string) => {
      values.delete(key);
    },
    get: async (key: string, options?: unknown) => {
      const value = values.get(key) ?? null;
      if (
        value !== null &&
        typeof options === "object" &&
        options !== null &&
        "type" in options &&
        options.type === "json"
      ) {
        return JSON.parse(value) as unknown;
      }
      return value;
    },
    list: async (options?: KVNamespaceListOptions) => {
      const prefix = options?.prefix ?? "";
      return {
        cacheStatus: null,
        complete: true,
        keys: [...values.keys()]
          .filter((key) => key.startsWith(prefix))
          .map((name) => ({ name })),
        list_complete: true,
      };
    },
    put: async (key: string, value: string | ArrayBuffer | ArrayBufferView) => {
      values.set(
        key,
        typeof value === "string"
          ? value
          : new TextDecoder().decode(
              value instanceof ArrayBuffer
                ? value
                : new Uint8Array(
                    value.buffer,
                    value.byteOffset,
                    value.byteLength,
                  ),
            ),
      );
    },
  } as unknown as KVNamespace;
}

function executionContext(): ExecutionContext {
  return {
    passThroughOnException: () => undefined,
    props: {},
    waitUntil: () => undefined,
  } as unknown as ExecutionContext;
}

async function codeChallenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(verifier),
  );
  return Buffer.from(digest).toString("base64url");
}

describe("Cloudflare OAuth provider compatibility contract", () => {
  it("discovers /mcp, restores a missing refresh resource, and tolerates one replay", async () => {
    const provider = new OAuthProvider({
      accessTokenTTL: ACCESS_TOKEN_TTL_SECONDS,
      allowPlainPKCE: false,
      apiHandler: {
        fetch: () => Response.json({ authenticated: true }),
      },
      apiRoute: "/mcp",
      authorizeEndpoint: "/authorize",
      clientRegistrationEndpoint: "/register",
      defaultHandler: {
        fetch: async (request: Request, env: TestEnv) => {
          const oauthRequest =
            await env.OAUTH_PROVIDER!.parseAuthRequest(request);
          const { redirectTo } =
            await env.OAUTH_PROVIDER!.completeAuthorization({
              metadata: { email: "test@example.com" },
              props: { email: "test@example.com" },
              request: oauthRequest,
              revokeExistingGrants: false,
              scope: oauthRequest.scope,
              userId: "test-user",
            });
          return Response.redirect(redirectTo, 302);
        },
      },
      refreshTokenTTL: REFRESH_TOKEN_TTL_SECONDS,
      resourceMetadata: {
        authorization_servers: ["https://mcp.yourown.chat"],
        resource: MCP_RESOURCE,
      },
      tokenEndpoint: "/token",
    });
    const env: TestEnv = { OAUTH_KV: createMemoryKv() };
    const fetch = (request: Request) =>
      provider.fetch(request, env, executionContext());

    const metadataResponse = await fetch(
      new Request(
        "https://mcp.yourown.chat/.well-known/oauth-protected-resource/mcp",
      ),
    );
    expect(metadataResponse.status).toBe(200);
    expect(await metadataResponse.json()).toMatchObject({
      authorization_servers: ["https://mcp.yourown.chat"],
      resource: MCP_RESOURCE,
    });

    const registrationResponse = await fetch(
      new Request("https://mcp.yourown.chat/register", {
        body: JSON.stringify({
          client_name: "refresh compatibility test",
          grant_types: ["authorization_code", "refresh_token"],
          redirect_uris: ["https://client.example/callback"],
          response_types: ["code"],
          token_endpoint_auth_method: "none",
        }),
        headers: { "content-type": "application/json" },
        method: "POST",
      }),
    );
    expect(registrationResponse.status).toBe(201);
    const registration =
      (await registrationResponse.json()) as RegistrationResponse;

    const verifier = "test-verifier-that-is-long-enough-for-pkce-0123456789";
    const authorizationUrl = new URL(
      "https://mcp.yourown.chat/authorize",
    );
    authorizationUrl.search = new URLSearchParams({
      client_id: registration.client_id,
      code_challenge: await codeChallenge(verifier),
      code_challenge_method: "S256",
      redirect_uri: "https://client.example/callback",
      resource: MCP_RESOURCE,
      response_type: "code",
    }).toString();
    const authorizationResponse = await fetch(
      new Request(authorizationUrl, { redirect: "manual" }),
    );
    expect(authorizationResponse.status).toBe(302);
    const authorizationRedirect = new URL(
      authorizationResponse.headers.get("location")!,
    );
    const code = authorizationRedirect.searchParams.get("code");
    expect(code).toBeTruthy();

    const initialTokenResponse = await fetch(
      tokenRequest({
        client_id: registration.client_id,
        code: code!,
        code_verifier: verifier,
        grant_type: "authorization_code",
        redirect_uri: "https://client.example/callback",
      }),
    );
    expect(initialTokenResponse.status).toBe(200);
    const initialToken =
      (await initialTokenResponse.json()) as TokenResponse;
    expect(initialToken).toMatchObject({
      expires_in: ACCESS_TOKEN_TTL_SECONDS,
      resource: MCP_RESOURCE,
      token_type: "bearer",
    });

    const firstRefreshResponse = await fetch(
      tokenRequest({
        client_id: registration.client_id,
        grant_type: "refresh_token",
        refresh_token: initialToken.refresh_token,
      }),
    );
    expect(firstRefreshResponse.status).toBe(200);
    const firstRefresh =
      (await firstRefreshResponse.json()) as TokenResponse;
    expect(firstRefresh.resource).toBe(MCP_RESOURCE);

    // A retry can arrive after the server rotated the token but before the
    // client persisted the response. The previous token remains valid once.
    const replayResponse = await fetch(
      tokenRequest({
        client_id: registration.client_id,
        grant_type: "refresh_token",
        refresh_token: initialToken.refresh_token,
      }),
    );
    expect(replayResponse.status).toBe(200);
    const replay = (await replayResponse.json()) as TokenResponse;
    expect(replay.resource).toBe(MCP_RESOURCE);

    // Using the previous token invalidated the competing token produced by
    // the first response, leaving exactly the retried token and its successor.
    const invalidatedResponse = await fetch(
      tokenRequest({
        client_id: registration.client_id,
        grant_type: "refresh_token",
        refresh_token: firstRefresh.refresh_token,
      }),
    );
    expect(invalidatedResponse.status).toBe(400);
    expect(await invalidatedResponse.json()).toMatchObject({
      error: "invalid_grant",
    });

    const apiResponse = await fetch(
      new Request(MCP_RESOURCE, {
        headers: { authorization: `Bearer ${replay.access_token}` },
      }),
    );
    expect(apiResponse.status).toBe(200);
    expect(await apiResponse.json()).toEqual({ authenticated: true });
  });
});

function tokenRequest(body: Record<string, string>): Request {
  return new Request("https://mcp.yourown.chat/token", {
    body: new URLSearchParams(body),
    headers: { "content-type": "application/x-www-form-urlencoded" },
    method: "POST",
  });
}
