// playerLoad.test.js — Khoá hồi quy cho lỗi 1.9.0/1.9.1: player.js GỌI
// buildPlaybackItems trong load() nhưng THIẾU dòng import (lỗi sửa file song
// song ở vòng 1.8.1) -> trên máy thật mở sách chết với "Can't find variable:
// buildPlaybackItems", bản 1.9.0 không có bắt lỗi nên trông như treo máy.
// Test này nạp player.js THẬT (stub tối thiểu window/Audio/localStorage) và
// chạy load() hết đường — thiếu import là đỏ ngay.
import { test } from "node:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// player.js import "../text-engine/index.js" — thư mục đó chỉ tồn tại trong
// bản build web/ (build-web chép từ src/). Trong môi trường test, tự dựng
// một bản sao tạm cạnh web-src/lib để nạp được module thật, xong tự dọn.
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const teDest = join(root, "web-src", "text-engine");
let madeTE = false;
if (!existsSync(join(teDest, "index.js"))) {
  cpSync(join(root, "src", "text-engine"), teDest, { recursive: true });
  madeTE = true;
}
process.on("exit", () => { if (madeTE) rmSync(teDest, { recursive: true, force: true }); });

globalThis.window = globalThis;
// Node 20 trên CI chưa có global navigator (máy local Node 24 có sẵn) mà
// player.stop() có kiểm "mediaSession" in navigator — stub để khớp cả hai.
globalThis.navigator = {};
globalThis.Audio = class {
  constructor() { this.preload = ""; }
  addEventListener() {}
  pause() {}
  removeAttribute() {}
};
const mem = new Map();
globalThis.localStorage = {
  getItem: (k) => (mem.has(k) ? mem.get(k) : null),
  setItem: (k, v) => mem.set(k, String(v)),
  removeItem: (k) => mem.delete(k),
};

const { Player } = await import("../web-src/lib/player.js");
const { EXTRACT_VERSION } = await import("../web-src/lib/extract.js");
assert.equal(typeof EXTRACT_VERSION, "number");

const LONG = "Ông tặng cho hậu thế những tư tưởng bình đẳng, tự do, trọng hoà bình, theo ông không phải là trở về thời ăn lông ở lỗ, sống bằng săn bắn và hái trái cây, mà trở về buổi đầu thời đại nông nghiệp, thời bộ lạc, có tù trưởng nhưng tù trưởng cũng sống như mọi người khác, không can thiệp vào đời sống của dân.";
const extracted = {
  title: "Lão Tử - Đạo Đức Kinh",
  author: "Lão Tử",
  chapters: [
    { title: "Phần 1", paragraphs: [LONG, "Đạo khả đạo, phi thường đạo."] },
    { title: "Phần 2", paragraphs: ["Danh khả danh, phi thường danh."] },
  ],
};

test("Player.load chạy hết đường: có câu + đoạn phát + ánh xạ đoạn->câu", async () => {
  const p = new Player({});
  const n = await p.load({ id: "b1" }, extracted, {}, null);
  assert.equal(n, 3);
  assert.equal(p.sentences.length, 3);
  assert.ok(p.playItems.length > 3, "câu dài phải bị chẻ thành nhiều đoạn phát");
  assert.equal(p.itemSentence.length, p.playItems.length);
  assert.equal(p.sentenceFirstItem[0], 0);
  assert.equal(p.itemSentence[p.sentenceFirstItem[1]], 1);
  for (const it of p.playItems) assert.ok(it.t && it.t.length <= 140, `đoạn quá dài: ${it.t.length}`);
});

test("Player giữ giọng đã chọn qua localStorage (1.9.0)", async () => {
  const p = new Player({});
  p.setVoice("Ngọc Huyền");
  const p2 = new Player({});
  assert.equal(p2.voice, "Ngọc Huyền");
});
