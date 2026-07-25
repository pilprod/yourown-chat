import assert from "node:assert/strict";
import test from "node:test";

import { toolResult } from "../tool-result.mjs";

test("wraps array payloads in object-shaped structured content", () => {
  const result = toolResult([{ id: "sdr-run1" }]);

  assert.deepEqual(result.structuredContent, {
    result: [{ id: "sdr-run1" }],
  });
  assert.equal(result.content[0].type, "text");
  assert.match(result.content[0].text, /sdr-run1/);
});
