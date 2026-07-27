import assert from "node:assert/strict";
import test from "node:test";

import { normalizeLegacyToolCall } from "../tool-name-compat.mjs";

test("maps a cached Terraform Stacks tool without exposing an alias", () => {
  const request = {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: { name: "terraform_stacks_list_deployment_runs", arguments: {} },
  };
  const normalized = normalizeLegacyToolCall(
    request,
    "terraform_stacks_",
    new Set(["list_deployment_runs"]),
  );
  assert.equal(normalized.params.name, "list_deployment_runs");
  assert.equal(request.params.name, "terraform_stacks_list_deployment_runs");
});

test("leaves current, unknown, and non-call requests unchanged", () => {
  const names = new Set(["list_deployment_runs"]);
  const current = {
    method: "tools/call",
    params: { name: "list_deployment_runs" },
  };
  const unknown = {
    method: "tools/call",
    params: { name: "terraform_stacks_unknown" },
  };
  const listing = { method: "tools/list", params: {} };
  assert.equal(
    normalizeLegacyToolCall(current, "terraform_stacks_", names),
    current,
  );
  assert.equal(
    normalizeLegacyToolCall(unknown, "terraform_stacks_", names),
    unknown,
  );
  assert.equal(
    normalizeLegacyToolCall(listing, "terraform_stacks_", names),
    listing,
  );
});
