// spokenCache.test.js — Cache câu đã chuẩn hoá (1.7.0): mở sách lớn không phải
// chạy lại 7 lớp text-engine trên toàn bộ sách. Chạy: npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { cleanupText, splitSentences, prepareForSpeech } from "../src/text-engine/index.js";
import { SPOKEN_CACHE_VERSION, dictKey, buildBookSentences } from "../web-src/lib/spokenCache.js";
import { EXTRACT_VERSION } from "../web-src/lib/extract.js";

const engine = { cleanupText, splitSentences, prepareForSpeech };
const EV = EXTRACT_VERSION;

const book = {
  title: "Đạo Đức Kinh",
  author: "Lão Tử",
  chapters: [
    {
      title: "Phần 1",
      paragraphs: [
        "Ngày 8/3/1945, Lão Tử nói. Đạo khả đạo, phi thường đạo.",
        "Người học trò hỏi thầy về 10km đường dài và 1,5kg gạo mang theo.",
      ],
    },
    {
      title: "Phần 2",
      paragraphs: [
        "Tháng IX năm đó, giá lúa lên tới 44.000 đồng một tạ, tăng 12% so với năm trước.",
        "PGS.TS. Nguyễn Văn A khám cho 3 bệnh nhân, mỗi người uống 10mg thuốc mỗi ngày.",
      ],
    },
  ],
};

test("dictKey: ổn định, không phụ thuộc thứ tự key; từ điển rỗng là []", () => {
  assert.equal(dictKey({}), "[]");
  assert.equal(dictKey({ b: "2", a: "1" }), dictKey({ a: "1", b: "2" }));
  assert.notEqual(dictKey({ a: "1" }), dictKey({ a: "2" }));
});

test("lần đầu dựng đủ câu (hit=false), lần hai khôi phục từ cache (hit=true, câu giống hệt)", () => {
  const first = buildBookSentences(book, {}, null, EV, engine);
  assert.equal(first.hit, false);
  assert.equal(first.sentences.length, 5);
  assert.equal(first.sentences[0].chapterTitle, "Phần 1");
  assert.equal(first.sentences[0].chapterIndex, 0);
  assert.equal(first.sentences[4].chapterIndex, 1);
  assert.ok(first.sentences[1].paraEnd, "câu cuối đoạn phải đánh paraEnd");
  assert.ok(!first.sentences[0].paraEnd);
  assert.match(first.sentences[0].spoken, /ngày tám tháng ba/);
  assert.match(first.sentences[2].spoken, /mười ki lô mét/);

  // Đếm số lần chuẩn hoá: lần hai KHÔNG được gọi prepareForSpeech lần nào.
  let prepareCalls = 0;
  const counting = {
    ...engine,
    prepareForSpeech: (...args) => { prepareCalls++; return prepareForSpeech(...args); },
  };
  const second = buildBookSentences(book, {}, first.cache, EV, counting);
  assert.equal(second.hit, true);
  assert.equal(prepareCalls, 0);
  assert.deepEqual(second.sentences, first.sentences);
  assert.deepEqual(second.cache, first.cache);
});

test("từ điển đổi -> cache vô hiệu, dựng lại và câu theo cách đọc mới", () => {
  const first = buildBookSentences(book, {}, null, EV, engine);
  const withDict = buildBookSentences(book, { "10km": "mười cây số" }, first.cache, EV, engine);
  assert.equal(withDict.hit, false);
  assert.match(withDict.sentences[2].spoken, /mười cây số/);
  // Cache với từ điển mới thì lần sau trúng lại.
  const again = buildBookSentences(book, { "10km": "mười cây số" }, withDict.cache, EV, engine);
  assert.equal(again.hit, true);
  assert.deepEqual(again.sentences, withDict.sentences);
});

test("EXTRACT_VERSION đổi -> cache vô hiệu, dựng lại đúng câu", () => {
  const first = buildBookSentences(book, {}, null, EV, engine);
  const rebuilt = buildBookSentences(book, {}, first.cache, EV + 1, engine);
  assert.equal(rebuilt.hit, false);
  assert.deepEqual(rebuilt.sentences, first.sentences);
});

test("cache thiếu đoạn / đoạn hỏng -> chỉ đoạn đó dựng lại, câu vẫn đúng", () => {
  const first = buildBookSentences(book, {}, null, EV, engine);
  const short = { ...first.cache, paras: first.cache.paras.slice(0, 2) };
  const rebuilt = buildBookSentences(book, {}, short, EV, engine);
  assert.equal(rebuilt.hit, false);
  assert.deepEqual(rebuilt.sentences, first.sentences);

  const corrupt = JSON.parse(JSON.stringify(first.cache));
  corrupt.paras[1].s = []; // số spoken không khớp số câu gốc
  const fixed = buildBookSentences(book, {}, corrupt, EV, engine);
  assert.equal(fixed.hit, false);
  assert.deepEqual(fixed.sentences, first.sentences);
});

test("câu bị lược (spoken rỗng) được ghi vị trí và khôi phục khớp 1-1", () => {
  // Engine giả: đoạn 2 có 2 câu gốc nhưng chỉ giữ 1 (câu đầu chuẩn hoá ra rỗng).
  const stub = {
    cleanupText,
    splitSentences,
    prepareForSpeech: (text, opts) => {
      const all = prepareForSpeech(text, opts);
      if (text.includes("lược")) return { sentences: all.sentences.slice(1), chunks: [] };
      return all;
    },
  };
  const small = {
    title: "T", author: "",
    chapters: [{ title: "C1", paragraphs: ["Câu giữ lại. Câu thứ hai còn đây.", "Đoạn lược: câu đầu biến mất. Câu sau còn."] }],
  };
  // Đoạn 2: prepare thật trả 2 câu; stub cắt câu đầu -> dropped=[0] cho đoạn đó.
  const first = buildBookSentences(small, {}, null, EV, stub);
  assert.equal(first.sentences.length, 3);
  assert.equal(first.cache.paras[1].d.length, 1);
  const second = buildBookSentences(small, {}, first.cache, EV, stub);
  assert.equal(second.hit, true);
  assert.deepEqual(second.sentences, first.sentences);
});

test("sách rỗng / đoạn rỗng không vỡ", () => {
  const empty = buildBookSentences({ title: "T", author: "", chapters: [] }, {}, null, EV, engine);
  assert.deepEqual(empty.sentences, []);
  assert.equal(empty.hit, false); // chưa có cache nào
  const again = buildBookSentences({ title: "T", author: "", chapters: [] }, {}, empty.cache, EV, engine);
  assert.equal(again.hit, true);
  const blank = buildBookSentences(
    { title: "T", author: "", chapters: [{ title: "C1", paragraphs: ["", "  "] }] },
    {}, null, EV, engine,
  );
  assert.deepEqual(blank.sentences, []);
});

test("SPOKEN_CACHE_VERSION là số nguyên dương, khoá đúng EXTRACT_VERSION hiện tại", () => {
  assert.ok(Number.isInteger(SPOKEN_CACHE_VERSION) && SPOKEN_CACHE_VERSION >= 1);
  const first = buildBookSentences(book, {}, null, EV, engine);
  assert.equal(first.cache.v, SPOKEN_CACHE_VERSION);
  assert.equal(first.cache.ev, EV);
});
