import Foundation
import Capacitor
import AVFoundation
import Vision
import UIKit

/// SachNoiBridge — cầu native của app Sách Nói Offline:
/// - TTS VieNeu nội bộ (giọng lấy từ gói đã tải, xem PackStore)
/// - Tải gói nền (core/giọng) qua BackgroundDownloader + kiểm SHA-256
/// - Nghe nền: Now Playing + remote command + ngắt quãng (BackgroundAudio)
/// - saveFile: xuất file qua khay chia sẻ iOS (WKWebView không tự tải blob được)
@objc(SachNoiBridgePlugin)
public class SachNoiBridgePlugin: CAPPlugin {
    private let player = NativePlayer()

    override public func load() {
        PackStore.ensureRoot()
        TtsServer.shared.start()
        lockWebView(attempt: 0)
        // NativePlayer (1.0.3): chuỗi phát chạy native để khoá máy vẫn đọc tiếp.
        player.onSentence = { [weak self] idx in self?.notifyListeners("ttsSentence", data: ["index": idx]) }
        player.onState = { [weak self] playing in self?.notifyListeners("ttsState", data: ["playing": playing]) }
        player.onEnded = { [weak self] in self?.notifyListeners("ttsEnded", data: [:]) }
        // Remote/ngắt quãng điều khiển THẲNG NativePlayer (WebView có thể đang bị
        // treo khi chạy nền) — vẫn chuyển sự kiện sang web để đồng bộ giao diện.
        BackgroundAudio.shared.onRemoteCommand = { [weak self] cmd in
            guard let self else { return }
            switch cmd {
            case "play": self.player.resume()
            case "pause": self.player.pause()
            case "toggle": if self.player.playing { self.player.pause() } else { self.player.resume() }
            case "next": self.player.next()
            case "prev": self.player.prev()
            default: break
            }
            self.notifyListeners("remoteCommand", data: ["command": cmd])
        }
        BackgroundAudio.shared.onInterruption = { [weak self] phase, shouldResume in
            guard let self else { return }
            if phase == "began" { self.player.interruptionBegan() }
            else { self.player.interruptionEnded(shouldResume: shouldResume) }
            self.notifyListeners("audioInterruption", data: ["phase": phase, "shouldResume": shouldResume])
        }
        BackgroundAudio.shared.onRoutePause = { [weak self] in
            self?.player.pause()
            self?.notifyListeners("remoteCommand", data: ["command": "pause"])
        }
        let dl = BackgroundDownloader.shared
        dl.onProgress = { [weak self] packId, received, total in
            self?.notifyListeners("packDownloadProgress", data: ["packId": packId, "received": received, "total": total])
        }
        dl.onFileFinished = { [weak self] packId, name, error in
            self?.notifyListeners("packFileFinished", data: ["packId": packId, "name": name, "error": error ?? ""])
        }
        dl.onPackFinished = { [weak self] packId in
            // Gói core vừa tải xong -> nạp engine ngay để bấm Nghe là có tiếng
            if packId.hasPrefix("vieneu-") { TtsServer.shared.warmup() }
            self?.notifyListeners("packDownloadFinished", data: ["packId": packId])
        }
    }

    @objc public static func startTtsEngine() {
        TtsServer.shared.start()
    }

    private func lockWebView(attempt: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let webView = self.bridge?.webView {
                webView.scrollView.bounces = false
                webView.scrollView.alwaysBounceVertical = false
                webView.scrollView.alwaysBounceHorizontal = false
                webView.allowsLinkPreview = false
            } else if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.lockWebView(attempt: attempt + 1) }
            }
        }
    }

    @objc func getInfo(_ call: CAPPluginCall) {
        let info = Bundle.main.infoDictionary
        call.resolve([
            "version": info?["CFBundleShortVersionString"] as? String ?? "0",
            "build": info?["CFBundleVersion"] as? String ?? "0",
            "platform": "ios",
            "ttsNative": true,
            "nativePlayer": true,
            "backgroundAudio": true,
            "backgroundDownloads": true,
            "coreInstalled": true,
            "coreBundled": Bundle.main.url(forResource: "TTSAssets", withExtension: nil) != nil,
            "manifestUpdateAvailable": BackgroundTasks.availableManifestVersion() ?? "",
        ])
    }

    @objc func saveFile(_ call: CAPPluginCall) {
        guard let name = call.getString("name"), !name.isEmpty,
              let base64 = call.getString("base64"),
              let data = Data(base64Encoded: base64) else {
            call.reject("saveFile needs name + base64"); return
        }
        let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do { try data.write(to: url, options: .atomic) } catch {
            call.reject("Cannot write temp file: \(error.localizedDescription)"); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let presenter = self?.bridge?.viewController else { call.reject("No presenter"); return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            }
            presenter.present(activity, animated: true) { call.resolve(["saved": true]) }
        }
    }

    // MARK: - TTS
    @objc func ttsVoices(_ call: CAPPluginCall) {
        // 3.1.0: giọng hệ thống iOS trước (mặc định, nhẹ), rồi 4 giọng
        // VieNeu Turbo (Bắc/Nam × nam/nữ) từ file preset — không cần dựng
        // engine để liệt kê.
        DispatchQueue.global(qos: .userInitiated).async {
            var voices = TtsServer.shared.systemVoices()
            if let store = try? TtsServer.shared.getVoiceStore() {
                let byName = Dictionary(uniqueKeysWithValues: store.presets.map { ($0.name, $0) })
                voices += TtsServer.vieneuVoices.compactMap { name in
                    byName[name].map { ["id": $0.name, "name": $0.label, "language": "vi"] }
                }
            }
            if voices.isEmpty {
                call.reject("Thiết bị chưa có giọng tiếng Việt")
            } else {
                call.resolve(["voices": voices])
            }
        }
    }

    @objc func ttsSynthesize(_ call: CAPPluginCall) {
        guard let text = call.getString("text"), !text.isEmpty else { call.reject("ttsSynthesize needs text"); return }
        let voice = call.getString("voice") ?? "default"
        // Đang tổng hợp mà app vào nền: xin thêm thời gian để không cắt giữa câu
        BackgroundAudio.shared.beginBackgroundAssertion(name: "SachNoiSynthesize")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { BackgroundAudio.shared.endBackgroundAssertion() }
            do {
                let wav = try TtsServer.shared.synthesizeSync(text: text, voice: voice)
                call.resolve(["base64": wav.base64EncodedString()])
            } catch {
                call.reject("Tổng hợp thất bại: \(error.localizedDescription)")
            }
        }
    }

    @objc func ttsDiagnostics(_ call: CAPPluginCall) {
        var info = TtsServer.shared.diagnostics()
        info["shellVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        info["packs"] = PackStore.installedPacks().map { "\($0["id"] ?? "?"):\($0["bytes"] ?? 0)" }.joined(separator: ",")
        call.resolve(info)
    }

    // MARK: - Gói tải nền (core + giọng)
    @objc func downloadPack(_ call: CAPPluginCall) {
        guard let packId = call.getString("packId"), !packId.isEmpty,
              let files = call.getArray("files") as? [[String: Any]], !files.isEmpty else {
            call.reject("downloadPack needs packId + files"); return
        }
        BackgroundDownloader.shared.download(packId: packId, files: files)
        call.resolve(["started": true])
    }

    @objc func cancelPackDownload(_ call: CAPPluginCall) {
        guard let packId = call.getString("packId") else { call.reject("needs packId"); return }
        BackgroundDownloader.shared.cancel(packId: packId)
        call.resolve(["cancelled": true])
    }

    @objc func packStatus(_ call: CAPPluginCall) {
        guard let packId = call.getString("packId") else { call.reject("needs packId"); return }
        let dir = PackStore.packURL(packId)
        let exists = FileManager.default.fileExists(atPath: dir.path)
        call.resolve(["installed": exists, "bytes": exists ? PackStore.directorySize(dir) : 0])
    }

    @objc func listInstalledPacks(_ call: CAPPluginCall) {
        call.resolve(["packs": PackStore.installedPacks()])
    }

    @objc func deletePack(_ call: CAPPluginCall) {
        guard let packId = call.getString("packId") else { call.reject("needs packId"); return }
        BackgroundDownloader.shared.cancel(packId: packId) // huỷ tải trước khi xoá thư mục
        do { try PackStore.deletePack(packId); call.resolve(["deleted": true]) }
        catch { call.reject(error.localizedDescription) }
    }

    @objc func verifyPack(_ call: CAPPluginCall) {
        guard let packId = call.getString("packId"),
              let files = call.getArray("files") as? [[String: Any]] else {
            call.reject("verifyPack needs packId + files"); return
        }
        DispatchQueue.global(qos: .utility).async {
            call.resolve(["files": PackStore.verify(packId: packId, files: files)])
        }
    }

    // MARK: - Nghe nền: Now Playing
    @objc func setNowPlaying(_ call: CAPPluginCall) {
        BackgroundAudio.shared.setNowPlaying(
            title: call.getString("title") ?? "",
            author: call.getString("author") ?? "",
            chapter: call.getString("chapter") ?? "",
            elapsed: call.getDouble("elapsed") ?? 0,
            duration: call.getDouble("duration") ?? 0,
            isPlaying: call.getBool("isPlaying") ?? false)
        call.resolve()
    }

    @objc func updatePlaybackState(_ call: CAPPluginCall) {
        BackgroundAudio.shared.updatePlayback(isPlaying: call.getBool("isPlaying") ?? false,
                                              elapsed: call.getDouble("elapsed") ?? 0)
        call.resolve()
    }

    @objc func clearNowPlaying(_ call: CAPPluginCall) {
        BackgroundAudio.shared.clearNowPlaying()
        call.resolve()
    }

    @objc func scheduleBackgroundTasks(_ call: CAPPluginCall) {
        BackgroundTasks.scheduleAll()
        call.resolve(["scheduled": true])
    }

    @objc func markManifestSeen(_ call: CAPPluginCall) {
        if let v = call.getString("version") { BackgroundTasks.markManifestSeen(v) }
        call.resolve()
    }

    // MARK: - OCR sách scan (Apple Vision, offline, cần iOS 16 cho tiếng Việt)
    @objc func ocrImage(_ call: CAPPluginCall) {
        guard let b64 = call.getString("image"),
              let data = Data(base64Encoded: b64),
              let image = UIImage(data: data),
              let cg = image.cgImage else {
            call.reject("Ảnh trang sách không hợp lệ"); return
        }
        guard #available(iOS 16.0, *) else {
            call.reject("OCR tiếng Việt cần iOS 16 trở lên — máy đang chạy iOS cũ hơn."); return
        }
        do {
            let langs = try VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: VNRecognizeTextRequestRevision3)
            guard langs.contains(where: { $0.hasPrefix("vi") }) else {
                call.reject("Thiết bị chưa hỗ trợ OCR tiếng Việt."); return
            }
        } catch {
            call.reject("Không kiểm tra được ngôn ngữ OCR: \(error.localizedDescription)"); return
        }
        let request = VNRecognizeTextRequest { (req, err) in
            if let err { call.reject("OCR lỗi: \(err.localizedDescription)"); return }
            let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            call.resolve(["lines": lines, "text": lines.joined(separator: "\n")])
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["vi-VN", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handler.perform([request]) }
            catch { call.reject("OCR lỗi: \(error.localizedDescription)") }
        }
    }

    // MARK: - NativePlayer (phát nền native)
    @objc func ttsPlay(_ call: CAPPluginCall) {
        guard let rawItems = call.getArray("items") as? [[String: Any]] else {
            call.reject("ttsPlay needs items"); return
        }
        let items = rawItems
            .map { NativePlayer.Item(text: ($0["t"] as? String) ?? "", chapter: ($0["c"] as? String) ?? "", paraEnd: ($0["p"] as? NSNumber)?.boolValue ?? false, cont: ($0["k"] as? NSNumber)?.boolValue ?? false) }
            .filter { !$0.text.isEmpty }
        guard !items.isEmpty else { call.reject("Không có câu nào để đọc"); return }
        // 2.2.0: bookId + cài đặt âm thanh đi cùng load để NativePlayer tính
        // khoá render và gắn BookRenderer (render trước) ngay từ đầu.
        let audio = call.getObject("audio").map { Self.audioSettings(from: $0) }
        player.load(items: items, voice: call.getString("voice") ?? "default",
                    title: call.getString("title") ?? "", author: call.getString("author") ?? "",
                    bookId: call.getString("bookId") ?? "", audio: audio)
        player.play(from: call.getInt("startIndex") ?? 0)
        call.resolve(["ok": true, "count": items.count])
    }

    /// 3.2.0 (theo mô hình resume của VoiceStudio): gắn BookRenderer cho
    /// một cuốn sách mà KHÔNG phát — web gọi khi app mở để render tự tiếp
    /// tục cuốn đang nghe dở, thay vì chờ người dùng bấm Nghe mới render.
    @objc func ttsRenderBook(_ call: CAPPluginCall) {
        guard let rawItems = call.getArray("items") as? [[String: Any]] else {
            call.reject("ttsRenderBook needs items"); return
        }
        let items = rawItems
            .map { NativePlayer.Item(text: ($0["t"] as? String) ?? "", chapter: ($0["c"] as? String) ?? "", paraEnd: ($0["p"] as? NSNumber)?.boolValue ?? false, cont: ($0["k"] as? NSNumber)?.boolValue ?? false) }
            .filter { !$0.text.isEmpty }
        guard !items.isEmpty else { call.reject("Không có câu nào để render"); return }
        let audio = call.getObject("audio").map { Self.audioSettings(from: $0) }
        player.preRender(items: items, voice: call.getString("voice") ?? "default",
                         bookId: call.getString("bookId") ?? "", audio: audio)
        call.resolve(["ok": true, "count": items.count])
    }

    private static func audioSettings(from d: [String: Any]) -> NativePlayer.AudioSettings {
        var s = NativePlayer.AudioSettings()
        if let v = (d["volume"] as? NSNumber)?.floatValue { s.volume = min(max(0, v), 1) }
        if let v = (d["pitch"] as? NSNumber)?.floatValue { s.pitchCents = min(max(-1200, v), 1200) }
        // 1.9.4: gapPunct là cài đặt nghỉ chung cho mọi dấu câu; vẫn nhận
        // gapSentence/gapComma cũ làm dự phòng để bản web cũ hơn vẫn chạy.
        if let v = (d["gapPunct"] as? NSNumber)?.doubleValue { s.gapPunct = min(max(0, v), 3) }
        else if let v = (d["gapSentence"] as? NSNumber)?.doubleValue { s.gapPunct = min(max(0, v), 3) }
        else if let v = (d["gapComma"] as? NSNumber)?.doubleValue { s.gapPunct = min(max(0, v), 3) }
        if let v = (d["gapParagraph"] as? NSNumber)?.doubleValue { s.gapParagraph = min(max(0, v), 5) }
        // Cùng giá trị áp cho khoảng lặng TẠI dấu câu bên trong engine Turbo
        // (đường nghe thử/tổng hợp cả đoạn) — một cài đặt chi phối tất cả.
        // NativePlayer cũng áp giữa các đoạn khi phát cho cả hai engine.
        TtsServer.shared.punctPauseSeconds = s.gapPunct
        TtsServer.shared.paraPauseSeconds = s.gapParagraph
        return s
    }

    @objc func ttsSetAudio(_ call: CAPPluginCall) {
        var d: [String: Any] = [:]
        for k in ["volume", "pitch", "gapPunct", "gapSentence", "gapComma", "gapParagraph"] {
            if let v = call.getDouble(k) { d[k] = v }
        }
        player.setAudio(Self.audioSettings(from: d))
        call.resolve(["ok": true])
    }

    @objc func ttsPause(_ call: CAPPluginCall) { player.pause(); call.resolve(["ok": true]) }
    @objc func ttsResume(_ call: CAPPluginCall) { player.resume(); call.resolve(["ok": true]) }
    @objc func ttsStopPlayback(_ call: CAPPluginCall) { player.stop(); call.resolve(["ok": true]) }
    @objc func ttsNext(_ call: CAPPluginCall) { player.next(); call.resolve(["ok": true]) }
    @objc func ttsPrev(_ call: CAPPluginCall) { player.prev(); call.resolve(["ok": true]) }

    @objc func ttsSeek(_ call: CAPPluginCall) {
        player.seek(to: call.getInt("index") ?? 0)
        call.resolve(["ok": true])
    }

    @objc func ttsSetRate(_ call: CAPPluginCall) {
        player.setRate(Float(call.getDouble("rate") ?? 1.0))
        call.resolve(["ok": true])
    }

    @objc func ttsSetVoice(_ call: CAPPluginCall) {
        player.setVoice(call.getString("voice") ?? "default")
        call.resolve(["ok": true])
    }

    @objc func ttsSetSleep(_ call: CAPPluginCall) {
        player.setSleep(mode: call.getString("mode") ?? "off", minutes: call.getDouble("minutes") ?? 0)
        call.resolve(["ok": true])
    }

    @objc func ttsPlayerState(_ call: CAPPluginCall) {
        call.resolve(["index": player.currentIndex, "count": player.count])
    }
}
