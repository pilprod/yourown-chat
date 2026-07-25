import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { readSecretEnv } from "../secret-env.mjs";

test("prefers a mounted secret file over the legacy environment value", () => {
  const directory = mkdtempSync(join(tmpdir(), "mcp-secret-"));
  const file = join(directory, "token");
  writeFileSync(file, "mounted-token\n", { mode: 0o600 });

  try {
    assert.equal(
      readSecretEnv("TFE_TOKEN", {
        TFE_TOKEN: "legacy-token",
        TFE_TOKEN_FILE: file,
      }),
      "mounted-token",
    );
  } finally {
    rmSync(directory, { recursive: true });
  }
});
