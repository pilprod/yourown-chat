import assert from "node:assert/strict";
import test from "node:test";

import { resolveLegacyToolName } from "../tool-name-compat.mjs";

test("maps a cached prefixed Google Cloud tool to its current protocol name", () => {
  const names = new Set(["deploy_list_job_runs", "billing_get_profile"]);
  assert.equal(
    resolveLegacyToolName(
      "google_cloud_deploy_list_job_runs",
      "google_cloud_",
      names,
    ),
    "deploy_list_job_runs",
  );
});

test("leaves current and unknown tools unchanged", () => {
  const names = new Set(["billing_get_profile"]);
  assert.equal(
    resolveLegacyToolName("billing_get_profile", "google_cloud_", names),
    "billing_get_profile",
  );
  assert.equal(
    resolveLegacyToolName("google_cloud_list_traces", "google_cloud_", names),
    "google_cloud_list_traces",
  );
});
