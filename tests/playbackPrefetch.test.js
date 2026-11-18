// Test tĩnh cho sửa 1.9.3 P0-B (prefetch native sâu 5 + cache ±6 + QoS .default)
// và P0-C (không còn chữ "cần tải gói Core trước").
// Bối cảnh P0-B: NativePlayer chỉ prefetch 2 đoạn kế (QoS .utility) và trimCache
// giữ ±3 — ở tốc độ 1.25×, tổng hợp chậm biến thiên là hết đệm, đọc ngắt quãng.
// Sửa: prefetch 1...5, trimCache ±6 (khớp, không xoá đoạn vừa prefetch),
// QoS prefetch .default. Độ liền mạch thật chỉ kết luận được khi anh nghe
// trên iPhone — đây là giả thuyết kỹ thuật tốt nhất kiểm chứng được ngoài máy.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const swift = readFileSync(join(root, "plugins/sachnoi-bridge/ios/Plugin/NativePlayer.swift"), "utf8");
const html = readFileSync(join(root, "web-src/index.html"), "utf8");

test("P0-B: prefetch sâu 5 đoạn (idx+1..idx+5), không còn chỉ 2 đoạn", () => {
  assert.ok(swift.includes("for n in 1...5 { self.prefetch(next: idx + n) }"),
    "startCurrent phải prefetch 1...5");
  assert.ok(!swift.includes("self.prefetch(next: idx + 1)"),
    "vẫn còn prefetch riêng lẻ idx+1 — phải là vòng 1...5");
  assert.ok(!swift.includes("self.prefetch(next: idx + 2)"),
    "vẫn còn prefetch riêng lẻ idx+2 — phải là vòng 1...5");
});

test("P0-B: trimCache nới thành ±6 để khớp prefetch sâu 5", () => {
  const m = swift.match(/private func trimCache[\s\S]*?abs\(n - idx\) > (\d+)/);
  assert.ok(m, "không tìm thấy trimCache");
  assert.equal(Number(m[1]), 6, `trimCache phải giữ ±6, đang là ±${m[1]}`);
});

test("P0-B: prefetch chạy ở QoS .default, không còn .utility", () => {
  const start = swift.indexOf("private func prefetch(");
  assert.ok(start >= 0, "không tìm thấy prefetch");
  const body = swift.slice(start, swift.indexOf("private func trimCache", start));
  assert.ok(body.includes("qos: .default"), "prefetch phải dùng QoS .default");
  assert.ok(!body.includes("qos: .utility"), "prefetch vẫn còn QoS .utility");
});

test("1.9.4: NativePlayer không còn chẻ mệnh đề / tách nghỉ câu-phẩy khi tổng hợp", () => {
  assert.ok(!swift.includes("Self.splitClauses"), "vẫn còn gọi splitClauses — 1.9.4 phải tổng hợp cả đoạn 1 lần gọi");
  assert.ok(!swift.includes("settings.gapComma"), "vẫn còn dùng settings.gapComma trong NativePlayer");
  assert.ok(!swift.includes("settings.gapSentence"), "vẫn còn dùng settings.gapSentence trong NativePlayer");
  assert.ok(swift.includes("gapPunct"), "thiếu gapPunct trong NativePlayer");
  assert.ok(swift.includes("synthesizeSync(text: item.text"), "startCurrent phải tổng hợp cả đoạn");
  assert.ok(swift.includes("makeBufferInMemory"), "thiếu giải mã WAV trong bộ nhớ");
});

test("1.9.4: một cài đặt nghỉ dấu câu chung ở cả web + plugin", () => {
  const playerJs = readFileSync(join(root, "web-src/lib/player.js"), "utf8");
  const plugin = readFileSync(join(root, "plugins/sachnoi-bridge/ios/Plugin/SachNoiBridgePlugin.swift"), "utf8");
  assert.ok(playerJs.includes("gapPunct"), "player.js thiếu gapPunct");
  assert.ok(html.includes('id="setGapPunct"'), "sheet thiếu slider Nghỉ tại dấu câu");
  assert.ok(!html.includes('id="setGapSentence"'), "sheet vẫn còn slider Nghỉ sau câu riêng");
  assert.ok(!html.includes('id="setGapComma"'), "sheet vẫn còn slider Nghỉ sau phẩy riêng");
  assert.ok(plugin.includes('"gapPunct"'), "plugin chưa nhận gapPunct");
});

test("1.9.5: TtsServer có hồ 2 engine song song, bỏ hàng đợi serial", () => {
  const server = readFileSync(join(root, "plugins/sachnoi-bridge/ios/Plugin/TtsServer.swift"), "utf8");
  assert.ok(server.includes("acquireEngine"), "thiếu acquireEngine (hồ engine)");
  assert.ok(server.includes("idleEngines"), "thiếu idleEngines (hồ engine)");
  assert.ok(server.includes("maxEngines"), "thiếu maxEngines");
  assert.ok(!server.includes("synthQueue.sync"), "synthesizeSync vẫn serial qua synthQueue — hồ không chạy song song được");
  const engine = readFileSync(join(root, "plugins/sachnoi-bridge/ios/Plugin/VieNeuEngine.swift"), "utf8");
  assert.ok(engine.includes("outputNamesCache"), "thiếu cache outputNames trong VieNeuEngine");
  assert.ok(engine.includes("lastSynthSteps"), "thiếu đo thời gian từng pha (lastSynthSteps)");
});

test("P0-C: không còn chữ 'cần tải gói Core trước' trong web-src", () => {
  assert.ok(!html.includes("cần tải gói Core trước"), "index.html vẫn còn câu lỗi thời");
  assert.ok(html.includes("<h3>Giọng VieNeu</h3>"), "tiêu đề Giọng VieNeu phải còn");
  const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]);
  const stale = walk(join(root, "web-src"))
    .filter((p) => p.endsWith(".html") || p.endsWith(".js"))
    .filter((p) => /cần tải (gói )?Core|tải gói Core trước|tải Core trước/i.test(readFileSync(p, "utf8")));
  assert.deepEqual(stale, [], `còn câu chữ lỗi thời về tải Core trong: ${stale.join(", ")}`);
});
