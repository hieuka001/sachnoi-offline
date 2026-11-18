import Foundation
import Capacitor
import AVFoundation

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
            "coreInstalled": PackStore.vieneuAssetsURL() != nil,
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
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let store = try TtsServer.shared.getVoiceStore()
                call.resolve(["voices": store.presets.map { ["id": $0.name, "name": $0.label, "language": "vi"] }])
            } catch {
                call.reject("Chưa tải gói core VieNeu hoặc gói lỗi: \(error.localizedDescription)")
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

    // MARK: - NativePlayer (phát nền native)
    @objc func ttsPlay(_ call: CAPPluginCall) {
        guard let rawItems = call.getArray("items") as? [[String: Any]] else {
            call.reject("ttsPlay needs items"); return
        }
        let items = rawItems
            .map { NativePlayer.Item(text: ($0["t"] as? String) ?? "", chapter: ($0["c"] as? String) ?? "", paraEnd: ($0["p"] as? NSNumber)?.boolValue ?? false) }
            .filter { !$0.text.isEmpty }
        guard !items.isEmpty else { call.reject("Không có câu nào để đọc"); return }
        player.load(items: items, voice: call.getString("voice") ?? "default",
                    title: call.getString("title") ?? "", author: call.getString("author") ?? "")
        if let audio = call.getObject("audio") { player.setAudio(Self.audioSettings(from: audio)) }
        player.play(from: call.getInt("startIndex") ?? 0)
        call.resolve(["ok": true, "count": items.count])
    }

    private static func audioSettings(from d: [String: Any]) -> NativePlayer.AudioSettings {
        var s = NativePlayer.AudioSettings()
        if let v = (d["volume"] as? NSNumber)?.floatValue { s.volume = min(max(0, v), 1) }
        if let v = (d["pitch"] as? NSNumber)?.floatValue { s.pitchCents = min(max(-1200, v), 1200) }
        if let v = (d["gapSentence"] as? NSNumber)?.doubleValue { s.gapSentence = min(max(0, v), 3) }
        if let v = (d["gapComma"] as? NSNumber)?.doubleValue { s.gapComma = min(max(0, v), 2) }
        if let v = (d["gapParagraph"] as? NSNumber)?.doubleValue { s.gapParagraph = min(max(0, v), 5) }
        return s
    }

    @objc func ttsSetAudio(_ call: CAPPluginCall) {
        var d: [String: Any] = [:]
        for k in ["volume", "pitch", "gapSentence", "gapComma", "gapParagraph"] {
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
