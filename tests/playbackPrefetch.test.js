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

test("3.0.0: bỏ toàn bộ VieNeu — engine duy nhất là giọng hệ thống iOS", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const server = readFileSync(join(pluginDir, "TtsServer.swift"), "utf8");
  assert.ok(server.includes("AVSpeechSynthesizer"), "TtsServer phải dùng AVSpeechSynthesizer (giọng hệ thống)");
  assert.ok(server.includes("synthesizer.write"), "TtsServer phải render qua AVSpeechSynthesizer.write");
  assert.ok(server.includes("vietnameseVoices"), "TtsServer thiếu liệt kê giọng tiếng Việt hệ thống");
  assert.ok(server.includes("resolveSystemVoice"), "TtsServer thiếu resolveSystemVoice (id lạ -> giọng hệ thống)");
  for (const gone of ["VieNeuEngine.swift", "NanoEngine.swift", "Phonemizer.swift", "SpeechUtils.swift", "BpeTokenizer.swift", "SeaG2p.swift", "SherpaTts.swift"]) {
    assert.ok(!existsSync(join(pluginDir, gone)), `${gone} phải đã xoá ở 3.0.0`);
  }
  assert.ok(!server.includes("VieNeuEngine"), "TtsServer vẫn còn VieNeuEngine");
  assert.ok(!server.includes("NWListener"), "TtsServer vẫn còn server HTTP thừa");
  const packStore = readFileSync(join(pluginDir, "PackStore.swift"), "utf8");
  assert.ok(!packStore.includes("vieneuAssetsURL"), "PackStore vẫn còn vieneuAssetsURL");
  assert.ok(!packStore.includes("nanoAssetsURL"), "PackStore vẫn còn nanoAssetsURL");
  const plugin = readFileSync(join(pluginDir, "SachNoiBridgePlugin.swift"), "utf8");
  assert.ok(plugin.includes("systemVoices"), "plugin ttsVoices phải trả giọng hệ thống");
  assert.ok(!plugin.includes("getVoiceStore"), "plugin vẫn còn getVoiceStore của VieNeu");
  const podspec = readFileSync(join(root, "plugins/sachnoi-bridge/SachnoiBridge.podspec"), "utf8");
  assert.ok(!podspec.includes("onnxruntime"), "podspec vẫn còn onnxruntime-objc");
  assert.ok(!podspec.includes("sea_g2p"), "podspec vẫn còn libsea_g2p_rs");
  assert.ok(!podspec.includes("SherpaOnnxC"), "podspec vẫn còn sherpa");
  const pbx = readFileSync(join(root, "ios/App/App.xcodeproj/project.pbxproj"), "utf8");
  assert.ok(!pbx.includes("TTSAssets"), "pbxproj vẫn còn TTSAssets");
  assert.ok(!pbx.includes("NanoAssets"), "pbxproj vẫn còn NanoAssets");
});

test("3.0.0: manifest chỉ còn giọng hệ thống, không gói model", () => {
  const manifest = JSON.parse(readFileSync(join(root, "voices/voices.json"), "utf8"));
  assert.equal(manifest.voices.length, 1, "manifest phải có đúng 1 giọng hệ thống");
  assert.equal(manifest.voices[0].engine, "system", "giọng duy nhất phải là engine system");
  assert.equal(manifest.packs.length, 0, "manifest không được còn gói model nào");
});

test("2.2.0/3.0.0: render trước cả cuốn — RenderStore + BookRenderer + NativePlayer đọc từ file", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const store = readFileSync(join(pluginDir, "RenderStore.swift"), "utf8");
  assert.ok(store.includes("TTSRender"), "RenderStore phải lưu ở SachNoi/TTSRender");
  assert.ok(store.includes("kAudioFormatMPEG4AAC"), "RenderStore phải nén AAC (WAV thô tốn ~345MB/giờ)");
  assert.ok(store.includes("saveWav"), "RenderStore thiếu saveWav");
  assert.ok(store.includes("evictIfNeeded"), "RenderStore thiếu trần dung lượng + dọn sách cũ");
  const renderer = readFileSync(join(pluginDir, "BookRenderer.swift"), "utf8");
  assert.ok(renderer.includes("priorityEnd"), "BookRenderer thiếu tính ranh giới ưu tiên theo chương");
  assert.ok(renderer.includes("chaptersSeen > 2"), "ưu tiên phải là chương hiện tại + 2 chương kế (đệm 2–3 chương)");
  assert.ok(renderer.includes("thermalState"), "BookRenderer phải nhường khi máy quá nóng (thermal)");
  assert.ok(renderer.includes("synthesizeSync"), "BookRenderer phải tổng hợp qua TtsServer");
  assert.ok(swift.includes("RenderStore.exists"), "NativePlayer phải ưu tiên file đã render trước khi sinh trực tiếp");
  assert.ok(swift.includes("BookRenderer.shared"), "NativePlayer phải gắn BookRenderer");
  assert.ok(swift.includes("persistRender"), "NativePlayer phải lưu đoạn sinh trực tiếp vào kho render");
  assert.ok(swift.includes("makeBufferFromFile"), "NativePlayer thiếu giải mã file đã render");
  const plugin = readFileSync(join(pluginDir, "SachNoiBridgePlugin.swift"), "utf8");
  assert.ok(plugin.includes("bookId"), "plugin phải chuyển bookId vào player.load");
  const playerJs = readFileSync(join(root, "web-src/lib/player.js"), "utf8");
  assert.ok(playerJs.includes("bookId"), "player.js phải gửi bookId khi ttsPlay");
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
