// Test tĩnh cho sửa 1.9.3 P0-B (prefetch native sâu 5 + cache ±6 + QoS .default)
// và P0-C (không còn chữ "cần tải gói Core trước").
// Bối cảnh P0-B: NativePlayer chỉ prefetch 2 đoạn kế (QoS .utility) và trimCache
// giữ ±3 — ở tốc độ 1.25×, tổng hợp chậm biến thiên là hết đệm, đọc ngắt quãng.
// Sửa: prefetch 1...5, trimCache ±6 (khớp, không xoá đoạn vừa prefetch),
// QoS prefetch .default. Độ liền mạch thật chỉ kết luận được khi anh nghe
// trên iPhone — đây là giả thuyết kỹ thuật tốt nhất kiểm chứng được ngoài máy.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync } from "node:fs";
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

test("2.1.0: thuần VieNeu — Nano (mượt) + Turbo (25 giọng), sherpa/Piper đã gỡ", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const server = readFileSync(join(pluginDir, "TtsServer.swift"), "utf8");
  assert.ok(server.includes("NanoEngine"), "TtsServer chưa định tuyến engine Nano");
  assert.ok(server.includes("VieNeuEngine"), "TtsServer thiếu hồ engine Turbo");
  assert.ok(server.includes("nano/"), "TtsServer thiếu tiền tố định tuyến nano/");
  assert.ok(!server.includes("NWListener"), "TtsServer vẫn còn server HTTP thừa");
  assert.ok(!server.includes("SherpaTts"), "TtsServer vẫn còn sherpa/Piper (2.1.0 thuần VieNeu)");
  const nano = readFileSync(join(pluginDir, "NanoEngine.swift"), "utf8");
  assert.ok(nano.includes("vector_estimator.onnx"), "NanoEngine thiếu graph vector_estimator");
  assert.ok(nano.includes("duration_predictor.onnx"), "NanoEngine thiếu duration_predictor");
  assert.ok(nano.includes("codec_decoder.onnx"), "NanoEngine thiếu codec_decoder");
  assert.ok(nano.includes("phonemizeWithEmotions"), "NanoEngine phải dùng chung Phonemizer với Turbo");
  assert.ok(nano.includes("trimAndFade"), "NanoEngine thiếu trim_and_fade như bản tham chiếu");
  for (const back of ["VieNeuEngine.swift", "Phonemizer.swift", "SpeechUtils.swift", "SeaG2p.swift", "BpeTokenizer.swift"]) {
    assert.ok(existsSync(join(pluginDir, back)), `${back} phải được khôi phục cho Turbo`);
  }
  assert.ok(!existsSync(join(pluginDir, "SherpaTts.swift")), "SherpaTts.swift phải đã xoá");
  const podspec = readFileSync(join(root, "plugins/sachnoi-bridge/SachnoiBridge.podspec"), "utf8");
  assert.ok(podspec.includes("dependency 'onnxruntime-objc'"), "podspec thiếu onnxruntime-objc");
  assert.ok(podspec.includes("libsea_g2p_rs.a"), "podspec thiếu libsea_g2p_rs.a");
  assert.ok(!podspec.includes("SherpaOnnxC"), "podspec vẫn còn sherpa");
  const manifest = JSON.parse(readFileSync(join(root, "voices/voices.json"), "utf8"));
  assert.equal(manifest.voices.length, 36, "manifest phải có 36 giọng (11 Nano + 25 Turbo)");
  assert.equal(manifest.voices.filter((v) => v.id.startsWith("nano/")).length, 11, "thiếu giọng Nano trong manifest");
});

test("2.1.1: ctx_mask đi đường uint8 (graph vá vieneu-nano-v2) — cấm quay lại tensor bool", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const nano = readFileSync(join(pluginDir, "NanoEngine.swift"), "utf8");
  // onnxruntime-objc 1.20.0 không tạo được tensor bool: bản 2.1.0 ép
  // rawValue 9 -> máy thật văng 'unsupported tensor element type'.
  assert.ok(nano.includes("uint8Tensor"), "NanoEngine phải tạo ctx_mask bằng uint8Tensor");
  assert.ok(nano.includes("elementType: .uInt8"), "uint8Tensor phải dùng elementType .uInt8 (case Swift của ORTTensorElementDataTypeUInt8, rawValue 3)");
  assert.ok(!nano.includes("elementType: .uint8"), "NanoEngine còn .uint8 — case này không tồn tại trong onnxruntime-objc 1.20.0");
  assert.ok(!nano.includes("boolTensor"), "NanoEngine còn boolTensor (đường bool đã chết trên iOS)");
  assert.ok(!nano.includes("ORTTensorElementDataType(rawValue: 9)"), "NanoEngine còn ép rawValue 9 cho tensor bool");
  const manifest = JSON.parse(readFileSync(join(root, "voices/voices.json"), "utf8"));
  const nanoPack = manifest.packs.find((p) => p.id === "vieneu-nano");
  assert.ok(nanoPack, "thiếu pack vieneu-nano trong manifest");
  for (const f of nanoPack.files) {
    assert.ok(f.url.includes("/vieneu-nano-v2/"), `file Nano ${f.name} chưa trỏ release v2 (graph đã vá ctx_mask)`);
  }
  const dur = nanoPack.files.find((f) => f.name === "duration_predictor.onnx");
  assert.equal(dur.sha256, "fa9ddef2db0d182826ce469adfc80694a2eeb71b501632cb4424cc6928889602", "duration_predictor phải là bản vá v2");
  const ve = nanoPack.files.find((f) => f.name === "vector_estimator.onnx");
  assert.equal(ve.sha256, "3c80e1245678aaae4121ffdd4246b6f73ab288b75b8c7e0cab9c331237418a38", "vector_estimator phải là bản vá v2");
});

test("P0-C: không còn chữ 'cần tải gói Core trước' trong web-src", () => {
  assert.ok(!html.includes("cần tải gói Core trước"), "index.html vẫn còn câu lỗi thời");
  assert.ok(html.includes("<h3>Giọng đọc</h3>"), "tiêu đề tab Giọng phải là 'Giọng đọc'");
  const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]);
  const stale = walk(join(root, "web-src"))
    .filter((p) => p.endsWith(".html") || p.endsWith(".js"))
    .filter((p) => /cần tải (gói )?Core|tải gói Core trước|tải Core trước/i.test(readFileSync(p, "utf8")));
  assert.deepEqual(stale, [], `còn câu chữ lỗi thời về tải Core trong: ${stale.join(", ")}`);
});
