// library.test.js — Tìm kiếm + sắp xếp thư viện (1.5.0). Chạy: npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { foldLibraryText, filterBooks, sortBooks } from "../web-src/lib/library.js";

const books = [
  { id: "a", title: "Đạo Đức Kinh", author: "Lão Tử", addedAt: 100 },
  { id: "b", title: "An Nhiên", author: "Nguyễn Văn A", addedAt: 300 },
  { id: "c", title: "Bánh Mì Sài Gòn", author: "", addedAt: 200 },
];

test("foldLibraryText: gấp dấu + đ/Đ + thường hoá", () => {
  assert.equal(foldLibraryText("Đạo Đức Kinh"), "dao duc kinh");
  assert.equal(foldLibraryText("Nguyễn Văn A"), "nguyen van a");
  assert.equal(foldLibraryText(null), "");
});

test("filterBooks: từ khoá rỗng trả toàn bộ (mảng mới)", () => {
  const out = filterBooks(books, "  ");
  assert.deepEqual(out.map((b) => b.id), ["a", "b", "c"]);
  assert.notEqual(out, books);
});

test("filterBooks: tìm không dấu khớp tên có dấu", () => {
  assert.deepEqual(filterBooks(books, "dao duc").map((b) => b.id), ["a"]);
  assert.deepEqual(filterBooks(books, "DAO DUC").map((b) => b.id), ["a"]);
  assert.deepEqual(filterBooks(books, "banh mi").map((b) => b.id), ["c"]);
});

test("filterBooks: khớp cả tác giả", () => {
  assert.deepEqual(filterBooks(books, "nguyen").map((b) => b.id), ["b"]);
  assert.deepEqual(filterBooks(books, "lao tu").map((b) => b.id), ["a"]);
});

test("filterBooks: không khớp trả rỗng", () => {
  assert.deepEqual(filterBooks(books, "xyz"), []);
});

test("sortBooks: recent — mới thêm trước", () => {
  assert.deepEqual(sortBooks(books, new Map(), "recent").map((b) => b.id), ["b", "c", "a"]);
});

test("sortBooks: title — tên A–Z tiếng Việt", () => {
  assert.deepEqual(sortBooks(books, new Map(), "title").map((b) => b.id), ["b", "c", "a"]);
});

test("sortBooks: progress — nghe nhiều trước, chưa nghe cuối, hoà thì tên A–Z", () => {
  const pr = new Map([
    ["a", { sentenceIndex: 99, totalSentences: 100 }], // xong 100%
    ["b", { sentenceIndex: 9, totalSentences: 100 }], // 10%
    // c: chưa nghe
  ]);
  assert.deepEqual(sortBooks(books, pr, "progress").map((b) => b.id), ["a", "b", "c"]);
  const tie = new Map([
    ["a", { sentenceIndex: 49, totalSentences: 100 }],
    ["b", { sentenceIndex: 49, totalSentences: 100 }],
  ]);
  assert.deepEqual(sortBooks(books, tie, "progress").map((b) => b.id), ["b", "a", "c"]);
});

test("sortBooks: progressById dạng object thường cũng chạy", () => {
  const pr = { a: { sentenceIndex: 99, totalSentences: 100 } };
  assert.deepEqual(sortBooks(books, pr, "progress").map((b) => b.id), ["a", "b", "c"]);
});

test("sortBooks: không sửa mảng gốc, mode lạ thì về recent", () => {
  const before = books.map((b) => b.id);
  sortBooks(books, new Map(), "title");
  assert.deepEqual(books.map((b) => b.id), before);
  assert.deepEqual(sortBooks(books, new Map(), "???").map((b) => b.id), ["b", "c", "a"]);
});
