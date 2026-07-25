import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { readSecretEnv } from "../secret-env.mjs";

test("rereads the mounted file instead of caching its first value", () => {
  const directory = mkdtempSync(join(tmpdir(), "mcp-secret-"));
  const file = join(directory, "token");

  try {
    writeFileSync(file, "first\n", { mode: 0o600 });
    const environment = { WHATSAPP_ACCESS_TOKEN_FILE: file };
    assert.equal(readSecretEnv("WHATSAPP_ACCESS_TOKEN", environment), "first");

    writeFileSync(file, "rotated\n", { mode: 0o600 });
    assert.equal(readSecretEnv("WHATSAPP_ACCESS_TOKEN", environment), "rotated");
  } finally {
    rmSync(directory, { recursive: true });
  }
});
