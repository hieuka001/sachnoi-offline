import Foundation

/// Mặt tiền tổng hợp giọng nói của app (NativePlayer, BookRenderer và
/// plugin gọi: start / warmup / synthesizeSync / diagnostics / getVoiceStore).
///
/// 2.2.0 — THUẦN VieNeu Turbo, 10 giọng cho 3 miền (lệnh của anh: bỏ Nano —
/// Nano chết trên máy thật vì onnxruntime không tạo được tensor bool; Turbo
/// là engine chất lượng nhất nhưng sinh từng khung hình nên chậm hơn tốc độ
/// nghe). Cách làm liền mạch từ 2.2.0 là RENDER TRƯỚC ra đĩa (BookRenderer +
/// RenderStore): phát từ file đã render, không phụ thuộc tốc độ sinh.
/// Hồ 2 engine song song như 1.9.5 — một engine phục vụ phát trực tiếp,
/// một engine render trước, thừa thì cả hai cùng render.
final class TtsServer {
    static let shared = TtsServer()

    /// 10 giọng Turbo được chọn cho đủ 3 miền (2026-11-19): Bắc 4 (Trúc Ly,
    /// Ngọc Huyền, Hải Đăng, Phạm Tuyên), Trung 2 (Ngọc Trân, Quang Sơn —
    /// miền Trung chỉ có đúng 2 giọng trong bộ preset), Nam 4 (Thùy Dung,
    /// Mỹ Duyên, Thái Sơn, Đức Trí). Phải khớp danh sách trong voices.json.
    static let allowedVoices = [
        "Trúc Ly", "Ngọc Huyền", "Hải Đăng", "Phạm Tuyên",
        "Ngọc Trân", "Quang Sơn",
        "Thùy Dung", "Mỹ Duyên", "Thái Sơn", "Đức Trí",
    ]
    static let defaultVoice = "Trúc Ly"

    /// Mọi id giọng lạ (giọng Nano cũ "nano/...", giọng Turbo đã bỏ, tuỳ
    /// chọn "Giọng mặc định") đều rơi về giọng mặc định — không bao giờ lỗi.
    static func resolveVoice(_ voice: String) -> String {
        allowedVoices.contains(voice) ? voice : defaultVoice
    }

    // ── Hồ engine Turbo (1.9.5): 2 engine độc lập tổng hợp 2 đoạn song
    // song; máy RAM < 3GB giữ 1 engine để tránh bị iOS giết vì bộ nhớ.
    private let maxEngines: Int
    private let poolLock = NSLock()
    private var idleEngines: [VieNeuEngine] = []
    private var totalEngines = 0

    private init() {
        maxEngines = ProcessInfo.processInfo.physicalMemory >= 3_000_000_000 ? 2 : 1
    }

    /// Khoảng lặng tại dấu câu do người dùng đặt (plugin ghi vào mỗi khi áp
    /// cài đặt âm thanh) — engine Turbo áp bên trong; NativePlayer cũng áp
    /// giữa các đoạn khi phát.
    var punctPauseSeconds: Double = 0.3
    var paraPauseSeconds: Double = 0.7

    private enum EngineState {
        case notStarted, loading, ready, failed(String)
    }
    private let stateLock = NSLock()
    private var turboState: EngineState = .notStarted
    private var lastEngineError: String?
    private var initStepsText = ""
    private var voiceStore: VoiceStore?

    // Thống kê tốc độ tổng hợp cho tab Chẩn đoán (giữ tên khoá như 1.9.x).
    private var synthLastMs = 0
    private var synthLastChars = 0
    private var synthAvgMs = 0
    private var synthSteps = ""
    private var synthEngine = ""

    private func setTurboState(_ v: EngineState) { stateLock.lock(); turboState = v; stateLock.unlock() }
    private func setEngineError(_ v: String?) { stateLock.lock(); lastEngineError = v; stateLock.unlock() }

    func start() {
        purgeLegacyAudioStores()
        warmup()
    }

    /// Nạp sẵn hồ engine Turbo ở nền ngay khi app mở để bấm Nghe là có tiếng.
    func warmup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for _ in 0..<self.maxEngines {
                self.poolLock.lock()
                if self.totalEngines >= self.maxEngines { self.poolLock.unlock(); break }
                self.totalEngines += 1
                self.poolLock.unlock()
                if let e = try? self.makeEngine() {
                    self.releaseEngine(e)
                } else {
                    self.poolLock.lock(); self.totalEngines -= 1; self.poolLock.unlock()
                    break
                }
            }
        }
    }

    // MARK: - Turbo

    func assetsURL() throws -> URL {
        guard let assets = PackStore.vieneuAssetsURL() else {
            throw VieNeuEngine.EngineError.asset("TTSAssets (chưa tải gói core VieNeu)")
        }
        return assets
    }

    /// Danh sách giọng Turbo đọc thẳng từ file preset — không cần dựng
    /// engine nên plugin trả nhanh; engine lỗi thì giọng vẫn liệt kê được.
    func getVoiceStore() throws -> VoiceStore {
        if let voiceStore { return voiceStore }
        let store = try VoiceStore(url: assetsURL().appendingPathComponent("voices_v3_turbo.json"))
        voiceStore = store
        return store
    }

    private func makeEngine() throws -> VieNeuEngine {
        setTurboState(.loading)
        do {
            let created = try VieNeuEngine(assetsDir: assetsURL())
            setTurboState(.ready)
            stateLock.lock(); initStepsText = VieNeuEngine.lastInitSteps; stateLock.unlock()
            setEngineError(nil)
            return created
        } catch {
            setTurboState(.failed(error.localizedDescription))
            stateLock.lock(); initStepsText = VieNeuEngine.lastInitSteps; stateLock.unlock()
            setEngineError(error.localizedDescription)
            throw error
        }
    }

    private func acquireEngine() throws -> VieNeuEngine {
        let deadline = Date().addingTimeInterval(30)
        while true {
            poolLock.lock()
            if let e = idleEngines.popLast() { poolLock.unlock(); return e }
            if totalEngines < maxEngines {
                totalEngines += 1
                poolLock.unlock()
                do { return try makeEngine() }
                catch {
                    poolLock.lock(); totalEngines -= 1; poolLock.unlock()
                    throw error
                }
            }
            poolLock.unlock()
            stateLock.lock()
            if case .failed(let msg) = turboState {
                stateLock.unlock()
                throw VieNeuEngine.EngineError.asset("engine lỗi: \(msg)")
            }
            stateLock.unlock()
            if Date() > deadline { throw VieNeuEngine.EngineError.asset("engine chưa sẵn sàng sau 30s") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func releaseEngine(_ e: VieNeuEngine) {
        poolLock.lock(); idleEngines.append(e); poolLock.unlock()
    }

    // MARK: - Tổng hợp

    func synthesizeSync(text: String, voice: String) throws -> Data {
        try synthesizeNow(text: text, voice: voice)
    }

    func synthesizeNow(text: String, voice: String) throws -> Data {
        let t0 = Date()
        let resolved = Self.resolveVoice(voice)
        let engine = try acquireEngine()
        let data: Data
        do {
            data = try engine.synthesize(text: text, voiceName: resolved,
                                         punctPause: punctPauseSeconds, paraPause: paraPauseSeconds)
        } catch {
            releaseEngine(engine)
            throw error
        }
        releaseEngine(engine)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        stateLock.lock()
        synthLastMs = ms
        synthLastChars = text.count
        synthAvgMs = synthAvgMs == 0 ? ms : (synthAvgMs * 3 + ms) / 4
        synthEngine = "turbo"
        synthSteps = VieNeuEngine.lastSynthSteps
        // WAV 44 byte header + PCM16: suy độ dài tiếng để đối chiếu tốc độ.
        let seconds = Double(max(0, data.count - 44)) / 2.0 / Double(VieNeuEngine.sampleRate)
        synthSteps += " · wav \(String(format: "%.1f", seconds))s"
        stateLock.unlock()
        return data
    }

    // MARK: - Chẩn đoán

    func diagnostics() -> [String: Any] {
        stateLock.lock()
        let ee = lastEngineError ?? ""
        let steps = initStepsText
        let sLast = synthLastMs, sChars = synthLastChars, sAvg = synthAvgMs
        let sSteps = synthSteps, sEngine = synthEngine
        func text(_ s: EngineState) -> String {
            switch s {
            case .notStarted: return "notStarted"
            case .loading: return "loading"
            case .ready: return "ready"
            case .failed(let m): return "failed: \(m)"
            }
        }
        let turboText = text(turboState)
        stateLock.unlock()
        poolLock.lock()
        let poolTotal = totalEngines, poolIdle = idleEngines.count
        poolLock.unlock()

        var assetsFound = false
        var missing: [String] = []
        if let assets = PackStore.vieneuAssetsURL() {
            assetsFound = true
            let expected = ["config.json", "heads.bin", "heads.json", "tokenizer.json", "sea_g2p.bin",
                            "voices_v3_turbo.json", "vieneu_prefill.onnx", "vieneu_decode_step.onnx",
                            "vieneu_acoustic_cached.onnx", "vieneu_backbone_shared.data",
                            "moss_audio_tokenizer_decode_full.onnx", "moss_audio_tokenizer_decode_shared.data"]
            for name in expected where !FileManager.default.fileExists(atPath: assets.appendingPathComponent(name).path) {
                missing.append(name)
            }
        }
        var info: [String: Any] = [
            "engine": turboText,
            "engineKind": "vieneu-turbo (10 giọng 3 miền) + render trước cả cuốn",
            "lastSynthEngine": sEngine,
            "engineError": ee,
            "initSteps": steps,
            "assetsFound": assetsFound,
            "assetsMissing": missing,
            "synthLastMs": sLast,
            "synthLastChars": sChars,
            "synthAvgMs": sAvg,
            "synthSteps": sSteps,
            "engines": "\(poolTotal)/\(maxEngines) (rảnh \(poolIdle))",
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        for (k, v) in BookRenderer.shared.stats() { info[k] = v }
        return info
    }

    /// Dọn một lần hai kho đĩa của pipeline cũ (trước 2.2.0 app không lưu
    /// audio đã đọc). Kho render mới nằm ở SachNoi/TTSRender — không đụng.
    private func purgeLegacyAudioStores() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: caches.appendingPathComponent("tts-cache", isDirectory: true))
        try? fm.removeItem(at: support.appendingPathComponent("tts-audio", isDirectory: true))
    }
}
