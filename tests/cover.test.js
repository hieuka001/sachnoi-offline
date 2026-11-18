// Test tìm ảnh bìa EPUB (lib/extract.js findCoverHref) — 1.2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { findCoverHref } from "../web-src/lib/extract.js";

test("findCoverHref: ưu tiên item gắn cờ cover-image (EPUB3)", () => {
  const manifest = { c1: "images/cover.jpg", t1: "text/c1.xhtml" };
  const props = { c1: "cover-image", t1: "" };
  assert.equal(findCoverHref(manifest, props, null), "images/cover.jpg");
});

test("findCoverHref: dùng meta cover id (EPUB2) khi không có cờ", () => {
  const manifest = { bia: "bia.png", t1: "c1.xhtml" };
  assert.equal(findCoverHref(manifest, { bia: "" }, "bia"), "bia.png");
});

test("findCoverHref: không có bìa thì null", () => {
  assert.equal(findCoverHref({ t1: "c1.xhtml" }, { t1: "" }, null), null);
  assert.equal(findCoverHref({}, {}, "khong-co"), null);
});
