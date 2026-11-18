// Test màn hình "Đang nghe" toàn màn hình (lib/nowPlaying.js) — 1.8.0
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  coverLetter, formatProgress, progressPercent,
  clampSeekIndex, nowPlayingInfo,
} from "../web-src/lib/nowPlaying.js";

test("coverLetter: chữ cái đầu, viết hoa; rỗng thì ?", () => {
  assert.equal(coverLetter("Đạo Đức Kinh"), "Đ");
  assert.equal(coverLetter("lão tử"), "L");
  assert.equal(coverLetter("  "), "?");
  assert.equal(coverLetter(null), "?");
});

test("formatProgress: câu hiện tại / tổng + tên chương", () => {
  assert.equal(formatProgress(0, 3788, "Chương 1"), "Câu 1 / 3788 · Chương 1");
  assert.equal(formatProgress(11, 100, ""), "Câu 12 / 100");
  assert.equal(formatProgress(99, 100, "Kết"), "Câu 100 / 100 · Kết");
  assert.equal(formatProgress(0, 0, ""), "Chưa có câu nào");
  assert.equal(formatProgress(-5, 100, ""), "Câu 1 / 100");
  assert.equal(formatProgress(500, 100, ""), "Câu 100 / 100");
});

test("progressPercent: 0 / giữa / 100, chặn ở 100", () => {
  assert.equal(progressPercent(0, 100), 1);
  assert.equal(progressPercent(49, 100), 50);
  assert.equal(progressPercent(99, 100), 100);
  assert.equal(progressPercent(500, 100), 100);
  assert.equal(progressPercent(0, 0), 0);
});

test("clampSeekIndex: kẹp vào 0..tổng-1, sách rỗng thì 0", () => {
  assert.equal(clampSeekIndex(5, 100), 5);
  assert.equal(clampSeekIndex(-1, 100), 0);
  assert.equal(clampSeekIndex(100, 100), 99);
  assert.equal(clampSeekIndex(0, 0), 0);
  assert.equal(clampSeekIndex(NaN, 100), 0);
  assert.equal(clampSeekIndex(3.7, 100), 3);
});

test("nowPlayingInfo: gom đủ dữ liệu hiển thị, thiếu thì mặc định", () => {
  const info = nowPlayingInfo({
    title: "Đạo Đức Kinh", author: "Lão Tử", chapterTitle: "Chương 1",
    sentence: "Đạo khả đạo, phi thường đạo.", index: 4, total: 3788,
  });
  assert.equal(info.title, "Đạo Đức Kinh");
  assert.equal(info.author, "Lão Tử");
  assert.equal(info.chapterTitle, "Chương 1");
  assert.equal(info.sentence, "Đạo khả đạo, phi thường đạo.");
  assert.equal(info.progressText, "Câu 5 / 3788 · Chương 1");
  assert.equal(info.percent, 0); // 5/3788 < 0.5% -> làm tròn 0
  assert.equal(info.seekMax, 3787);
  assert.equal(info.seekValue, 4);
  assert.equal(info.coverLetter, "Đ");

  const empty = nowPlayingInfo({ title: "", author: "", chapterTitle: "", sentence: "", index: -1, total: 0 });
  assert.equal(empty.title, "—");
  assert.equal(empty.sentence, "—");
  assert.equal(empty.progressText, "Chưa có câu nào");
  assert.equal(empty.seekMax, 0);
  assert.equal(empty.seekValue, 0);
  assert.equal(empty.coverLetter, "?");
});
