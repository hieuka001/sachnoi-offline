import Foundation

/// Mặt tiền tổng hợp giọng nói của app (NativePlayer và plugin gọi:
/// start / warmup / synthesizeSync / diagnostics / getVoiceStore).
///
/// 2.1.0 — THUẦN VieNeu, HAI engine sau một mặt tiền (lệnh của anh: "vừa
/// VieNeu vừa mượt"):
///  * **Nano** (VieNeu-TTS v3 Nano): model flow, số bước cố định, nhanh hơn
///    thời gian thực trên CPU yếu -> nghe LIỀN MẠCH. 11 giọng preset, 24kHz.
///    Giọng chọn bằng id "nano/<Tên preset>".
///  * **Turbo** (VieNeu-TTS v3 Turbo int8): 25 giọng 3 miền, 48kHz, chất
///    lượng cao nhất nhưng sinh từng khung hình nên chậm trên máy yếu
///    (số liệu 1.9.6: ~9,8s cho 6,2s tiếng). Hồ 2 engine song song như 1.9.5.
/// sherpa-onnx/Piper của 2.0.0 đã GỠ (anh chốt thuần VieNeu) cùng server
/// HTTP 127.0.0.1:3900 từ thời pipeline cũ — bề mặt duy nhất là synthesizeSync.
final class TtsServer {
    static let shared = TtsServer()

    static let nanoPrefix = "nano/"

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
    /// giữa các đoạn khi phát cho cả hai engine.
    var punctPauseSeconds: Double = 0.3
    var paraPauseSeconds: Double = 0.7

    private enum EngineState {
        case notStarted, loading, ready, failed(String)
    }
    private let stateLock = NSLock()
    private var turboState: EngineState = .notStarted
    private var nanoState: EngineState = .notStarted
    private var lastEngineError: String?
    private var initStepsText = ""
    private var nanoInitStepsText = ""
    private var voiceStore: VoiceStore?

    // Thống kê tốc độ tổng hợp cho tab Chẩn đoán (giữ tên khoá như 1.9.x).
    private var synthLastMs = 0
    private var synthLastChars = 0
    private var synthAvgMs = 0
    private var synthSteps = ""
    private var synthEngine = ""

    // ── Engine Nano (đơn, khoá nối tiếp) ──
    private var nanoEngine: NanoEngine?
    private let nanoLock = NSLock()
    private let nanoSynthLock = NSLock()

    private func setTurboState(_ v: EngineState) { stateLock.lock(); turboState = v; stateLock.unlock() }
    private func setNanoState(_ v: EngineState) { stateLock.lock(); nanoState = v; stateLock.unlock() }
    private func setEngineError(_ v: String?) { stateLock.lock(); lastEngineError = v; stateLock.unlock() }

    func start() {
        purgeLegacyAudioStores()
        warmup()
    }

    /// Nạp sẵn cả hai engine ở nền ngay khi app mở: Nano trước (nhẹ, là
    /// đường nghe mượt), rồi tới hồ Turbo — tuần tự để không tranh CPU.
    func warmup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = try? self.getNanoEngine()
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

    // MARK: - Nano

    func nanoAssetsURL() throws -> URL {
        guard let assets = PackStore.nanoAssetsURL() else {
            throw NanoEngine.EngineError.asset("NanoAssets (chưa gắn sẵn trong app)")
        }
        return assets
    }

    private func getNanoEngine() throws -> NanoEngine {
        nanoLock.lock()
        defer { nanoLock.unlock() }
        if let nanoEngine { return nanoEngine }
        setNanoState(.loading)
        do {
            let created = try NanoEngine(assetsDir: nanoAssetsURL(),
                                         g2pPath: assetsURL().appendingPathComponent("sea_g2p.bin").path)
            nanoEngine = created
            setNanoState(.ready)
            stateLock.lock(); nanoInitStepsText = NanoEngine.lastInitSteps; stateLock.unlock()
            return created
        } catch {
            setNanoState(.failed(error.localizedDescription))
            setEngineError(error.localizedDescription)
            throw error
        }
    }

    /// Danh sách giọng Nano cho plugin (id có tiền tố "nano/" để định tuyến).
    func nanoVoiceList() -> [[String: String]] {
        guard let engine = try? getNanoEngine() else { return [] }
        return engine.voices.map {
            ["id": Self.nanoPrefix + $0.name, "name": "\($0.name) · Nano (mượt)", "language": "vi"]
        }
    }

    // MARK: - Tổng hợp (định tuyến theo giọng)

    func synthesizeSync(text: String, voice: String) throws -> Data {
        try synthesizeNow(text: text, voice: voice)
    }

    func synthesizeNow(text: String, voice: String) throws -> Data {
        let t0 = Date()
        let data: Data
        let kind: String
        // 2.1.0: "Giọng mặc định" (default/rỗng) đi đường NANO — mặc định
        // nghe sách phải mượt; giọng Turbo chọn tường minh theo tên preset.
        let isNano = voice.hasPrefix(Self.nanoPrefix) || voice.isEmpty || voice == "default"
        if isNano {
            let engine = try getNanoEngine()
            nanoSynthLock.lock()
            do {
                let preset = voice.hasPrefix(Self.nanoPrefix) ? String(voice.dropFirst(Self.nanoPrefix.count)) : nil
                data = try engine.synthesize(text: text, voiceName: preset)
            } catch {
                nanoSynthLock.unlock()
                throw error
            }
            nanoSynthLock.unlock()
            kind = "nano"
            stateLock.lock(); synthSteps = NanoEngine.lastSynthSteps; stateLock.unlock()
        } else {
            let engine = try acquireEngine()
            do {
                data = try engine.synthesize(text: text, voiceName: voice.isEmpty ? nil : voice,
                                             punctPause: punctPauseSeconds, paraPause: paraPauseSeconds)
            } catch {
                releaseEngine(engine)
                throw error
            }
            releaseEngine(engine)
            kind = "turbo"
            stateLock.lock(); synthSteps = VieNeuEngine.lastSynthSteps; stateLock.unlock()
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        stateLock.lock()
        synthLastMs = ms
        synthLastChars = text.count
        synthAvgMs = synthAvgMs == 0 ? ms : (synthAvgMs * 3 + ms) / 4
        synthEngine = kind
        // WAV 44 byte header + PCM16: suy độ dài tiếng để đối chiếu tốc độ.
        let rate = kind == "nano" ? NanoEngine.sampleRate : VieNeuEngine.sampleRate
        let seconds = Double(max(0, data.count - 44)) / 2.0 / Double(rate)
        synthSteps += " · wav \(String(format: "%.1f", seconds))s"
        stateLock.unlock()
        return data
    }

    // MARK: - Chẩn đoán

    func diagnostics() -> [String: Any] {
        stateLock.lock()
        let ee = lastEngineError ?? ""
        let steps = initStepsText
        let nanoSteps = nanoInitStepsText
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
        let nanoText = text(nanoState)
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
        var nanoFound = false
        var nanoMissing: [String] = []
        if let assets = PackStore.nanoAssetsURL() {
            nanoFound = true
            for name in ["text_encoder.onnx", "duration_predictor.onnx", "vector_estimator.onnx",
                         "codec_decoder.onnx", "config.json", "constants.json", "voices_v3_nano.json"]
            where !FileManager.default.fileExists(atPath: assets.appendingPathComponent(name).path) {
                nanoMissing.append(name)
            }
        }
        return [
            "engine": turboText,
            "engineKind": "vieneu-turbo (25 giọng) + vieneu-nano (11 giọng, mượt)",
            "lastSynthEngine": sEngine,
            "nanoEngine": nanoText,
            "engineError": ee,
            "initSteps": steps,
            "nanoInitSteps": nanoSteps,
            "assetsFound": assetsFound,
            "assetsMissing": missing,
            "nanoAssetsFound": nanoFound,
            "nanoAssetsMissing": nanoMissing,
            "synthLastMs": sLast,
            "synthLastChars": sChars,
            "synthAvgMs": sAvg,
            "synthSteps": sSteps,
            "engines": "\(poolTotal)/\(maxEngines) (rảnh \(poolIdle))",
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        ]
    }

    /// Đợt 31: app KHÔNG lưu lại âm thanh đã đọc. Dọn một lần hai kho đĩa
    /// của các đợt cũ nếu còn sót trên máy.
    private func purgeLegacyAudioStores() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: caches.appendingPathComponent("tts-cache", isDirectory: true))
        try? fm.removeItem(at: support.appendingPathComponent("tts-audio", isDirectory: true))
    }
}
