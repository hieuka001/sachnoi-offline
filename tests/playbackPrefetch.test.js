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

test("2.2.0: Nano đã gỡ hẳn — thuần Turbo, không còn định tuyến/assets Nano", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const server = readFileSync(join(pluginDir, "TtsServer.swift"), "utf8");
  assert.ok(!existsSync(join(pluginDir, "NanoEngine.swift")), "NanoEngine.swift phải đã xoá (2.2.0 bỏ Nano)");
  assert.ok(!server.includes("NanoEngine"), "TtsServer vẫn còn định tuyến engine Nano");
  assert.ok(!server.includes("nanoPrefix"), "TtsServer vẫn còn tiền tố nano/");
  assert.ok(!server.includes("getNanoEngine"), "TtsServer vẫn còn getNanoEngine");
  assert.ok(server.includes("VieNeuEngine"), "TtsServer thiếu hồ engine Turbo");
  assert.ok(!server.includes("NWListener"), "TtsServer vẫn còn server HTTP thừa");
  assert.ok(!server.includes("SherpaTts"), "TtsServer vẫn còn sherpa/Piper");
  const packStore = readFileSync(join(pluginDir, "PackStore.swift"), "utf8");
  assert.ok(!packStore.includes("nanoAssetsURL"), "PackStore vẫn còn nanoAssetsURL");
  const plugin = readFileSync(join(pluginDir, "SachNoiBridgePlugin.swift"), "utf8");
  assert.ok(!plugin.includes("nanoVoiceList"), "plugin vẫn còn nanoVoiceList");
  for (const back of ["VieNeuEngine.swift", "Phonemizer.swift", "SpeechUtils.swift", "SeaG2p.swift", "BpeTokenizer.swift"]) {
    assert.ok(existsSync(join(pluginDir, back)), `${back} phải còn cho Turbo`);
  }
  assert.ok(!existsSync(join(pluginDir, "SherpaTts.swift")), "SherpaTts.swift phải đã xoá");
  const podspec = readFileSync(join(root, "plugins/sachnoi-bridge/SachnoiBridge.podspec"), "utf8");
  assert.ok(podspec.includes("dependency 'onnxruntime-objc'"), "podspec thiếu onnxruntime-objc");
  assert.ok(podspec.includes("libsea_g2p_rs.a"), "podspec thiếu libsea_g2p_rs.a");
  assert.ok(!podspec.includes("SherpaOnnxC"), "podspec vẫn còn sherpa");
  const pbx = readFileSync(join(root, "ios/App/App.xcodeproj/project.pbxproj"), "utf8");
  assert.ok(!pbx.includes("NanoAssets"), "pbxproj vẫn còn NanoAssets");
});

test("2.2.0: đúng 10 giọng Turbo cho 3 miền — Swift và manifest phải khớp", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const server = readFileSync(join(pluginDir, "TtsServer.swift"), "utf8");
  const expected = ["Trúc Ly", "Ngọc Huyền", "Hải Đăng", "Phạm Tuyên", "Ngọc Trân", "Quang Sơn", "Thùy Dung", "Mỹ Duyên", "Thái Sơn", "Đức Trí"];
  for (const name of expected) {
    assert.ok(server.includes(`"${name}"`), `TtsServer.allowedVoices thiếu giọng ${name}`);
  }
  assert.ok(server.includes("resolveVoice"), "TtsServer thiếu resolveVoice (giọng lạ -> mặc định)");
  assert.ok(server.includes('defaultVoice = "Trúc Ly"'), "giọng mặc định phải là Trúc Ly");
  const manifest = JSON.parse(readFileSync(join(root, "voices/voices.json"), "utf8"));
  assert.equal(manifest.voices.length, 10, "manifest phải có đúng 10 giọng");
  assert.deepEqual(manifest.voices.map((v) => v.id).sort(), [...expected].sort(), "manifest và Swift lệch danh sách giọng");
  assert.ok(manifest.voices.every((v) => v.engine === "vieneu-turbo"), "còn giọng không phải Turbo trong manifest");
  const byRegion = (r) => manifest.voices.filter((v) => v.region === r).length;
  assert.equal(byRegion("Miền Bắc"), 4, "phải có 4 giọng Bắc");
  assert.equal(byRegion("Miền Trung"), 2, "phải có 2 giọng Trung (bộ preset chỉ có 2)");
  assert.equal(byRegion("Miền Nam"), 4, "phải có 4 giọng Nam");
  assert.ok(!manifest.packs.some((p) => p.id === "vieneu-nano"), "manifest vẫn còn pack vieneu-nano");
});

test("2.2.0: render trước cả cuốn — RenderStore + BookRenderer + NativePlayer đọc từ file", () => {
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
