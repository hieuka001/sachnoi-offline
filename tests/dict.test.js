// Test từ điển phát âm dùng chung (lib/dict.js) — 1.2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { mergeDicts } from "../web-src/lib/dict.js";

test("mergeDicts: gộp chung + riêng, riêng thắng khi trùng từ", () => {
  const merged = mergeDicts({ "Đạo": "đạo chung", "Lão Tử": "lão tử" }, { "Đạo": "đạo riêng" });
  assert.equal(merged["Đạo"], "đạo riêng");
  assert.equal(merged["Lão Tử"], "lão tử");
});

test("mergeDicts: chịu được đầu vào null/undefined", () => {
  assert.deepEqual(mergeDicts(null, null), {});
  assert.deepEqual(mergeDicts(undefined, { a: "b" }), { a: "b" });
});
