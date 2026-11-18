// Test thống kê nghe (lib/stats.js) — 1.3.0
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  AVG_CHARS_PER_SENTENCE, CHARS_PER_SECOND,
  isFinished, listenedCount, listenedChars,
  computeListeningStats, formatDuration,
} from "../web-src/lib/stats.js";
import { splitSentences, normalizeForSpeech } from "../src/text-engine/index.js";

const engine = { splitSentences, normalizeForSpeech };

test("isFinished: chỉ xong khi đã nghe tới câu cuối", () => {
  assert.equal(isFinished({ sentenceIndex: 99, totalSentences: 100 }), true);
  assert.equal(isFinished({ sentenceIndex: 98, totalSentences: 100 }), false);
  assert.equal(isFinished({ sentenceIndex: 0, totalSentences: 0 }), false);
  assert.equal(isFinished({}), false);
  assert.equal(isFinished(null), false);
});

test("listenedCount: chưa bấm nghe (không có lastListenedAt) thì tính 0 câu", () => {
  assert.equal(listenedCount({ sentenceIndex: 0, totalSentences: 100 }), 0);
  assert.equal(listenedCount({ sentenceIndex: 0, totalSentences: 100, lastListenedAt: 1 }), 1);
  assert.equal(listenedCount({ sentenceIndex: 49, totalSentences: 100, lastListenedAt: 1 }), 50);
  // sentenceIndex vượt tổng (bản trích cũ) thì chặn ở tổng số câu
  assert.equal(listenedCount({ sentenceIndex: 500, totalSentences: 100, lastListenedAt: 1 }), 100);
  assert.equal(listenedCount({ sentenceIndex: 5, lastListenedAt: 1 }), 0);
});

test("listenedChars: đo đúng từ bản trích qua engine thật", () => {
  const extracted = {
    chapters: [{ title: "C1", paragraphs: ["Đạo khả đạo, phi thường đạo. Danh khả danh, phi thường danh."] }],
  };
  // 2 câu: "Đạo khả đạo, phi thường đạo." + "Danh khả danh, phi thường danh."
  const expected = normalizeForSpeech("Đạo khả đạo, phi thường đạo.").length
    + normalizeForSpeech("Danh khả danh, phi thường danh.").length;
  assert.equal(listenedChars(extracted, 2, engine), expected);
  assert.equal(listenedChars(extracted, 1, engine), normalizeForSpeech("Đạo khả đạo, phi thường đạo.").length);
});

test("listenedChars: không có bản trích thì tính theo trung bình; thiếu câu thì bù trung bình", () => {
  assert.equal(listenedChars(null, 10, engine), 10 * AVG_CHARS_PER_SENTENCE);
  assert.equal(listenedChars(undefined, 3), 3 * AVG_CHARS_PER_SENTENCE);
  const extracted = { chapters: [{ title: "C1", paragraphs: ["Một câu ngắn."] }] };
  const one = normalizeForSpeech("Một câu ngắn.").length;
  assert.equal(listenedChars(extracted, 4, engine), one + 3 * AVG_CHARS_PER_SENTENCE);
  assert.equal(listenedChars({ chapters: [] }, 0, engine), 0);
});

test("computeListeningStats: tổng hợp nhiều sách, tốc độ làm đổi ước tính", () => {
  const list = [
    { bookId: "b1", sentenceIndex: 99, totalSentences: 100, lastListenedAt: 1 }, // xong
    { bookId: "b2", sentenceIndex: 9, totalSentences: 200, lastListenedAt: 2 }, // đang nghe
    { bookId: "b3", sentenceIndex: 0, totalSentences: 50 }, // mới nhập, chưa nghe
    { bookId: "b4", sentenceIndex: 5, totalSentences: 0, lastListenedAt: 3 }, // chưa có tổng -> bỏ
  ];
  const st = computeListeningStats(list, { speed: 1 });
  assert.equal(st.booksStarted, 2);
  assert.equal(st.sentencesListened, 110);
  assert.equal(st.booksFinished, 1);
  assert.equal(st.booksInProgress, 1);
  assert.equal(st.totalChars, 110 * AVG_CHARS_PER_SENTENCE);
  assert.equal(st.estimatedSeconds, (110 * AVG_CHARS_PER_SENTENCE) / CHARS_PER_SECOND);
  const fast = computeListeningStats(list, { speed: 2 });
  assert.equal(fast.estimatedSeconds, st.estimatedSeconds / 2);
});

test("computeListeningStats: có bản trích thì đo đúng độ dài câu nói", () => {
  const extracted = { chapters: [{ title: "C1", paragraphs: ["Đạo khả đạo."] }] };
  const st = computeListeningStats(
    [{ bookId: "b1", sentenceIndex: 0, totalSentences: 1, lastListenedAt: 1, extractedCache: extracted }],
    { speed: 1, engine },
  );
  assert.equal(st.totalChars, normalizeForSpeech("Đạo khả đạo.").length);
  assert.equal(st.booksFinished, 1);
});

test("computeListeningStats: danh sách rỗng thì toàn 0", () => {
  assert.deepEqual(computeListeningStats([]), {
    booksStarted: 0, sentencesListened: 0, booksFinished: 0,
    booksInProgress: 0, totalChars: 0, estimatedSeconds: 0,
  });
});

test("formatDuration: giây / phút / giờ", () => {
  assert.equal(formatDuration(0), "0 giây");
  assert.equal(formatDuration(45), "45 giây");
  assert.equal(formatDuration(59.4), "59 giây");
  assert.equal(formatDuration(60), "1 phút");
  assert.equal(formatDuration(90), "1 phút");
  assert.equal(formatDuration(45 * 60), "45 phút");
  assert.equal(formatDuration(3600), "1 giờ");
  assert.equal(formatDuration(2 * 3600 + 15 * 60), "2 giờ 15 phút");
  assert.equal(formatDuration(10 * 3600 + 59 * 60), "10 giờ 59 phút");
});
