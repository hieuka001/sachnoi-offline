// golden.test.js — Bộ test vàng: sai 1 câu là đỏ. Chạy: npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { normalizeForSpeech } from "../src/text-engine/index.js";

const here = dirname(fileURLToPath(import.meta.url));
const golden = JSON.parse(readFileSync(join(here, "..", "text-engine", "golden-v1-starter.json"), "utf8"));

for (const c of golden.cases) {
  test(`[${c.group}] ${c.input}`, () => {
    assert.equal(normalizeForSpeech(c.input), c.expected);
  });
}
