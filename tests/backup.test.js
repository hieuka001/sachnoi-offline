// Test sao lưu / khôi phục thư viện (lib/backup.js) — 1.2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildBackup, parseBackup, BACKUP_FORMAT } from "../web-src/lib/backup.js";

const sample = () => ({
  books: [
    { id: "b1", title: "Đạo Đức Kinh", format: "epub", chapters: 2 },
    { id: "b2", title: "Sách chưa mở", format: "pdf", chapters: 10 },
  ],
  progressList: [
    { bookId: "b1", extractedCache: { title: "Đạo Đức Kinh", chapters: [{ title: "C1", paragraphs: ["Đạo khả đạo."] }] }, sentenceIndex: 5, totalSentences: 100, chapterTitle: "C1", lastListenedAt: 123 },
    { bookId: "b2", sentenceIndex: 0 }, // chưa trích -> không có cache
  ],
  bookmarksByBook: { b1: [{ id: "b1:5", bookId: "b1", sentenceIndex: 5, text: "Đạo khả đạo." }] },
  dictsByBook: { b1: { "Đạo": "đạo" } },
});

test("buildBackup: chỉ gồm sách đã có bản trích, đếm sách bỏ qua", () => {
  const bk = buildBackup(sample());
  assert.equal(bk.format, BACKUP_FORMAT);
  assert.equal(bk.books.length, 1);
  assert.equal(bk.skipped, 1);
  assert.equal(bk.books[0].meta.id, "b1");
  assert.equal(bk.books[0].progress.sentenceIndex, 5);
  assert.equal(bk.books[0].bookmarks.length, 1);
  assert.equal(bk.books[0].dict["Đạo"], "đạo");
});

test("backup round-trip: build -> JSON -> parse giữ nguyên dữ liệu", () => {
  const bk = buildBackup(sample());
  const parsed = parseBackup(JSON.stringify(bk));
  assert.equal(parsed.books.length, 1);
  assert.equal(parsed.books[0].extracted.chapters[0].paragraphs[0], "Đạo khả đạo.");
  assert.equal(parsed.books[0].progress.sentenceIndex, 5);
});

test("parseBackup: từ chối file không đúng định dạng", () => {
  assert.throws(() => parseBackup("{}"), /không phải file sao lưu/);
  assert.throws(() => parseBackup("không phải json"), /JSON hợp lệ/);
  assert.throws(() => parseBackup({ format: BACKUP_FORMAT, version: 1, books: [] }), /không có cuốn sách nào/);
});

test("parseBackup: bỏ mục sách hỏng, giữ mục tốt", () => {
  const parsed = parseBackup({
    format: BACKUP_FORMAT, version: 1,
    books: [
      { meta: { id: "x" }, extracted: { chapters: [] } },
      { meta: { id: "y", title: "Tốt" }, extracted: { chapters: [{ title: "C", paragraphs: ["a"] }] } },
    ],
  });
  assert.equal(parsed.books.length, 1);
  assert.equal(parsed.books[0].meta.id, "y");
});
