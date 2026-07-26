// node_modules/@cloudflare/workers-oauth-provider/dist/oauth-provider.js
import { WorkerEntrypoint } from "cloudflare:workers";
var EMA_ID_JAG_JWT_TYPE = "oauth-id-jag+jwt";
var EMA_ID_JAG_GRANT_PROFILE = "urn:ietf:params:oauth:grant-profile:id-jag";
var EMA_MAX_JWT_BYTES = 16 * 1024;
var EMA_JWKS_MAX_SIZE_BYTES = 64 * 1024;
var EMA_JWKS_FETCH_TIMEOUT_MS = 1e4;
var EMA_DEFAULT_JWKS_CACHE_TTL_SECONDS = 300;
var EMA_DEFAULT_CLOCK_SKEW_SECONDS = 60;
var EMA_DEFAULT_MAX_ASSERTION_LIFETIME_SECONDS = 300;
var EMA_JWKS_FORCE_REFRESH_COOLDOWN_SECONDS = 30;
var EMA_DEFAULT_JWT_ALGORITHM = "RS256";
var EMA_SUPPORTED_JWT_ALGORITHMS = /* @__PURE__ */ new Set(["RS256", "ES256"]);
var ok = (value) => ({
  ok: true,
  value
});
var err = (error) => ({
  ok: false,
  error
});
function emaErrorToWire(e) {
  switch (e.reason) {
    case "assertion_missing":
      return {
        code: "invalid_request",
        message: "assertion is required"
      };
    case "invalid_scope_param":
      return {
        code: "invalid_request",
        message: "Invalid scope parameter format"
      };
    case "resource_invalid":
    case "resource_mismatch":
      return {
        code: "invalid_target",
        message: "Invalid resource"
      };
    case "mapper_denied":
    case "mapper_threw":
      return {
        code: "invalid_grant",
        message: "Assertion was not authorized"
      };
    case "invalid_mapped_user":
      return {
        code: "invalid_grant",
        message: "Invalid mapped user"
      };
    case "invalid_mapped_scope":
      return {
        code: "invalid_grant",
        message: "Invalid mapped scope"
      };
    case "invalid_mapped_props":
      return {
        code: "invalid_grant",
        message: "Invalid mapped props"
      };
    case "invalid_mapped_ttl":
      return {
        code: "invalid_grant",
        message: "Invalid access token TTL"
      };
    case "assertion_expired_after_processing":
      return {
        code: "invalid_grant",
        message: "Assertion has expired"
      };
    case "assertion_too_large":
    case "assertion_malformed":
    case "invalid_typ":
    case "invalid_alg":
    case "issuer_not_trusted":
    case "no_matching_key":
    case "signature_failed":
    case "jwks_fetch_failed":
    case "invalid_claim":
    case "aud_mismatch":
    case "expired":
    case "iat_in_future":
    case "nbf_in_future":
    case "lifetime_too_long":
    case "replayed":
    case "client_id_mismatch":
      return {
        code: "invalid_grant",
        message: "Invalid assertion"
      };
  }
}
async function sha256Hex(input) {
  const data = new TextEncoder().encode(input);
  const buffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(buffer)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
var EMA_JTI_KV_PREFIX = "enterprise-jti:";
function createKvJtiStore() {
  return { async markUsed({ issuer, jti, exp, now, env }) {
    const ttl = Math.max(1, exp - now);
    const key = `${EMA_JTI_KV_PREFIX}${await sha256Hex(`${issuer}
${jti}`)}`;
    if (await env.OAUTH_KV.get(key)) return err({
      reason: "replayed",
      jti
    });
    await env.OAUTH_KV.put(key, "1", { expirationTtl: ttl });
    return ok(void 0);
  } };
}
function createDefaultJwksProvider(opts = {}) {
  const cache2 = /* @__PURE__ */ new Map();
  const cacheTtl = opts.cacheTtlSeconds ?? EMA_DEFAULT_JWKS_CACHE_TTL_SECONDS;
  return { async fetch(issuer, { forceRefresh, now }) {
    const cached = cache2.get(issuer.issuer);
    if (!forceRefresh && cached && cached.expiresAt > now) return ok(cached.jwks);
    if (forceRefresh && cached && cached.nextForceRefreshAllowedAt > now) return ok(cached.jwks);
    const abortController = new AbortController();
    const timeoutId = setTimeout(() => abortController.abort(), EMA_JWKS_FETCH_TIMEOUT_MS);
    try {
      const response = await fetch(issuer.jwksUri, {
        headers: { Accept: "application/json" },
        signal: abortController.signal,
        cf: { cacheEverything: true }
      });
      if (!response.ok) return err({
        reason: "jwks_fetch_failed",
        status: response.status
      });
      const contentLength = response.headers.get("content-length");
      if (contentLength && parseInt(contentLength, 10) > EMA_JWKS_MAX_SIZE_BYTES) return err({
        reason: "jwks_fetch_failed",
        status: response.status
      });
      const rawJwks = await readJsonWithSizeLimit(response, EMA_JWKS_MAX_SIZE_BYTES);
      if (!rawJwks.ok) return err({ reason: "jwks_fetch_failed" });
      if (!Array.isArray(rawJwks.value.keys)) return err({ reason: "jwks_fetch_failed" });
      const jwks = { keys: rawJwks.value.keys };
      cache2.set(issuer.issuer, {
        jwks,
        expiresAt: now + cacheTtl,
        nextForceRefreshAllowedAt: now + EMA_JWKS_FORCE_REFRESH_COOLDOWN_SECONDS
      });
      return ok(jwks);
    } catch {
      return err({ reason: "jwks_fetch_failed" });
    } finally {
      clearTimeout(timeoutId);
    }
  } };
}
async function readJsonWithSizeLimit(response, maxBytes) {
  if (!response.body) return { ok: false };
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        reader.cancel();
        return { ok: false };
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    const parsed = JSON.parse(new TextDecoder().decode(merged));
    if (typeof parsed !== "object" || parsed === null) return { ok: false };
    return {
      ok: true,
      value: parsed
    };
  } catch {
    return { ok: false };
  }
}
function parseIdJag(assertion, maxBytes) {
  if (typeof assertion !== "string" || assertion.length === 0) return err({ reason: "assertion_missing" });
  if (assertion.length > maxBytes) return err({
    reason: "assertion_too_large",
    size: assertion.length,
    max: maxBytes
  });
  const parts = assertion.split(".");
  if (parts.length !== 3 || parts.some((part) => part.length === 0)) return err({ reason: "assertion_malformed" });
  const [encodedHeader, encodedClaims, encodedSignature] = parts;
  let header;
  let rawClaims;
  let signature;
  try {
    header = parseJwtJsonPart(encodedHeader);
    rawClaims = parseJwtJsonPart(encodedClaims);
    signature = base64UrlToBytes(encodedSignature);
  } catch {
    return err({ reason: "assertion_malformed" });
  }
  const signingInput = new TextEncoder().encode(`${encodedHeader}.${encodedClaims}`);
  return ok({
    header,
    rawClaims,
    signingInput,
    signature
  });
}
function selectJwk(jwks, alg, kid) {
  const matching = (jwks.keys ?? []).filter((key) => {
    if (kid && key.kid !== kid) return false;
    if (key.alg && key.alg !== alg) return false;
    if (key.use && key.use !== "sig") return false;
    if (Array.isArray(key.key_ops) && !key.key_ops.includes("verify")) return false;
    if (alg.startsWith("RS") && key.kty !== "RSA") return false;
    if (alg.startsWith("ES") && key.kty !== "EC") return false;
    return true;
  });
  if (kid) {
    const picked = matching[0];
    if (!picked) return err({
      reason: "no_matching_key",
      kid
    });
    return ok(picked);
  }
  if (matching.length !== 1) return err({ reason: "no_matching_key" });
  return ok(matching[0]);
}
async function verifyIdJagSignature(input) {
  try {
    const { importAlgorithm, verifyAlgorithm } = getJwtCryptoAlgorithms(input.alg);
    const key = await crypto.subtle.importKey("jwk", input.jwk, importAlgorithm, false, ["verify"]);
    return await crypto.subtle.verify(verifyAlgorithm, key, input.signature, input.signingInput);
  } catch {
    return false;
  }
}
function validateIdJagHeader(header, expectedTyp, supportedAlgs) {
  const typ = header.typ;
  if (typeof typ !== "string" || typ !== expectedTyp) return err({
    reason: "invalid_typ",
    got: typ
  });
  const alg = header.alg;
  if (typeof alg !== "string" || alg === "none" || !supportedAlgs.has(alg)) return err({
    reason: "invalid_alg",
    got: alg
  });
  const kidRaw = header.kid;
  return ok({
    typ,
    alg,
    kid: typeof kidRaw === "string" && kidRaw.length > 0 ? kidRaw : void 0
  });
}
async function resolveTrustedIssuer(input) {
  const { iss, alg, resolver, env, request, clientInfo } = input;
  if (typeof iss !== "string" || iss.length === 0) return err({
    reason: "invalid_claim",
    claim: "iss"
  });
  let resolved;
  try {
    resolved = await resolver({
      iss,
      env,
      request,
      clientInfo
    });
  } catch {
    return err({
      reason: "issuer_not_trusted",
      iss
    });
  }
  if (!resolved) return err({
    reason: "issuer_not_trusted",
    iss
  });
  if (resolved.issuer !== iss) return err({
    reason: "issuer_not_trusted",
    iss
  });
  if (!isWellFormedTrustedIssuer(resolved)) return err({
    reason: "issuer_not_trusted",
    iss
  });
  if (!(resolved.algorithms ?? [EMA_DEFAULT_JWT_ALGORITHM]).includes(alg)) return err({
    reason: "issuer_not_trusted",
    iss
  });
  return ok(resolved);
}
function isWellFormedTrustedIssuer(issuer) {
  let issuerUrl;
  try {
    issuerUrl = new URL(issuer.issuer);
  } catch {
    return false;
  }
  if (issuerUrl.protocol !== "https:") return false;
  let jwksUrl;
  try {
    jwksUrl = new URL(issuer.jwksUri);
  } catch {
    return false;
  }
  if (jwksUrl.protocol !== "https:") return false;
  const algorithms = issuer.algorithms ?? [EMA_DEFAULT_JWT_ALGORITHM];
  if (algorithms.length === 0) return false;
  for (const alg of algorithms) if (!EMA_SUPPORTED_JWT_ALGORITHMS.has(alg)) return false;
  if (issuer.audience !== void 0) try {
    new URL(issuer.audience);
  } catch {
    return false;
  }
  return true;
}
function validateIdJagClaims(input) {
  const { rawClaims, trustedIssuer, expectedAudience, clientId, configuredResource, matchOriginOnly } = input;
  const { now, clockSkewSeconds, maxAssertionLifetimeSeconds } = input;
  const iss = readRequiredString(rawClaims, "iss");
  if (!iss.ok) return iss;
  if (iss.value !== trustedIssuer.issuer) return err({
    reason: "issuer_not_trusted",
    iss: iss.value
  });
  const sub = readRequiredString(rawClaims, "sub");
  if (!sub.ok) return sub;
  const aud = readAudienceClaim(rawClaims);
  if (!aud.ok) return aud;
  const resource = readRequiredString(rawClaims, "resource");
  if (!resource.ok) return resource;
  const claimClientId = readRequiredString(rawClaims, "client_id");
  if (!claimClientId.ok) return claimClientId;
  const jti = readRequiredString(rawClaims, "jti");
  if (!jti.ok) return jti;
  const exp = readNumericDateClaim(rawClaims, "exp");
  if (!exp.ok) return exp;
  const iat = readNumericDateClaim(rawClaims, "iat");
  if (!iat.ok) return iat;
  if (!(Array.isArray(aud.value) ? aud.value : [aud.value]).includes(expectedAudience)) return err({
    reason: "aud_mismatch",
    expected: expectedAudience,
    got: aud.value
  });
  if (claimClientId.value !== clientId) return err({
    reason: "client_id_mismatch",
    expected: clientId,
    got: claimClientId.value
  });
  if (!validateResourceUri(resource.value)) return err({
    reason: "resource_invalid",
    resource: resource.value
  });
  if (!resourceMatches(resource.value, configuredResource, matchOriginOnly)) return err({
    reason: "resource_mismatch",
    expected: configuredResource,
    got: resource.value
  });
  if (exp.value + clockSkewSeconds <= now) return err({
    reason: "expired",
    exp: exp.value,
    now
  });
  if (iat.value > now + clockSkewSeconds) return err({
    reason: "iat_in_future",
    iat: iat.value,
    now,
    skew: clockSkewSeconds
  });
  if (rawClaims.nbf !== void 0) {
    const nbf = readNumericDateClaim(rawClaims, "nbf");
    if (!nbf.ok) return nbf;
    if (nbf.value > now + clockSkewSeconds) return err({
      reason: "nbf_in_future",
      nbf: nbf.value,
      now,
      skew: clockSkewSeconds
    });
  }
  const lifetime = exp.value - iat.value;
  if (lifetime > maxAssertionLifetimeSeconds + clockSkewSeconds) return err({
    reason: "lifetime_too_long",
    lifetime,
    max: maxAssertionLifetimeSeconds
  });
  let scope;
  let assertionScopes = [];
  if (rawClaims.scope !== void 0) {
    const parsed = readRequiredString(rawClaims, "scope");
    if (!parsed.ok) return parsed;
    const tokens = parsed.value.split(" ").filter(Boolean);
    for (const token of tokens) if (!isValidOAuthScopeToken(token)) return err({
      reason: "invalid_claim",
      claim: "scope"
    });
    scope = parsed.value;
    assertionScopes = tokens;
  }
  return ok({
    claims: {
      ...rawClaims,
      iss: iss.value,
      sub: sub.value,
      aud: aud.value,
      resource: resource.value,
      client_id: claimClientId.value,
      jti: jti.value,
      exp: exp.value,
      iat: iat.value,
      scope
    },
    resource: resource.value,
    assertionScopes
  });
}
function parseEmaScopeParam(scope, assertionScopes) {
  let requested;
  if (scope === void 0) requested = [...assertionScopes];
  else if (typeof scope === "string") {
    const tokens = scope.split(" ").filter(Boolean);
    for (const token of tokens) if (!isValidOAuthScopeToken(token)) return err({ reason: "invalid_scope_param" });
    requested = tokens;
  } else if (Array.isArray(scope) && scope.every((value) => typeof value === "string")) {
    requested = [];
    for (const part of scope) {
      const tokens = part.split(" ").filter(Boolean);
      for (const token of tokens) if (!isValidOAuthScopeToken(token)) return err({ reason: "invalid_scope_param" });
      requested.push(...tokens);
    }
  } else return err({ reason: "invalid_scope_param" });
  if (assertionScopes.length > 0) {
    const allowed = new Set(assertionScopes);
    requested = requested.filter((token) => allowed.has(token));
  }
  return ok(requested);
}
function validateEmaMapperResult(result) {
  if (result === null) return err({ reason: "mapper_denied" });
  if (typeof result !== "object") return err({ reason: "invalid_mapped_user" });
  const r = result;
  if (typeof r.userId !== "string" || r.userId.length === 0 || r.userId.includes(":")) return err({ reason: "invalid_mapped_user" });
  if (!Array.isArray(r.scope) || !r.scope.every((s) => typeof s === "string" && isValidOAuthScopeToken(s))) return err({ reason: "invalid_mapped_scope" });
  if (!("props" in r) || r.props === void 0) return err({ reason: "invalid_mapped_props" });
  if (r.accessTokenTTL !== void 0) {
    if (typeof r.accessTokenTTL !== "number" || !Number.isFinite(r.accessTokenTTL) || r.accessTokenTTL <= 0) return err({ reason: "invalid_mapped_ttl" });
  }
  return ok({
    userId: r.userId,
    scope: r.scope,
    props: r.props,
    metadata: r.metadata,
    accessTokenTTL: r.accessTokenTTL
  });
}
function computeEmaAccessTokenTTL(input) {
  const { configuredDefaultSeconds, assertionExp, mapperTtl, now, minTtlSeconds } = input;
  if (assertionExp - now <= 0) return err({ reason: "assertion_expired_after_processing" });
  const ttl = mapperTtl ?? configuredDefaultSeconds;
  if (ttl < minTtlSeconds) return err({ reason: "invalid_mapped_ttl" });
  return ok(ttl);
}
function readRequiredString(claims, claimName) {
  const value = claims[claimName];
  if (typeof value !== "string" || value.length === 0) return err({
    reason: "invalid_claim",
    claim: claimName
  });
  return ok(value);
}
function readAudienceClaim(claims) {
  const aud = claims.aud;
  if (typeof aud === "string" && aud.length > 0) return ok(aud);
  if (Array.isArray(aud) && aud.length > 0 && aud.every((v) => typeof v === "string" && v.length > 0)) return ok(aud);
  return err({
    reason: "invalid_claim",
    claim: "aud"
  });
}
function readNumericDateClaim(claims, claimName) {
  const value = claims[claimName];
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) return err({
    reason: "invalid_claim",
    claim: claimName
  });
  return ok(value);
}
var PROTECTED_RESOURCE_WELL_KNOWN_PREFIX = "/.well-known/oauth-protected-resource";
var NO_CACHE_HEADERS = {
  "Cache-Control": "no-store",
  Pragma: "no-cache"
};
if (!(typeof Cloudflare !== "undefined" && Cloudflare.compatibilityFlags?.global_fetch_strictly_public === true)) console.warn(`CIMD (Client ID Metadata Document) is disabled: add '"compatibility_flags": ["global_fetch_strictly_public"]' to your wrangler.jsonc to enable. See: https://developers.cloudflare.com/workers/configuration/compatibility-flags/#global-fetch-strictly-public`);
var HandlerType = /* @__PURE__ */ function(HandlerType$1) {
  HandlerType$1[HandlerType$1["EXPORTED_HANDLER"] = 0] = "EXPORTED_HANDLER";
  HandlerType$1[HandlerType$1["WORKER_ENTRYPOINT"] = 1] = "WORKER_ENTRYPOINT";
  return HandlerType$1;
}(HandlerType || {});
var GrantType = /* @__PURE__ */ function(GrantType$1) {
  GrantType$1["AUTHORIZATION_CODE"] = "authorization_code";
  GrantType$1["REFRESH_TOKEN"] = "refresh_token";
  GrantType$1["TOKEN_EXCHANGE"] = "urn:ietf:params:oauth:grant-type:token-exchange";
  GrantType$1["JWT_BEARER"] = "urn:ietf:params:oauth:grant-type:jwt-bearer";
  return GrantType$1;
}({});
var OAuthProvider = class {
  #impl;
  /**
  * Creates a new OAuth provider instance
  * @param options - Configuration options for the provider
  */
  constructor(options) {
    this.#impl = new OAuthProviderImpl(options);
  }
  /**
  * Main fetch handler for the Worker
  * Routes requests to the appropriate handler based on the URL
  * @param request - The HTTP request
  * @param env - Cloudflare Worker environment variables
  * @param ctx - Cloudflare Worker execution context
  * @returns A Promise resolving to an HTTP Response
  */
  fetch(request, env, ctx) {
    return this.#impl.fetch(request, env, ctx);
  }
  /**
  * Purges expired and orphaned data from the KV namespace.
  * Can be called directly from a scheduled handler without needing a request context.
  *
  * @param env - Cloudflare Worker environment variables (must include OAUTH_KV binding)
  * @param options - Optional configuration for batch size and which purge types to enable
  * @returns Statistics about what was checked and purged
  */
  purgeExpiredData(env, options) {
    return this.#impl.createOAuthHelpers(env).purgeExpiredData(options);
  }
};
var OAuthProviderImpl = class OAuthProviderImpl2 {
  /**
  * Creates a new OAuth provider instance
  * @param options - Configuration options for the provider
  */
  constructor(options) {
    this.typedApiHandlers = [];
    const hasSingleHandlerConfig = !!(options.apiRoute && options.apiHandler);
    const hasMultiHandlerConfig = !!options.apiHandlers;
    if (hasSingleHandlerConfig && hasMultiHandlerConfig) throw new TypeError("Cannot use both apiRoute/apiHandler and apiHandlers. Use either apiRoute + apiHandler OR apiHandlers, not both.");
    if (!hasSingleHandlerConfig && !hasMultiHandlerConfig) throw new TypeError("Must provide either apiRoute + apiHandler OR apiHandlers. No API route configuration provided.");
    this.typedDefaultHandler = this.validateHandler(options.defaultHandler, "defaultHandler");
    if (hasSingleHandlerConfig) {
      const apiHandler = this.validateHandler(options.apiHandler, "apiHandler");
      if (Array.isArray(options.apiRoute)) options.apiRoute.forEach((route, index) => {
        this.validateEndpoint(route, `apiRoute[${index}]`);
        this.typedApiHandlers.push([route, apiHandler]);
      });
      else {
        this.validateEndpoint(options.apiRoute, "apiRoute");
        this.typedApiHandlers.push([options.apiRoute, apiHandler]);
      }
    } else for (const [route, handler] of Object.entries(options.apiHandlers)) {
      this.validateEndpoint(route, `apiHandlers key: ${route}`);
      this.typedApiHandlers.push([route, this.validateHandler(handler, `apiHandlers[${route}]`)]);
    }
    this.validateEndpoint(options.authorizeEndpoint, "authorizeEndpoint");
    this.validateEndpoint(options.tokenEndpoint, "tokenEndpoint");
    if (options.clientRegistrationEndpoint) this.validateEndpoint(options.clientRegistrationEndpoint, "clientRegistrationEndpoint");
    this.options = {
      accessTokenTTL: DEFAULT_ACCESS_TOKEN_TTL,
      refreshTokenTTL: DEFAULT_REFRESH_TOKEN_TTL,
      clientRegistrationTTL: DEFAULT_CLIENT_REGISTRATION_TTL,
      onError: ({ status, code, description }) => console.warn(`OAuth error response: ${status} ${code} - ${description}`),
      ...options
    };
    if (!Number.isInteger(this.options.accessTokenTTL) || this.options.accessTokenTTL < KV_MIN_EXPIRATION_TTL_SECONDS) throw new TypeError(`accessTokenTTL must be an integer of at least ${KV_MIN_EXPIRATION_TTL_SECONDS} seconds (Cloudflare KV's minimum expiration window).`);
    this.validateEmaOptions(this.options.enterpriseManagedAuthorization);
    if (this.options.enterpriseManagedAuthorization) {
      this.jwksProvider = createDefaultJwksProvider({ cacheTtlSeconds: this.options.enterpriseManagedAuthorization.jwksCacheTtlSeconds });
      this.jtiStore = createKvJtiStore();
    }
  }
  /**
  * Validates that an endpoint is either an absolute path or a full URL
  * @param endpoint - The endpoint to validate
  * @param name - The name of the endpoint property for error messages
  * @throws TypeError if the endpoint is invalid
  */
  validateEndpoint(endpoint, name) {
    if (this.isPath(endpoint)) {
      if (!endpoint.startsWith("/")) throw new TypeError(`${name} path must be an absolute path starting with /`);
    } else try {
      new URL(endpoint);
    } catch (e) {
      throw new TypeError(`${name} must be either an absolute path starting with / or a valid URL`);
    }
  }
  /**
  * Validates that a handler is either an ExportedHandler or a class extending WorkerEntrypoint
  * @param handler - The handler to validate
  * @param name - The name of the handler property for error messages
  * @returns The type of the handler (EXPORTED_HANDLER or WORKER_ENTRYPOINT)
  * @throws TypeError if the handler is invalid
  */
  validateHandler(handler, name) {
    if (typeof handler === "object" && handler !== null && typeof handler.fetch === "function") return {
      type: HandlerType.EXPORTED_HANDLER,
      handler
    };
    if (typeof handler === "function" && handler.prototype instanceof WorkerEntrypoint) return {
      type: HandlerType.WORKER_ENTRYPOINT,
      handler
    };
    throw new TypeError(`${name} must be either an ExportedHandler object with a fetch method or a class extending WorkerEntrypoint`);
  }
  /**
  * Validates MCP Enterprise-Managed Authorization configuration at construction time.
  *
  * Presence of `enterpriseManagedAuthorization` on options enables the feature —
  * there is no separate `enabled` flag (which would silently disable EMA when
  * forgotten). Configuration is checked structurally; runtime concerns
  * (JWKS reachability etc.) are checked when assertions arrive.
  */
  validateEmaOptions(options) {
    if (!options) return;
    if (typeof options.trustedIssuers !== "function") throw new TypeError("enterpriseManagedAuthorization.trustedIssuers must be a resolver function: (input) => EmaTrustedIssuer | null");
    if (typeof options.mapClaims !== "function") throw new TypeError("enterpriseManagedAuthorization.mapClaims must be a function");
    if (!this.options.resourceMetadata?.resource) throw new TypeError("enterpriseManagedAuthorization requires resourceMetadata.resource to be configured");
    if (options.jwksCacheTtlSeconds !== void 0 && options.jwksCacheTtlSeconds <= 0) throw new TypeError("enterpriseManagedAuthorization.jwksCacheTtlSeconds must be greater than 0");
    if (options.clockSkewSeconds !== void 0 && options.clockSkewSeconds < 0) throw new TypeError("enterpriseManagedAuthorization.clockSkewSeconds must be non-negative");
    if (options.maxAssertionLifetimeSeconds !== void 0 && options.maxAssertionLifetimeSeconds <= 0) throw new TypeError("enterpriseManagedAuthorization.maxAssertionLifetimeSeconds must be greater than 0");
  }
  /**
  * Main fetch handler for the Worker
  * Routes requests to the appropriate handler based on the URL
  * @param request - The HTTP request
  * @param env - Cloudflare Worker environment variables
  * @param ctx - Cloudflare Worker execution context
  * @returns A Promise resolving to an HTTP Response
  */
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") {
      if (this.isApiRequest(url) || url.pathname === "/.well-known/oauth-authorization-server" || this.isProtectedResourceMetadataRequest(url) || this.isTokenEndpoint(url) || this.options.clientRegistrationEndpoint && this.isClientRegistrationEndpoint(url)) return this.addCorsHeaders(new Response(null, {
        status: 204,
        headers: { "Content-Length": "0" }
      }), request);
    }
    if (url.pathname === "/.well-known/oauth-authorization-server") {
      const response = await this.handleMetadataDiscovery(url);
      return this.addCorsHeaders(response, request);
    }
    if (this.isProtectedResourceMetadataRequest(url)) {
      const response = this.handleProtectedResourceMetadata(url);
      return this.addCorsHeaders(response, request);
    }
    if (this.isTokenEndpoint(url)) {
      const parsed = await this.parseTokenEndpointRequest(request, env);
      if (parsed instanceof Response) return this.addCorsHeaders(parsed, request);
      let response;
      if (parsed.isRevocationRequest) response = await this.handleRevocationRequest(parsed.body, parsed.clientInfo, env);
      else response = await this.handleTokenRequest(parsed.body, parsed.clientInfo, env, url, request);
      return this.addCorsHeaders(response, request);
    }
    if (this.options.clientRegistrationEndpoint && this.isClientRegistrationEndpoint(url)) {
      const response = await this.handleClientRegistration(request, env);
      return this.addCorsHeaders(response, request);
    }
    if (this.isApiRequest(url)) {
      const response = await this.handleApiRequest(request, env, ctx);
      return this.addCorsHeaders(response, request);
    }
    if (!env.OAUTH_PROVIDER) env.OAUTH_PROVIDER = this.createOAuthHelpers(env);
    if (this.typedDefaultHandler.type === HandlerType.EXPORTED_HANDLER) return this.typedDefaultHandler.handler.fetch(request, env, ctx);
    else return new this.typedDefaultHandler.handler(ctx, env).fetch(request);
  }
  /**
  * Decodes a token and returns token data with decrypted props
  * @param token - The granted token
  * @param env - Cloudflare Worker environment variables
  * @returns Promise resolving to token data with decrypted props, or null if token is invalid
  */
  async unwrapToken(token, env) {
    const parts = token.split(":");
    if (!(parts.length === 3)) return null;
    const [userId, grantId] = parts;
    const id = await generateTokenId(token);
    const tokenData = await env.OAUTH_KV.get(`token:${userId}:${grantId}:${id}`, { type: "json" });
    if (!tokenData) return null;
    const now = Math.floor(Date.now() / 1e3);
    if (tokenData.expiresAt < now) return null;
    const decryptedProps = await decryptProps(await unwrapKeyWithToken(token, tokenData.wrappedEncryptionKey), tokenData.grant.encryptedProps);
    const { grant } = tokenData;
    return {
      id: tokenData.id,
      grantId: tokenData.grantId,
      userId: tokenData.userId,
      createdAt: tokenData.createdAt,
      expiresAt: tokenData.expiresAt,
      audience: tokenData.audience,
      scope: tokenData.scope || grant.scope,
      grant: {
        clientId: grant.clientId,
        scope: grant.scope,
        props: decryptedProps
      }
    };
  }
  /**
  * Determines if an endpoint configuration is a path or a full URL
  * @param endpoint - The endpoint configuration
  * @returns True if the endpoint is a path (starts with /), false if it's a full URL
  */
  isPath(endpoint) {
    return endpoint.startsWith("/");
  }
  /**
  * Matches a URL against an endpoint pattern that can be a full URL or just a path
  * @param url - The URL to check
  * @param endpoint - The endpoint pattern (full URL or path)
  * @returns True if the URL matches the endpoint pattern
  */
  matchEndpoint(url, endpoint) {
    if (this.isPath(endpoint)) return url.pathname === endpoint;
    else {
      const endpointUrl = new URL(endpoint);
      return url.hostname === endpointUrl.hostname && url.pathname === endpointUrl.pathname;
    }
  }
  /**
  * Checks if a URL matches the configured token endpoint
  * @param url - The URL to check
  * @returns True if the URL matches the token endpoint
  */
  isTokenEndpoint(url) {
    return this.matchEndpoint(url, this.options.tokenEndpoint);
  }
  /**
  * Checks if a URL matches the configured client registration endpoint
  * @param url - The URL to check
  * @returns True if the URL matches the client registration endpoint
  */
  isClientRegistrationEndpoint(url) {
    if (!this.options.clientRegistrationEndpoint) return false;
    return this.matchEndpoint(url, this.options.clientRegistrationEndpoint);
  }
  /**
  * Checks if a URL is a request for OAuth Protected Resource Metadata (RFC 9728).
  * Matches both the root well-known path and path-suffixed variants per RFC 9728 §3.1.
  */
  isProtectedResourceMetadataRequest(url) {
    return url.pathname === PROTECTED_RESOURCE_WELL_KNOWN_PREFIX || url.pathname.startsWith(PROTECTED_RESOURCE_WELL_KNOWN_PREFIX + "/");
  }
  /**
  * Derives the resource identifier from a protected resource metadata well-known URL.
  * Per RFC 9728 §3.1, the well-known URI is inserted after the authority and before the path,
  * so the resource identifier is reconstructed by removing the well-known prefix.
  *
  * Examples:
  *   /.well-known/oauth-protected-resource       → origin (e.g. https://example.com)
  *   /.well-known/oauth-protected-resource/mcp   → origin + /mcp (e.g. https://example.com/mcp)
  */
  deriveResourceIdentifier(requestUrl) {
    const suffix = requestUrl.pathname.slice(37);
    if (!suffix || suffix === "/") return requestUrl.origin;
    return `${requestUrl.origin}${suffix}`;
  }
  /**
  * Parses and validates a token endpoint request (used for both token exchange and revocation)
  * @param request - The HTTP request to parse
  * @returns Promise with parsed body and client info, or error response
  */
  async parseTokenEndpointRequest(request, env) {
    if (request.method !== "POST") return this.createErrorResponse("invalid_request", {
      description: "Method not allowed",
      statusCode: 405
    });
    let contentType = request.headers.get("Content-Type") || "";
    let body = {};
    if (!contentType.includes("application/x-www-form-urlencoded")) return this.createErrorResponse("invalid_request", {
      description: "Content-Type must be application/x-www-form-urlencoded",
      statusCode: 400
    });
    const formData = await request.formData();
    const processedKeys = /* @__PURE__ */ new Set();
    for (const [key, value] of formData.entries()) {
      if (processedKeys.has(key)) continue;
      processedKeys.add(key);
      const allValues = formData.getAll(key);
      if (key !== "resource" && allValues.length > 1) return this.createErrorResponse("invalid_request", {
        description: `Request parameter "${key}" must not be repeated`,
        statusCode: 400
      });
      body[key] = allValues.length > 1 ? allValues : value;
    }
    const authHeader = request.headers.get("Authorization");
    let clientId = "";
    let clientSecret = "";
    if (authHeader && authHeader.startsWith("Basic ")) {
      if (body.client_id || body.client_secret) return this.createErrorResponse("invalid_request", {
        description: "Client must not use multiple authentication methods",
        statusCode: 400
      });
      const credentials = atob(authHeader.substring(6));
      const separatorIndex = credentials.indexOf(":");
      if (separatorIndex === -1) return this.createErrorResponse("invalid_client", {
        description: "Client authentication failed: invalid Basic credentials",
        statusCode: 401
      });
      const id = credentials.substring(0, separatorIndex);
      const secret = credentials.substring(separatorIndex + 1);
      clientId = decodeFormUrlEncodedComponent(id);
      clientSecret = decodeFormUrlEncodedComponent(secret);
    } else {
      clientId = body.client_id;
      clientSecret = body.client_secret || "";
    }
    if (!clientId) return this.createErrorResponse("invalid_client", {
      description: "Client ID is required",
      statusCode: 401
    });
    const clientInfo = await this.getClient(env, clientId);
    if (!clientInfo) return this.createErrorResponse("invalid_client", {
      description: "Client not found",
      statusCode: 401
    });
    if (!(clientInfo.tokenEndpointAuthMethod === "none")) {
      if (!clientSecret) return this.createErrorResponse("invalid_client", {
        description: "Client authentication failed: missing client_secret",
        statusCode: 401
      });
      if (!clientInfo.clientSecret) return this.createErrorResponse("invalid_client", {
        description: "Client authentication failed: client has no registered secret",
        statusCode: 401
      });
      if (await hashSecret(clientSecret) !== clientInfo.clientSecret) return this.createErrorResponse("invalid_client", {
        description: "Client authentication failed: invalid client_secret",
        statusCode: 401
      });
    }
    return {
      body,
      clientInfo,
      isRevocationRequest: !body.grant_type && !!body.token
    };
  }
  /**
  * Checks if a URL matches a specific API route
  * @param url - The URL to check
  * @param route - The API route to check against
  * @returns True if the URL matches the API route
  */
  matchApiRoute(url, route) {
    if (this.isPath(route)) {
      if (route === "/") return url.pathname === "/";
      return url.pathname.startsWith(route);
    } else {
      const apiUrl = new URL(route);
      return url.hostname === apiUrl.hostname && url.pathname.startsWith(apiUrl.pathname);
    }
  }
  /**
  * Checks if a URL is an API request based on the configured API route(s)
  * @param url - The URL to check
  * @returns True if the URL matches any of the API routes
  */
  isApiRequest(url) {
    for (const [route, _] of this.typedApiHandlers) if (this.matchApiRoute(url, route)) return true;
    return false;
  }
  /**
  * Finds the appropriate API handler for a URL
  * @param url - The URL to find a handler for
  * @returns The TypedHandler for the URL, or undefined if no handler matches
  */
  findApiHandlerForUrl(url) {
    for (const [route, handler] of this.typedApiHandlers) if (this.matchApiRoute(url, route)) return handler;
  }
  /**
  * Gets the full URL for an endpoint, using the provided request URL's
  * origin for endpoints specified as just paths
  * @param endpoint - The endpoint configuration (path or full URL)
  * @param requestUrl - The URL of the incoming request
  * @returns The full URL for the endpoint
  */
  getFullEndpointUrl(endpoint, requestUrl) {
    if (this.isPath(endpoint)) return `${requestUrl.origin}${endpoint}`;
    else return endpoint;
  }
  /**
  * Gets the authorization server issuer using the same derivation as RFC 8414 metadata.
  */
  getAuthorizationServerIssuer(requestUrl) {
    const tokenEndpoint = this.getFullEndpointUrl(this.options.tokenEndpoint, requestUrl);
    return new URL(tokenEndpoint).origin;
  }
  /**
  * Adds CORS headers to a response
  * @param response - The response to add CORS headers to
  * @param request - The original request
  * @returns A new Response with CORS headers added
  */
  addCorsHeaders(response, request) {
    const origin = request.headers.get("Origin");
    if (!origin) return response;
    const newResponse = new Response(response.body, response);
    newResponse.headers.set("Access-Control-Allow-Origin", origin);
    newResponse.headers.set("Access-Control-Allow-Methods", "*");
    newResponse.headers.set("Access-Control-Allow-Headers", "Authorization, *");
    newResponse.headers.set("Access-Control-Max-Age", "86400");
    return newResponse;
  }
  /**
  * Handles the OAuth metadata discovery endpoint
  * Implements RFC 8414 for OAuth Server Metadata
  * @param requestUrl - The URL of the incoming request
  * @returns Response with OAuth server metadata
  */
  async handleMetadataDiscovery(requestUrl) {
    const tokenEndpoint = this.getFullEndpointUrl(this.options.tokenEndpoint, requestUrl);
    const authorizeEndpoint = this.getFullEndpointUrl(this.options.authorizeEndpoint, requestUrl);
    let registrationEndpoint = void 0;
    if (this.options.clientRegistrationEndpoint) registrationEndpoint = this.getFullEndpointUrl(this.options.clientRegistrationEndpoint, requestUrl);
    const responseTypesSupported = ["code"];
    if (this.options.allowImplicitFlow) responseTypesSupported.push("token");
    const grantTypesSupported = [GrantType.AUTHORIZATION_CODE, GrantType.REFRESH_TOKEN];
    if (this.options.allowTokenExchangeGrant) grantTypesSupported.push(GrantType.TOKEN_EXCHANGE);
    const authorizationGrantProfilesSupported = [];
    if (this.options.enterpriseManagedAuthorization) {
      grantTypesSupported.push(GrantType.JWT_BEARER);
      authorizationGrantProfilesSupported.push(EMA_ID_JAG_GRANT_PROFILE);
    }
    const metadata = {
      issuer: new URL(tokenEndpoint).origin,
      authorization_endpoint: authorizeEndpoint,
      token_endpoint: tokenEndpoint,
      registration_endpoint: registrationEndpoint,
      scopes_supported: this.options.scopesSupported,
      response_types_supported: responseTypesSupported,
      response_modes_supported: this.options.allowImplicitFlow ? ["query", "fragment"] : ["query"],
      grant_types_supported: grantTypesSupported,
      ...authorizationGrantProfilesSupported.length > 0 ? { authorization_grant_profiles_supported: authorizationGrantProfilesSupported } : {},
      token_endpoint_auth_methods_supported: [
        "client_secret_basic",
        "client_secret_post",
        "none"
      ],
      revocation_endpoint: tokenEndpoint,
      code_challenge_methods_supported: this.options.allowPlainPKCE !== false ? ["plain", "S256"] : ["S256"],
      client_id_metadata_document_supported: !!this.options.clientIdMetadataDocumentEnabled && this.hasGlobalFetchStrictlyPublic()
    };
    return new Response(JSON.stringify(metadata), { headers: { "Content-Type": "application/json" } });
  }
  /**
  * Handles the OAuth Protected Resource Metadata endpoint
  * Implements RFC 9728 for OAuth Protected Resource Metadata
  * @param requestUrl - The URL of the incoming request
  * @returns Response with protected resource metadata
  */
  handleProtectedResourceMetadata(requestUrl) {
    const rm = this.options.resourceMetadata;
    const tokenEndpointUrl = this.getFullEndpointUrl(this.options.tokenEndpoint, requestUrl);
    const authServerOrigin = new URL(tokenEndpointUrl).origin;
    const metadata = {
      resource: rm?.resource ?? this.deriveResourceIdentifier(requestUrl),
      authorization_servers: rm?.authorization_servers ?? [authServerOrigin],
      scopes_supported: rm?.scopes_supported ?? this.options.scopesSupported,
      bearer_methods_supported: rm?.bearer_methods_supported ?? ["header"]
    };
    if (rm?.resource_name) metadata.resource_name = rm.resource_name;
    return new Response(JSON.stringify(metadata), { headers: { "Content-Type": "application/json" } });
  }
  /**
  * Handles client authentication and token issuance via the token endpoint
  * Supports authorization_code and refresh_token grant types
  * @param body - The parsed request body
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response with token data or error
  */
  async handleTokenRequest(body, clientInfo, env, requestUrl, request) {
    try {
      const grantType = body.grant_type;
      if (grantType === GrantType.AUTHORIZATION_CODE) return await this.handleAuthorizationCodeGrant(body, clientInfo, env);
      else if (grantType === GrantType.REFRESH_TOKEN) return await this.handleRefreshTokenGrant(body, clientInfo, env);
      else if (grantType === GrantType.TOKEN_EXCHANGE && this.options.allowTokenExchangeGrant) return await this.handleTokenExchangeGrant(body, clientInfo, env);
      else if (grantType === GrantType.JWT_BEARER) return await this.handleJwtBearerGrant(body, clientInfo, env, requestUrl, request);
      else return this.createErrorResponse("unsupported_grant_type", { description: "Grant type not supported" });
    } catch (error) {
      const response = this.createOAuthErrorResponse(error);
      if (response) return response;
      throw error;
    }
  }
  /**
  * Build a structured OAuth `/token` error response from an OAuth error.
  *
  * The supported form is throwing this package's exported `OAuthError`.
  * Anything else is re-thrown so unexpected failures still surface as 500s.
  *
  * Use `headers['Retry-After']` for rate-limit / transient-failure backoff
  * hints (see RFC 7231 §7.1.3 — either an integer seconds value or an
  * HTTP-date is allowed).
  */
  createOAuthErrorResponse(error) {
    if (!(error instanceof OAuthError)) return void 0;
    return this.createErrorResponse(error.code, error.options);
  }
  /**
  * Handles the authorization code grant type
  * Exchanges an authorization code for access and refresh tokens
  * @param body - The parsed request body
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response with token data or error
  */
  async handleAuthorizationCodeGrant(body, clientInfo, env) {
    const code = body.code;
    const redirectUri = body.redirect_uri;
    const codeVerifier = body.code_verifier;
    if (!code) return this.createErrorResponse("invalid_request", { description: "Authorization code is required" });
    const codeParts = code.split(":");
    if (codeParts.length !== 3) return this.createErrorResponse("invalid_grant", { description: "Invalid authorization code format" });
    const [userId, grantId, _] = codeParts;
    const grantKey = `grant:${userId}:${grantId}`;
    const grantData = await env.OAUTH_KV.get(grantKey, { type: "json" });
    if (!grantData) return this.createErrorResponse("invalid_grant", { description: "Grant not found or authorization code expired" });
    const codeHash = await hashSecret(code);
    if (!grantData.authCodeId || codeHash !== grantData.authCodeId) return this.createErrorResponse("invalid_grant", { description: "Invalid authorization code" });
    if (grantData.clientId !== clientInfo.clientId) return this.createErrorResponse("invalid_grant", { description: "Client ID mismatch" });
    if (!grantData.authCodeWrappedKey) {
      try {
        await this.createOAuthHelpers(env).revokeGrant(grantId, userId);
      } catch {
      }
      return this.createErrorResponse("invalid_grant", { description: "Authorization code already used" });
    }
    const isPkceEnabled = !!grantData.codeChallenge;
    if (!redirectUri && !isPkceEnabled) return this.createErrorResponse("invalid_request", { description: "redirect_uri is required when not using PKCE" });
    if (redirectUri && !isValidRedirectUri(redirectUri, clientInfo.redirectUris)) return this.createErrorResponse("invalid_grant", { description: "Invalid redirect URI" });
    if (!isPkceEnabled && codeVerifier) return this.createErrorResponse("invalid_request", { description: "code_verifier provided for a flow that did not use PKCE" });
    if (isPkceEnabled) {
      if (!codeVerifier) return this.createErrorResponse("invalid_request", { description: "code_verifier is required for PKCE" });
      let calculatedChallenge;
      if (grantData.codeChallengeMethod === "S256") {
        const data = new TextEncoder().encode(codeVerifier);
        const hashBuffer = await crypto.subtle.digest("SHA-256", data);
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        calculatedChallenge = base64UrlEncode(String.fromCharCode(...hashArray));
      } else calculatedChallenge = codeVerifier;
      if (calculatedChallenge !== grantData.codeChallenge) return this.createErrorResponse("invalid_grant", { description: "Invalid PKCE code_verifier" });
    }
    let accessTokenTTL = this.options.accessTokenTTL;
    let refreshTokenTTL = this.options.refreshTokenTTL;
    const encryptionKey = await unwrapKeyWithToken(code, grantData.authCodeWrappedKey);
    let grantEncryptionKey = encryptionKey;
    let accessTokenEncryptionKey = encryptionKey;
    let encryptedAccessTokenProps = grantData.encryptedProps;
    let tokenScopes = this.downscope(body.scope, grantData.scope);
    if (this.options.tokenExchangeCallback) {
      const decryptedProps = await decryptProps(encryptionKey, grantData.encryptedProps);
      let grantProps = decryptedProps;
      let accessTokenProps = decryptedProps;
      const callbackOptions = {
        grantType: GrantType.AUTHORIZATION_CODE,
        clientId: clientInfo.clientId,
        userId,
        grantId,
        scope: grantData.scope,
        requestedScope: tokenScopes,
        props: decryptedProps
      };
      const callbackResult = await Promise.resolve(this.options.tokenExchangeCallback(callbackOptions));
      if (callbackResult) {
        if (callbackResult.newProps) {
          grantProps = callbackResult.newProps;
          if (!callbackResult.accessTokenProps) accessTokenProps = callbackResult.newProps;
        }
        if (callbackResult.accessTokenProps) accessTokenProps = callbackResult.accessTokenProps;
        if (callbackResult.accessTokenTTL !== void 0) accessTokenTTL = callbackResult.accessTokenTTL;
        if ("refreshTokenTTL" in callbackResult) refreshTokenTTL = callbackResult.refreshTokenTTL;
        if (callbackResult.accessTokenScope) tokenScopes = this.downscope(callbackResult.accessTokenScope, grantData.scope);
      }
      const grantResult = await encryptProps(grantProps);
      grantData.encryptedProps = grantResult.encryptedData;
      grantEncryptionKey = grantResult.key;
      if (accessTokenProps !== grantProps) {
        const tokenResult = await encryptProps(accessTokenProps);
        encryptedAccessTokenProps = tokenResult.encryptedData;
        accessTokenEncryptionKey = tokenResult.key;
      } else {
        encryptedAccessTokenProps = grantData.encryptedProps;
        accessTokenEncryptionKey = grantEncryptionKey;
      }
    }
    const now = Math.floor(Date.now() / 1e3);
    const useRefreshToken = refreshTokenTTL !== 0;
    delete grantData.codeChallenge;
    delete grantData.codeChallengeMethod;
    delete grantData.authCodeWrappedKey;
    let refreshToken;
    if (useRefreshToken) {
      refreshToken = `${userId}:${grantId}:${generateRandomString(TOKEN_LENGTH)}`;
      const refreshTokenId = await generateTokenId(refreshToken);
      const refreshTokenWrappedKey = await wrapKeyWithToken(refreshToken, grantEncryptionKey);
      const expiresAt = refreshTokenTTL !== void 0 ? now + refreshTokenTTL : void 0;
      grantData.refreshTokenId = refreshTokenId;
      grantData.refreshTokenWrappedKey = refreshTokenWrappedKey;
      grantData.previousRefreshTokenId = void 0;
      grantData.previousRefreshTokenWrappedKey = void 0;
      grantData.expiresAt = expiresAt;
    }
    await this.saveGrantWithTTL(env, grantKey, grantData, now);
    const originOnly = !!this.options.resourceMatchOriginOnly;
    if (body.resource && grantData.resource) {
      const requestedResources = Array.isArray(body.resource) ? body.resource : [body.resource];
      const grantedResources = Array.isArray(grantData.resource) ? grantData.resource : [grantData.resource];
      for (const requested of requestedResources) if (!grantedResources.some((granted) => resourceMatches(requested, granted, originOnly))) return this.createErrorResponse("invalid_target", { description: "Requested resource was not included in the authorization request" });
    }
    const audience = parseResourceParameter(body.resource || grantData.resource);
    if ((body.resource || grantData.resource) && !audience) return this.createErrorResponse("invalid_target", { description: "The resource parameter must be a valid absolute URI without a fragment" });
    const tokenResponse = {
      access_token: await this.createAccessToken({
        userId,
        grantId,
        clientId: grantData.clientId,
        scope: tokenScopes,
        encryptedProps: encryptedAccessTokenProps,
        encryptionKey: accessTokenEncryptionKey,
        expiresIn: accessTokenTTL,
        audience,
        env
      }),
      token_type: "bearer",
      expires_in: accessTokenTTL,
      scope: tokenScopes.join(" ")
    };
    if (refreshToken) tokenResponse.refresh_token = refreshToken;
    if (audience) tokenResponse.resource = audience;
    return new Response(JSON.stringify(tokenResponse), { headers: {
      "Content-Type": "application/json",
      ...NO_CACHE_HEADERS
    } });
  }
  /**
  * Handles the refresh token grant type
  * Issues a new access token using a refresh token
  * @param body - The parsed request body
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response with token data or error
  */
  async handleRefreshTokenGrant(body, clientInfo, env) {
    const refreshToken = body.refresh_token;
    if (!refreshToken) return this.createErrorResponse("invalid_request", { description: "Refresh token is required" });
    const tokenParts = refreshToken.split(":");
    if (tokenParts.length !== 3) return this.createErrorResponse("invalid_grant", { description: "Invalid token format" });
    const [userId, grantId, _] = tokenParts;
    const providedTokenHash = await generateTokenId(refreshToken);
    const grantKey = `grant:${userId}:${grantId}`;
    const grantData = await env.OAUTH_KV.get(grantKey, { type: "json" });
    if (!grantData) return this.createErrorResponse("invalid_grant", { description: "Grant not found" });
    const isCurrentToken = grantData.refreshTokenId === providedTokenHash;
    const isPreviousToken = grantData.previousRefreshTokenId === providedTokenHash;
    if (!isCurrentToken && !isPreviousToken) return this.createErrorResponse("invalid_grant", { description: "Invalid refresh token" });
    if (grantData.clientId !== clientInfo.clientId) return this.createErrorResponse("invalid_grant", { description: "Client ID mismatch" });
    if (grantData.expiresAt !== void 0) {
      const now$1 = Math.floor(Date.now() / 1e3);
      if (grantData.expiresAt - now$1 < KV_MIN_EXPIRATION_TTL_SECONDS) return this.createErrorResponse("invalid_grant", { description: "Refresh token has expired" });
    }
    const newAccessToken = `${userId}:${grantId}:${generateRandomString(TOKEN_LENGTH)}`;
    const accessTokenId = await generateTokenId(newAccessToken);
    let accessTokenTTL = this.options.accessTokenTTL;
    let wrappedKeyToUse;
    if (isCurrentToken) wrappedKeyToUse = grantData.refreshTokenWrappedKey;
    else wrappedKeyToUse = grantData.previousRefreshTokenWrappedKey;
    const encryptionKey = await unwrapKeyWithToken(refreshToken, wrappedKeyToUse);
    let grantEncryptionKey = encryptionKey;
    let accessTokenEncryptionKey = encryptionKey;
    let encryptedAccessTokenProps = grantData.encryptedProps;
    let tokenScopes = this.downscope(body.scope, grantData.scope);
    let grantPropsChanged = false;
    if (this.options.tokenExchangeCallback) {
      const decryptedProps = await decryptProps(encryptionKey, grantData.encryptedProps);
      let grantProps = decryptedProps;
      let accessTokenProps = decryptedProps;
      const callbackOptions = {
        grantType: GrantType.REFRESH_TOKEN,
        clientId: clientInfo.clientId,
        userId,
        grantId,
        scope: grantData.scope,
        requestedScope: tokenScopes,
        props: decryptedProps
      };
      const callbackResult = await Promise.resolve(this.options.tokenExchangeCallback(callbackOptions));
      if (callbackResult) {
        if (callbackResult.newProps) {
          grantProps = callbackResult.newProps;
          grantPropsChanged = true;
          if (!callbackResult.accessTokenProps) accessTokenProps = callbackResult.newProps;
        }
        if (callbackResult.accessTokenProps) accessTokenProps = callbackResult.accessTokenProps;
        if (callbackResult.accessTokenTTL !== void 0) accessTokenTTL = callbackResult.accessTokenTTL;
        if ("refreshTokenTTL" in callbackResult) return this.createErrorResponse("invalid_request", { description: "refreshTokenTTL cannot be changed during refresh token exchange" });
        if (callbackResult.accessTokenScope) tokenScopes = this.downscope(callbackResult.accessTokenScope, grantData.scope);
      }
      if (grantPropsChanged) {
        const grantResult = await encryptProps(grantProps);
        grantData.encryptedProps = grantResult.encryptedData;
        if (grantResult.key !== encryptionKey) {
          grantEncryptionKey = grantResult.key;
          wrappedKeyToUse = await wrapKeyWithToken(refreshToken, grantEncryptionKey);
        } else grantEncryptionKey = grantResult.key;
      }
      if (accessTokenProps !== grantProps) {
        const tokenResult = await encryptProps(accessTokenProps);
        encryptedAccessTokenProps = tokenResult.encryptedData;
        accessTokenEncryptionKey = tokenResult.key;
      } else {
        encryptedAccessTokenProps = grantData.encryptedProps;
        accessTokenEncryptionKey = grantEncryptionKey;
      }
    }
    const now = Math.floor(Date.now() / 1e3);
    if (grantData.expiresAt !== void 0 && grantData.expiresAt - now < KV_MIN_EXPIRATION_TTL_SECONDS) return this.createErrorResponse("invalid_grant", { description: "Refresh token has expired" });
    if (grantData.expiresAt !== void 0) {
      const remainingRefreshTokenLifetime = grantData.expiresAt - now;
      if (remainingRefreshTokenLifetime > 0) accessTokenTTL = Math.min(accessTokenTTL, remainingRefreshTokenLifetime);
    }
    if (accessTokenTTL < KV_MIN_EXPIRATION_TTL_SECONDS) return this.createErrorResponse("invalid_request", { description: "Requested token lifetime must be at least 60 seconds" });
    const accessTokenExpiresAt = now + accessTokenTTL;
    const accessTokenWrappedKey = await wrapKeyWithToken(newAccessToken, accessTokenEncryptionKey);
    const newRefreshToken = `${userId}:${grantId}:${generateRandomString(TOKEN_LENGTH)}`;
    const newRefreshTokenId = await generateTokenId(newRefreshToken);
    const newRefreshTokenWrappedKey = await wrapKeyWithToken(newRefreshToken, grantEncryptionKey);
    grantData.previousRefreshTokenId = providedTokenHash;
    grantData.previousRefreshTokenWrappedKey = wrappedKeyToUse;
    grantData.refreshTokenId = newRefreshTokenId;
    grantData.refreshTokenWrappedKey = newRefreshTokenWrappedKey;
    await this.saveGrantWithTTL(env, grantKey, grantData, now);
    const originOnly = !!this.options.resourceMatchOriginOnly;
    if (body.resource && grantData.resource) {
      const requestedResources = Array.isArray(body.resource) ? body.resource : [body.resource];
      const grantedResources = Array.isArray(grantData.resource) ? grantData.resource : [grantData.resource];
      for (const requested of requestedResources) if (!grantedResources.some((granted) => resourceMatches(requested, granted, originOnly))) return this.createErrorResponse("invalid_target", { description: "Requested resource was not included in the authorization request" });
    }
    const audience = parseResourceParameter(body.resource || grantData.resource);
    if ((body.resource || grantData.resource) && !audience) return this.createErrorResponse("invalid_target", { description: "The resource parameter must be a valid absolute URI without a fragment" });
    const accessTokenData = {
      id: accessTokenId,
      grantId,
      userId,
      createdAt: now,
      expiresAt: accessTokenExpiresAt,
      audience,
      scope: tokenScopes,
      wrappedEncryptionKey: accessTokenWrappedKey,
      grant: {
        clientId: grantData.clientId,
        scope: grantData.scope,
        encryptedProps: encryptedAccessTokenProps
      }
    };
    try {
      await env.OAUTH_KV.put(`token:${userId}:${grantId}:${accessTokenId}`, JSON.stringify(accessTokenData), { expirationTtl: accessTokenTTL });
    } catch (error) {
      this.throwRetryableTokenStorageErrorIfKvRateLimited(error);
      throw error;
    }
    const tokenResponse = {
      access_token: newAccessToken,
      token_type: "bearer",
      expires_in: accessTokenTTL,
      refresh_token: newRefreshToken,
      scope: tokenScopes.join(" ")
    };
    if (audience) tokenResponse.resource = audience;
    return new Response(JSON.stringify(tokenResponse), { headers: {
      "Content-Type": "application/json",
      ...NO_CACHE_HEADERS
    } });
  }
  /**
  * Core token exchange logic (RFC 8693)
  * Performs the actual token exchange operation
  * This method is not private because `OAuthHelpers` needs to call it. Note that since
  * `OAuthProviderImpl` is not exposed outside this module, this is still effectively
  * module-private.
  * @param subjectToken - The subject token to exchange
  * @param requestedScopes - Optional narrowed scopes (must be subset of original)
  * @param requestedResource - Optional resource/audience (must be subset of original if original had resource)
  * @param expiresIn - Optional TTL override in seconds
  * @param clientInfo - The client making the exchange request
  * @param env - Cloudflare Worker environment variables
  * @returns Promise resolving to token response
  * @throws OAuthError with OAuth error code and description
  */
  async exchangeToken(subjectToken, requestedScopes, requestedResource, expiresIn, clientInfo, env) {
    const tokenSummary = await this.unwrapToken(subjectToken, env);
    if (!tokenSummary) throw new OAuthError("invalid_grant", { description: "Invalid or expired subject token" });
    const grantKey = `grant:${tokenSummary.userId}:${tokenSummary.grantId}`;
    const grantData = await env.OAUTH_KV.get(grantKey, { type: "json" });
    if (!grantData) throw new OAuthError("invalid_grant", { description: "Grant not found" });
    let tokenScopes = this.downscope(requestedScopes, grantData.scope);
    const originOnly = !!this.options.resourceMatchOriginOnly;
    let newAudience = tokenSummary.audience;
    if (requestedResource) {
      if (grantData.resource) {
        const requestedResources = Array.isArray(requestedResource) ? requestedResource : [requestedResource];
        const grantedResources = Array.isArray(grantData.resource) ? grantData.resource : [grantData.resource];
        for (const requested of requestedResources) if (!grantedResources.some((granted) => resourceMatches(requested, granted, originOnly))) throw new OAuthError("invalid_target", { description: "Requested resource was not included in the authorization request" });
      }
      const parsedResource = parseResourceParameter(requestedResource);
      if (!parsedResource) throw new OAuthError("invalid_target", { description: "The resource parameter must be a valid absolute URI without a fragment" });
      newAudience = parsedResource;
    }
    const now = Math.floor(Date.now() / 1e3);
    const subjectTokenRemainingLifetime = tokenSummary.expiresAt - now;
    if (subjectTokenRemainingLifetime < KV_MIN_EXPIRATION_TTL_SECONDS) throw new OAuthError("invalid_grant", { description: "Subject token is too close to expiry to exchange" });
    let accessTokenTTL = this.options.accessTokenTTL ?? DEFAULT_ACCESS_TOKEN_TTL;
    if (expiresIn !== void 0) {
      if (expiresIn <= 0) throw new OAuthError("invalid_request", { description: "Invalid expires_in parameter" });
      accessTokenTTL = Math.min(expiresIn, subjectTokenRemainingLifetime);
    } else accessTokenTTL = Math.min(accessTokenTTL, subjectTokenRemainingLifetime);
    const subjectTokenData = await env.OAUTH_KV.get(`token:${tokenSummary.userId}:${tokenSummary.grantId}:${tokenSummary.id}`, { type: "json" });
    if (!subjectTokenData) throw new OAuthError("invalid_grant", { description: "Subject token data not found" });
    const encryptionKey = await unwrapKeyWithToken(subjectToken, subjectTokenData.wrappedEncryptionKey);
    let accessTokenEncryptionKey = encryptionKey;
    let encryptedAccessTokenProps = subjectTokenData.grant.encryptedProps;
    if (this.options.tokenExchangeCallback) {
      const decryptedProps = await decryptProps(encryptionKey, subjectTokenData.grant.encryptedProps);
      const callbackOptions = {
        grantType: GrantType.TOKEN_EXCHANGE,
        clientId: clientInfo.clientId,
        userId: tokenSummary.userId,
        grantId: tokenSummary.grantId,
        scope: tokenSummary.grant.scope,
        requestedScope: tokenScopes,
        props: decryptedProps
      };
      const callbackResult = await Promise.resolve(this.options.tokenExchangeCallback(callbackOptions));
      if (callbackResult) {
        let accessTokenProps = decryptedProps;
        if (callbackResult.newProps) {
          if (!callbackResult.accessTokenProps) accessTokenProps = callbackResult.newProps;
        }
        if (callbackResult.accessTokenProps) accessTokenProps = callbackResult.accessTokenProps;
        if (callbackResult.accessTokenTTL !== void 0) accessTokenTTL = Math.min(callbackResult.accessTokenTTL, subjectTokenRemainingLifetime);
        if (accessTokenProps !== decryptedProps) {
          const tokenResult = await encryptProps(accessTokenProps);
          encryptedAccessTokenProps = tokenResult.encryptedData;
          accessTokenEncryptionKey = tokenResult.key;
        }
        if (callbackResult.accessTokenScope) tokenScopes = this.downscope(callbackResult.accessTokenScope, grantData.scope);
      }
    }
    if (accessTokenTTL < KV_MIN_EXPIRATION_TTL_SECONDS) throw new OAuthError("invalid_request", { description: "Requested token lifetime must be at least 60 seconds" });
    const tokenResponse = {
      access_token: await this.createAccessToken({
        userId: tokenSummary.userId,
        grantId: tokenSummary.grantId,
        clientId: tokenSummary.grant.clientId,
        scope: tokenScopes,
        encryptedProps: encryptedAccessTokenProps,
        encryptionKey: accessTokenEncryptionKey,
        expiresIn: accessTokenTTL,
        audience: newAudience,
        env
      }),
      issued_token_type: "urn:ietf:params:oauth:token-type:access_token",
      token_type: "bearer",
      expires_in: accessTokenTTL,
      scope: tokenScopes.join(" ")
    };
    if (newAudience) tokenResponse.resource = newAudience;
    return tokenResponse;
  }
  /**
  * Handles OAuth 2.0 token exchange requests (RFC 8693)
  * Exchanges an existing access token for a new one with modified characteristics
  * @param body - The parsed request body
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response with new token data or error
  */
  async handleTokenExchangeGrant(body, clientInfo, env) {
    const subjectToken = body.subject_token;
    const subjectTokenType = body.subject_token_type;
    const requestedTokenType = body.requested_token_type || "urn:ietf:params:oauth:token-type:access_token";
    const requestedScope = body.scope;
    const requestedResource = body.resource;
    if (!subjectToken) return this.createErrorResponse("invalid_request", { description: "subject_token is required" });
    if (!subjectTokenType) return this.createErrorResponse("invalid_request", { description: "subject_token_type is required" });
    if (subjectTokenType !== "urn:ietf:params:oauth:token-type:access_token") return this.createErrorResponse("invalid_request", { description: "Only access_token subject_token_type is supported" });
    if (requestedTokenType !== "urn:ietf:params:oauth:token-type:access_token") return this.createErrorResponse("invalid_request", { description: "Only access_token requested_token_type is supported" });
    let requestedScopes;
    if (requestedScope) if (typeof requestedScope === "string") requestedScopes = requestedScope.split(" ").filter(Boolean);
    else if (Array.isArray(requestedScope)) requestedScopes = requestedScope;
    else return this.createErrorResponse("invalid_request", { description: "Invalid scope parameter format" });
    let expiresIn;
    if (body.expires_in !== void 0) {
      const requestedTTL = parseInt(body.expires_in, 10);
      if (isNaN(requestedTTL) || requestedTTL <= 0) return this.createErrorResponse("invalid_request", { description: "Invalid expires_in parameter" });
      expiresIn = requestedTTL;
    }
    try {
      const tokenResponse = await this.exchangeToken(subjectToken, requestedScopes, requestedResource, expiresIn, clientInfo, env);
      return new Response(JSON.stringify(tokenResponse), { headers: {
        "Content-Type": "application/json",
        ...NO_CACHE_HEADERS
      } });
    } catch (error) {
      const response = this.createOAuthErrorResponse(error);
      if (response) return response;
      throw error;
    }
  }
  /**
  * Handles the MCP Enterprise-Managed Authorization JWT-bearer grant.
  *
  * Acts as a thin shell around `runEmaPipeline`: gate non-EMA traffic, run
  * the pipeline, translate the typed `EmaValidationError` Result back to a
  * standard OAuth wire response. All validation logic lives in pure
  * functions in `src/ema/`.
  */
  async handleJwtBearerGrant(body, clientInfo, env, requestUrl, request) {
    const enterpriseOptions = this.options.enterpriseManagedAuthorization;
    if (!enterpriseOptions) return this.createErrorResponse("unsupported_grant_type", { description: "Grant type not supported" });
    if (clientInfo.tokenEndpointAuthMethod === "none" && !enterpriseOptions.allowPublicClients) return this.createErrorResponse("invalid_client", {
      description: "Enterprise-managed authorization requires client authentication",
      statusCode: 401
    });
    const result = await this.runEmaPipeline({
      body,
      clientInfo,
      env,
      requestUrl,
      request,
      enterpriseOptions
    });
    if (!result.ok) {
      const wire = emaErrorToWire(result.error);
      return this.createErrorResponse(wire.code, { description: wire.message }, {
        category: "enterprise-managed-authorization",
        reason: result.error.reason,
        detail: result.error
      });
    }
    return new Response(JSON.stringify(result.value), { headers: {
      "Content-Type": "application/json",
      ...NO_CACHE_HEADERS
    } });
  }
  /**
  * Runs the full EMA token-request pipeline as a chain of pure validators
  * and adapter calls. Each step short-circuits on the first failure.
  *
  * Sequence:
  *   parse → validate header → trust issuer → fetch JWKS → select key →
  *   verify signature → validate claims → record jti → parse scope →
  *   run mapper → validate mapper result → compute TTL → mint token.
  */
  async runEmaPipeline(args) {
    const { body, clientInfo, env, requestUrl, request, enterpriseOptions } = args;
    const { jwksProvider, jtiStore } = this;
    const configuredResource = this.options.resourceMetadata?.resource;
    if (!jwksProvider || !jtiStore || !configuredResource) throw new Error("EMA pipeline invoked without configured adapters");
    const now = Math.floor(Date.now() / 1e3);
    const parsed = parseIdJag(body.assertion, EMA_MAX_JWT_BYTES);
    if (!parsed.ok) return parsed;
    const header = validateIdJagHeader(parsed.value.header, EMA_ID_JAG_JWT_TYPE, EMA_SUPPORTED_JWT_ALGORITHMS);
    if (!header.ok) return header;
    const alg = header.value.alg;
    const trustedIssuer = await resolveTrustedIssuer({
      iss: parsed.value.rawClaims.iss,
      alg,
      resolver: enterpriseOptions.trustedIssuers,
      env,
      request,
      clientInfo
    });
    if (!trustedIssuer.ok) return trustedIssuer;
    const verified = await this.verifyAssertionSignature({
      parsed: parsed.value,
      header: header.value,
      trustedIssuer: trustedIssuer.value,
      jwksProvider,
      now
    });
    if (!verified.ok) return verified;
    const claims = validateIdJagClaims({
      rawClaims: parsed.value.rawClaims,
      trustedIssuer: trustedIssuer.value,
      expectedAudience: trustedIssuer.value.audience ?? this.getAuthorizationServerIssuer(requestUrl),
      clientId: clientInfo.clientId,
      configuredResource,
      matchOriginOnly: !!this.options.resourceMatchOriginOnly,
      now,
      clockSkewSeconds: enterpriseOptions.clockSkewSeconds ?? EMA_DEFAULT_CLOCK_SKEW_SECONDS,
      maxAssertionLifetimeSeconds: enterpriseOptions.maxAssertionLifetimeSeconds ?? EMA_DEFAULT_MAX_ASSERTION_LIFETIME_SECONDS
    });
    if (!claims.ok) return claims;
    const markNow = Math.floor(Date.now() / 1e3);
    const replay = await jtiStore.markUsed({
      issuer: claims.value.claims.iss,
      jti: claims.value.claims.jti,
      exp: claims.value.claims.exp,
      now: markNow,
      env
    });
    if (!replay.ok) return replay;
    const requestedScope = parseEmaScopeParam(body.scope, claims.value.assertionScopes);
    if (!requestedScope.ok) return requestedScope;
    let mapperOutput;
    try {
      mapperOutput = await enterpriseOptions.mapClaims({
        claims: claims.value.claims,
        clientInfo,
        resource: claims.value.resource,
        requestedScope: requestedScope.value,
        request: args.request,
        env
      });
    } catch {
      return err({ reason: "mapper_threw" });
    }
    const mapped = validateEmaMapperResult(mapperOutput);
    if (!mapped.ok) return mapped;
    const issueNow = Math.floor(Date.now() / 1e3);
    const ttl = computeEmaAccessTokenTTL({
      configuredDefaultSeconds: this.options.accessTokenTTL ?? DEFAULT_ACCESS_TOKEN_TTL,
      assertionExp: claims.value.claims.exp,
      mapperTtl: mapped.value.accessTokenTTL,
      now: issueNow,
      minTtlSeconds: KV_MIN_EXPIRATION_TTL_SECONDS
    });
    if (!ttl.ok) return ttl;
    return ok(await this.issueEmaAccessToken({
      clientId: clientInfo.clientId,
      userId: mapped.value.userId,
      mapperScope: mapped.value.scope,
      mapperProps: mapped.value.props,
      mapperMetadata: mapped.value.metadata,
      assertionScopes: claims.value.assertionScopes,
      resource: claims.value.resource,
      accessTokenTTLSeconds: ttl.value,
      env,
      now: issueNow
    }));
  }
  /**
  * Verifies the ID-JAG signature against the trusted issuer's JWKS,
  * force-refreshing once on a `kid` miss to accommodate IdP key rotation.
  * Uses the in-memory cached JWKS fetcher with anti-DoS cool-down.
  */
  async verifyAssertionSignature(args) {
    const alg = args.header.alg;
    const { jwksProvider } = args;
    const initialJwks = await jwksProvider.fetch(args.trustedIssuer, {
      forceRefresh: false,
      now: args.now
    });
    if (!initialJwks.ok) return initialJwks;
    let jwk = selectJwk(initialJwks.value, alg, args.header.kid);
    if (!jwk.ok && args.header.kid) {
      const refreshed = await jwksProvider.fetch(args.trustedIssuer, {
        forceRefresh: true,
        now: args.now
      });
      if (!refreshed.ok) return refreshed;
      jwk = selectJwk(refreshed.value, alg, args.header.kid);
    }
    if (!jwk.ok) return jwk;
    if (!await verifyIdJagSignature({
      alg,
      jwk: jwk.value,
      signingInput: args.parsed.signingInput,
      signature: args.parsed.signature
    })) return err({ reason: "signature_failed" });
    return ok(void 0);
  }
  /**
  * Mints the access token for an authorized EMA request.
  *
  * Uses the same grant + access-token machinery as the authorization-code
  * grant: encrypt the props, persist the grant under `grant:userId:grantId`,
  * and create an opaque access token bound to the resource as audience.
  */
  async issueEmaAccessToken(args) {
    const tokenScopes = args.assertionScopes.length > 0 ? this.downscope(args.mapperScope, args.assertionScopes) : args.mapperScope;
    const grantId = generateRandomString(16);
    const { encryptedData, key: encryptionKey } = await encryptProps(args.mapperProps);
    const grant = {
      id: grantId,
      clientId: args.clientId,
      userId: args.userId,
      scope: tokenScopes,
      metadata: args.mapperMetadata ?? null,
      encryptedProps: encryptedData,
      createdAt: args.now,
      expiresAt: args.now + args.accessTokenTTLSeconds,
      resource: args.resource
    };
    await this.saveGrantWithTTL(args.env, `grant:${args.userId}:${grantId}`, grant, args.now);
    return {
      access_token: await this.createAccessToken({
        userId: args.userId,
        grantId,
        clientId: args.clientId,
        scope: tokenScopes,
        encryptedProps: encryptedData,
        encryptionKey,
        expiresIn: args.accessTokenTTLSeconds,
        audience: args.resource,
        env: args.env
      }),
      token_type: "bearer",
      expires_in: args.accessTokenTTLSeconds,
      scope: tokenScopes.join(" "),
      resource: args.resource
    };
  }
  /**
  * Handles OAuth 2.0 token revocation requests (RFC 7009)
  * @param body - The parsed request body containing revocation parameters
  * @param env - Cloudflare Worker environment variables
  * @returns Response confirming revocation or error
  */
  async handleRevocationRequest(body, clientInfo, env) {
    return this.revokeToken(body, clientInfo, env);
  }
  /**
  * - Access tokens: Revokes only the specific token
  * - Refresh tokens: Revokes the entire grant (access + refresh tokens)
  * Per RFC 7009 §2.1, the server MUST verify the token was issued to the client making the request.
  * @param body - The parsed request body containing token parameter
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response confirming revocation or error
  */
  async revokeToken(body, clientInfo, env) {
    const token = body.token;
    const tokenTypeHint = body.token_type_hint;
    if (!token) return this.createErrorResponse("invalid_request", { description: "Token parameter is required" });
    const tokenParts = token.split(":");
    if (tokenParts.length !== 3) return new Response("", { status: 200 });
    const [userId, grantId, _] = tokenParts;
    const tokenId = await generateTokenId(token);
    if (tokenTypeHint === "refresh_token") {
      if (await this.revokeRefreshIfOwned(tokenId, userId, grantId, clientInfo, env)) return new Response("", { status: 200 });
      if (await this.revokeAccessIfOwned(tokenId, userId, grantId, clientInfo, env)) return new Response("", { status: 200 });
    } else {
      if (await this.revokeAccessIfOwned(tokenId, userId, grantId, clientInfo, env)) return new Response("", { status: 200 });
      if (await this.revokeRefreshIfOwned(tokenId, userId, grantId, clientInfo, env)) return new Response("", { status: 200 });
    }
    return new Response("", { status: 200 });
  }
  /** Revoke an access token if it exists and belongs to the requesting client. */
  async revokeAccessIfOwned(tokenId, userId, grantId, clientInfo, env) {
    const tokenData = await env.OAUTH_KV.get(`token:${userId}:${grantId}:${tokenId}`, { type: "json" });
    if (!tokenData) return false;
    const tokenClientId = tokenData.grant?.clientId;
    if (tokenClientId !== void 0) {
      if (tokenClientId !== clientInfo.clientId) return false;
    } else if ((await env.OAUTH_KV.get(`grant:${userId}:${grantId}`, { type: "json" }))?.clientId !== clientInfo.clientId) return false;
    await this.revokeSpecificAccessToken(tokenId, userId, grantId, env);
    return true;
  }
  /** Revoke a refresh token (and its grant) if it exists and belongs to the requesting client. */
  async revokeRefreshIfOwned(tokenId, userId, grantId, clientInfo, env) {
    const grantData = await env.OAUTH_KV.get(`grant:${userId}:${grantId}`, { type: "json" });
    if (!grantData) return false;
    if (!(grantData.refreshTokenId === tokenId || grantData.previousRefreshTokenId === tokenId)) return false;
    if (grantData.clientId !== clientInfo.clientId) return false;
    await this.createOAuthHelpers(env).revokeGrant(grantId, userId);
    return true;
  }
  /**
  * Revokes a specific access token without affecting the refresh token
  * @param tokenId - The hashed token ID
  * @param userId - The user ID extracted from the token
  * @param grantId - The grant ID extracted from the token
  * @param env - Cloudflare Worker environment variables
  */
  async revokeSpecificAccessToken(tokenId, userId, grantId, env) {
    const tokenKey = `token:${userId}:${grantId}:${tokenId}`;
    await env.OAUTH_KV.delete(tokenKey);
  }
  /**
  * Handles the dynamic client registration endpoint (RFC 7591)
  * @param request - The HTTP request
  * @param env - Cloudflare Worker environment variables
  * @returns Response with client registration data or error
  */
  async handleClientRegistration(request, env) {
    if (!this.options.clientRegistrationEndpoint) return this.createErrorResponse("not_implemented", {
      description: "Client registration is not enabled",
      statusCode: 501
    });
    if (request.method !== "POST") return this.createErrorResponse("invalid_request", {
      description: "Method not allowed",
      statusCode: 405
    });
    if (parseInt(request.headers.get("Content-Length") || "0", 10) > 1048576) return this.createErrorResponse("invalid_request", {
      description: "Request payload too large, must be under 1 MiB",
      statusCode: 413
    });
    const callbackRequest = request.clone();
    let clientMetadata;
    try {
      const text = await request.text();
      if (text.length > 1048576) return this.createErrorResponse("invalid_request", {
        description: "Request payload too large, must be under 1 MiB",
        statusCode: 413
      });
      clientMetadata = JSON.parse(text);
    } catch (error) {
      return this.createErrorResponse("invalid_request", {
        description: "Invalid JSON payload",
        statusCode: 400
      });
    }
    const authMethod = OAuthProviderImpl2.validateStringField(clientMetadata.token_endpoint_auth_method) || "client_secret_basic";
    const isPublicClient = authMethod === "none";
    if (isPublicClient && this.options.disallowPublicClientRegistration) return this.createErrorResponse("invalid_client_metadata", { description: "Public client registration is not allowed" });
    const clientId = generateRandomString(16);
    let clientSecret;
    let hashedSecret;
    if (!isPublicClient) {
      clientSecret = generateRandomString(32);
      hashedSecret = await hashSecret(clientSecret);
    }
    let clientInfo;
    try {
      const redirectUris = OAuthProviderImpl2.validateStringArray(clientMetadata.redirect_uris);
      if (!redirectUris || redirectUris.length === 0) throw new Error("At least one redirect URI is required");
      for (const uri of redirectUris) validateRedirectUriScheme(uri);
      clientInfo = {
        clientId,
        redirectUris,
        clientName: OAuthProviderImpl2.validateStringField(clientMetadata.client_name, "client_name"),
        logoUri: OAuthProviderImpl2.validateOptionalUriField(clientMetadata.logo_uri, "logo_uri"),
        clientUri: OAuthProviderImpl2.validateOptionalUriField(clientMetadata.client_uri, "client_uri"),
        policyUri: OAuthProviderImpl2.validateOptionalUriField(clientMetadata.policy_uri, "policy_uri"),
        tosUri: OAuthProviderImpl2.validateOptionalUriField(clientMetadata.tos_uri, "tos_uri"),
        jwksUri: OAuthProviderImpl2.validateOptionalUriField(clientMetadata.jwks_uri, "jwks_uri"),
        i18n: OAuthProviderImpl2.extractI18nFields(clientMetadata),
        contacts: OAuthProviderImpl2.validateStringArray(clientMetadata.contacts),
        grantTypes: OAuthProviderImpl2.validateStringArray(clientMetadata.grant_types) || [
          GrantType.AUTHORIZATION_CODE,
          GrantType.REFRESH_TOKEN,
          ...this.options.allowTokenExchangeGrant ? [GrantType.TOKEN_EXCHANGE] : []
        ],
        responseTypes: OAuthProviderImpl2.validateStringArray(clientMetadata.response_types) || ["code"],
        registrationDate: Math.floor(Date.now() / 1e3),
        tokenEndpointAuthMethod: authMethod
      };
      if (!isPublicClient && hashedSecret) clientInfo.clientSecret = hashedSecret;
    } catch (error) {
      return this.createErrorResponse("invalid_client_metadata", { description: error instanceof Error ? error.message : "Invalid client metadata" });
    }
    if (this.options.clientRegistrationCallback) {
      let callbackResult;
      try {
        callbackResult = await Promise.resolve(this.options.clientRegistrationCallback({
          clientMetadata,
          request: callbackRequest
        }));
      } catch (error) {
        return this.createErrorResponse("server_error", {
          description: error instanceof Error ? error.message : "Client registration callback failed",
          statusCode: 500
        });
      }
      if (callbackResult !== void 0) return this.createErrorResponse(callbackResult.code || "invalid_client_metadata", {
        description: callbackResult.description || "Client registration denied",
        statusCode: callbackResult.status ?? 400
      });
    }
    const clientKvOptions = {};
    if (this.options.clientRegistrationTTL !== void 0) clientKvOptions.expirationTtl = this.options.clientRegistrationTTL;
    await env.OAUTH_KV.put(`client:${clientId}`, JSON.stringify(clientInfo), clientKvOptions);
    const response = {
      client_id: clientInfo.clientId,
      redirect_uris: clientInfo.redirectUris,
      client_name: clientInfo.clientName,
      logo_uri: clientInfo.logoUri,
      client_uri: clientInfo.clientUri,
      policy_uri: clientInfo.policyUri,
      tos_uri: clientInfo.tosUri,
      jwks_uri: clientInfo.jwksUri,
      contacts: clientInfo.contacts,
      grant_types: clientInfo.grantTypes,
      response_types: clientInfo.responseTypes,
      token_endpoint_auth_method: clientInfo.tokenEndpointAuthMethod,
      registration_client_uri: `${this.options.clientRegistrationEndpoint}/${clientId}`,
      client_id_issued_at: clientInfo.registrationDate
    };
    if (clientInfo.i18n) {
      for (const [key, value] of Object.entries(clientInfo.i18n)) if (!(key in response)) response[key] = value;
    }
    if (clientSecret) {
      response.client_secret = clientSecret;
      response.client_secret_expires_at = this.options.clientRegistrationTTL && clientInfo.registrationDate ? clientInfo.registrationDate + this.options.clientRegistrationTTL : 0;
      response.client_secret_issued_at = clientInfo.registrationDate;
    }
    return new Response(JSON.stringify(response), {
      status: 201,
      headers: {
        "Content-Type": "application/json",
        ...NO_CACHE_HEADERS
      }
    });
  }
  /**
  * Handles API requests by validating the access token and calling the API handler
  * @param request - The HTTP request
  * @param env - Cloudflare Worker environment variables
  * @param ctx - Cloudflare Worker execution context
  * @returns Response from the API handler or error
  */
  async handleApiRequest(request, env, ctx) {
    const url = new URL(request.url);
    const resourceMetadataUrl = `${url.origin}/.well-known/oauth-protected-resource${url.pathname}`;
    const authHeader = request.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) return this.createErrorResponse("invalid_token", {
      description: "Missing or invalid access token",
      statusCode: 401,
      headers: { "WWW-Authenticate": this.buildWwwAuthenticateHeader(resourceMetadataUrl, "invalid_token", "Missing or invalid access token") }
    });
    const accessToken = authHeader.substring(7);
    const parts = accessToken.split(":");
    const isPossiblyInternalFormat = parts.length === 3;
    let tokenData = null;
    let userId = "";
    let grantId = "";
    if (isPossiblyInternalFormat) {
      [userId, grantId] = parts;
      const id = await generateTokenId(accessToken);
      tokenData = await env.OAUTH_KV.get(`token:${userId}:${grantId}:${id}`, { type: "json" });
    }
    if (!tokenData && !this.options.resolveExternalToken) return this.createErrorResponse("invalid_token", {
      description: "Invalid access token",
      statusCode: 401,
      headers: { "WWW-Authenticate": this.buildWwwAuthenticateHeader(resourceMetadataUrl, "invalid_token") }
    });
    if (tokenData) {
      const now = Math.floor(Date.now() / 1e3);
      if (tokenData.expiresAt < now) return this.createErrorResponse("invalid_token", {
        description: "Access token expired",
        statusCode: 401,
        headers: { "WWW-Authenticate": this.buildWwwAuthenticateHeader(resourceMetadataUrl, "invalid_token") }
      });
      if (tokenData.audience) {
        const requestUrl = new URL(request.url);
        const resourceServer = `${requestUrl.protocol}//${requestUrl.host}${requestUrl.pathname}`;
        if (!(Array.isArray(tokenData.audience) ? tokenData.audience : [tokenData.audience]).some((aud) => audienceMatches(resourceServer, aud))) return this.createErrorResponse("invalid_token", {
          description: "Token audience does not match resource server",
          statusCode: 401,
          headers: { "WWW-Authenticate": this.buildWwwAuthenticateHeader(resourceMetadataUrl, "invalid_token", "Invalid audience") }
        });
      }
      ctx.props = await decryptProps(await unwrapKeyWithToken(accessToken, tokenData.wrappedEncryptionKey), tokenData.grant.encryptedProps);
    } else if (this.options.resolveExternalToken) {
      const ext = await this.options.resolveExternalToken({
        token: accessToken,
        request,
        env
      });
      if (!ext) return this.createErrorResponse("invalid_token", {
        description: "Invalid access token",
        statusCode: 401,
        headers: { "WWW-Authenticate": this.buildWwwAuthenticateHeader(resourceMetadataUrl, "invalid_token") }
      });
      if (ext.audience) {
        const requestUrl = new URL(request.url);
        const resourceServer = `${requestUrl.protocol}//${requestUrl.host}${requestUrl.pathname}`;
        if (!(Array.isArray(ext.audience) ? ext.audience : [ext.audience]).some((aud) => audienceMatches(resourceServer, aud))) return this.createErrorResponse("invalid_token", {
          description: "Token audience does not match resource server",
          statusCode: 401,
          headers: { "WWW-Authenticate": this.buildWwwAuthenticateHeader(resourceMetadataUrl, "invalid_token", "Invalid audience") }
        });
      }
      ctx.props = ext.props;
    }
    if (!env.OAUTH_PROVIDER) env.OAUTH_PROVIDER = this.createOAuthHelpers(env);
    const apiHandler = this.findApiHandlerForUrl(url);
    if (!apiHandler) return this.createErrorResponse("invalid_request", {
      description: "No handler found for API route",
      statusCode: 404
    });
    if (apiHandler.type === HandlerType.EXPORTED_HANDLER) return apiHandler.handler.fetch(request, env, ctx);
    else return new apiHandler.handler(ctx, env).fetch(request);
  }
  /**
  * Creates the helper methods object for OAuth operations
  * This is passed to the handler functions to allow them to interact with the OAuth system
  * @param env - Cloudflare Worker environment variables
  * @returns An instance of OAuthHelpers
  */
  createOAuthHelpers(env) {
    return new OAuthHelpersImpl(env, this);
  }
  /**
  * Saves a grant to KV with appropriate TTL based on expiration
  * @param env - The environment bindings
  * @param grantKey - The KV key for the grant
  * @param grantData - The grant data to save
  * @param now - Current timestamp in seconds
  */
  async saveGrantWithTTL(env, grantKey, grantData, now) {
    const minExpiration = now + KV_MIN_EXPIRATION_TTL_SECONDS + KV_EXPIRATION_CLAMP_MARGIN_SECONDS;
    const kvOptions = grantData.expiresAt !== void 0 ? { expiration: Math.max(grantData.expiresAt, minExpiration) } : {};
    try {
      await env.OAUTH_KV.put(grantKey, JSON.stringify(grantData), kvOptions);
    } catch (error) {
      this.throwRetryableTokenStorageErrorIfKvRateLimited(error);
      throw error;
    }
  }
  throwRetryableTokenStorageErrorIfKvRateLimited(error) {
    if (!this.isKvRateLimitError(error)) return;
    throw new OAuthError("temporarily_unavailable", {
      description: "Token issuance is temporarily unavailable; retry shortly",
      statusCode: 429,
      headers: { "Retry-After": "30" }
    });
  }
  isKvRateLimitError(error) {
    if (!(error instanceof Error)) return false;
    return /KV .*failed: 429 Too Many Requests/i.test(error.message) || /429 Too Many Requests/i.test(error.message);
  }
  /**
  * Fetches client information from KV storage or via CIMD (Client ID Metadata Document)
  * This method is not private because `OAuthHelpers` needs to call it. Note that since
  * `OAuthProviderImpl` is not exposed outside this module, this is still effectively
  * module-private.
  *
  * Supports CIMD: If clientId is an HTTPS URL with a non-root path, the metadata
  * document will be fetched from that URL instead of looking up in KV storage.
  *
  * @param env - Cloudflare Worker environment variables
  * @param clientId - The client ID to look up (can be a regular ID or an HTTPS URL for CIMD)
  * @returns The client information, or null if not found
  */
  async getClient(env, clientId) {
    if (this.isClientMetadataUrl(clientId)) {
      if (!this.options.clientIdMetadataDocumentEnabled) {
        const clientKey$1 = `client:${clientId}`;
        return env.OAUTH_KV.get(clientKey$1, { type: "json" });
      }
      if (!this.hasGlobalFetchStrictlyPublic()) throw new Error(`CIMD is enabled but 'global_fetch_strictly_public' compatibility flag is not set.`);
      try {
        return await this.fetchClientMetadataDocument(clientId);
      } catch (error) {
        console.warn(`CIMD fetch failed for ${clientId}:`, error instanceof Error ? error.message : error);
        return null;
      }
    }
    const clientKey = `client:${clientId}`;
    return env.OAUTH_KV.get(clientKey, { type: "json" });
  }
  /**
  * Creates and stores an access token
  * @param params - Options for creating the access token
  * @returns The access token string
  */
  async createAccessToken(params) {
    const { userId, grantId, clientId, scope, encryptedProps, encryptionKey, expiresIn, audience, env } = params;
    if (expiresIn < KV_MIN_EXPIRATION_TTL_SECONDS) throw new OAuthError("invalid_request", { description: "Requested token lifetime must be at least 60 seconds" });
    const accessToken = `${userId}:${grantId}:${generateRandomString(TOKEN_LENGTH)}`;
    const now = Math.floor(Date.now() / 1e3);
    const accessTokenId = await generateTokenId(accessToken);
    const accessTokenData = {
      id: accessTokenId,
      grantId,
      userId,
      createdAt: now,
      expiresAt: now + expiresIn,
      audience,
      scope,
      wrappedEncryptionKey: await wrapKeyWithToken(accessToken, encryptionKey),
      grant: {
        clientId,
        scope,
        encryptedProps
      }
    };
    try {
      await env.OAUTH_KV.put(`token:${userId}:${grantId}:${accessTokenId}`, JSON.stringify(accessTokenData), { expirationTtl: expiresIn });
    } catch (error) {
      this.throwRetryableTokenStorageErrorIfKvRateLimited(error);
      throw error;
    }
    return accessToken;
  }
  /**
  * Downscopes requested scopes to only include those that are in the grant
  * Filters out any requested scopes that are not in the granted scopes
  * @param requestedScope - The scope parameter from the request (string or array)
  * @param grantedScopes - The scopes that were granted in the authorization
  * @returns The filtered scopes that are a subset of the granted scopes
  */
  downscope(requestedScope, grantedScopes) {
    if (!requestedScope) return grantedScopes;
    return (typeof requestedScope === "string" ? requestedScope.split(" ").filter(Boolean) : requestedScope).filter((scope) => grantedScopes.includes(scope));
  }
  /**
  * Checks if the global_fetch_strictly_public compatibility flag is enabled.
  * This flag is required for CIMD to prevent SSRF attacks.
  * See: https://developers.cloudflare.com/workers/configuration/compatibility-flags/#global-fetch-strictly-public
  */
  hasGlobalFetchStrictlyPublic() {
    return !!(typeof Cloudflare !== "undefined" && Cloudflare.compatibilityFlags ? Cloudflare.compatibilityFlags : null)?.global_fetch_strictly_public;
  }
  /**
  * Checks if a client_id is a CIMD URL (HTTPS with non-root path).
  * Not private because OAuthHelpersImpl needs access for purgeExpiredData.
  */
  isClientMetadataUrl(clientId) {
    try {
      const url = new URL(clientId);
      return url.protocol === "https:" && url.pathname !== "/";
    } catch {
      return false;
    }
  }
  static {
    this.CIMD_MAX_SIZE_BYTES = 5 * 1024;
  }
  static {
    this.CIMD_FETCH_TIMEOUT_MS = 1e4;
  }
  static {
    this.CIMD_ALLOWED_AUTH_METHODS = ["none", "private_key_jwt"];
  }
  /**
  * Validates that a field is a string or undefined
  * @param field - The field value to validate
  * @param fieldName - Name of the field for error messages
  * @returns The validated string or undefined
  * @throws Error if field is not a string or undefined
  */
  static validateStringField(field, fieldName) {
    if (field === void 0) return void 0;
    if (typeof field !== "string") throw new Error(fieldName ? `Invalid ${fieldName}: expected string, got ${typeof field}` : "Field must be a string");
    return field;
  }
  /**
  * Validates that a field is an optional URI string using a safe scheme.
  *
  * Client metadata URI fields (e.g. logo_uri, client_uri, policy_uri, tos_uri,
  * jwks_uri) are frequently rendered into HTML attributes such as `<a href>` or
  * `<img src>` on consent screens. Permitting non-http(s) schemes such as
  * `javascript:` or `data:` would allow script execution in that context, so we
  * require an absolute http: or https: URL here, matching how redirect URIs are
  * already restricted.
  *
  * @param field - The field to validate
  * @param fieldName - Name of the field for error messages
  * @returns The validated URI string or undefined
  * @throws Error if the field is not a string or is not an absolute http(s) URL
  */
  static validateOptionalUriField(field, fieldName) {
    const value = OAuthProviderImpl2.validateStringField(field, fieldName);
    if (value === void 0) return void 0;
    let parsed;
    try {
      parsed = new URL(value);
    } catch {
      throw new Error(`Invalid ${fieldName}: must be an absolute http: or https: URL`);
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new Error(`Invalid ${fieldName}: must be an absolute http: or https: URL`);
    return value;
  }
  static {
    this.I18N_FIELDS = {
      client_name: "string",
      client_uri: "uri",
      logo_uri: "uri",
      tos_uri: "uri",
      policy_uri: "uri"
    };
  }
  /**
  * Extracts RFC 7591 §2.2 internationalized metadata variants from a raw
  * registration payload.
  *
  * Localized variants are expressed by appending a `#<BCP 47 language tag>`
  * suffix to a metadata member name (e.g. `client_name#ja`, `tos_uri#fr`).
  * Only the human-readable fields the RFC names are considered; each value is
  * validated with the same rules as its canonical field (URI fields must be
  * absolute http(s) URLs). The raw `field#tag` keys are preserved verbatim so
  * that consumers can do their own locale matching.
  *
  * @param raw - The parsed client metadata object
  * @returns A map of `field#tag` to validated value, or undefined if none present
  * @throws Error if a localized value fails its field's validation
  */
  static extractI18nFields(raw) {
    const result = {};
    for (const key of Object.keys(raw)) {
      const hashIndex = key.indexOf("#");
      if (hashIndex <= 0 || hashIndex === key.length - 1) continue;
      const baseField = key.slice(0, hashIndex);
      const kind = OAuthProviderImpl2.I18N_FIELDS[baseField];
      if (!kind) continue;
      const validated = kind === "uri" ? OAuthProviderImpl2.validateOptionalUriField(raw[key], key) : OAuthProviderImpl2.validateStringField(raw[key], key);
      if (validated !== void 0) result[key] = validated;
    }
    return Object.keys(result).length > 0 ? result : void 0;
  }
  /**
  * Validates that a field is a string array or undefined
  * @param arr - The array to validate
  * @param fieldName - Name of the field for error messages
  * @returns The validated string array or undefined
  * @throws Error if field is not a string array or undefined
  */
  static validateStringArray(arr, fieldName) {
    if (arr === void 0) return void 0;
    if (!Array.isArray(arr)) throw new Error(fieldName ? `Invalid ${fieldName}: expected array, got ${typeof arr}` : "Field must be an array");
    if (!arr.every((item) => typeof item === "string")) throw new Error(fieldName ? `Invalid ${fieldName}: array must contain only strings` : "All array elements must be strings");
    return arr;
  }
  /**
  * Fetches and validates a Client ID Metadata Document from the given URL
  * Per the MCP spec, the client_id in the document must match the URL exactly
  *
  * Uses Cloudflare HTTP cache for caching (via cacheEverything option).
  * Response size is limited to 5KB per IETF spec.
  *
  * @param metadataUrl - The HTTPS URL to fetch metadata from
  * @returns The client information
  * @throws Error if fetch fails or validation fails
  */
  async fetchClientMetadataDocument(metadataUrl) {
    const abortController = new AbortController();
    const timeoutId = setTimeout(() => abortController.abort(), OAuthProviderImpl2.CIMD_FETCH_TIMEOUT_MS);
    try {
      const response = await fetch(metadataUrl, {
        headers: { Accept: "application/json" },
        signal: abortController.signal,
        cf: { cacheEverything: true }
      });
      clearTimeout(timeoutId);
      if (!response.ok) throw new Error(`Failed to fetch client metadata: HTTP ${response.status}`);
      const contentLength = response.headers.get("content-length");
      if (contentLength && parseInt(contentLength, 10) > OAuthProviderImpl2.CIMD_MAX_SIZE_BYTES) throw new Error(`Client metadata exceeds size limit: ${contentLength} bytes (max ${OAuthProviderImpl2.CIMD_MAX_SIZE_BYTES})`);
      const rawMetadata = await this.readJsonWithSizeLimit(response, OAuthProviderImpl2.CIMD_MAX_SIZE_BYTES);
      const clientId = OAuthProviderImpl2.validateStringField(rawMetadata.client_id, "client_id");
      const redirectUris = OAuthProviderImpl2.validateStringArray(rawMetadata.redirect_uris, "redirect_uris");
      const tokenEndpointAuthMethod = OAuthProviderImpl2.validateStringField(rawMetadata.token_endpoint_auth_method, "token_endpoint_auth_method");
      if (clientId !== metadataUrl) throw new Error(`client_id "${clientId}" does not match metadata URL "${metadataUrl}"`);
      if (!redirectUris || redirectUris.length === 0) throw new Error("redirect_uris is required and must not be empty");
      if (tokenEndpointAuthMethod && !OAuthProviderImpl2.CIMD_ALLOWED_AUTH_METHODS.includes(tokenEndpointAuthMethod)) throw new Error(`token_endpoint_auth_method "${tokenEndpointAuthMethod}" is not allowed for CIMD clients. Allowed methods: ${OAuthProviderImpl2.CIMD_ALLOWED_AUTH_METHODS.join(", ")}`);
      return {
        clientId,
        redirectUris,
        clientName: OAuthProviderImpl2.validateStringField(rawMetadata.client_name, "client_name"),
        clientUri: OAuthProviderImpl2.validateOptionalUriField(rawMetadata.client_uri, "client_uri"),
        logoUri: OAuthProviderImpl2.validateOptionalUriField(rawMetadata.logo_uri, "logo_uri"),
        policyUri: OAuthProviderImpl2.validateOptionalUriField(rawMetadata.policy_uri, "policy_uri"),
        tosUri: OAuthProviderImpl2.validateOptionalUriField(rawMetadata.tos_uri, "tos_uri"),
        jwksUri: OAuthProviderImpl2.validateOptionalUriField(rawMetadata.jwks_uri, "jwks_uri"),
        i18n: OAuthProviderImpl2.extractI18nFields(rawMetadata),
        contacts: OAuthProviderImpl2.validateStringArray(rawMetadata.contacts, "contacts"),
        grantTypes: OAuthProviderImpl2.validateStringArray(rawMetadata.grant_types, "grant_types") || ["authorization_code"],
        responseTypes: OAuthProviderImpl2.validateStringArray(rawMetadata.response_types, "response_types") || ["code"],
        tokenEndpointAuthMethod: tokenEndpointAuthMethod || "none"
      };
    } finally {
      clearTimeout(timeoutId);
    }
  }
  /**
  * Reads JSON from a response with a size limit to prevent DoS attacks.
  * Streams the response body and aborts if it exceeds the limit.
  *
  * @param response - The fetch response
  * @param maxBytes - Maximum allowed size in bytes
  * @returns Parsed JSON object
  * @throws Error if response body is null, size exceeded, or JSON parse failed
  */
  async readJsonWithSizeLimit(response, maxBytes) {
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Response body is null");
    const chunks = [];
    let totalSize = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        totalSize += value.length;
        if (totalSize > maxBytes) {
          await reader.cancel();
          throw new Error(`Response exceeded size limit of ${maxBytes} bytes`);
        }
        chunks.push(value);
      }
    }
    const allChunks = new Uint8Array(totalSize);
    let position = 0;
    for (const chunk of chunks) {
      allChunks.set(chunk, position);
      position += chunk.length;
    }
    const text = new TextDecoder().decode(allChunks);
    return JSON.parse(text);
  }
  /**
  * Builds a WWW-Authenticate header value with resource_metadata per RFC 9728 §5.1
  */
  buildWwwAuthenticateHeader(resourceMetadataUrl, error, errorDescription) {
    let header = `Bearer realm="OAuth", resource_metadata="${resourceMetadataUrl}", error="${error}"`;
    if (errorDescription) header += `, error_description="${errorDescription}"`;
    return header;
  }
  /**
  * Helper function to create OAuth error responses.
  *
  * `internal` (optional) carries a tagged, server-side-only reason. It is
  * forwarded to the deployer's `onError` hook but never placed on the wire,
  * so the public response stays RFC-compliant and free of information leak
  * while the deployer can still observe which check failed.
  */
  createErrorResponse(code, options, internal) {
    const { description } = options;
    const responseStatus = options.statusCode ?? 400;
    const responseHeaders = {
      ...NO_CACHE_HEADERS,
      ...options.headers ?? {}
    };
    const customErrorResponse = this.options.onError?.({
      code,
      description,
      status: responseStatus,
      headers: responseHeaders,
      ...internal ? { internal } : {}
    });
    if (customErrorResponse) return customErrorResponse;
    const body = JSON.stringify({
      error: code,
      error_description: description
    });
    return new Response(body, {
      status: responseStatus,
      headers: {
        "Content-Type": "application/json",
        ...responseHeaders
      }
    });
  }
};
var OAuthError = class extends Error {
  constructor(code, options) {
    super(options.description);
    this.name = "OAuthError";
    this.code = code;
    this.options = {
      ...options,
      statusCode: options.statusCode ?? 400
    };
    this.description = this.options.description;
    this.statusCode = this.options.statusCode;
    this.headers = this.options.headers;
  }
};
var DEFAULT_ACCESS_TOKEN_TTL = 3600;
var DEFAULT_REFRESH_TOKEN_TTL = 720 * 60 * 60;
var DEFAULT_CLIENT_REGISTRATION_TTL = 2160 * 60 * 60;
var KV_MIN_EXPIRATION_TTL_SECONDS = 60;
var KV_EXPIRATION_CLAMP_MARGIN_SECONDS = 5;
var DEFAULT_PURGE_BATCH_SIZE = 50;
var MAX_KV_LIST_LIMIT = 1e3;
var DEFAULT_REVOKE_EXISTING_GRANTS_BATCH_SIZE = 50;
function getRevokeExistingGrantsBatchSize(batchSize) {
  if (batchSize === void 0) return DEFAULT_REVOKE_EXISTING_GRANTS_BATCH_SIZE;
  if (!Number.isFinite(batchSize) || !Number.isInteger(batchSize) || batchSize < 1) throw new Error("revokeExistingGrantsBatchSize must be a positive integer.");
  return Math.min(batchSize, MAX_KV_LIST_LIMIT);
}
var TOKEN_LENGTH = 32;
var OAUTH_SCOPE_TOKEN_PATTERN = /^[\x21\x23-\x5B\x5D-\x7E]+$/;
function validateResourceUri(uri) {
  if (!uri || typeof uri !== "string") return false;
  try {
    const parsed = new URL(uri);
    if (!parsed.protocol) return false;
    if (parsed.hash) return false;
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    return true;
  } catch {
    return false;
  }
}
function audienceMatches(resourceServerUrl, audienceValue) {
  try {
    const resource = new URL(resourceServerUrl);
    const audience = new URL(audienceValue);
    if (resource.origin !== audience.origin) return false;
    if (audience.pathname === "/" || audience.pathname === "") return true;
    return resource.pathname === audience.pathname || resource.pathname.startsWith(audience.pathname + "/");
  } catch {
    return false;
  }
}
function parseResourceParameter(value) {
  if (!value) return;
  const uris = Array.isArray(value) ? value : [value];
  for (const uri of uris) if (typeof uri !== "string" || !validateResourceUri(uri)) return;
  return value;
}
function resourceMatches(requested, granted, originOnly) {
  if (!originOnly) return requested === granted;
  try {
    return new URL(requested).origin === new URL(granted).origin;
  } catch {
    return requested === granted;
  }
}
async function hashSecret(secret) {
  return generateTokenId(secret);
}
function decodeFormUrlEncodedComponent(value) {
  return decodeURIComponent(value.replace(/\+/g, " "));
}
function generateRandomString(length) {
  const characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let result = "";
  const values = new Uint8Array(length);
  crypto.getRandomValues(values);
  for (let i = 0; i < length; i++) result += characters.charAt(values[i] % 64);
  return result;
}
async function generateTokenId(token) {
  const data = new TextEncoder().encode(token);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function validateRedirectUriScheme(redirectUri) {
  const dangerousSchemes = [
    "javascript:",
    "data:",
    "vbscript:",
    "file:",
    "mailto:",
    "blob:"
  ];
  const normalized = redirectUri.trim();
  for (let i = 0; i < normalized.length; i++) {
    const code = normalized.charCodeAt(i);
    if (code >= 0 && code <= 31 || code >= 127 && code <= 159) throw new Error("Invalid redirect URI");
  }
  const colonIndex = normalized.indexOf(":");
  if (colonIndex === -1) throw new Error("Invalid redirect URI");
  const scheme = normalized.substring(0, colonIndex + 1).toLowerCase();
  for (const dangerousScheme of dangerousSchemes) if (scheme === dangerousScheme) throw new Error("Invalid redirect URI");
}
function isLoopbackUri(uri) {
  try {
    const host = new URL(uri).hostname;
    if (host.match(/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)) return true;
    if (host === "::1" || host === "[::1]") return true;
    if (host.toLowerCase() === "localhost") return true;
    return false;
  } catch {
    return false;
  }
}
function isValidRedirectUri(requestUri, registeredUris) {
  return registeredUris.some((registered) => {
    if (isLoopbackUri(requestUri) && isLoopbackUri(registered)) try {
      const reqUrl = new URL(requestUri);
      const regUrl = new URL(registered);
      return reqUrl.protocol === regUrl.protocol && reqUrl.hostname === regUrl.hostname && reqUrl.pathname === regUrl.pathname && reqUrl.search === regUrl.search;
    } catch {
      return false;
    }
    return requestUri === registered;
  });
}
function base64UrlEncode(str) {
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}
function base64UrlToBytes(base64Url2) {
  const base64 = base64Url2.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(base64.length + (4 - base64.length % 4) % 4, "=");
  const binaryString = atob(padded);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) bytes[i] = binaryString.charCodeAt(i);
  return bytes;
}
function parseJwtJsonPart(encoded) {
  try {
    const json = new TextDecoder().decode(base64UrlToBytes(encoded));
    const parsed = JSON.parse(json);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("JWT part must be an object");
    return parsed;
  } catch {
    throw new Error("Malformed JWT part");
  }
}
function isValidOAuthScopeToken(scopeToken) {
  return OAUTH_SCOPE_TOKEN_PATTERN.test(scopeToken);
}
function getJwtCryptoAlgorithms(alg) {
  if (alg === "RS256") {
    const algorithm = {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256"
    };
    return {
      importAlgorithm: algorithm,
      verifyAlgorithm: algorithm
    };
  }
  if (alg === "ES256") return {
    importAlgorithm: {
      name: "ECDSA",
      namedCurve: "P-256"
    },
    verifyAlgorithm: {
      name: "ECDSA",
      hash: "SHA-256"
    }
  };
  throw new Error(`Unsupported JWT alg: ${alg}`);
}
function arrayBufferToBase64(buffer) {
  return btoa(String.fromCharCode(...new Uint8Array(buffer)));
}
function base64ToArrayBuffer(base64) {
  const binaryString = atob(base64);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) bytes[i] = binaryString.charCodeAt(i);
  return bytes.buffer;
}
async function encryptProps(data) {
  const key = await crypto.subtle.generateKey({
    name: "AES-GCM",
    length: 256
  }, true, ["encrypt", "decrypt"]);
  const iv = new Uint8Array(12);
  const jsonData = JSON.stringify(data);
  const encodedData = new TextEncoder().encode(jsonData);
  return {
    encryptedData: arrayBufferToBase64(await crypto.subtle.encrypt({
      name: "AES-GCM",
      iv
    }, key, encodedData)),
    key
  };
}
async function decryptProps(key, encryptedData) {
  const encryptedBuffer = base64ToArrayBuffer(encryptedData);
  const iv = new Uint8Array(12);
  const decryptedBuffer = await crypto.subtle.decrypt({
    name: "AES-GCM",
    iv
  }, key, encryptedBuffer);
  const jsonData = new TextDecoder().decode(decryptedBuffer);
  return JSON.parse(jsonData);
}
var WRAPPING_KEY_HMAC_KEY = new Uint8Array([
  34,
  126,
  38,
  134,
  141,
  241,
  225,
  109,
  128,
  112,
  234,
  23,
  151,
  91,
  71,
  166,
  130,
  24,
  250,
  135,
  40,
  174,
  222,
  133,
  181,
  29,
  74,
  217,
  150,
  202,
  202,
  67
]);
async function deriveKeyFromToken(tokenStr) {
  const encoder2 = new TextEncoder();
  const hmacKey = await crypto.subtle.importKey("raw", WRAPPING_KEY_HMAC_KEY, {
    name: "HMAC",
    hash: "SHA-256"
  }, false, ["sign"]);
  const hmacResult = await crypto.subtle.sign("HMAC", hmacKey, encoder2.encode(tokenStr));
  return await crypto.subtle.importKey("raw", hmacResult, { name: "AES-KW" }, false, ["wrapKey", "unwrapKey"]);
}
async function wrapKeyWithToken(tokenStr, keyToWrap) {
  const wrappingKey = await deriveKeyFromToken(tokenStr);
  return arrayBufferToBase64(await crypto.subtle.wrapKey("raw", keyToWrap, wrappingKey, { name: "AES-KW" }));
}
async function unwrapKeyWithToken(tokenStr, wrappedKeyBase64) {
  const wrappingKey = await deriveKeyFromToken(tokenStr);
  const wrappedKeyBuffer = base64ToArrayBuffer(wrappedKeyBase64);
  return await crypto.subtle.unwrapKey("raw", wrappedKeyBuffer, wrappingKey, { name: "AES-KW" }, { name: "AES-GCM" }, true, ["encrypt", "decrypt"]);
}
var OAuthHelpersImpl = class {
  /**
  * Creates a new OAuthHelpers instance
  * @param env - Cloudflare Worker environment variables
  * @param provider - Reference to the parent provider instance
  */
  constructor(env, provider) {
    this.env = env;
    this.provider = provider;
  }
  /**
  * Parses an OAuth authorization request from the HTTP request
  * @param request - The HTTP request containing OAuth parameters
  * @returns The parsed authorization request parameters
  */
  async parseAuthRequest(request) {
    const url = new URL(request.url);
    const responseType = url.searchParams.get("response_type") || "";
    const clientId = url.searchParams.get("client_id") || "";
    const redirectUri = url.searchParams.get("redirect_uri") || "";
    const scope = (url.searchParams.get("scope") || "").split(" ").filter(Boolean);
    const state = url.searchParams.get("state") || "";
    const codeChallenge = url.searchParams.get("code_challenge") || void 0;
    const codeChallengeMethod = url.searchParams.get("code_challenge_method") || "plain";
    const resourceParams = url.searchParams.getAll("resource");
    const resourceParam = resourceParams.length > 0 ? resourceParams.length === 1 ? resourceParams[0] : resourceParams : void 0;
    validateRedirectUriScheme(redirectUri);
    const resource = parseResourceParameter(resourceParam);
    if (resourceParam && !resource) throw new Error("The resource parameter must be a valid absolute URI without a fragment");
    if (responseType === "token" && !this.provider.options.allowImplicitFlow) throw new Error("The implicit grant flow is not enabled for this provider");
    if (codeChallengeMethod === "plain" && this.provider.options.allowPlainPKCE === false) throw new Error("The plain PKCE method is not allowed. Use S256 instead.");
    if (clientId) {
      const clientInfo = await this.lookupClient(clientId);
      if (!clientInfo) throw new Error(`Invalid client. The clientId provided does not match to this client.`);
      if (clientInfo && redirectUri) {
        if (!isValidRedirectUri(redirectUri, clientInfo.redirectUris)) throw new Error(`Invalid redirect URI. The redirect URI provided does not match any registered URI for this client.`);
      }
    }
    return {
      responseType,
      clientId,
      redirectUri,
      scope,
      state,
      codeChallenge,
      codeChallengeMethod,
      resource
    };
  }
  /**
  * Looks up a client by its client ID
  * @param clientId - The client ID to look up
  * @returns A Promise resolving to the client info, or null if not found
  */
  async lookupClient(clientId) {
    return await this.provider.getClient(this.env, clientId);
  }
  /**
  * Completes an authorization request by creating a grant and either:
  * - For authorization code flow: generating an authorization code
  * - For implicit flow: generating an access token directly
  * @param options - Options specifying the grant details
  * @returns A Promise resolving to an object containing the redirect URL
  */
  async completeAuthorization(options) {
    const { clientId, redirectUri } = options.request;
    if (!clientId || !redirectUri) throw new Error("Client ID and Redirect URI are required in the authorization request.");
    const clientInfo = await this.lookupClient(clientId);
    if (!clientInfo || !isValidRedirectUri(redirectUri, clientInfo.redirectUris)) throw new Error("Invalid redirect URI. The redirect URI provided does not match any registered URI for this client.");
    let grantsToRevoke = [];
    if (options.revokeExistingGrants !== false) {
      const batchSize = getRevokeExistingGrantsBatchSize(options.revokeExistingGrantsBatchSize);
      let cursor;
      do {
        const page = await this.listUserGrants(options.userId, {
          cursor,
          limit: batchSize
        });
        for (const grant of page.items) if (grant.clientId === clientId) grantsToRevoke.push(grant.id);
        cursor = page.cursor;
      } while (cursor);
    }
    const grantId = generateRandomString(16);
    const { encryptedData, key: encryptionKey } = await encryptProps(options.props);
    const now = Math.floor(Date.now() / 1e3);
    if (options.request.responseType === "token") {
      const accessTokenSecret = generateRandomString(TOKEN_LENGTH);
      const accessToken = `${options.userId}:${grantId}:${accessTokenSecret}`;
      const accessTokenId = await generateTokenId(accessToken);
      const accessTokenTTL = this.provider.options.accessTokenTTL || DEFAULT_ACCESS_TOKEN_TTL;
      const accessTokenExpiresAt = now + accessTokenTTL;
      const accessTokenWrappedKey = await wrapKeyWithToken(accessToken, encryptionKey);
      const audience = parseResourceParameter(options.request.resource);
      if (options.request.resource && !audience) throw new Error("The resource parameter must be a valid absolute URI without a fragment");
      const grant = {
        id: grantId,
        clientId: options.request.clientId,
        userId: options.userId,
        scope: options.scope,
        metadata: options.metadata,
        encryptedProps: encryptedData,
        createdAt: now,
        resource: options.request.resource
      };
      const grantKey = `grant:${options.userId}:${grantId}`;
      await this.env.OAUTH_KV.put(grantKey, JSON.stringify(grant));
      const accessTokenData = {
        id: accessTokenId,
        grantId,
        userId: options.userId,
        createdAt: now,
        expiresAt: accessTokenExpiresAt,
        audience,
        scope: options.scope,
        wrappedEncryptionKey: accessTokenWrappedKey,
        grant: {
          clientId: options.request.clientId,
          scope: options.scope,
          encryptedProps: encryptedData
        }
      };
      await this.env.OAUTH_KV.put(`token:${options.userId}:${grantId}:${accessTokenId}`, JSON.stringify(accessTokenData), { expirationTtl: accessTokenTTL });
      const redirectUrl = new URL(options.request.redirectUri);
      const fragment = new URLSearchParams();
      fragment.set("access_token", accessToken);
      fragment.set("token_type", "bearer");
      fragment.set("expires_in", accessTokenTTL.toString());
      fragment.set("scope", options.scope.join(" "));
      if (options.request.state) fragment.set("state", options.request.state);
      redirectUrl.hash = fragment.toString();
      try {
        await Promise.allSettled(grantsToRevoke.map((oldGrantId) => this.revokeGrant(oldGrantId, options.userId)));
      } catch {
      }
      return { redirectTo: redirectUrl.toString() };
    } else {
      const authCodeSecret = generateRandomString(32);
      const authCode = `${options.userId}:${grantId}:${authCodeSecret}`;
      const authCodeId = await hashSecret(authCode);
      const authCodeWrappedKey = await wrapKeyWithToken(authCode, encryptionKey);
      const grant = {
        id: grantId,
        clientId: options.request.clientId,
        userId: options.userId,
        scope: options.scope,
        metadata: options.metadata,
        encryptedProps: encryptedData,
        createdAt: now,
        authCodeId,
        authCodeWrappedKey,
        codeChallenge: options.request.codeChallenge,
        codeChallengeMethod: options.request.codeChallengeMethod,
        resource: options.request.resource
      };
      const grantKey = `grant:${options.userId}:${grantId}`;
      await this.env.OAUTH_KV.put(grantKey, JSON.stringify(grant), { expirationTtl: 600 });
      const redirectUrl = new URL(options.request.redirectUri);
      redirectUrl.searchParams.set("code", authCode);
      if (options.request.state) redirectUrl.searchParams.set("state", options.request.state);
      try {
        await Promise.allSettled(grantsToRevoke.map((oldGrantId) => this.revokeGrant(oldGrantId, options.userId)));
      } catch {
      }
      return { redirectTo: redirectUrl.toString() };
    }
  }
  /**
  * Creates a new OAuth client
  * @param clientInfo - Partial client information to create the client with
  * @returns A Promise resolving to the created client info
  */
  async createClient(clientInfo) {
    const clientId = generateRandomString(16);
    const tokenEndpointAuthMethod = clientInfo.tokenEndpointAuthMethod || "client_secret_basic";
    const isPublicClient = tokenEndpointAuthMethod === "none";
    const newClient = {
      clientId,
      redirectUris: clientInfo.redirectUris || [],
      clientName: clientInfo.clientName,
      logoUri: clientInfo.logoUri,
      clientUri: clientInfo.clientUri,
      policyUri: clientInfo.policyUri,
      tosUri: clientInfo.tosUri,
      jwksUri: clientInfo.jwksUri,
      i18n: clientInfo.i18n,
      contacts: clientInfo.contacts,
      grantTypes: clientInfo.grantTypes || [
        GrantType.AUTHORIZATION_CODE,
        GrantType.REFRESH_TOKEN,
        ...this.provider.options.allowTokenExchangeGrant ? [GrantType.TOKEN_EXCHANGE] : []
      ],
      responseTypes: clientInfo.responseTypes || ["code"],
      registrationDate: Math.floor(Date.now() / 1e3),
      tokenEndpointAuthMethod
    };
    for (const uri of newClient.redirectUris) validateRedirectUriScheme(uri);
    let clientSecret;
    if (!isPublicClient) {
      clientSecret = generateRandomString(32);
      newClient.clientSecret = await hashSecret(clientSecret);
    }
    await this.env.OAUTH_KV.put(`client:${clientId}`, JSON.stringify(newClient));
    const clientResponse = { ...newClient };
    if (!isPublicClient && clientSecret) clientResponse.clientSecret = clientSecret;
    return clientResponse;
  }
  /**
  * Lists all registered OAuth clients with pagination support
  * @param options - Optional pagination parameters (limit and cursor)
  * @returns A Promise resolving to the list result with items and optional cursor
  */
  async listClients(options) {
    const listOptions = { prefix: "client:" };
    if (options?.limit !== void 0) listOptions.limit = options.limit;
    if (options?.cursor !== void 0) listOptions.cursor = options.cursor;
    const response = await this.env.OAUTH_KV.list(listOptions);
    const clients = [];
    const promises = response.keys.map(async (key) => {
      const clientId = key.name.substring(7);
      const client = await this.provider.getClient(this.env, clientId);
      if (client) clients.push(client);
    });
    await Promise.all(promises);
    return {
      items: clients,
      cursor: response.list_complete ? void 0 : response.cursor
    };
  }
  /**
  * Updates an existing OAuth client
  * @param clientId - The ID of the client to update
  * @param updates - Partial client information with fields to update
  * @returns A Promise resolving to the updated client info, or null if not found
  */
  async updateClient(clientId, updates) {
    const client = await this.provider.getClient(this.env, clientId);
    if (!client) return null;
    let authMethod = updates.tokenEndpointAuthMethod || client.tokenEndpointAuthMethod || "client_secret_basic";
    const isPublicClient = authMethod === "none";
    let secretToStore = client.clientSecret;
    let originalSecret = void 0;
    if (isPublicClient) secretToStore = void 0;
    else if (updates.clientSecret) {
      originalSecret = updates.clientSecret;
      secretToStore = await hashSecret(updates.clientSecret);
    }
    const updatedClient = {
      ...client,
      ...updates,
      clientId: client.clientId,
      tokenEndpointAuthMethod: authMethod
    };
    if (!isPublicClient && secretToStore) updatedClient.clientSecret = secretToStore;
    else delete updatedClient.clientSecret;
    const clientKvOptions = {};
    if (this.provider.options.clientRegistrationTTL !== void 0) clientKvOptions.expirationTtl = this.provider.options.clientRegistrationTTL;
    await this.env.OAUTH_KV.put(`client:${clientId}`, JSON.stringify(updatedClient), clientKvOptions);
    const response = { ...updatedClient };
    if (!isPublicClient && originalSecret) response.clientSecret = originalSecret;
    return response;
  }
  /**
  * Deletes an OAuth client and revokes all associated grants across all users.
  * @param clientId - The ID of the client to delete
  * @returns A Promise resolving when the deletion is confirmed.
  */
  async deleteClient(clientId) {
    let cursor;
    let allProcessed = false;
    while (!allProcessed) {
      const listOptions = { prefix: "grant:" };
      if (cursor) listOptions.cursor = cursor;
      const result = await this.env.OAUTH_KV.list(listOptions);
      for (const key of result.keys) {
        const grantData = await this.env.OAUTH_KV.get(key.name, { type: "json" });
        if (grantData && grantData.clientId === clientId) await this.revokeGrant(grantData.id, grantData.userId);
      }
      if (result.list_complete) allProcessed = true;
      else cursor = result.cursor;
    }
    await this.env.OAUTH_KV.delete(`client:${clientId}`);
  }
  /**
  * Lists all authorization grants for a specific user with pagination support
  * Returns a summary of each grant without sensitive information
  * @param userId - The ID of the user whose grants to list
  * @param options - Optional pagination parameters (limit and cursor)
  * @returns A Promise resolving to the list result with grant summaries and optional cursor
  */
  async listUserGrants(userId, options) {
    const listOptions = { prefix: `grant:${userId}:` };
    if (options?.limit !== void 0) listOptions.limit = options.limit;
    if (options?.cursor !== void 0) listOptions.cursor = options.cursor;
    const response = await this.env.OAUTH_KV.list(listOptions);
    const grantSummaries = [];
    const promises = response.keys.map(async (key) => {
      const grantData = await this.env.OAUTH_KV.get(key.name, { type: "json" });
      if (grantData) {
        const summary = {
          id: grantData.id,
          clientId: grantData.clientId,
          userId: grantData.userId,
          scope: grantData.scope,
          metadata: grantData.metadata,
          createdAt: grantData.createdAt,
          expiresAt: grantData.expiresAt
        };
        grantSummaries.push(summary);
      }
    });
    await Promise.all(promises);
    return {
      items: grantSummaries,
      cursor: response.list_complete ? void 0 : response.cursor
    };
  }
  /**
  * Revokes an authorization grant and all its associated access tokens
  * @param grantId - The ID of the grant to revoke
  * @param userId - The ID of the user who owns the grant
  * @returns A Promise resolving when the revocation is confirmed.
  */
  async revokeGrant(grantId, userId) {
    const grantKey = `grant:${userId}:${grantId}`;
    const tokenPrefix = `token:${userId}:${grantId}:`;
    let cursor;
    let allTokensDeleted = false;
    while (!allTokensDeleted) {
      const listOptions = { prefix: tokenPrefix };
      if (cursor) listOptions.cursor = cursor;
      const result = await this.env.OAUTH_KV.list(listOptions);
      if (result.keys.length > 0) await Promise.all(result.keys.map((key) => {
        return this.env.OAUTH_KV.delete(key.name);
      }));
      if (result.list_complete) allTokensDeleted = true;
      else cursor = result.cursor;
    }
    await this.env.OAUTH_KV.delete(grantKey);
  }
  /**
  * Decodes a token and returns token data with decrypted props
  * @param token - The token
  * @returns Promise resolving to token data with decrypted props, or null if token is invalid
  */
  async unwrapToken(token) {
    return await this.provider.unwrapToken(token, this.env);
  }
  /**
  * Exchanges an existing access token for a new one with modified characteristics
  * Implements OAuth 2.0 Token Exchange (RFC 8693)
  * @param options - Options for token exchange including subject token and optional modifications
  * @returns Promise resolving to token response with new access token
  */
  async exchangeToken(options) {
    const tokenSummary = await this.unwrapToken(options.subjectToken);
    if (!tokenSummary) throw new Error("Invalid or expired subject token");
    const clientInfo = await this.lookupClient(tokenSummary.grant.clientId);
    if (!clientInfo) throw new Error("Client not found");
    return await this.provider.exchangeToken(options.subjectToken, options.scope, options.aud, options.expiresIn, clientInfo, this.env);
  }
  async purgeExpiredData(options) {
    const batchSize = options?.batchSize ?? DEFAULT_PURGE_BATCH_SIZE;
    const purgeOrphanedGrants = options?.purgeOrphanedGrants !== false;
    const purgeExpiredGrants = options?.purgeExpiredGrants !== false;
    const purgeOrphanedTokens = options?.purgeOrphanedTokens !== false;
    const now = Math.floor(Date.now() / 1e3);
    const result = {
      grantsChecked: 0,
      grantsPurged: 0,
      tokensChecked: 0,
      tokensPurged: 0,
      done: false
    };
    if (purgeOrphanedGrants || purgeExpiredGrants) {
      const knownGoodClients = /* @__PURE__ */ new Set();
      const knownMissingClients = /* @__PURE__ */ new Set();
      let grantCursor;
      let grantsDone = false;
      while (!grantsDone && result.grantsChecked < batchSize) {
        const listOptions = {
          prefix: "grant:",
          limit: Math.min(1e3, batchSize - result.grantsChecked)
        };
        if (grantCursor) listOptions.cursor = grantCursor;
        const page = await this.env.OAUTH_KV.list(listOptions);
        for (const key of page.keys) {
          if (result.grantsChecked >= batchSize) break;
          result.grantsChecked++;
          const grantData = await this.env.OAUTH_KV.get(key.name, { type: "json" });
          if (!grantData) continue;
          let shouldPurge = false;
          if (purgeExpiredGrants && grantData.expiresAt !== void 0 && now >= grantData.expiresAt) shouldPurge = true;
          if (!shouldPurge && purgeOrphanedGrants && !this.provider.isClientMetadataUrl(grantData.clientId)) {
            if (knownMissingClients.has(grantData.clientId)) shouldPurge = true;
            else if (!knownGoodClients.has(grantData.clientId)) if (await this.env.OAUTH_KV.get(`client:${grantData.clientId}`, { type: "json" })) knownGoodClients.add(grantData.clientId);
            else {
              knownMissingClients.add(grantData.clientId);
              shouldPurge = true;
            }
          }
          if (shouldPurge) {
            await this.revokeGrant(grantData.id, grantData.userId);
            result.grantsPurged++;
          }
        }
        if (page.list_complete) grantsDone = true;
        else grantCursor = page.cursor;
      }
      if (!grantsDone) return result;
    }
    if (purgeOrphanedTokens) {
      const knownGoodGrants = /* @__PURE__ */ new Set();
      const knownMissingGrants = /* @__PURE__ */ new Set();
      let tokenCursor;
      let tokensDone = false;
      while (!tokensDone && result.tokensChecked < batchSize) {
        const listOptions = {
          prefix: "token:",
          limit: Math.min(1e3, batchSize - result.tokensChecked)
        };
        if (tokenCursor) listOptions.cursor = tokenCursor;
        const page = await this.env.OAUTH_KV.list(listOptions);
        for (const key of page.keys) {
          if (result.tokensChecked >= batchSize) break;
          result.tokensChecked++;
          const tokenData = await this.env.OAUTH_KV.get(key.name, { type: "json" });
          if (!tokenData) continue;
          const grantKey = `grant:${tokenData.userId}:${tokenData.grantId}`;
          if (knownMissingGrants.has(grantKey)) {
            await this.env.OAUTH_KV.delete(key.name);
            result.tokensPurged++;
          } else if (!knownGoodGrants.has(grantKey)) if (await this.env.OAUTH_KV.get(grantKey)) knownGoodGrants.add(grantKey);
          else {
            knownMissingGrants.add(grantKey);
            await this.env.OAUTH_KV.delete(key.name);
            result.tokensPurged++;
          }
        }
        if (page.list_complete) tokensDone = true;
        else tokenCursor = page.cursor;
      }
      if (!tokensDone) return result;
    }
    result.done = true;
    return result;
  }
};
var oauth_provider_default = OAuthProvider;

// node_modules/jose/dist/webapi/lib/buffer_utils.js
var encoder = new TextEncoder();
var decoder = new TextDecoder();
var MAX_INT32 = 2 ** 32;
function concat(...buffers) {
  const size = buffers.reduce((acc, { length }) => acc + length, 0);
  const buf = new Uint8Array(size);
  let i = 0;
  for (const buffer of buffers) {
    buf.set(buffer, i);
    i += buffer.length;
  }
  return buf;
}

// node_modules/jose/dist/webapi/lib/base64.js
function decodeBase64(encoded) {
  if (Uint8Array.fromBase64) {
    return Uint8Array.fromBase64(encoded);
  }
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// node_modules/jose/dist/webapi/util/base64url.js
function decode(input) {
  if (Uint8Array.fromBase64) {
    return Uint8Array.fromBase64(typeof input === "string" ? input : decoder.decode(input), {
      alphabet: "base64url"
    });
  }
  let encoded = input;
  if (encoded instanceof Uint8Array) {
    encoded = decoder.decode(encoded);
  }
  encoded = encoded.replace(/-/g, "+").replace(/_/g, "/").replace(/\s/g, "");
  try {
    return decodeBase64(encoded);
  } catch {
    throw new TypeError("The input to be decoded is not correctly encoded.");
  }
}

// node_modules/jose/dist/webapi/util/errors.js
var JOSEError = class extends Error {
  static code = "ERR_JOSE_GENERIC";
  code = "ERR_JOSE_GENERIC";
  constructor(message2, options) {
    super(message2, options);
    this.name = this.constructor.name;
    Error.captureStackTrace?.(this, this.constructor);
  }
};
var JWTClaimValidationFailed = class extends JOSEError {
  static code = "ERR_JWT_CLAIM_VALIDATION_FAILED";
  code = "ERR_JWT_CLAIM_VALIDATION_FAILED";
  claim;
  reason;
  payload;
  constructor(message2, payload, claim = "unspecified", reason = "unspecified") {
    super(message2, { cause: { claim, reason, payload } });
    this.claim = claim;
    this.reason = reason;
    this.payload = payload;
  }
};
var JWTExpired = class extends JOSEError {
  static code = "ERR_JWT_EXPIRED";
  code = "ERR_JWT_EXPIRED";
  claim;
  reason;
  payload;
  constructor(message2, payload, claim = "unspecified", reason = "unspecified") {
    super(message2, { cause: { claim, reason, payload } });
    this.claim = claim;
    this.reason = reason;
    this.payload = payload;
  }
};
var JOSEAlgNotAllowed = class extends JOSEError {
  static code = "ERR_JOSE_ALG_NOT_ALLOWED";
  code = "ERR_JOSE_ALG_NOT_ALLOWED";
};
var JOSENotSupported = class extends JOSEError {
  static code = "ERR_JOSE_NOT_SUPPORTED";
  code = "ERR_JOSE_NOT_SUPPORTED";
};
var JWSInvalid = class extends JOSEError {
  static code = "ERR_JWS_INVALID";
  code = "ERR_JWS_INVALID";
};
var JWTInvalid = class extends JOSEError {
  static code = "ERR_JWT_INVALID";
  code = "ERR_JWT_INVALID";
};
var JWKSInvalid = class extends JOSEError {
  static code = "ERR_JWKS_INVALID";
  code = "ERR_JWKS_INVALID";
};
var JWKSNoMatchingKey = class extends JOSEError {
  static code = "ERR_JWKS_NO_MATCHING_KEY";
  code = "ERR_JWKS_NO_MATCHING_KEY";
  constructor(message2 = "no applicable key found in the JSON Web Key Set", options) {
    super(message2, options);
  }
};
var JWKSMultipleMatchingKeys = class extends JOSEError {
  [Symbol.asyncIterator];
  static code = "ERR_JWKS_MULTIPLE_MATCHING_KEYS";
  code = "ERR_JWKS_MULTIPLE_MATCHING_KEYS";
  constructor(message2 = "multiple matching keys found in the JSON Web Key Set", options) {
    super(message2, options);
  }
};
var JWKSTimeout = class extends JOSEError {
  static code = "ERR_JWKS_TIMEOUT";
  code = "ERR_JWKS_TIMEOUT";
  constructor(message2 = "request timed out", options) {
    super(message2, options);
  }
};
var JWSSignatureVerificationFailed = class extends JOSEError {
  static code = "ERR_JWS_SIGNATURE_VERIFICATION_FAILED";
  code = "ERR_JWS_SIGNATURE_VERIFICATION_FAILED";
  constructor(message2 = "signature verification failed", options) {
    super(message2, options);
  }
};

// node_modules/jose/dist/webapi/lib/crypto_key.js
function unusable(name, prop = "algorithm.name") {
  return new TypeError(`CryptoKey does not support this operation, its ${prop} must be ${name}`);
}
function isAlgorithm(algorithm, name) {
  return algorithm.name === name;
}
function getHashLength(hash) {
  return parseInt(hash.name.slice(4), 10);
}
function getNamedCurve(alg) {
  switch (alg) {
    case "ES256":
      return "P-256";
    case "ES384":
      return "P-384";
    case "ES512":
      return "P-521";
    default:
      throw new Error("unreachable");
  }
}
function checkUsage(key, usage) {
  if (usage && !key.usages.includes(usage)) {
    throw new TypeError(`CryptoKey does not support this operation, its usages must include ${usage}.`);
  }
}
function checkSigCryptoKey(key, alg, usage) {
  switch (alg) {
    case "HS256":
    case "HS384":
    case "HS512": {
      if (!isAlgorithm(key.algorithm, "HMAC"))
        throw unusable("HMAC");
      const expected = parseInt(alg.slice(2), 10);
      const actual = getHashLength(key.algorithm.hash);
      if (actual !== expected)
        throw unusable(`SHA-${expected}`, "algorithm.hash");
      break;
    }
    case "RS256":
    case "RS384":
    case "RS512": {
      if (!isAlgorithm(key.algorithm, "RSASSA-PKCS1-v1_5"))
        throw unusable("RSASSA-PKCS1-v1_5");
      const expected = parseInt(alg.slice(2), 10);
      const actual = getHashLength(key.algorithm.hash);
      if (actual !== expected)
        throw unusable(`SHA-${expected}`, "algorithm.hash");
      break;
    }
    case "PS256":
    case "PS384":
    case "PS512": {
      if (!isAlgorithm(key.algorithm, "RSA-PSS"))
        throw unusable("RSA-PSS");
      const expected = parseInt(alg.slice(2), 10);
      const actual = getHashLength(key.algorithm.hash);
      if (actual !== expected)
        throw unusable(`SHA-${expected}`, "algorithm.hash");
      break;
    }
    case "Ed25519":
    case "EdDSA": {
      if (!isAlgorithm(key.algorithm, "Ed25519"))
        throw unusable("Ed25519");
      break;
    }
    case "ML-DSA-44":
    case "ML-DSA-65":
    case "ML-DSA-87": {
      if (!isAlgorithm(key.algorithm, alg))
        throw unusable(alg);
      break;
    }
    case "ES256":
    case "ES384":
    case "ES512": {
      if (!isAlgorithm(key.algorithm, "ECDSA"))
        throw unusable("ECDSA");
      const expected = getNamedCurve(alg);
      const actual = key.algorithm.namedCurve;
      if (actual !== expected)
        throw unusable(expected, "algorithm.namedCurve");
      break;
    }
    default:
      throw new TypeError("CryptoKey does not support this operation");
  }
  checkUsage(key, usage);
}

// node_modules/jose/dist/webapi/lib/invalid_key_input.js
function message(msg, actual, ...types) {
  types = types.filter(Boolean);
  if (types.length > 2) {
    const last = types.pop();
    msg += `one of type ${types.join(", ")}, or ${last}.`;
  } else if (types.length === 2) {
    msg += `one of type ${types[0]} or ${types[1]}.`;
  } else {
    msg += `of type ${types[0]}.`;
  }
  if (actual == null) {
    msg += ` Received ${actual}`;
  } else if (typeof actual === "function" && actual.name) {
    msg += ` Received function ${actual.name}`;
  } else if (typeof actual === "object" && actual != null) {
    if (actual.constructor?.name) {
      msg += ` Received an instance of ${actual.constructor.name}`;
    }
  }
  return msg;
}
var invalid_key_input_default = (actual, ...types) => {
  return message("Key must be ", actual, ...types);
};
function withAlg(alg, actual, ...types) {
  return message(`Key for the ${alg} algorithm must be `, actual, ...types);
}

// node_modules/jose/dist/webapi/lib/is_key_like.js
function isCryptoKey(key) {
  return key?.[Symbol.toStringTag] === "CryptoKey";
}
function isKeyObject(key) {
  return key?.[Symbol.toStringTag] === "KeyObject";
}
var is_key_like_default = (key) => {
  return isCryptoKey(key) || isKeyObject(key);
};

// node_modules/jose/dist/webapi/lib/is_disjoint.js
var is_disjoint_default = (...headers) => {
  const sources = headers.filter(Boolean);
  if (sources.length === 0 || sources.length === 1) {
    return true;
  }
  let acc;
  for (const header of sources) {
    const parameters = Object.keys(header);
    if (!acc || acc.size === 0) {
      acc = new Set(parameters);
      continue;
    }
    for (const parameter of parameters) {
      if (acc.has(parameter)) {
        return false;
      }
      acc.add(parameter);
    }
  }
  return true;
};

// node_modules/jose/dist/webapi/lib/is_object.js
function isObjectLike(value) {
  return typeof value === "object" && value !== null;
}
var is_object_default = (input) => {
  if (!isObjectLike(input) || Object.prototype.toString.call(input) !== "[object Object]") {
    return false;
  }
  if (Object.getPrototypeOf(input) === null) {
    return true;
  }
  let proto = input;
  while (Object.getPrototypeOf(proto) !== null) {
    proto = Object.getPrototypeOf(proto);
  }
  return Object.getPrototypeOf(input) === proto;
};

// node_modules/jose/dist/webapi/lib/check_key_length.js
var check_key_length_default = (alg, key) => {
  if (alg.startsWith("RS") || alg.startsWith("PS")) {
    const { modulusLength } = key.algorithm;
    if (typeof modulusLength !== "number" || modulusLength < 2048) {
      throw new TypeError(`${alg} requires key modulusLength to be 2048 bits or larger`);
    }
  }
};

// node_modules/jose/dist/webapi/lib/jwk_to_key.js
function subtleMapping(jwk) {
  let algorithm;
  let keyUsages;
  switch (jwk.kty) {
    case "AKP": {
      switch (jwk.alg) {
        case "ML-DSA-44":
        case "ML-DSA-65":
        case "ML-DSA-87":
          algorithm = { name: jwk.alg };
          keyUsages = jwk.priv ? ["sign"] : ["verify"];
          break;
        default:
          throw new JOSENotSupported('Invalid or unsupported JWK "alg" (Algorithm) Parameter value');
      }
      break;
    }
    case "RSA": {
      switch (jwk.alg) {
        case "PS256":
        case "PS384":
        case "PS512":
          algorithm = { name: "RSA-PSS", hash: `SHA-${jwk.alg.slice(-3)}` };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "RS256":
        case "RS384":
        case "RS512":
          algorithm = { name: "RSASSA-PKCS1-v1_5", hash: `SHA-${jwk.alg.slice(-3)}` };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "RSA-OAEP":
        case "RSA-OAEP-256":
        case "RSA-OAEP-384":
        case "RSA-OAEP-512":
          algorithm = {
            name: "RSA-OAEP",
            hash: `SHA-${parseInt(jwk.alg.slice(-3), 10) || 1}`
          };
          keyUsages = jwk.d ? ["decrypt", "unwrapKey"] : ["encrypt", "wrapKey"];
          break;
        default:
          throw new JOSENotSupported('Invalid or unsupported JWK "alg" (Algorithm) Parameter value');
      }
      break;
    }
    case "EC": {
      switch (jwk.alg) {
        case "ES256":
          algorithm = { name: "ECDSA", namedCurve: "P-256" };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "ES384":
          algorithm = { name: "ECDSA", namedCurve: "P-384" };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "ES512":
          algorithm = { name: "ECDSA", namedCurve: "P-521" };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "ECDH-ES":
        case "ECDH-ES+A128KW":
        case "ECDH-ES+A192KW":
        case "ECDH-ES+A256KW":
          algorithm = { name: "ECDH", namedCurve: jwk.crv };
          keyUsages = jwk.d ? ["deriveBits"] : [];
          break;
        default:
          throw new JOSENotSupported('Invalid or unsupported JWK "alg" (Algorithm) Parameter value');
      }
      break;
    }
    case "OKP": {
      switch (jwk.alg) {
        case "Ed25519":
        case "EdDSA":
          algorithm = { name: "Ed25519" };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "ECDH-ES":
        case "ECDH-ES+A128KW":
        case "ECDH-ES+A192KW":
        case "ECDH-ES+A256KW":
          algorithm = { name: jwk.crv };
          keyUsages = jwk.d ? ["deriveBits"] : [];
          break;
        default:
          throw new JOSENotSupported('Invalid or unsupported JWK "alg" (Algorithm) Parameter value');
      }
      break;
    }
    default:
      throw new JOSENotSupported('Invalid or unsupported JWK "kty" (Key Type) Parameter value');
  }
  return { algorithm, keyUsages };
}
var jwk_to_key_default = async (jwk) => {
  if (!jwk.alg) {
    throw new TypeError('"alg" argument is required when "jwk.alg" is not present');
  }
  const { algorithm, keyUsages } = subtleMapping(jwk);
  const keyData = { ...jwk };
  if (keyData.kty !== "AKP") {
    delete keyData.alg;
  }
  delete keyData.use;
  return crypto.subtle.importKey("jwk", keyData, algorithm, jwk.ext ?? (jwk.d || jwk.priv ? false : true), jwk.key_ops ?? keyUsages);
};

// node_modules/jose/dist/webapi/key/import.js
async function importJWK(jwk, alg, options) {
  if (!is_object_default(jwk)) {
    throw new TypeError("JWK must be an object");
  }
  let ext;
  alg ??= jwk.alg;
  ext ??= options?.extractable ?? jwk.ext;
  switch (jwk.kty) {
    case "oct":
      if (typeof jwk.k !== "string" || !jwk.k) {
        throw new TypeError('missing "k" (Key Value) Parameter value');
      }
      return decode(jwk.k);
    case "RSA":
      if ("oth" in jwk && jwk.oth !== void 0) {
        throw new JOSENotSupported('RSA JWK "oth" (Other Primes Info) Parameter value is not supported');
      }
      return jwk_to_key_default({ ...jwk, alg, ext });
    case "AKP": {
      if (typeof jwk.alg !== "string" || !jwk.alg) {
        throw new TypeError('missing "alg" (Algorithm) Parameter value');
      }
      if (alg !== void 0 && alg !== jwk.alg) {
        throw new TypeError("JWK alg and alg option value mismatch");
      }
      return jwk_to_key_default({ ...jwk, ext });
    }
    case "EC":
    case "OKP":
      return jwk_to_key_default({ ...jwk, alg, ext });
    default:
      throw new JOSENotSupported('Unsupported "kty" (Key Type) Parameter value');
  }
}

// node_modules/jose/dist/webapi/lib/validate_crit.js
var validate_crit_default = (Err, recognizedDefault, recognizedOption, protectedHeader, joseHeader) => {
  if (joseHeader.crit !== void 0 && protectedHeader?.crit === void 0) {
    throw new Err('"crit" (Critical) Header Parameter MUST be integrity protected');
  }
  if (!protectedHeader || protectedHeader.crit === void 0) {
    return /* @__PURE__ */ new Set();
  }
  if (!Array.isArray(protectedHeader.crit) || protectedHeader.crit.length === 0 || protectedHeader.crit.some((input) => typeof input !== "string" || input.length === 0)) {
    throw new Err('"crit" (Critical) Header Parameter MUST be an array of non-empty strings when present');
  }
  let recognized;
  if (recognizedOption !== void 0) {
    recognized = new Map([...Object.entries(recognizedOption), ...recognizedDefault.entries()]);
  } else {
    recognized = recognizedDefault;
  }
  for (const parameter of protectedHeader.crit) {
    if (!recognized.has(parameter)) {
      throw new JOSENotSupported(`Extension Header Parameter "${parameter}" is not recognized`);
    }
    if (joseHeader[parameter] === void 0) {
      throw new Err(`Extension Header Parameter "${parameter}" is missing`);
    }
    if (recognized.get(parameter) && protectedHeader[parameter] === void 0) {
      throw new Err(`Extension Header Parameter "${parameter}" MUST be integrity protected`);
    }
  }
  return new Set(protectedHeader.crit);
};

// node_modules/jose/dist/webapi/lib/validate_algorithms.js
var validate_algorithms_default = (option, algorithms) => {
  if (algorithms !== void 0 && (!Array.isArray(algorithms) || algorithms.some((s) => typeof s !== "string"))) {
    throw new TypeError(`"${option}" option must be an array of strings`);
  }
  if (!algorithms) {
    return void 0;
  }
  return new Set(algorithms);
};

// node_modules/jose/dist/webapi/lib/is_jwk.js
function isJWK(key) {
  return is_object_default(key) && typeof key.kty === "string";
}
function isPrivateJWK(key) {
  return key.kty !== "oct" && (key.kty === "AKP" && typeof key.priv === "string" || typeof key.d === "string");
}
function isPublicJWK(key) {
  return key.kty !== "oct" && typeof key.d === "undefined" && typeof key.priv === "undefined";
}
function isSecretJWK(key) {
  return key.kty === "oct" && typeof key.k === "string";
}

// node_modules/jose/dist/webapi/lib/normalize_key.js
var cache;
var handleJWK = async (key, jwk, alg, freeze = false) => {
  cache ||= /* @__PURE__ */ new WeakMap();
  let cached = cache.get(key);
  if (cached?.[alg]) {
    return cached[alg];
  }
  const cryptoKey = await jwk_to_key_default({ ...jwk, alg });
  if (freeze)
    Object.freeze(key);
  if (!cached) {
    cache.set(key, { [alg]: cryptoKey });
  } else {
    cached[alg] = cryptoKey;
  }
  return cryptoKey;
};
var handleKeyObject = (keyObject, alg) => {
  cache ||= /* @__PURE__ */ new WeakMap();
  let cached = cache.get(keyObject);
  if (cached?.[alg]) {
    return cached[alg];
  }
  const isPublic = keyObject.type === "public";
  const extractable = isPublic ? true : false;
  let cryptoKey;
  if (keyObject.asymmetricKeyType === "x25519") {
    switch (alg) {
      case "ECDH-ES":
      case "ECDH-ES+A128KW":
      case "ECDH-ES+A192KW":
      case "ECDH-ES+A256KW":
        break;
      default:
        throw new TypeError("given KeyObject instance cannot be used for this algorithm");
    }
    cryptoKey = keyObject.toCryptoKey(keyObject.asymmetricKeyType, extractable, isPublic ? [] : ["deriveBits"]);
  }
  if (keyObject.asymmetricKeyType === "ed25519") {
    if (alg !== "EdDSA" && alg !== "Ed25519") {
      throw new TypeError("given KeyObject instance cannot be used for this algorithm");
    }
    cryptoKey = keyObject.toCryptoKey(keyObject.asymmetricKeyType, extractable, [
      isPublic ? "verify" : "sign"
    ]);
  }
  switch (keyObject.asymmetricKeyType) {
    case "ml-dsa-44":
    case "ml-dsa-65":
    case "ml-dsa-87": {
      if (alg !== keyObject.asymmetricKeyType.toUpperCase()) {
        throw new TypeError("given KeyObject instance cannot be used for this algorithm");
      }
      cryptoKey = keyObject.toCryptoKey(keyObject.asymmetricKeyType, extractable, [
        isPublic ? "verify" : "sign"
      ]);
    }
  }
  if (keyObject.asymmetricKeyType === "rsa") {
    let hash;
    switch (alg) {
      case "RSA-OAEP":
        hash = "SHA-1";
        break;
      case "RS256":
      case "PS256":
      case "RSA-OAEP-256":
        hash = "SHA-256";
        break;
      case "RS384":
      case "PS384":
      case "RSA-OAEP-384":
        hash = "SHA-384";
        break;
      case "RS512":
      case "PS512":
      case "RSA-OAEP-512":
        hash = "SHA-512";
        break;
      default:
        throw new TypeError("given KeyObject instance cannot be used for this algorithm");
    }
    if (alg.startsWith("RSA-OAEP")) {
      return keyObject.toCryptoKey({
        name: "RSA-OAEP",
        hash
      }, extractable, isPublic ? ["encrypt"] : ["decrypt"]);
    }
    cryptoKey = keyObject.toCryptoKey({
      name: alg.startsWith("PS") ? "RSA-PSS" : "RSASSA-PKCS1-v1_5",
      hash
    }, extractable, [isPublic ? "verify" : "sign"]);
  }
  if (keyObject.asymmetricKeyType === "ec") {
    const nist = /* @__PURE__ */ new Map([
      ["prime256v1", "P-256"],
      ["secp384r1", "P-384"],
      ["secp521r1", "P-521"]
    ]);
    const namedCurve = nist.get(keyObject.asymmetricKeyDetails?.namedCurve);
    if (!namedCurve) {
      throw new TypeError("given KeyObject instance cannot be used for this algorithm");
    }
    if (alg === "ES256" && namedCurve === "P-256") {
      cryptoKey = keyObject.toCryptoKey({
        name: "ECDSA",
        namedCurve
      }, extractable, [isPublic ? "verify" : "sign"]);
    }
    if (alg === "ES384" && namedCurve === "P-384") {
      cryptoKey = keyObject.toCryptoKey({
        name: "ECDSA",
        namedCurve
      }, extractable, [isPublic ? "verify" : "sign"]);
    }
    if (alg === "ES512" && namedCurve === "P-521") {
      cryptoKey = keyObject.toCryptoKey({
        name: "ECDSA",
        namedCurve
      }, extractable, [isPublic ? "verify" : "sign"]);
    }
    if (alg.startsWith("ECDH-ES")) {
      cryptoKey = keyObject.toCryptoKey({
        name: "ECDH",
        namedCurve
      }, extractable, isPublic ? [] : ["deriveBits"]);
    }
  }
  if (!cryptoKey) {
    throw new TypeError("given KeyObject instance cannot be used for this algorithm");
  }
  if (!cached) {
    cache.set(keyObject, { [alg]: cryptoKey });
  } else {
    cached[alg] = cryptoKey;
  }
  return cryptoKey;
};
var normalize_key_default = async (key, alg) => {
  if (key instanceof Uint8Array) {
    return key;
  }
  if (isCryptoKey(key)) {
    return key;
  }
  if (isKeyObject(key)) {
    if (key.type === "secret") {
      return key.export();
    }
    if ("toCryptoKey" in key && typeof key.toCryptoKey === "function") {
      try {
        return handleKeyObject(key, alg);
      } catch (err2) {
        if (err2 instanceof TypeError) {
          throw err2;
        }
      }
    }
    let jwk = key.export({ format: "jwk" });
    return handleJWK(key, jwk, alg);
  }
  if (isJWK(key)) {
    if (key.k) {
      return decode(key.k);
    }
    return handleJWK(key, key, alg, true);
  }
  throw new Error("unreachable");
};

// node_modules/jose/dist/webapi/lib/check_key_type.js
var tag = (key) => key?.[Symbol.toStringTag];
var jwkMatchesOp = (alg, key, usage) => {
  if (key.use !== void 0) {
    let expected;
    switch (usage) {
      case "sign":
      case "verify":
        expected = "sig";
        break;
      case "encrypt":
      case "decrypt":
        expected = "enc";
        break;
    }
    if (key.use !== expected) {
      throw new TypeError(`Invalid key for this operation, its "use" must be "${expected}" when present`);
    }
  }
  if (key.alg !== void 0 && key.alg !== alg) {
    throw new TypeError(`Invalid key for this operation, its "alg" must be "${alg}" when present`);
  }
  if (Array.isArray(key.key_ops)) {
    let expectedKeyOp;
    switch (true) {
      case (usage === "sign" || usage === "verify"):
      case alg === "dir":
      case alg.includes("CBC-HS"):
        expectedKeyOp = usage;
        break;
      case alg.startsWith("PBES2"):
        expectedKeyOp = "deriveBits";
        break;
      case /^A\d{3}(?:GCM)?(?:KW)?$/.test(alg):
        if (!alg.includes("GCM") && alg.endsWith("KW")) {
          expectedKeyOp = usage === "encrypt" ? "wrapKey" : "unwrapKey";
        } else {
          expectedKeyOp = usage;
        }
        break;
      case (usage === "encrypt" && alg.startsWith("RSA")):
        expectedKeyOp = "wrapKey";
        break;
      case usage === "decrypt":
        expectedKeyOp = alg.startsWith("RSA") ? "unwrapKey" : "deriveBits";
        break;
    }
    if (expectedKeyOp && key.key_ops?.includes?.(expectedKeyOp) === false) {
      throw new TypeError(`Invalid key for this operation, its "key_ops" must include "${expectedKeyOp}" when present`);
    }
  }
  return true;
};
var symmetricTypeCheck = (alg, key, usage) => {
  if (key instanceof Uint8Array)
    return;
  if (isJWK(key)) {
    if (isSecretJWK(key) && jwkMatchesOp(alg, key, usage))
      return;
    throw new TypeError(`JSON Web Key for symmetric algorithms must have JWK "kty" (Key Type) equal to "oct" and the JWK "k" (Key Value) present`);
  }
  if (!is_key_like_default(key)) {
    throw new TypeError(withAlg(alg, key, "CryptoKey", "KeyObject", "JSON Web Key", "Uint8Array"));
  }
  if (key.type !== "secret") {
    throw new TypeError(`${tag(key)} instances for symmetric algorithms must be of type "secret"`);
  }
};
var asymmetricTypeCheck = (alg, key, usage) => {
  if (isJWK(key)) {
    switch (usage) {
      case "decrypt":
      case "sign":
        if (isPrivateJWK(key) && jwkMatchesOp(alg, key, usage))
          return;
        throw new TypeError(`JSON Web Key for this operation be a private JWK`);
      case "encrypt":
      case "verify":
        if (isPublicJWK(key) && jwkMatchesOp(alg, key, usage))
          return;
        throw new TypeError(`JSON Web Key for this operation be a public JWK`);
    }
  }
  if (!is_key_like_default(key)) {
    throw new TypeError(withAlg(alg, key, "CryptoKey", "KeyObject", "JSON Web Key"));
  }
  if (key.type === "secret") {
    throw new TypeError(`${tag(key)} instances for asymmetric algorithms must not be of type "secret"`);
  }
  if (key.type === "public") {
    switch (usage) {
      case "sign":
        throw new TypeError(`${tag(key)} instances for asymmetric algorithm signing must be of type "private"`);
      case "decrypt":
        throw new TypeError(`${tag(key)} instances for asymmetric algorithm decryption must be of type "private"`);
      default:
        break;
    }
  }
  if (key.type === "private") {
    switch (usage) {
      case "verify":
        throw new TypeError(`${tag(key)} instances for asymmetric algorithm verifying must be of type "public"`);
      case "encrypt":
        throw new TypeError(`${tag(key)} instances for asymmetric algorithm encryption must be of type "public"`);
      default:
        break;
    }
  }
};
var check_key_type_default = (alg, key, usage) => {
  const symmetric = alg.startsWith("HS") || alg === "dir" || alg.startsWith("PBES2") || /^A(?:128|192|256)(?:GCM)?(?:KW)?$/.test(alg) || /^A(?:128|192|256)CBC-HS(?:256|384|512)$/.test(alg);
  if (symmetric) {
    symmetricTypeCheck(alg, key, usage);
  } else {
    asymmetricTypeCheck(alg, key, usage);
  }
};

// node_modules/jose/dist/webapi/lib/subtle_dsa.js
var subtle_dsa_default = (alg, algorithm) => {
  const hash = `SHA-${alg.slice(-3)}`;
  switch (alg) {
    case "HS256":
    case "HS384":
    case "HS512":
      return { hash, name: "HMAC" };
    case "PS256":
    case "PS384":
    case "PS512":
      return { hash, name: "RSA-PSS", saltLength: parseInt(alg.slice(-3), 10) >> 3 };
    case "RS256":
    case "RS384":
    case "RS512":
      return { hash, name: "RSASSA-PKCS1-v1_5" };
    case "ES256":
    case "ES384":
    case "ES512":
      return { hash, name: "ECDSA", namedCurve: algorithm.namedCurve };
    case "Ed25519":
    case "EdDSA":
      return { name: "Ed25519" };
    case "ML-DSA-44":
    case "ML-DSA-65":
    case "ML-DSA-87":
      return { name: alg };
    default:
      throw new JOSENotSupported(`alg ${alg} is not supported either by JOSE or your javascript runtime`);
  }
};

// node_modules/jose/dist/webapi/lib/get_sign_verify_key.js
var get_sign_verify_key_default = async (alg, key, usage) => {
  if (key instanceof Uint8Array) {
    if (!alg.startsWith("HS")) {
      throw new TypeError(invalid_key_input_default(key, "CryptoKey", "KeyObject", "JSON Web Key"));
    }
    return crypto.subtle.importKey("raw", key, { hash: `SHA-${alg.slice(-3)}`, name: "HMAC" }, false, [usage]);
  }
  checkSigCryptoKey(key, alg, usage);
  return key;
};

// node_modules/jose/dist/webapi/lib/verify.js
var verify_default = async (alg, key, signature, data) => {
  const cryptoKey = await get_sign_verify_key_default(alg, key, "verify");
  check_key_length_default(alg, cryptoKey);
  const algorithm = subtle_dsa_default(alg, cryptoKey.algorithm);
  try {
    return await crypto.subtle.verify(algorithm, cryptoKey, signature, data);
  } catch {
    return false;
  }
};

// node_modules/jose/dist/webapi/jws/flattened/verify.js
async function flattenedVerify(jws, key, options) {
  if (!is_object_default(jws)) {
    throw new JWSInvalid("Flattened JWS must be an object");
  }
  if (jws.protected === void 0 && jws.header === void 0) {
    throw new JWSInvalid('Flattened JWS must have either of the "protected" or "header" members');
  }
  if (jws.protected !== void 0 && typeof jws.protected !== "string") {
    throw new JWSInvalid("JWS Protected Header incorrect type");
  }
  if (jws.payload === void 0) {
    throw new JWSInvalid("JWS Payload missing");
  }
  if (typeof jws.signature !== "string") {
    throw new JWSInvalid("JWS Signature missing or incorrect type");
  }
  if (jws.header !== void 0 && !is_object_default(jws.header)) {
    throw new JWSInvalid("JWS Unprotected Header incorrect type");
  }
  let parsedProt = {};
  if (jws.protected) {
    try {
      const protectedHeader = decode(jws.protected);
      parsedProt = JSON.parse(decoder.decode(protectedHeader));
    } catch {
      throw new JWSInvalid("JWS Protected Header is invalid");
    }
  }
  if (!is_disjoint_default(parsedProt, jws.header)) {
    throw new JWSInvalid("JWS Protected and JWS Unprotected Header Parameter names must be disjoint");
  }
  const joseHeader = {
    ...parsedProt,
    ...jws.header
  };
  const extensions = validate_crit_default(JWSInvalid, /* @__PURE__ */ new Map([["b64", true]]), options?.crit, parsedProt, joseHeader);
  let b64 = true;
  if (extensions.has("b64")) {
    b64 = parsedProt.b64;
    if (typeof b64 !== "boolean") {
      throw new JWSInvalid('The "b64" (base64url-encode payload) Header Parameter must be a boolean');
    }
  }
  const { alg } = joseHeader;
  if (typeof alg !== "string" || !alg) {
    throw new JWSInvalid('JWS "alg" (Algorithm) Header Parameter missing or invalid');
  }
  const algorithms = options && validate_algorithms_default("algorithms", options.algorithms);
  if (algorithms && !algorithms.has(alg)) {
    throw new JOSEAlgNotAllowed('"alg" (Algorithm) Header Parameter value not allowed');
  }
  if (b64) {
    if (typeof jws.payload !== "string") {
      throw new JWSInvalid("JWS Payload must be a string");
    }
  } else if (typeof jws.payload !== "string" && !(jws.payload instanceof Uint8Array)) {
    throw new JWSInvalid("JWS Payload must be a string or an Uint8Array instance");
  }
  let resolvedKey = false;
  if (typeof key === "function") {
    key = await key(parsedProt, jws);
    resolvedKey = true;
  }
  check_key_type_default(alg, key, "verify");
  const data = concat(encoder.encode(jws.protected ?? ""), encoder.encode("."), typeof jws.payload === "string" ? encoder.encode(jws.payload) : jws.payload);
  let signature;
  try {
    signature = decode(jws.signature);
  } catch {
    throw new JWSInvalid("Failed to base64url decode the signature");
  }
  const k = await normalize_key_default(key, alg);
  const verified = await verify_default(alg, k, signature, data);
  if (!verified) {
    throw new JWSSignatureVerificationFailed();
  }
  let payload;
  if (b64) {
    try {
      payload = decode(jws.payload);
    } catch {
      throw new JWSInvalid("Failed to base64url decode the payload");
    }
  } else if (typeof jws.payload === "string") {
    payload = encoder.encode(jws.payload);
  } else {
    payload = jws.payload;
  }
  const result = { payload };
  if (jws.protected !== void 0) {
    result.protectedHeader = parsedProt;
  }
  if (jws.header !== void 0) {
    result.unprotectedHeader = jws.header;
  }
  if (resolvedKey) {
    return { ...result, key: k };
  }
  return result;
}

// node_modules/jose/dist/webapi/jws/compact/verify.js
async function compactVerify(jws, key, options) {
  if (jws instanceof Uint8Array) {
    jws = decoder.decode(jws);
  }
  if (typeof jws !== "string") {
    throw new JWSInvalid("Compact JWS must be a string or Uint8Array");
  }
  const { 0: protectedHeader, 1: payload, 2: signature, length } = jws.split(".");
  if (length !== 3) {
    throw new JWSInvalid("Invalid Compact JWS");
  }
  const verified = await flattenedVerify({ payload, protected: protectedHeader, signature }, key, options);
  const result = { payload: verified.payload, protectedHeader: verified.protectedHeader };
  if (typeof key === "function") {
    return { ...result, key: verified.key };
  }
  return result;
}

// node_modules/jose/dist/webapi/lib/epoch.js
var epoch_default = (date) => Math.floor(date.getTime() / 1e3);

// node_modules/jose/dist/webapi/lib/secs.js
var minute = 60;
var hour = minute * 60;
var day = hour * 24;
var week = day * 7;
var year = day * 365.25;
var REGEX = /^(\+|\-)? ?(\d+|\d+\.\d+) ?(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w|years?|yrs?|y)(?: (ago|from now))?$/i;
var secs_default = (str) => {
  const matched = REGEX.exec(str);
  if (!matched || matched[4] && matched[1]) {
    throw new TypeError("Invalid time period format");
  }
  const value = parseFloat(matched[2]);
  const unit = matched[3].toLowerCase();
  let numericDate;
  switch (unit) {
    case "sec":
    case "secs":
    case "second":
    case "seconds":
    case "s":
      numericDate = Math.round(value);
      break;
    case "minute":
    case "minutes":
    case "min":
    case "mins":
    case "m":
      numericDate = Math.round(value * minute);
      break;
    case "hour":
    case "hours":
    case "hr":
    case "hrs":
    case "h":
      numericDate = Math.round(value * hour);
      break;
    case "day":
    case "days":
    case "d":
      numericDate = Math.round(value * day);
      break;
    case "week":
    case "weeks":
    case "w":
      numericDate = Math.round(value * week);
      break;
    default:
      numericDate = Math.round(value * year);
      break;
  }
  if (matched[1] === "-" || matched[4] === "ago") {
    return -numericDate;
  }
  return numericDate;
};

// node_modules/jose/dist/webapi/lib/jwt_claims_set.js
var normalizeTyp = (value) => {
  if (value.includes("/")) {
    return value.toLowerCase();
  }
  return `application/${value.toLowerCase()}`;
};
var checkAudiencePresence = (audPayload, audOption) => {
  if (typeof audPayload === "string") {
    return audOption.includes(audPayload);
  }
  if (Array.isArray(audPayload)) {
    return audOption.some(Set.prototype.has.bind(new Set(audPayload)));
  }
  return false;
};
function validateClaimsSet(protectedHeader, encodedPayload, options = {}) {
  let payload;
  try {
    payload = JSON.parse(decoder.decode(encodedPayload));
  } catch {
  }
  if (!is_object_default(payload)) {
    throw new JWTInvalid("JWT Claims Set must be a top-level JSON object");
  }
  const { typ } = options;
  if (typ && (typeof protectedHeader.typ !== "string" || normalizeTyp(protectedHeader.typ) !== normalizeTyp(typ))) {
    throw new JWTClaimValidationFailed('unexpected "typ" JWT header value', payload, "typ", "check_failed");
  }
  const { requiredClaims = [], issuer, subject, audience, maxTokenAge } = options;
  const presenceCheck = [...requiredClaims];
  if (maxTokenAge !== void 0)
    presenceCheck.push("iat");
  if (audience !== void 0)
    presenceCheck.push("aud");
  if (subject !== void 0)
    presenceCheck.push("sub");
  if (issuer !== void 0)
    presenceCheck.push("iss");
  for (const claim of new Set(presenceCheck.reverse())) {
    if (!(claim in payload)) {
      throw new JWTClaimValidationFailed(`missing required "${claim}" claim`, payload, claim, "missing");
    }
  }
  if (issuer && !(Array.isArray(issuer) ? issuer : [issuer]).includes(payload.iss)) {
    throw new JWTClaimValidationFailed('unexpected "iss" claim value', payload, "iss", "check_failed");
  }
  if (subject && payload.sub !== subject) {
    throw new JWTClaimValidationFailed('unexpected "sub" claim value', payload, "sub", "check_failed");
  }
  if (audience && !checkAudiencePresence(payload.aud, typeof audience === "string" ? [audience] : audience)) {
    throw new JWTClaimValidationFailed('unexpected "aud" claim value', payload, "aud", "check_failed");
  }
  let tolerance;
  switch (typeof options.clockTolerance) {
    case "string":
      tolerance = secs_default(options.clockTolerance);
      break;
    case "number":
      tolerance = options.clockTolerance;
      break;
    case "undefined":
      tolerance = 0;
      break;
    default:
      throw new TypeError("Invalid clockTolerance option type");
  }
  const { currentDate } = options;
  const now = epoch_default(currentDate || /* @__PURE__ */ new Date());
  if ((payload.iat !== void 0 || maxTokenAge) && typeof payload.iat !== "number") {
    throw new JWTClaimValidationFailed('"iat" claim must be a number', payload, "iat", "invalid");
  }
  if (payload.nbf !== void 0) {
    if (typeof payload.nbf !== "number") {
      throw new JWTClaimValidationFailed('"nbf" claim must be a number', payload, "nbf", "invalid");
    }
    if (payload.nbf > now + tolerance) {
      throw new JWTClaimValidationFailed('"nbf" claim timestamp check failed', payload, "nbf", "check_failed");
    }
  }
  if (payload.exp !== void 0) {
    if (typeof payload.exp !== "number") {
      throw new JWTClaimValidationFailed('"exp" claim must be a number', payload, "exp", "invalid");
    }
    if (payload.exp <= now - tolerance) {
      throw new JWTExpired('"exp" claim timestamp check failed', payload, "exp", "check_failed");
    }
  }
  if (maxTokenAge) {
    const age = now - payload.iat;
    const max = typeof maxTokenAge === "number" ? maxTokenAge : secs_default(maxTokenAge);
    if (age - tolerance > max) {
      throw new JWTExpired('"iat" claim timestamp check failed (too far in the past)', payload, "iat", "check_failed");
    }
    if (age < 0 - tolerance) {
      throw new JWTClaimValidationFailed('"iat" claim timestamp check failed (it should be in the past)', payload, "iat", "check_failed");
    }
  }
  return payload;
}

// node_modules/jose/dist/webapi/jwt/verify.js
async function jwtVerify(jwt, key, options) {
  const verified = await compactVerify(jwt, key, options);
  if (verified.protectedHeader.crit?.includes("b64") && verified.protectedHeader.b64 === false) {
    throw new JWTInvalid("JWTs MUST NOT use unencoded payload");
  }
  const payload = validateClaimsSet(verified.protectedHeader, verified.payload, options);
  const result = { payload, protectedHeader: verified.protectedHeader };
  if (typeof key === "function") {
    return { ...result, key: verified.key };
  }
  return result;
}

// node_modules/jose/dist/webapi/jwks/local.js
function getKtyFromAlg(alg) {
  switch (typeof alg === "string" && alg.slice(0, 2)) {
    case "RS":
    case "PS":
      return "RSA";
    case "ES":
      return "EC";
    case "Ed":
      return "OKP";
    case "ML":
      return "AKP";
    default:
      throw new JOSENotSupported('Unsupported "alg" value for a JSON Web Key Set');
  }
}
function isJWKSLike(jwks) {
  return jwks && typeof jwks === "object" && Array.isArray(jwks.keys) && jwks.keys.every(isJWKLike);
}
function isJWKLike(key) {
  return is_object_default(key);
}
var LocalJWKSet = class {
  #jwks;
  #cached = /* @__PURE__ */ new WeakMap();
  constructor(jwks) {
    if (!isJWKSLike(jwks)) {
      throw new JWKSInvalid("JSON Web Key Set malformed");
    }
    this.#jwks = structuredClone(jwks);
  }
  jwks() {
    return this.#jwks;
  }
  async getKey(protectedHeader, token) {
    const { alg, kid } = { ...protectedHeader, ...token?.header };
    const kty = getKtyFromAlg(alg);
    const candidates = this.#jwks.keys.filter((jwk2) => {
      let candidate = kty === jwk2.kty;
      if (candidate && typeof kid === "string") {
        candidate = kid === jwk2.kid;
      }
      if (candidate && (typeof jwk2.alg === "string" || kty === "AKP")) {
        candidate = alg === jwk2.alg;
      }
      if (candidate && typeof jwk2.use === "string") {
        candidate = jwk2.use === "sig";
      }
      if (candidate && Array.isArray(jwk2.key_ops)) {
        candidate = jwk2.key_ops.includes("verify");
      }
      if (candidate) {
        switch (alg) {
          case "ES256":
            candidate = jwk2.crv === "P-256";
            break;
          case "ES384":
            candidate = jwk2.crv === "P-384";
            break;
          case "ES512":
            candidate = jwk2.crv === "P-521";
            break;
          case "Ed25519":
          case "EdDSA":
            candidate = jwk2.crv === "Ed25519";
            break;
        }
      }
      return candidate;
    });
    const { 0: jwk, length } = candidates;
    if (length === 0) {
      throw new JWKSNoMatchingKey();
    }
    if (length !== 1) {
      const error = new JWKSMultipleMatchingKeys();
      const _cached = this.#cached;
      error[Symbol.asyncIterator] = async function* () {
        for (const jwk2 of candidates) {
          try {
            yield await importWithAlgCache(_cached, jwk2, alg);
          } catch {
          }
        }
      };
      throw error;
    }
    return importWithAlgCache(this.#cached, jwk, alg);
  }
};
async function importWithAlgCache(cache2, jwk, alg) {
  const cached = cache2.get(jwk) || cache2.set(jwk, {}).get(jwk);
  if (cached[alg] === void 0) {
    const key = await importJWK({ ...jwk, ext: true }, alg);
    if (key instanceof Uint8Array || key.type !== "public") {
      throw new JWKSInvalid("JSON Web Key Set members must be public keys");
    }
    cached[alg] = key;
  }
  return cached[alg];
}
function createLocalJWKSet(jwks) {
  const set = new LocalJWKSet(jwks);
  const localJWKSet = async (protectedHeader, token) => set.getKey(protectedHeader, token);
  Object.defineProperties(localJWKSet, {
    jwks: {
      value: () => structuredClone(set.jwks()),
      enumerable: false,
      configurable: false,
      writable: false
    }
  });
  return localJWKSet;
}

// node_modules/jose/dist/webapi/jwks/remote.js
function isCloudflareWorkers() {
  return typeof WebSocketPair !== "undefined" || typeof navigator !== "undefined" && navigator.userAgent === "Cloudflare-Workers" || typeof EdgeRuntime !== "undefined" && EdgeRuntime === "vercel";
}
var USER_AGENT;
if (typeof navigator === "undefined" || !navigator.userAgent?.startsWith?.("Mozilla/5.0 ")) {
  const NAME = "jose";
  const VERSION = "v6.1.0";
  USER_AGENT = `${NAME}/${VERSION}`;
}
var customFetch = Symbol();
async function fetchJwks(url, headers, signal, fetchImpl = fetch) {
  const response = await fetchImpl(url, {
    method: "GET",
    signal,
    redirect: "manual",
    headers
  }).catch((err2) => {
    if (err2.name === "TimeoutError") {
      throw new JWKSTimeout();
    }
    throw err2;
  });
  if (response.status !== 200) {
    throw new JOSEError("Expected 200 OK from the JSON Web Key Set HTTP response");
  }
  try {
    return await response.json();
  } catch {
    throw new JOSEError("Failed to parse the JSON Web Key Set HTTP response as JSON");
  }
}
var jwksCache = Symbol();
function isFreshJwksCache(input, cacheMaxAge) {
  if (typeof input !== "object" || input === null) {
    return false;
  }
  if (!("uat" in input) || typeof input.uat !== "number" || Date.now() - input.uat >= cacheMaxAge) {
    return false;
  }
  if (!("jwks" in input) || !is_object_default(input.jwks) || !Array.isArray(input.jwks.keys) || !Array.prototype.every.call(input.jwks.keys, is_object_default)) {
    return false;
  }
  return true;
}
var RemoteJWKSet = class {
  #url;
  #timeoutDuration;
  #cooldownDuration;
  #cacheMaxAge;
  #jwksTimestamp;
  #pendingFetch;
  #headers;
  #customFetch;
  #local;
  #cache;
  constructor(url, options) {
    if (!(url instanceof URL)) {
      throw new TypeError("url must be an instance of URL");
    }
    this.#url = new URL(url.href);
    this.#timeoutDuration = typeof options?.timeoutDuration === "number" ? options?.timeoutDuration : 5e3;
    this.#cooldownDuration = typeof options?.cooldownDuration === "number" ? options?.cooldownDuration : 3e4;
    this.#cacheMaxAge = typeof options?.cacheMaxAge === "number" ? options?.cacheMaxAge : 6e5;
    this.#headers = new Headers(options?.headers);
    if (USER_AGENT && !this.#headers.has("User-Agent")) {
      this.#headers.set("User-Agent", USER_AGENT);
    }
    if (!this.#headers.has("accept")) {
      this.#headers.set("accept", "application/json");
      this.#headers.append("accept", "application/jwk-set+json");
    }
    this.#customFetch = options?.[customFetch];
    if (options?.[jwksCache] !== void 0) {
      this.#cache = options?.[jwksCache];
      if (isFreshJwksCache(options?.[jwksCache], this.#cacheMaxAge)) {
        this.#jwksTimestamp = this.#cache.uat;
        this.#local = createLocalJWKSet(this.#cache.jwks);
      }
    }
  }
  pendingFetch() {
    return !!this.#pendingFetch;
  }
  coolingDown() {
    return typeof this.#jwksTimestamp === "number" ? Date.now() < this.#jwksTimestamp + this.#cooldownDuration : false;
  }
  fresh() {
    return typeof this.#jwksTimestamp === "number" ? Date.now() < this.#jwksTimestamp + this.#cacheMaxAge : false;
  }
  jwks() {
    return this.#local?.jwks();
  }
  async getKey(protectedHeader, token) {
    if (!this.#local || !this.fresh()) {
      await this.reload();
    }
    try {
      return await this.#local(protectedHeader, token);
    } catch (err2) {
      if (err2 instanceof JWKSNoMatchingKey) {
        if (this.coolingDown() === false) {
          await this.reload();
          return this.#local(protectedHeader, token);
        }
      }
      throw err2;
    }
  }
  async reload() {
    if (this.#pendingFetch && isCloudflareWorkers()) {
      this.#pendingFetch = void 0;
    }
    this.#pendingFetch ||= fetchJwks(this.#url.href, this.#headers, AbortSignal.timeout(this.#timeoutDuration), this.#customFetch).then((json) => {
      this.#local = createLocalJWKSet(json);
      if (this.#cache) {
        this.#cache.uat = Date.now();
        this.#cache.jwks = json;
      }
      this.#jwksTimestamp = Date.now();
      this.#pendingFetch = void 0;
    }).catch((err2) => {
      this.#pendingFetch = void 0;
      throw err2;
    });
    await this.#pendingFetch;
  }
};
function createRemoteJWKSet(url, options) {
  const set = new RemoteJWKSet(url, options);
  const remoteJWKSet = async (protectedHeader, token) => set.getKey(protectedHeader, token);
  Object.defineProperties(remoteJWKSet, {
    coolingDown: {
      get: () => set.coolingDown(),
      enumerable: true,
      configurable: false
    },
    fresh: {
      get: () => set.fresh(),
      enumerable: true,
      configurable: false
    },
    reload: {
      value: () => set.reload(),
      enumerable: true,
      configurable: false,
      writable: false
    },
    reloading: {
      get: () => set.pendingFetch(),
      enumerable: true,
      configurable: false
    },
    jwks: {
      value: () => set.jwks(),
      enumerable: true,
      configurable: false,
      writable: false
    }
  });
  return remoteJWKSet;
}

// src/config.ts
var ACCESS_TOKEN_TTL_SECONDS = 15 * 60;
var REFRESH_TOKEN_TTL_SECONDS = 14 * 24 * 60 * 60;
var CLIENT_REGISTRATION_TTL_SECONDS = 90 * 24 * 60 * 60;
var OAUTH_STATE_TTL_SECONDS = 10 * 60;
var MCP_RESOURCE = "https://mcp.yourown.chat/mcp";
var HOSTED_REDIRECTS = /* @__PURE__ */ new Map([
  ["claude.ai", "/api/mcp/auth_callback"],
  ["claude.com", "/api/mcp/auth_callback"],
  ["chatgpt.com", null],
  ["playground.ai.cloudflare.com", null],
  [
    "oauth-callbacks.cloudflareaccess.com",
    "/cdn-cgi/access/outbound-oauth-callback"
  ]
]);
function isAllowedRedirectUri(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.username || url.password || url.hash) {
    return false;
  }
  const hostname = url.hostname.toLowerCase();
  const isLoopback = hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
  if (isLoopback) {
    return (url.protocol === "http:" || url.protocol === "https:") && url.pathname.length > 0;
  }
  if (url.protocol !== "https:") {
    return false;
  }
  const requiredPath = HOSTED_REDIRECTS.get(hostname);
  if (requiredPath === void 0) {
    return false;
  }
  return requiredPath === null || url.pathname === requiredPath;
}
function parseAllowedEmails(value) {
  let parsed;
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

// src/state.ts
var textEncoder = new TextEncoder();
async function createSignedState(kv, keyPrefix, value, secret) {
  const id = crypto.randomUUID();
  const signature = await sign(id, secret);
  await kv.put(`${keyPrefix}:${id}`, JSON.stringify(value), {
    expirationTtl: OAUTH_STATE_TTL_SECONDS
  });
  return `${id}.${signature}`;
}
async function consumeSignedState(kv, keyPrefix, token, secret) {
  const separator = token.lastIndexOf(".");
  if (separator < 1) {
    throw new Error("Invalid OAuth state");
  }
  const id = token.slice(0, separator);
  const suppliedSignature = token.slice(separator + 1);
  if (!await verify(id, suppliedSignature, secret)) {
    throw new Error("Invalid OAuth state");
  }
  const key = `${keyPrefix}:${id}`;
  const serialized = await kv.get(key);
  if (serialized === null) {
    throw new Error("Expired or already used OAuth state");
  }
  await kv.delete(key);
  return JSON.parse(serialized);
}
async function createPkce() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const codeVerifier = base64Url(bytes);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    textEncoder.encode(codeVerifier)
  );
  return {
    codeChallenge: base64Url(new Uint8Array(digest)),
    codeVerifier
  };
}
function createCsrfCookie() {
  const token = crypto.randomUUID();
  return {
    token,
    cookie: `__Host-MCP_CSRF=${token}; HttpOnly; Secure; Path=/; SameSite=Lax; Max-Age=${OAUTH_STATE_TTL_SECONDS}`
  };
}
function validateCsrf(request, supplied) {
  if (typeof supplied !== "string") {
    throw new Error("Missing CSRF token");
  }
  const cookie = request.headers.get("cookie")?.split(";").map((part) => part.trim()).find((part) => part.startsWith("__Host-MCP_CSRF="));
  const stored = cookie?.slice("__Host-MCP_CSRF=".length);
  if (!stored || !timingSafeEqual(stored, supplied)) {
    throw new Error("Invalid CSRF token");
  }
  return "__Host-MCP_CSRF=; HttpOnly; Secure; Path=/; SameSite=Lax; Max-Age=0";
}
async function sign(value, secret) {
  if (secret.length < 32) {
    throw new Error("OAUTH_STATE_SECRET must contain at least 32 characters");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { hash: "SHA-256", name: "HMAC" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    textEncoder.encode(value)
  );
  return base64Url(new Uint8Array(signature));
}
async function verify(value, suppliedSignature, secret) {
  const expected = await sign(value, secret);
  return timingSafeEqual(expected, suppliedSignature);
}
function timingSafeEqual(left, right) {
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
function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
}

// src/auth.ts
async function handleAuthorizationRequest(request, env) {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/authorize") {
    const oauthRequest = await env.OAUTH_PROVIDER.parseAuthRequest(request);
    assertAllowedOAuthRequest(oauthRequest);
    const client = await env.OAUTH_PROVIDER.lookupClient(oauthRequest.clientId);
    const approvalState = await createSignedState(
      env.OAUTH_KV,
      "approval",
      oauthRequest,
      env.OAUTH_STATE_SECRET
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
    const oauthRequest = await consumeSignedState(
      env.OAUTH_KV,
      "approval",
      approvalState,
      env.OAUTH_STATE_SECRET
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
        url.searchParams.get("error_description") ?? "Cloudflare Access denied authorization"
      );
    }
    const state = url.searchParams.get("state");
    const code = url.searchParams.get("code");
    if (!state || !code) {
      return oauthError("invalid_request", "Missing Access authorization response");
    }
    const upstreamState = await consumeSignedState(
      env.OAUTH_KV,
      "upstream",
      state,
      env.OAUTH_STATE_SECRET
    );
    const tokens = await exchangeAccessCode(
      request,
      code,
      upstreamState.codeVerifier,
      env
    );
    const identity = await verifyAccessIdentity(tokens.id_token, env);
    const allowedEmails = parseAllowedEmails(env.ALLOWED_EMAILS);
    if (!allowedEmails.has(identity.email.toLowerCase())) {
      console.warn(
        JSON.stringify({
          email: identity.email,
          event: "oauth_identity_denied"
        })
      );
      return oauthError("access_denied", "This identity is not allowed");
    }
    const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
      metadata: { email: identity.email },
      props: identity,
      request: upstreamState.oauthRequest,
      revokeExistingGrants: false,
      scope: upstreamState.oauthRequest.scope,
      userId: identity.sub
    });
    console.log(
      JSON.stringify({
        client_id: upstreamState.oauthRequest.clientId,
        email: identity.email,
        event: "oauth_authorization_completed"
      })
    );
    return Response.redirect(redirectTo, 302);
  }
  if (request.method === "GET" && url.pathname === "/healthz") {
    return Response.json({ status: "ok" });
  }
  return new Response("Not Found", { status: 404 });
}
function assertAllowedOAuthRequest(request) {
  if (!request.clientId || !isAllowedRedirectUri(request.redirectUri)) {
    throw new Error("OAuth client redirect URI is not allowed");
  }
}
async function createAccessRedirect(request, oauthRequest, env) {
  const { codeChallenge, codeVerifier } = await createPkce();
  const state = await createSignedState(
    env.OAUTH_KV,
    "upstream",
    { codeVerifier, oauthRequest },
    env.OAUTH_STATE_SECRET
  );
  const authorizationUrl = new URL(env.ACCESS_AUTHORIZATION_URL);
  authorizationUrl.searchParams.set("client_id", env.ACCESS_CLIENT_ID);
  authorizationUrl.searchParams.set("code_challenge", codeChallenge);
  authorizationUrl.searchParams.set("code_challenge_method", "S256");
  authorizationUrl.searchParams.set(
    "redirect_uri",
    new URL("/callback", request.url).href
  );
  authorizationUrl.searchParams.set("response_type", "code");
  authorizationUrl.searchParams.set("scope", "openid email profile");
  authorizationUrl.searchParams.set("state", state);
  return Response.redirect(authorizationUrl.toString(), 302);
}
async function exchangeAccessCode(request, code, codeVerifier, env) {
  const response = await fetch(env.ACCESS_TOKEN_URL, {
    body: new URLSearchParams({
      client_id: env.ACCESS_CLIENT_ID,
      client_secret: env.ACCESS_CLIENT_SECRET,
      code,
      code_verifier: codeVerifier,
      grant_type: "authorization_code",
      redirect_uri: new URL("/callback", request.url).href
    }),
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded"
    },
    method: "POST"
  });
  if (!response.ok) {
    console.error(
      JSON.stringify({
        event: "access_code_exchange_failed",
        status: response.status
      })
    );
    throw new Error("Cloudflare Access code exchange failed");
  }
  const tokens = await response.json();
  if (!tokens.access_token || !tokens.id_token) {
    throw new Error("Cloudflare Access returned an incomplete token response");
  }
  return {
    access_token: tokens.access_token,
    id_token: tokens.id_token
  };
}
async function verifyAccessIdentity(idToken, env) {
  const { payload } = await jwtVerify(
    idToken,
    createRemoteJWKSet(new URL(env.ACCESS_JWKS_URL)),
    {
      algorithms: ["RS256"],
      audience: env.ACCESS_CLIENT_ID,
      clockTolerance: 5,
      issuer: env.ACCESS_ISSUER
    }
  );
  if (typeof payload.sub !== "string" || typeof payload.email !== "string") {
    throw new Error("Cloudflare Access ID token is missing identity claims");
  }
  return {
    email: payload.email,
    name: typeof payload.name === "string" ? payload.name : payload.email,
    sub: payload.sub
  };
}
function renderApproval(client, state) {
  const { cookie, token } = createCsrfCookie();
  const clientName = escapeHtml(client?.clientName ?? "MCP client");
  const redirectUris = (client?.redirectUris ?? []).map((uri) => `<li><code>${escapeHtml(uri)}</code></li>`).join("");
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
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "Content-Type": "text/html; charset=utf-8",
      "Referrer-Policy": "no-referrer",
      "Set-Cookie": cookie,
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY"
    }
  });
}
function oauthError(error, description) {
  return Response.json(
    { error, error_description: description },
    { status: 400 }
  );
}
function escapeHtml(value) {
  return value.replace(/&/gu, "&amp;").replace(/</gu, "&lt;").replace(/>/gu, "&gt;").replace(/"/gu, "&quot;").replace(/'/gu, "&#039;");
}

// src/proxy.ts
var PRIVATE_REQUEST_HEADERS = [
  "authorization",
  "cookie",
  "cf-access-client-id",
  "cf-access-client-secret",
  "cf-authorization",
  "host"
];
function createPortalRequest(request, env) {
  const incomingUrl = new URL(request.url);
  const upstreamUrl = new URL(env.PORTAL_ORIGIN_URL);
  upstreamUrl.pathname = incomingUrl.pathname;
  upstreamUrl.search = incomingUrl.search;
  const headers = new Headers(request.headers);
  for (const name of PRIVATE_REQUEST_HEADERS) {
    headers.delete(name);
  }
  headers.set("CF-Access-Client-Id", env.PORTAL_SERVICE_TOKEN_ID);
  headers.set("CF-Access-Client-Secret", env.PORTAL_SERVICE_TOKEN_SECRET);
  const init = {
    body: request.method === "GET" || request.method === "HEAD" ? void 0 : request.body,
    headers,
    method: request.method,
    redirect: "manual"
  };
  if (init.body !== void 0) {
    init.duplex = "half";
  }
  return new Request(upstreamUrl, init);
}
async function proxyPortalRequest(request, env) {
  const startedAt = Date.now();
  const response = await fetch(createPortalRequest(request, env));
  console.log(
    JSON.stringify({
      duration_ms: Date.now() - startedAt,
      event: "portal_proxy",
      method: request.method,
      status: response.status
    })
  );
  return response;
}

// src/index.ts
var oauthProvider = new oauth_provider_default({
  accessTokenTTL: ACCESS_TOKEN_TTL_SECONDS,
  allowPlainPKCE: false,
  apiHandler: {
    fetch: (request, env) => proxyPortalRequest(request, env)
  },
  apiRoute: "/mcp",
  authorizeEndpoint: "/authorize",
  clientRegistrationEndpoint: "/register",
  clientRegistrationTTL: CLIENT_REGISTRATION_TTL_SECONDS,
  defaultHandler: {
    fetch: (request, env) => handleAuthorizationRequest(request, env)
  },
  onError: ({ code, description, status }) => {
    console.error(
      JSON.stringify({
        code,
        description,
        event: "oauth_error",
        status
      })
    );
  },
  refreshTokenTTL: REFRESH_TOKEN_TTL_SECONDS,
  resourceMetadata: {
    authorization_servers: ["https://mcp.yourown.chat"],
    bearer_methods_supported: ["header"],
    resource: MCP_RESOURCE,
    resource_name: "yourown-chat MCP portal"
  },
  tokenEndpoint: "/token",
  tokenExchangeCallback: ({ clientId, grantType, userId }) => {
    console.log(
      JSON.stringify({
        client_id: clientId,
        event: "oauth_token_exchange",
        grant_type: grantType,
        user_id: userId
      })
    );
  }
});
var index_default = {
  fetch(request, env, ctx) {
    return oauthProvider.fetch(request, env, ctx);
  },
  scheduled(_controller, env, ctx) {
    ctx.waitUntil(oauthProvider.purgeExpiredData(env, { batchSize: 100 }));
  }
};
export {
  index_default as default
};
