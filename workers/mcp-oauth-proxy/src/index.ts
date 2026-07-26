import OAuthProvider from "@cloudflare/workers-oauth-provider";
import { handleAuthorizationRequest, type AuthEnv } from "./auth";
import {
  ACCESS_TOKEN_TTL_SECONDS,
  CLIENT_REGISTRATION_TTL_SECONDS,
  MCP_RESOURCE,
  REFRESH_TOKEN_TTL_SECONDS,
} from "./config";
import {
  proxyPortalRequest,
  type PortalProxyEnv,
} from "./proxy";

type Env = AuthEnv & PortalProxyEnv;

const oauthProvider = new OAuthProvider({
  accessTokenTTL: ACCESS_TOKEN_TTL_SECONDS,
  allowPlainPKCE: false,
  apiHandler: {
    fetch: (request: Request, env: Env) => proxyPortalRequest(request, env),
  },
  apiRoute: "/mcp",
  authorizeEndpoint: "/authorize",
  clientRegistrationEndpoint: "/register",
  clientRegistrationTTL: CLIENT_REGISTRATION_TTL_SECONDS,
  defaultHandler: {
    fetch: (request: Request, env: Env) =>
      handleAuthorizationRequest(request, env),
  },
  onError: ({ code, description, status }) => {
    console.error(
      JSON.stringify({
        code,
        description,
        event: "oauth_error",
        status,
      }),
    );
  },
  refreshTokenTTL: REFRESH_TOKEN_TTL_SECONDS,
  resourceMetadata: {
    authorization_servers: ["https://mcp.yourown.chat"],
    bearer_methods_supported: ["header"],
    resource: MCP_RESOURCE,
    resource_name: "yourown-chat MCP portal",
  },
  tokenEndpoint: "/token",
  tokenExchangeCallback: ({ clientId, grantType, userId }) => {
    console.log(
      JSON.stringify({
        client_id: clientId,
        event: "oauth_token_exchange",
        grant_type: grantType,
        user_id: userId,
      }),
    );
  },
});

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return oauthProvider.fetch(request, env, ctx);
  },
  scheduled(
    _controller: ScheduledController,
    env: Env,
    ctx: ExecutionContext,
  ): void {
    ctx.waitUntil(oauthProvider.purgeExpiredData(env, { batchSize: 100 }));
  },
};
