import Foundation

/// Mặt tiền tổng hợp giọng nói của app (giữ nguyên bề mặt mà NativePlayer
/// và plugin đang gọi: start / warmup / synthesizeSync / diagnostics).
///
/// 2.0.0 — THAY LÕI: engine VieNeu tự port + server HTTP 127.0.0.1:3900 +
/// hồ engine song song đều đã XOÁ (mã thừa tích từ thời Bút Nghiên, và
/// VieNeu sinh từng khung hình quá chậm trên máy yếu — xem SherpaTts.swift).
/// Nay chỉ còn: MỘT SherpaTtsEngine (sherpa-onnx + Piper tiếng Việt gắn
/// sẵn), một khoá nối tiếp các lần tổng hợp, và thống kê tốc độ cho tab
/// Chẩn đoán. Khoảng nghỉ giữa các đoạn do NativePlayer áp khi phát
/// (gapPunct/gapParagraph), không nằm trong engine nữa.
final class TtsServer {
    static let shared = TtsServer()
    private init() {}

    /// Giọng duy nhất của model Piper gắn sẵn — plugin ttsVoices trả về
    /// đúng mục này; web hiển thị từ voices.json (khớp id "vais1000").
    static let voiceList: [[String: String]] = [
        ["id": "vais1000", "name": "Vais1000 · Piper (gắn sẵn)", "language": "vi"],
    ]

    private var engine: SherpaTtsEngine?
    private let engineLock = NSLock()
    /// SherpaOnnxOfflineTts không an toàn đa luồng -> mọi lần tổng hợp
    /// (đoạn đang phát + prefetch + nghe thử) xếp hàng qua khoá này.
    private let synthLock = NSLock()

    private enum EngineState {
        case notStarted, loading, ready, failed(String)
    }
    private var engineState: EngineState = .notStarted
    private var lastEngineError: String?

    // Thống kê tốc độ tổng hợp cho tab Chẩn đoán (giữ cùng tên khoá như
    // các bản 1.9.x để ảnh chụp của anh đối chiếu được qua các bản).
    private var synthLastMs = 0
    private var synthLastChars = 0
    private var synthAvgMs = 0
    private var synthSteps = ""

    func start() {
        purgeLegacyAudioStores()
        warmup()
    }

    /// Nạp engine ở nền ngay khi app mở để lần bấm Nghe đầu tiên không chờ.
    func warmup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.getEngine()
        }
    }

    func assetsURL() throws -> URL {
        guard let assets = Bundle.main.url(forResource: "PiperAssets", withExtension: nil) else {
            throw SherpaTtsEngine.EngineError.asset("PiperAssets (chưa gắn sẵn trong app)")
        }
        return assets
    }

    private func getEngine() throws -> SherpaTtsEngine {
        engineLock.lock()
        defer { engineLock.unlock() }
        if let engine { return engine }
        engineState = .loading
        do {
            let created = try SherpaTtsEngine(assetsDir: assetsURL())
            engine = created
            engineState = .ready
            lastEngineError = nil
            return created
        } catch {
            engineState = .failed(error.localizedDescription)
            lastEngineError = error.localizedDescription
            throw error
        }
    }

    /// Tổng hợp 1 đoạn -> WAV. Tham số voice giữ cho khớp nơi gọi cũ;
    /// model Piper gắn sẵn chỉ có một giọng nên voice được bỏ qua.
    func synthesizeSync(text: String, voice: String) throws -> Data {
        try synthesizeNow(text: text, voice: voice)
    }

    func synthesizeNow(text: String, voice: String) throws -> Data {
        let engine = try getEngine()
        synthLock.lock()
        defer { synthLock.unlock() }
        let t0 = Date()
        let data = try engine.synthesize(text)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        engineLock.lock()
        synthLastMs = ms
        synthLastChars = text.count
        synthAvgMs = synthAvgMs == 0 ? ms : (synthAvgMs * 3 + ms) / 4
        // WAV 44 byte header + PCM16: suy ra độ dài tiếng để đối chiếu tốc độ.
        let seconds = Double(max(0, data.count - 44)) / 2.0 / Double(engine.sampleRate)
        synthSteps = "sherpa-piper · wav \(String(format: "%.1f", seconds))s · \(engine.sampleRate)Hz"
        engineLock.unlock()
        return data
    }

    /// Ảnh chụp trạng thái cho tab Chẩn đoán (plugin ttsDiagnostics gọi).
    func diagnostics() -> [String: Any] {
        engineLock.lock()
        let stateText: String
        switch engineState {
        case .notStarted: stateText = "notStarted"
        case .loading: stateText = "loading"
        case .ready: stateText = "ready"
        case .failed(let msg): stateText = "failed: \(msg)"
        }
        let ee = lastEngineError ?? ""
        let sLast = synthLastMs, sChars = synthLastChars, sAvg = synthAvgMs
        let steps = synthSteps
        let rate = engine?.sampleRate ?? 0
        engineLock.unlock()

        var missing: [String] = []
        var found = false
        if let assets = try? assetsURL() {
            found = true
            for name in ["vi_VN-vais1000-medium.onnx", "tokens.txt", "espeak-ng-data"]
            where !FileManager.default.fileExists(atPath: assets.appendingPathComponent(name).path) {
                missing.append(name)
            }
        }
        return [
            "engine": stateText,
            "engineKind": SherpaTtsEngine.kind,
            "engineError": ee,
            "sampleRate": rate,
            "assetsFound": found,
            "assetsMissing": missing,
            "synthLastMs": sLast,
            "synthLastChars": sChars,
            "synthAvgMs": sAvg,
            "synthSteps": steps,
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
