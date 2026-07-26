import type {
  AuthRequest,
  ClientInfo,
  OAuthHelpers,
} from "@cloudflare/workers-oauth-provider";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { isAllowedRedirectUri, parseAllowedEmails } from "./config";
import {
  consumeSignedState,
  createCsrfCookie,
  createPkce,
  createSignedState,
  type UpstreamState,
  validateCsrf,
} from "./state";

export interface AuthEnv {
  ACCESS_AUTHORIZATION_URL: string;
  ACCESS_CLIENT_ID: string;
  ACCESS_CLIENT_SECRET: string;
  ACCESS_ISSUER: string;
  ACCESS_JWKS_URL: string;
  ACCESS_TOKEN_URL: string;
  ALLOWED_EMAILS: string;
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: OAuthHelpers;
  OAUTH_STATE_SECRET: string;
}

interface AccessTokenResponse {
  access_token?: string;
  id_token?: string;
}

export async function handleAuthorizationRequest(
  request: Request,
  env: AuthEnv,
): Promise<Response> {
  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === "/authorize") {
    const oauthRequest = await env.OAUTH_PROVIDER.parseAuthRequest(request);
    assertAllowedOAuthRequest(oauthRequest);
    const client = await env.OAUTH_PROVIDER.lookupClient(oauthRequest.clientId);
    const approvalState = await createSignedState(
      env.OAUTH_KV,
      "approval",
      oauthRequest,
      env.OAUTH_STATE_SECRET,
    );
    return renderApproval(client, approvalState);
  }

  if (request.method === "POST" && url.pathname === "/authorize") {
    const form = await request.formData();
    const clearCookie = validateCsrf(request, form.get("csrf_token"));
    const approvalState = form.get("state");
    if (typeof approvalState !== "string") {
      return oauthError("invalid_request", "Missing authorization state");
    }

    const oauthRequest = await consumeSignedState<AuthRequest>(
      env.OAUTH_KV,
      "approval",
      approvalState,
      env.OAUTH_STATE_SECRET,
    );
    assertAllowedOAuthRequest(oauthRequest);
    const redirect = await createAccessRedirect(request, oauthRequest, env);
    redirect.headers.append("Set-Cookie", clearCookie);
    return redirect;
  }

  if (request.method === "GET" && url.pathname === "/callback") {
    if (url.searchParams.has("error")) {
      return oauthError(
        url.searchParams.get("error") ?? "access_denied",
        url.searchParams.get("error_description") ?? "Cloudflare Access denied authorization",
      );
    }

    const state = url.searchParams.get("state");
    const code = url.searchParams.get("code");
    if (!state || !code) {
      return oauthError("invalid_request", "Missing Access authorization response");
    }

    const upstreamState = await consumeSignedState<UpstreamState>(
      env.OAUTH_KV,
      "upstream",
      state,
      env.OAUTH_STATE_SECRET,
    );
    const tokens = await exchangeAccessCode(
      request,
      code,
      upstreamState.codeVerifier,
      env,
    );
    const identity = await verifyAccessIdentity(tokens.id_token, env);
    const allowedEmails = parseAllowedEmails(env.ALLOWED_EMAILS);
    if (!allowedEmails.has(identity.email.toLowerCase())) {
      console.warn(
        JSON.stringify({
          email: identity.email,
          event: "oauth_identity_denied",
        }),
      );
      return oauthError("access_denied", "This identity is not allowed");
    }

    const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
      metadata: { email: identity.email },
      props: identity,
      request: upstreamState.oauthRequest,
      revokeExistingGrants: false,
      scope: upstreamState.oauthRequest.scope,
      userId: identity.sub,
    });
    console.log(
      JSON.stringify({
        client_id: upstreamState.oauthRequest.clientId,
        email: identity.email,
        event: "oauth_authorization_completed",
      }),
    );
    return Response.redirect(redirectTo, 302);
  }

  if (request.method === "GET" && url.pathname === "/healthz") {
    return Response.json({ status: "ok" });
  }

  return new Response("Not Found", { status: 404 });
}

function assertAllowedOAuthRequest(request: AuthRequest): void {
  if (!request.clientId || !isAllowedRedirectUri(request.redirectUri)) {
    throw new Error("OAuth client redirect URI is not allowed");
  }
}

async function createAccessRedirect(
  request: Request,
  oauthRequest: AuthRequest,
  env: AuthEnv,
): Promise<Response> {
  const { codeChallenge, codeVerifier } = await createPkce();
  const state = await createSignedState<UpstreamState>(
    env.OAUTH_KV,
    "upstream",
    { codeVerifier, oauthRequest },
    env.OAUTH_STATE_SECRET,
  );
  const authorizationUrl = new URL(env.ACCESS_AUTHORIZATION_URL);
  authorizationUrl.searchParams.set("client_id", env.ACCESS_CLIENT_ID);
  authorizationUrl.searchParams.set("code_challenge", codeChallenge);
  authorizationUrl.searchParams.set("code_challenge_method", "S256");
  authorizationUrl.searchParams.set(
    "redirect_uri",
    new URL("/callback", request.url).href,
  );
  authorizationUrl.searchParams.set("response_type", "code");
  authorizationUrl.searchParams.set("scope", "openid email profile");
  authorizationUrl.searchParams.set("state", state);
  return Response.redirect(authorizationUrl.toString(), 302);
}

async function exchangeAccessCode(
  request: Request,
  code: string,
  codeVerifier: string,
  env: AuthEnv,
): Promise<Required<AccessTokenResponse>> {
  const response = await fetch(env.ACCESS_TOKEN_URL, {
    body: new URLSearchParams({
      client_id: env.ACCESS_CLIENT_ID,
      client_secret: env.ACCESS_CLIENT_SECRET,
      code,
      code_verifier: codeVerifier,
      grant_type: "authorization_code",
      redirect_uri: new URL("/callback", request.url).href,
    }),
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
    },
    method: "POST",
  });

  if (!response.ok) {
    console.error(
      JSON.stringify({
        event: "access_code_exchange_failed",
        status: response.status,
      }),
    );
    throw new Error("Cloudflare Access code exchange failed");
  }

  const tokens = (await response.json()) as AccessTokenResponse;
  if (!tokens.access_token || !tokens.id_token) {
    throw new Error("Cloudflare Access returned an incomplete token response");
  }
  return {
    access_token: tokens.access_token,
    id_token: tokens.id_token,
  };
}

async function verifyAccessIdentity(
  idToken: string,
  env: AuthEnv,
): Promise<{ email: string; name: string; sub: string }> {
  const { payload } = await jwtVerify(
    idToken,
    createRemoteJWKSet(new URL(env.ACCESS_JWKS_URL)),
    {
      algorithms: ["RS256"],
      audience: env.ACCESS_CLIENT_ID,
      clockTolerance: 5,
      issuer: env.ACCESS_ISSUER,
    },
  );

  if (
    typeof payload.sub !== "string" ||
    typeof payload.email !== "string"
  ) {
    throw new Error("Cloudflare Access ID token is missing identity claims");
  }

  return {
    email: payload.email,
    name: typeof payload.name === "string" ? payload.name : payload.email,
    sub: payload.sub,
  };
}

function renderApproval(client: ClientInfo | null, state: string): Response {
  const { cookie, token } = createCsrfCookie();
  const clientName = escapeHtml(client?.clientName ?? "MCP client");
  const redirectUris = (client?.redirectUris ?? [])
    .map((uri) => `<li><code>${escapeHtml(uri)}</code></li>`)
    .join("");
  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Authorize ${clientName}</title>
  <style>
    body{font:16px system-ui;max-width:42rem;margin:12vh auto;padding:0 1.5rem;color:#171717}
    main{border:1px solid #ddd;border-radius:16px;padding:2rem}
    code{overflow-wrap:anywhere}button{font:inherit;padding:.7rem 1rem;border:0;border-radius:10px;background:#171717;color:white}
  </style>
</head>
<body><main>
  <h1>Authorize ${clientName}</h1>
  <p>This client is requesting access to the private yourown-chat MCP portal.</p>
  <ul>${redirectUris}</ul>
  <form method="post" action="/authorize">
    <input type="hidden" name="csrf_token" value="${escapeHtml(token)}">
    <input type="hidden" name="state" value="${escapeHtml(state)}">
    <button type="submit">Continue with Cloudflare Access</button>
  </form>
</main></body></html>`;

  return new Response(html, {
    headers: {
      "Content-Security-Policy":
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "Content-Type": "text/html; charset=utf-8",
      "Referrer-Policy": "no-referrer",
      "Set-Cookie": cookie,
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
    },
  });
}

function oauthError(error: string, description: string): Response {
  return Response.json(
    { error, error_description: description },
    { status: 400 },
  );
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/gu, "&amp;")
    .replace(/</gu, "&lt;")
    .replace(/>/gu, "&gt;")
    .replace(/"/gu, "&quot;")
    .replace(/'/gu, "&#039;");
}
