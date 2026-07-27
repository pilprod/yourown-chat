import assert from "node:assert/strict";
import test from "node:test";

import { BillingCostClient } from "../billing-cost-client.mjs";

const auth = {
  async getClient() {
    return {
      async getRequestHeaders() {
        return new Headers({ authorization: "Bearer test" });
      },
    };
  },
};

function response(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}

test("gets billing profile and budgets from the linked account", async () => {
  const requests = [];
  const client = new BillingCostClient({
    project: "yourown-chat",
    exportTable: "yourown-chat.billing.gcp_billing_export_resource_v1_TEST",
    auth,
    fetchImpl: async (url) => {
      requests.push(String(url));
      if (String(url).endsWith("/projects/yourown-chat/billingInfo")) {
        return response({
          projectId: "yourown-chat",
          billingAccountName: "billingAccounts/ABC-DEF",
          billingEnabled: true,
        });
      }
      if (String(url).endsWith("/billingAccounts/ABC-DEF")) {
        return response({
          name: "billingAccounts/ABC-DEF",
          displayName: "Primary",
          open: true,
        });
      }
      return response({
        budgets: [{ name: "billingAccounts/ABC-DEF/budgets/one" }],
      });
    },
  });

  const result = await client.listBudgets({ projectOnly: true });
  assert.equal(result.billing_account.displayName, "Primary");
  assert.equal(result.budgets.length, 1);
  assert.match(requests.at(-1), /scope=projects%2Fyourown-chat/);
});

test("runs a parameterized, byte-bounded aggregate billing query", async () => {
  let body;
  const client = new BillingCostClient({
    project: "yourown-chat",
    exportTable: "yourown-chat.billing.gcp_billing_export_resource_v1_TEST",
    maximumBytesBilled: 123_000_000,
    auth,
    fetchImpl: async (_url, options) => {
      body = JSON.parse(options.body);
      return response({
        jobComplete: true,
        cacheHit: false,
        totalRows: "1",
        totalBytesProcessed: "2048",
        totalBytesBilled: "10000000",
        schema: {
          fields: [
            { name: "dimension" },
            { name: "currency" },
            { name: "net_cost" },
          ],
        },
        rows: [{ f: [{ v: "Compute Engine" }, { v: "USD" }, { v: "2.5" }] }],
      });
    },
  });

  const result = await client.queryCosts({
    startDate: "2026-07-01",
    endDate: "2026-08-01",
    groupBy: "service",
    limit: 10,
  });
  assert.equal(body.maximumBytesBilled, "123000000");
  assert.equal(body.useLegacySql, false);
  assert.match(body.query, /TIMESTAMP\(@start_date\)/);
  assert.equal(body.queryParameters[0].parameterValue.value, "2026-07-01");
  assert.deepEqual(result.rows[0], {
    dimension: "Compute Engine",
    currency: "USD",
    net_cost: "2.5",
  });
});

test("reports partial recommender failures without dropping good results", async () => {
  const client = new BillingCostClient({
    project: "yourown-chat",
    recommenderIds: ["good.Recommender", "missing.Recommender"],
    recommenderLocations: ["global"],
    auth,
    fetchImpl: async (url) => {
      if (String(url).includes("missing.Recommender")) {
        return response({ error: { message: "not enabled" } }, 403);
      }
      return response({
        recommendations: [
          {
            name: "projects/yourown-chat/recommendations/one",
            description: "Stop idle VM",
            priority: "P2",
            stateInfo: { state: "ACTIVE" },
            primaryImpact: {
              category: "COST",
              costProjection: { cost: { currencyCode: "USD", units: "-12" } },
            },
          },
        ],
      });
    },
  });

  const result = await client.listRecommendations();
  assert.equal(result.recommendations.length, 1);
  assert.equal(result.partial_errors.length, 1);
});

test("requires an explicitly allowlisted billing export table", async () => {
  const client = new BillingCostClient({
    project: "yourown-chat",
    auth,
    fetchImpl: async () => {
      throw new Error("must not call");
    },
  });
  await assert.rejects(
    () =>
      client.queryCosts({
        startDate: "2026-07-01",
        endDate: "2026-08-01",
      }),
    /Detailed billing analysis is not configured/,
  );
});
