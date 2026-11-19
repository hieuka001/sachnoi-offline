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

test("3.3.0: bản thử Supertonic — giọng hệ thống mặc định + Supertonic 3 qua sherpa-onnx, VieNeu gỡ hẳn", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const server = readFileSync(join(pluginDir, "TtsServer.swift"), "utf8");
  assert.ok(server.includes("AVSpeechSynthesizer"), "TtsServer phải có giọng hệ thống (AVSpeechSynthesizer)");
  assert.ok(server.includes("synthesizer.write"), "TtsServer phải render giọng hệ thống qua AVSpeechSynthesizer.write");
  assert.ok(server.includes("supertonicPresets"), "TtsServer thiếu bảng 10 giọng Supertonic");
  assert.ok(server.includes("isSupertonic"), "TtsServer thiếu định tuyến isSupertonic");
  assert.ok(server.includes("synthesizeSupertonic"), "TtsServer thiếu đường tổng hợp Supertonic");
  assert.ok(server.includes("SupertonicEngine"), "TtsServer phải dùng SupertonicEngine");
  assert.ok(existsSync(join(pluginDir, "SupertonicEngine.swift")), "SupertonicEngine.swift phải tồn tại ở 3.3.0");
  assert.ok(!existsSync(join(pluginDir, "VieNeuEngine.swift")), "VieNeuEngine phải đã gỡ ở 3.3.0");
  assert.ok(!existsSync(join(pluginDir, "NanoEngine.swift")), "NanoEngine vẫn phải vắng mặt");
  assert.ok(!server.includes("NWListener"), "TtsServer vẫn còn server HTTP thừa");
  const engine = readFileSync(join(pluginDir, "SupertonicEngine.swift"), "utf8");
  assert.ok(engine.includes("SherpaOnnxC"), "SupertonicEngine phải gọi C API sherpa-onnx qua SherpaOnnxC");
  assert.ok(engine.includes("config.model.supertonic"), "SupertonicEngine phải cấu hình model supertonic");
  assert.ok(engine.includes("voice_style"), "SupertonicEngine thiếu voice_style (voice.bin)");
  assert.ok(engine.includes('\\"lang\\"'), "SupertonicEngine phải chọn lang trong extra JSON");
  assert.ok(engine.includes("SherpaOnnxOfflineTtsGenerateWithConfig"), "SupertonicEngine phải sinh bằng GenerateWithConfig (cần sid + lang)");
  const packStore = readFileSync(join(pluginDir, "PackStore.swift"), "utf8");
  assert.ok(packStore.includes("supertonicAssetsURL"), "PackStore phải có supertonicAssetsURL");
  assert.ok(!packStore.includes("vieneuAssetsURL"), "PackStore vẫn còn vieneuAssetsURL");
  const plugin = readFileSync(join(pluginDir, "SachNoiBridgePlugin.swift"), "utf8");
  assert.ok(plugin.includes("systemVoices"), "plugin ttsVoices phải liệt kê giọng hệ thống");
  assert.ok(plugin.includes("supertonicPresets"), "plugin ttsVoices phải liệt kê thêm 10 giọng Supertonic");
  const podspec = readFileSync(join(root, "plugins/sachnoi-bridge/SachnoiBridge.podspec"), "utf8");
  // Gói PHẢI tên SherpaOnnxC.xcframework cho khớp framework bên trong —
  // CocoaPods lấy tên gói làm cờ -framework (2.0.0 fix2 7017eb0; 3.3.0
  // từng lùi về sherpa-onnx.xcframework và CI chết "framework
  // 'sherpa-onnx' not found" ở build 44570504734).
  assert.ok(podspec.includes("SherpaOnnxC.xcframework"), "podspec phải vendor SherpaOnnxC.xcframework");
  assert.ok(!podspec.includes("onnxruntime"), "podspec vẫn còn onnxruntime-objc");
  assert.ok(!podspec.includes("sea_g2p"), "podspec vẫn còn libsea_g2p_rs");
  const pbx = readFileSync(join(root, "ios/App/App.xcodeproj/project.pbxproj"), "utf8");
  assert.ok(pbx.includes("SupertonicAssets"), "pbxproj phải có SupertonicAssets (model gắn sẵn)");
  assert.ok(!pbx.includes("TTSAssets"), "pbxproj vẫn còn TTSAssets");
  assert.ok(!pbx.includes("NanoAssets"), "pbxproj vẫn còn NanoAssets");
  const ci = readFileSync(join(root, ".github/workflows/build-ipa.yml"), "utf8");
  // Biến thể PHẢI là shared-onnxruntime-static (dylib tự chứa onnxruntime)
  // — biến thể -ios-static cần onnxruntime riêng và link lỗi Undefined
  // _OrtGetApiBase (2.0.0 fix3 57ee1bb; 3.3.0 từng lùi về -ios-static).
  assert.ok(ci.includes("sherpa-onnx-v1.13.8-ios-shared-onnxruntime-static.xcframework.zip"), "CI phải tải xcframework sherpa-onnx 1.13.8 ghim bản (biến thể shared-onnxruntime-static)");
  assert.ok(ci.includes("sherpa-onnx-supertonic-3-tts-int8-2026-05-11"), "CI phải tải gói Supertonic 3 int8 của k2-fsa");
  assert.ok(!ci.includes("libsea_g2p_rs"), "CI vẫn còn bước build Rust sea-g2p");
});

test("3.3.0: đúng 10 giọng Supertonic (5 nữ F1–F5 + 5 nam M1–M5) + 1 giọng hệ thống — manifest khớp Swift", () => {
  const manifest = JSON.parse(readFileSync(join(root, "voices/voices.json"), "utf8"));
  assert.equal(manifest.voices.length, 11, "manifest phải có 11 giọng (1 hệ thống + 10 Supertonic)");
  const system = manifest.voices.filter(v => v.engine === "system");
  assert.equal(system.length, 1, "phải có đúng 1 giọng hệ thống");
  assert.equal(system[0].id, "Linh");
  const sup = manifest.voices.filter(v => v.engine === "supertonic");
  assert.equal(sup.length, 10, "phải có đúng 10 giọng Supertonic");
  assert.deepEqual(sup.filter(v => v.gender === "Nữ").map(v => v.id),
    ["supertonic/F1", "supertonic/F2", "supertonic/F3", "supertonic/F4", "supertonic/F5"], "5 giọng nữ F1–F5");
  assert.deepEqual(sup.filter(v => v.gender === "Nam").map(v => v.id),
    ["supertonic/M1", "supertonic/M2", "supertonic/M3", "supertonic/M4", "supertonic/M5"], "5 giọng nam M1–M5");
  const server = readFileSync(join(root, "plugins/sachnoi-bridge/ios/Plugin/TtsServer.swift"), "utf8");
  for (const v of sup) {
    assert.ok(server.includes(`"${v.id}"`), `TtsServer.supertonicPresets thiếu "${v.id}"`);
  }
  const pack = manifest.packs.find(p => p.id === "supertonic-3-int8");
  assert.ok(pack && pack.status === "available", "gói supertonic-3-int8 phải available");
  assert.equal(pack.files.length, 7, "gói Supertonic phải có đúng 7 file");
});

test("2.2.0/3.2.0: render trước cả cuốn — RenderStore + BookRenderer + NativePlayer đọc từ file", () => {
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
  assert.ok(swift.includes("RenderStore.usable"), "NativePlayer phải ưu tiên file đã render (đã kiểm tra dùng được) trước khi sinh trực tiếp");
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

test("3.2.0 (VoiceStudio): kho render địa chỉ hoá theo NỘI DUNG đoạn, không theo chỉ số sách", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const store = readFileSync(join(pluginDir, "RenderStore.swift"), "utf8");
  assert.ok(store.includes("func segmentID"), "RenderStore thiếu segmentID (hash nội dung đoạn)");
  assert.ok(store.includes("segmentsURL"), "RenderStore thiếu kho đoạn chung segments/");
  assert.ok(store.includes("sweepLegacy"), "RenderStore thiếu dọn bố cục thư mục-theo-sách cũ");
  assert.ok(store.includes("func usable"), "RenderStore thiếu usable() — kiểm tra file render hỏng trước khi phát");
  assert.ok(store.includes("AVAudioFile(forReading"), "usable() phải mở thử file bằng AVAudioFile");
  const renderer = readFileSync(join(pluginDir, "BookRenderer.swift"), "utf8");
  assert.ok(renderer.includes("segmentIDs"), "BookRenderer phải tính địa chỉ nội dung từng đoạn");
  assert.ok(renderer.includes("RenderStore.renderedIndices(segmentIDs:"), "BookRenderer phải đọc việc đã xong từ kho chung");
  const player = readFileSync(join(pluginDir, "NativePlayer.swift"), "utf8");
  assert.ok(player.includes("func segmentID(for"), "NativePlayer thiếu segmentID(for:)");
  assert.ok(player.includes("RenderStore.usable(segID)"), "NativePlayer phải phát từ file đã kiểm tra usable");
  assert.ok(!player.includes("RenderStore.exists(self.renderKey"), "NativePlayer vẫn còn tra file theo khoá sách cũ");
  assert.ok(player.includes("func preRender"), "NativePlayer thiếu preRender (gắn renderer không phát)");
});

test("3.2.0 (VoiceStudio): render TỰ TIẾP TỤC khi mở app — ttsRenderBook + resumeRender", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const plugin = readFileSync(join(pluginDir, "SachNoiBridgePlugin.swift"), "utf8");
  assert.ok(plugin.includes("func ttsRenderBook"), "plugin thiếu ttsRenderBook");
  assert.ok(plugin.includes("preRender"), "ttsRenderBook phải gọi NativePlayer.preRender");
  const reg = readFileSync(join(pluginDir, "SachNoiBridgePlugin.m"), "utf8");
  assert.ok(reg.includes("ttsRenderBook"), "SachNoiBridgePlugin.m chưa đăng ký ttsRenderBook");
  const playerJs = readFileSync(join(root, "web-src/lib/player.js"), "utf8");
  assert.ok(playerJs.includes("preRender()"), "player.js thiếu preRender()");
  assert.ok(playerJs.includes("ttsRenderBook"), "player.preRender phải gọi bridge.ttsRenderBook");
  const appJs = readFileSync(join(root, "web-src/app.js"), "utf8");
  assert.ok(appJs.includes("resumeRender"), "app.js thiếu resumeRender() lúc khởi động");
  assert.ok(appJs.includes("lastListenedAt"), "resumeRender phải chọn cuốn nghe gần nhất");
});

test("3.2.1: nền thuộc về tầng phát — renderer chỉ chạy tiền cảnh, preRender không đè phiên thật", () => {
  const pluginDir = join(root, "plugins/sachnoi-bridge/ios/Plugin");
  const renderer = readFileSync(join(pluginDir, "BookRenderer.swift"), "utf8");
  assert.ok(renderer.includes("applicationState"), "BookRenderer phải kiểm tra applicationState (chỉ render khi app active)");
  assert.ok(renderer.includes("UIApplication"), "BookRenderer thiếu UIApplication");
  const server = readFileSync(join(pluginDir, "TtsServer.swift"), "utf8");
  const warmupBody = server.slice(server.indexOf("func warmup()"), server.indexOf("// MARK: - Supertonic"));
  assert.ok(!warmupBody.includes("SupertonicEngine("), "warmup KHÔNG được dựng engine Supertonic lúc mở app (dựng lười)");
  const player = readFileSync(join(pluginDir, "NativePlayer.swift"), "utf8");
  assert.ok(player.includes("didLoad"), "NativePlayer thiếu cờ didLoad chặn preRender sau phiên thật");
  assert.ok(player.includes("!self.didLoad"), "preRender phải bị chặn khi đã có phiên load thật");
});
