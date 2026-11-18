// spokenCacheAsync.test.js — Bản dựng câu BẤT ĐỒNG BỘ (1.9.1) phải cho kết
// quả y hệt bản đồng bộ, chỉ khác là nhường UI + báo tiến độ. Bối cảnh: dựng
// đồng bộ toàn sách trên máy thật đóng băng màn hình mở sách rất lâu.
import { test } from "node:test";
import assert from "node:assert/strict";
import { cleanupText, splitSentences, prepareForSpeech } from "../src/text-engine/index.js";
import { buildBookSentences, buildBookSentencesAsync } from "../web-src/lib/spokenCache.js";
import { EXTRACT_VERSION } from "../web-src/lib/extract.js";

const engine = { cleanupText, splitSentences, prepareForSpeech };
const EV = EXTRACT_VERSION;

const para = "Ngày 8/3/1945, Lão Tử nói về đạo. Người học trò hỏi thầy về 10km đường dài và 1,5kg gạo mang theo, giá lúa lên tới 44.000 đồng một tạ.";
const book = {
  title: "Sách lớn",
  author: "X",
  chapters: Array.from({ length: 6 }, (_, c) => ({
    title: `Phần ${c + 1}`,
    paragraphs: Array.from({ length: 60 }, () => para),
  })),
};

test("async (cache trượt) == sync: cùng câu, cùng cache, hit=false", async () => {
  const sync = buildBookSentences(book, {}, null, EV, engine);
  const asyncR = await buildBookSentencesAsync(book, {}, null, EV, engine);
  assert.equal(asyncR.hit, false);
  assert.deepEqual(asyncR.sentences, sync.sentences);
  assert.deepEqual(asyncR.cache, sync.cache);
});

test("async (cache trúng) == sync: hit=true, không chạy lại chuẩn hoá", async () => {
  const first = buildBookSentences(book, {}, null, EV, engine);
  const sync = buildBookSentences(book, {}, first.cache, EV, engine);
  const asyncR = await buildBookSentencesAsync(book, {}, first.cache, EV, engine);
  assert.equal(asyncR.hit, true);
  assert.deepEqual(asyncR.sentences, sync.sentences);
});

test("async báo tiến độ tăng dần và kết thúc ở 100", async () => {
  const seen = [];
  await buildBookSentencesAsync(book, {}, null, EV, engine, (pct) => seen.push(pct));
  assert.ok(seen.length >= 1, "phải có ít nhất 1 lần báo tiến độ");
  assert.equal(seen[seen.length - 1], 100);
  for (let i = 1; i < seen.length; i++) assert.ok(seen[i] >= seen[i - 1], "tiến độ không được giảm");
  for (const p of seen) assert.ok(p >= 0 && p <= 100);
});
