// Test chẻ đoạn phát (lib/playbackChunks.js) — 1.8.1
// Bối cảnh: câu văn xuôi dài 250–350 ký tự khiến bộ phát phải tổng hợp toàn bộ
// câu mới phát -> chờ rất lâu. Đoạn phát phải <= ~110 ký tự, ghép lại đủ câu.
import { test } from "node:test";
import assert from "node:assert/strict";
import { chunkText, buildPlaybackItems, PLAYBACK_MAX_CHARS } from "../web-src/lib/playbackChunks.js";

const LONG = "Ông tặng cho hậu thế những tư tưởng bình đẳng, tự do, trọng hoà bình, không tranh giành nhau mà khoan dung với nhau, trở về tự nhiên, sống thanh tịnh. Trở về tự nhiên theo ông không phải là trở về thời ăn lông ở lỗ, sống bằng săn bắn và hái trái cây, mà trở về buổi đầu thời đại nông nghiệp, thời bộ lạc, có tù trưởng nhưng tù trưởng cũng sống như mọi người khác, không can thiệp vào đời sống của dân.";

test("chunkText: câu ngắn giữ nguyên 1 đoạn", () => {
  assert.deepEqual(chunkText("Đạo khả đạo, phi thường đạo."), ["Đạo khả đạo, phi thường đạo."]);
  assert.deepEqual(chunkText(""), []);
  assert.deepEqual(chunkText("   "), []);
});

test("chunkText: câu dài chẻ thành đoạn <= max+30, ghép lại đủ nội dung", () => {
  const chunks = chunkText(LONG);
  assert.ok(chunks.length >= 3, `phải chẻ >= 3 đoạn, được ${chunks.length}`);
  for (const c of chunks) assert.ok(c.length <= PLAYBACK_MAX_CHARS + 30, `đoạn quá dài: ${c.length}`);
  assert.equal(chunks.join(" "), LONG);
});

test("chunkText: không cắt ở dấu phẩy thập phân (1,5kg)", () => {
  const chunks = chunkText("Anh ấy mua 1,5kg gạo và 2,5kg thịt, mang về nhà nấu cơm cho cả gia đình ăn tối nay, xong còn đi làm về muộn nữa nên mọi người chờ rất lâu ở ngoài sân.");
  assert.ok(chunks.join(" ").includes("1,5kg"));
  assert.ok(chunks.join(" ").includes("2,5kg"));
});

test("chunkText: mệnh đề không dấu phẩy dài vẫn bị cắt tại khoảng trắng", () => {
  const s = "một câu rất dài không hề có dấu câu nào ở giữa cả mà cứ thế kéo dài mãi cho tới khi vượt quá giới hạn cho phép của một đoạn phát thì phải cắt ra tại khoảng trắng gần nhất";
  const chunks = chunkText(s);
  assert.ok(chunks.length >= 2);
  for (const c of chunks) assert.ok(c.length <= PLAYBACK_MAX_CHARS + 30);
  assert.equal(chunks.join(" "), s);
});

test("buildPlaybackItems: cờ k/p đúng, ánh xạ đoạn->câu đúng", () => {
  const sentences = [
    { spoken: "Câu ngắn.", chapterTitle: "C1", paraEnd: false },
    { spoken: LONG, chapterTitle: "C1", paraEnd: true },
    { spoken: "Câu cuối.", chapterTitle: "C2", paraEnd: true },
  ];
  const { items, itemSentence, sentenceFirstItem } = buildPlaybackItems(sentences);
  assert.equal(sentenceFirstItem[0], 0);
  assert.equal(items[0].k, 0);
  assert.equal(items[0].p, false);
  const start1 = sentenceFirstItem[1];
  assert.ok(start1 >= 1);
  const longItems = items.slice(start1, sentenceFirstItem[2]);
  assert.ok(longItems.length >= 3);
  longItems.forEach((it, i) => {
    assert.equal(it.k, i < longItems.length - 1 ? 1 : 0, `k sai ở đoạn ${i}`);
    assert.equal(it.p, i === longItems.length - 1, `p chỉ ở đoạn cuối (đoạn ${i})`);
    assert.equal(it.c, "C1");
  });
  assert.equal(itemSentence[start1], 1);
  assert.equal(itemSentence[items.length - 1], 2);
  assert.ok(items.map((i) => i.t).join(" ").includes("Câu ngắn."));
});

test("buildPlaybackItems: câu spoken rỗng không sinh item (tránh lệch chỉ số native)", () => {
  const { items, sentenceFirstItem } = buildPlaybackItems([
    { spoken: "", chapterTitle: "C1", paraEnd: false },
    { spoken: "Có chữ.", chapterTitle: "C1", paraEnd: true },
  ]);
  assert.equal(items.length, 1);
  assert.equal(sentenceFirstItem[1], 0);
});
