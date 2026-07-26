export interface PortalProxyEnv {
  PORTAL_ORIGIN_URL: string;
  PORTAL_SERVICE_TOKEN_ID: string;
  PORTAL_SERVICE_TOKEN_SECRET: string;
}

const PRIVATE_REQUEST_HEADERS = [
  "authorization",
  "cookie",
  "cf-access-client-id",
  "cf-access-client-secret",
  "cf-authorization",
  "host",
];

export function createPortalRequest(
  request: Request,
  env: PortalProxyEnv,
): Request {
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

  const init: RequestInit & { duplex?: "half" } = {
    body:
      request.method === "GET" || request.method === "HEAD"
        ? undefined
        : request.body,
    headers,
    method: request.method,
    redirect: "manual",
  };
  if (init.body !== undefined) {
    // Required by Node's Fetch implementation in tests; accepted by workerd.
    init.duplex = "half";
  }

  return new Request(upstreamUrl, init);
}

export async function proxyPortalRequest(
  request: Request,
  env: PortalProxyEnv,
): Promise<Response> {
  const startedAt = Date.now();
  const response = await fetch(createPortalRequest(request, env));
  console.log(
    JSON.stringify({
      duration_ms: Date.now() - startedAt,
      event: "portal_proxy",
      method: request.method,
      status: response.status,
    }),
  );
  return response;
}
