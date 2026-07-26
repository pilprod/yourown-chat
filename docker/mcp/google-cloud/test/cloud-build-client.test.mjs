import assert from "node:assert/strict";
import test from "node:test";

import {
  CloudBuildClient,
  cloudBuildClientFromEnv,
} from "../cloud-build-client.mjs";

const auth = {
  async getClient() {
    return {
      async getRequestHeaders() {
        return new Headers({ authorization: "Bearer test" });
      },
    };
  },
};

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function sequenceFetch(responses, calls = []) {
  return async (url, options) => {
    calls.push({
      url: url.toString(),
      method: options.method,
      body: options.body ? JSON.parse(options.body) : undefined,
    });
    const next = responses.shift();
    if (!next) throw new Error(`Unexpected request: ${url}`);
    return jsonResponse(next.body, next.status ?? 200);
  };
}

test("configuration can inherit the constrained deploy project and location", () => {
  const client = cloudBuildClientFromEnv({
    GOOGLE_CLOUD_DEPLOY_PROJECT: "yourown-chat",
    GOOGLE_CLOUD_DEPLOY_LOCATION: "europe-west3",
  });
  assert.equal(client.project, "yourown-chat");
  assert.equal(client.location, "europe-west3");
});

test("lists regional builds newest first with step and substitution detail", async () => {
  const calls = [];
  const client = new CloudBuildClient({
    project: "yourown-chat",
    location: "europe-west3",
    auth,
    fetchImpl: sequenceFetch(
      [
        {
          body: {
            builds: [
              {
                id: "older",
                createTime: "2026-07-25T00:00:00Z",
                substitutions: { TAG_NAME: "0.0.16" },
              },
              {
                id: "newer",
                createTime: "2026-07-26T00:00:00Z",
                steps: [{ id: "release", status: "SUCCESS" }],
              },
            ],
          },
        },
      ],
      calls,
    ),
  });
  const result = await client.listBuilds({ pageSize: 10 });
  assert.deepEqual(
    result.builds.map((build) => build.id),
    ["newer", "older"],
  );
  assert.equal(result.builds[0].steps[0].id, "release");
  assert.match(calls[0].url, /locations\/europe-west3\/builds/);
});

test("inspect rejects malformed IDs before issuing an API request", async () => {
  const client = new CloudBuildClient({
    project: "yourown-chat",
    location: "europe-west3",
    auth,
    fetchImpl: sequenceFetch([]),
  });
  await assert.rejects(
    client.inspectBuild({ buildId: "../../other" }),
    /Invalid build ID/,
  );
});

test("build logs use a build-scoped Logging filter and ordered pagination", async () => {
  const calls = [];
  const client = new CloudBuildClient({
    project: "yourown-chat",
    location: "europe-west3",
    auth,
    fetchImpl: sequenceFetch(
      [
        {
          body: {
            entries: [
              {
                timestamp: "2026-07-26T00:00:00Z",
                severity: "INFO",
                textPayload: "route complete",
              },
            ],
            nextPageToken: "next",
          },
        },
      ],
      calls,
    ),
  });
  const result = await client.listBuildLogs({
    buildId: "927b1399-7b27-467e-92e4-33052b057753",
    pageSize: 25,
  });
  assert.equal(result.entries[0].text, "route complete");
  assert.equal(result.next_page_token, "next");
  assert.equal(calls[0].method, "POST");
  assert.match(calls[0].url, /logging\.googleapis\.com\/v2\/entries:list/);
  assert.match(
    calls[0].body.filter,
    /resource\.labels\.build_id="927b1399-7b27-467e-92e4-33052b057753"/,
  );
  assert.equal(calls[0].body.orderBy, "timestamp asc");
});
