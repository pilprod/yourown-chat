import { GoogleAuth } from "google-auth-library";

const BILLING_API_ROOT = "https://cloudbilling.googleapis.com/v1";
const BUDGET_API_ROOT = "https://billingbudgets.googleapis.com/v1";
const BIGQUERY_API_ROOT = "https://bigquery.googleapis.com/bigquery/v2";
const RECOMMENDER_API_ROOT = "https://recommender.googleapis.com/v1";
const PROJECT = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;
const TABLE =
  /^[a-z][a-z0-9-]{4,28}[a-z0-9]\.[A-Za-z_][A-Za-z0-9_]{0,1023}\.[A-Za-z_][A-Za-z0-9_*$-]{0,1023}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const DEFAULT_MAXIMUM_BYTES_BILLED = 1_000_000_000;
const DEFAULT_RECOMMENDERS = [
  "google.compute.instance.IdleResourceRecommender",
  "google.compute.instance.MachineTypeRecommender",
  "google.compute.disk.IdleResourceRecommender",
  "google.compute.address.IdleResourceRecommender",
  "google.compute.image.IdleResourceRecommender",
  "google.compute.commitment.UsageCommitmentRecommender",
  "google.cloudsql.instance.IdleRecommender",
  "google.cloudsql.instance.OverprovisionedRecommender",
  "google.container.DiagnosisRecommender",
  "google.run.service.CostRecommender",
  "google.storage.bucket.SoftDeleteRecommender",
  "google.bigquery.table.PartitionClusterRecommender",
];

function requiredEnv(env, name, fallback) {
  const value = env[name]?.trim() || fallback?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function parseCsv(value, fallback) {
  const parsed = (value ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  return parsed.length > 0 ? parsed : fallback;
}

function validateDate(value, name) {
  if (!DATE.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) {
    throw new Error(`${name} must be an ISO date (YYYY-MM-DD)`);
  }
}

function valueFromCell(cell) {
  if (cell?.v === null || cell?.v === undefined) return null;
  if (Array.isArray(cell.v)) return cell.v.map(valueFromCell);
  if (typeof cell.v === "object" && Array.isArray(cell.v.f)) {
    return cell.v.f.map(valueFromCell);
  }
  return cell.v;
}

function rowsFromQuery(payload) {
  const fields = payload.schema?.fields ?? [];
  return (payload.rows ?? []).map((row) =>
    Object.fromEntries(
      fields.map((field, index) => [field.name, valueFromCell(row.f[index])]),
    ),
  );
}

function recommendationSummary(recommendation) {
  const cost = recommendation.primaryImpact?.costProjection;
  return {
    name: recommendation.name,
    description: recommendation.description,
    subtype: recommendation.recommenderSubtype,
    priority: recommendation.priority,
    state: recommendation.stateInfo?.state,
    last_refresh_time: recommendation.lastRefreshTime,
    cost_projection: cost
      ? {
          cost: cost.cost,
          duration: cost.duration,
          cost_in_local_currency: cost.costInLocalCurrency,
        }
      : null,
    primary_impact: recommendation.primaryImpact,
    additional_impacts: recommendation.additionalImpact ?? [],
    resources: recommendation.content?.operationGroups ?? [],
    associated_insights: recommendation.associatedInsights ?? [],
    etag: recommendation.etag,
  };
}

export class BillingCostClient {
  constructor({
    project,
    exportTable,
    exportLocation = "EU",
    maximumBytesBilled = DEFAULT_MAXIMUM_BYTES_BILLED,
    recommenderLocations = ["global"],
    recommenderIds = DEFAULT_RECOMMENDERS,
    auth = new GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/cloud-platform"],
    }),
    fetchImpl = fetch,
  }) {
    if (!PROJECT.test(project)) throw new Error("Invalid Google Cloud project");
    if (exportTable && !TABLE.test(exportTable)) {
      throw new Error(
        "GOOGLE_CLOUD_BILLING_EXPORT_TABLE must be project.dataset.table",
      );
    }
    this.project = project;
    this.exportTable = exportTable;
    this.exportLocation = exportLocation;
    this.maximumBytesBilled = Math.max(
      10_000_000,
      Number(maximumBytesBilled) || DEFAULT_MAXIMUM_BYTES_BILLED,
    );
    this.recommenderLocations = recommenderLocations;
    this.recommenderIds = recommenderIds;
    this.auth = auth;
    this.fetchImpl = fetchImpl;
  }

  async request(root, path, { method = "GET", query, body } = {}) {
    const url = new URL(`${root}/${path}`);
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
    const authClient = await this.auth.getClient();
    const authHeaders = await authClient.getRequestHeaders(url.toString());
    const response = await this.fetchImpl(url, {
      method,
      headers: {
        ...Object.fromEntries(authHeaders),
        accept: "application/json",
        ...(body ? { "content-type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await response.text();
    const payload = text ? JSON.parse(text) : {};
    if (!response.ok) {
      throw new Error(
        `Google API ${method} ${url.pathname} failed (${response.status}): ${
          payload.error?.message ?? text
        }`,
      );
    }
    return payload;
  }

  async getBillingProfile() {
    const projectBilling = await this.request(
      BILLING_API_ROOT,
      `projects/${this.project}/billingInfo`,
    );
    const billingAccount = projectBilling.billingAccountName
      ? await this.request(BILLING_API_ROOT, projectBilling.billingAccountName)
      : null;
    return {
      project: this.project,
      billing_enabled: projectBilling.billingEnabled ?? false,
      billing_account: billingAccount,
      detailed_export: {
        configured: Boolean(this.exportTable),
        table: this.exportTable,
        location: this.exportLocation,
        maximum_bytes_billed: this.maximumBytesBilled,
      },
    };
  }

  async listBudgets({ pageSize = 100, pageToken, projectOnly = false } = {}) {
    const profile = await this.getBillingProfile();
    if (!profile.billing_account?.name) {
      return { ...profile, budgets: [], next_page_token: null };
    }
    const payload = await this.request(
      BUDGET_API_ROOT,
      `${profile.billing_account.name}/budgets`,
      {
        query: {
          pageSize: Math.min(Math.max(pageSize, 1), 100),
          pageToken,
          scope: projectOnly ? `projects/${this.project}` : undefined,
        },
      },
    );
    return {
      billing_account: profile.billing_account,
      budgets: payload.budgets ?? [],
      next_page_token: payload.nextPageToken,
    };
  }

  requireExportTable() {
    if (!this.exportTable) {
      throw new Error(
        "Detailed billing analysis is not configured. Enable Cloud Billing Detailed usage cost export and set GOOGLE_CLOUD_BILLING_EXPORT_TABLE to its project.dataset.table.",
      );
    }
  }

  async queryCosts({
    startDate,
    endDate,
    groupBy = "service",
    limit = 50,
  }) {
    this.requireExportTable();
    validateDate(startDate, "start_date");
    validateDate(endDate, "end_date");
    if (startDate >= endDate) throw new Error("start_date must precede end_date");
    const dimensions = {
      day: ["DATE(usage_start_time)", "day"],
      service: ["service.description", "service"],
      sku: ["CONCAT(service.description, ' / ', sku.description)", "sku"],
      project: ["COALESCE(project.id, '(no project)')", "project"],
      location: [
        "COALESCE(location.location, location.region, location.zone, '(global)')",
        "location",
      ],
      resource: [
        "COALESCE(resource.global_name, resource.name, '(unattributed)')",
        "resource",
      ],
      invoice_month: ["invoice.month", "invoice_month"],
      cost_type: ["cost_type", "cost_type"],
    };
    const dimension = dimensions[groupBy];
    if (!dimension) throw new Error(`Unsupported group_by: ${groupBy}`);
    const boundedLimit = Math.min(Math.max(limit, 1), 200);
    const query = `
      SELECT
        ${dimension[0]} AS dimension,
        ANY_VALUE(currency) AS currency,
        ROUND(SUM(cost), 6) AS gross_cost,
        ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 6) AS credits,
        ROUND(SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 6) AS net_cost,
        ROUND(SUM(IFNULL(cost_at_list, cost)), 6) AS list_cost,
        ROUND(SUM(IFNULL(cost_at_effective_price_default, cost)), 6) AS default_effective_cost,
        COUNT(*) AS line_items,
        MIN(usage_start_time) AS first_usage,
        MAX(usage_end_time) AS last_usage
      FROM \`${this.exportTable}\`
      WHERE usage_start_time >= TIMESTAMP(@start_date)
        AND usage_start_time < TIMESTAMP(@end_date)
      GROUP BY dimension
      ORDER BY net_cost DESC
      LIMIT ${boundedLimit}`;
    const payload = await this.request(
      BIGQUERY_API_ROOT,
      `projects/${this.project}/queries`,
      {
        method: "POST",
        body: {
          query,
          useLegacySql: false,
          location: this.exportLocation,
          maxResults: boundedLimit,
          timeoutMs: 30_000,
          jobTimeoutMs: "30000",
          maximumBytesBilled: String(this.maximumBytesBilled),
          parameterMode: "NAMED",
          queryParameters: [
            {
              name: "start_date",
              parameterType: { type: "DATE" },
              parameterValue: { value: startDate },
            },
            {
              name: "end_date",
              parameterType: { type: "DATE" },
              parameterValue: { value: endDate },
            },
          ],
          labels: { workload: "mcp_billing_analysis" },
        },
      },
    );
    if (!payload.jobComplete) {
      throw new Error(
        "Billing query exceeded the 30 second MCP budget; narrow the date range",
      );
    }
    return {
      range: { start_date: startDate, end_date: endDate },
      group_by: groupBy,
      rows: rowsFromQuery(payload),
      query_stats: {
        cache_hit: payload.cacheHit,
        total_rows: payload.totalRows,
        total_bytes_processed: payload.totalBytesProcessed,
        total_bytes_billed: payload.totalBytesBilled,
        total_slot_ms: payload.totalSlotMs,
      },
    };
  }

  async listRecommendations({
    state = "ACTIVE",
    pageSize = 100,
    includeRaw = false,
  } = {}) {
    const results = [];
    const errors = [];
    const boundedPageSize = Math.min(Math.max(pageSize, 1), 100);
    for (const location of this.recommenderLocations) {
      for (const recommenderId of this.recommenderIds) {
        try {
          const parent =
            `projects/${this.project}/locations/${location}/recommenders/` +
            encodeURIComponent(recommenderId);
          const payload = await this.request(
            RECOMMENDER_API_ROOT,
            `${parent}/recommendations`,
            {
              query: {
                pageSize: boundedPageSize,
                filter: state ? `stateInfo.state=${state}` : undefined,
              },
            },
          );
          for (const recommendation of payload.recommendations ?? []) {
            results.push(
              includeRaw
                ? recommendation
                : {
                    recommender: recommenderId,
                    location,
                    ...recommendationSummary(recommendation),
                  },
            );
          }
        } catch (error) {
          errors.push({
            recommender: recommenderId,
            location,
            error: error.message,
          });
        }
      }
    }
    return {
      project: this.project,
      recommendations: results,
      checked_recommenders: this.recommenderIds,
      checked_locations: this.recommenderLocations,
      partial_errors: errors,
    };
  }
}

export function billingCostClientFromEnv(env = process.env, options = {}) {
  return new BillingCostClient({
    project: requiredEnv(
      env,
      "GOOGLE_CLOUD_BILLING_PROJECT",
      env.GOOGLE_CLOUD_PROJECT ?? env.GOOGLE_CLOUD_DEPLOY_PROJECT,
    ),
    exportTable: env.GOOGLE_CLOUD_BILLING_EXPORT_TABLE?.trim(),
    exportLocation:
      env.GOOGLE_CLOUD_BILLING_EXPORT_LOCATION?.trim() || "EU",
    maximumBytesBilled:
      env.GOOGLE_CLOUD_BILLING_MAXIMUM_BYTES_BILLED ??
      DEFAULT_MAXIMUM_BYTES_BILLED,
    recommenderLocations: parseCsv(
      env.GOOGLE_CLOUD_RECOMMENDER_LOCATIONS,
      ["global"],
    ),
    recommenderIds: parseCsv(
      env.GOOGLE_CLOUD_COST_RECOMMENDERS,
      DEFAULT_RECOMMENDERS,
    ),
    ...options,
  });
}
