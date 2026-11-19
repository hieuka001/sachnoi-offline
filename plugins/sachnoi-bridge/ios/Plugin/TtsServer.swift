import Foundation
import AVFoundation

/// Mặt tiền tổng hợp giọng nói của app (NativePlayer, BookRenderer và
/// plugin gọi: start / warmup / synthesizeSync / diagnostics).
///
/// 3.3.0 — BẢN THỬ SUPERTONIC theo lệnh của anh (sau khi số liệu máy thật
/// 3.2.1 chốt hạ VieNeu Turbo: sinh chậm hơn thời gian thực ~4,4 lần —
/// nghe chờ từng đoạn, không chạy nền nổi; Turbo đã gỡ hẳn ở bản này):
///  * **Giọng hệ thống iOS** (AVSpeechSynthesizer, giọng "Linh") vẫn là
///    MẶC ĐỊNH: 0 MB model, nhẹ CPU, khoá màn hình vẫn đọc — đường an
///    toàn cho việc nghe hằng ngày.
///  * **10 giọng Supertonic 3** qua sherpa-onnx (SupertonicEngine): mô
///    hình flow int8 ~145MB gắn sẵn, 5 nữ (F1–F5) + 5 nam (M1–M5),
///    lang "vi". Kỳ vọng nhanh hơn thời gian thực nhiều lần; chất giọng
///    tiếng Việt là thứ bản thử này cần anh nghe để quyết định.
/// synthesizeSync luôn trả WAV PCM16 nên NativePlayer/RenderStore/
/// BookRenderer không đổi.
final class TtsServer {
    static let shared = TtsServer()

    /// 10 giọng Supertonic: id -> (tên hiển thị, sid trong voice.bin).
    /// sid 0–4 = F1–F5 (nữ), 5–9 = M1–M5 (nam) theo đúng thứ tự gói của
    /// sherpa-onnx. Phải khớp voices.json.
    static let supertonicPresets: [(id: String, name: String, sid: Int32)] = [
        ("supertonic/F1", "Nữ 1 (Supertonic)", 0),
        ("supertonic/F2", "Nữ 2 (Supertonic)", 1),
        ("supertonic/F3", "Nữ 3 (Supertonic)", 2),
        ("supertonic/F4", "Nữ 4 (Supertonic)", 3),
        ("supertonic/F5", "Nữ 5 (Supertonic)", 4),
        ("supertonic/M1", "Nam 1 (Supertonic)", 5),
        ("supertonic/M2", "Nam 2 (Supertonic)", 6),
        ("supertonic/M3", "Nam 3 (Supertonic)", 7),
        ("supertonic/M4", "Nam 4 (Supertonic)", 8),
        ("supertonic/M5", "Nam 5 (Supertonic)", 9),
    ]

    static func isSupertonic(_ voice: String) -> Bool {
        supertonicPresets.contains { $0.id == voice }
    }

    static func supertonicSid(_ voice: String) -> Int32? {
        supertonicPresets.first { $0.id == voice }?.sid
    }

    // MARK: - Giọng hệ thống iOS

    /// Giọng tiếng Việt của hệ thống, ưu tiên bản nâng cao (enhanced /
    /// premium) nếu người dùng đã tải trong Cài đặt iOS.
    static func vietnameseVoices() -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("vi") }
        return all.sorted { a, b in qualityRank(a) > qualityRank(b) }
    }

    private static func qualityRank(_ v: AVSpeechSynthesisVoice) -> Int {
        // rawValue: default=1, enhanced=2, premium=3 — dùng rawValue để
        // không dính availability của case .premium (chỉ có từ iOS 16,
        // app hỗ trợ từ iOS 13).
        v.quality.rawValue
    }

    static func resolveSystemVoice(_ voice: String) -> AVSpeechSynthesisVoice? {
        let list = vietnameseVoices()
        if let match = list.first(where: { $0.identifier == voice || $0.name == voice }) { return match }
        return list.first ?? AVSpeechSynthesisVoice(language: "vi-VN")
    }

    /// Danh sách giọng hệ thống cho plugin (id = identifier của iOS).
    func systemVoices() -> [[String: String]] {
        Self.vietnameseVoices().map {
            ["id": $0.identifier, "name": $0.name, "language": $0.language]
        }
    }

    // Tổng hợp hệ thống nối tiếp qua MỘT synthesizer (write không an toàn
    // khi gọi chồng nhau) — engine của Apple đủ nhanh khi nối tiếp.
    private let synthQueue = DispatchQueue(label: "app.sachnoi.systemtts", qos: .userInitiated)
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Engine Supertonic (một bản duy nhất, nối tiếp)

    // sherpa-onnx không an toàn đa luồng -> MỌI lần sinh Supertonic (tầng
    // phát + renderer) đều nối tiếp qua hàng đợi này. Engine dựng LƯỜI ở
    // lần gọi đầu tiên và giữ thường trực: khác hồ Turbo ngày trước,
    // Supertonic là cửa duy nhất cho 10 giọng này và việc nghe nền cần nó
    // sống khi app ở nền (sinh theo yêu cầu của tầng phát, chu kỳ thấp).
    private let superQueue = DispatchQueue(label: "app.sachnoi.supertonic", qos: .userInitiated)
    private var superEngine: SupertonicEngine?

    private init() {}

    /// Khoảng lặng tại dấu câu do người dùng đặt — NativePlayer áp giữa
    /// các đoạn khi phát (mọi engine).
    var punctPauseSeconds: Double = 0.3
    var paraPauseSeconds: Double = 0.7

    private enum EngineState {
        case notStarted, loading, ready, failed(String)
    }
    private let stateLock = NSLock()
    private var superState: EngineState = .notStarted
    private var systemState: EngineState = .notStarted
    private var lastEngineError: String?
    private var initStepsText = ""

    // Thống kê tốc độ tổng hợp cho tab Chẩn đoán (giữ tên khoá như cũ).
    private var synthLastMs = 0
    private var synthLastChars = 0
    private var synthAvgMs = 0
    private var synthSteps = ""
    private var synthEngine = ""

    private func setSuperState(_ v: EngineState) { stateLock.lock(); superState = v; stateLock.unlock() }
    private func setEngineError(_ v: String?) { stateLock.lock(); lastEngineError = v; stateLock.unlock() }

    func start() {
        warmup()
    }

    /// Nạp ấm ở nền ngay khi app mở: CHỈ giọng hệ thống (nhẹ, là mặc
    /// định). Engine Supertonic dựng lười ở lần chọn giọng đầu tiên —
    /// không giữ ~145MB model thường trực cho người chỉ nghe giọng hệ
    /// thống (bài học jetsam của hồ Turbo ở 3.2.0).
    func warmup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = try? self.synthesizeSync(text: "Sẵn sàng.", voice: "default")
        }
    }

    // MARK: - Supertonic

    /// Engine dùng chung, dựng một lần. PHẢI gọi trên superQueue.
    private func engineLocked() throws -> SupertonicEngine {
        if let superEngine { return superEngine }
        stateLock.lock()
        if case .failed(let msg) = superState {
            stateLock.unlock()
            throw SupertonicEngine.EngineError.asset("engine lỗi: \(msg)")
        }
        stateLock.unlock()
        setSuperState(.loading)
        let t0 = Date()
        do {
            guard let assets = PackStore.supertonicAssetsURL() else {
                throw SupertonicEngine.EngineError.asset("SupertonicAssets (chưa gắn sẵn trong app)")
            }
            let created = try SupertonicEngine(assetsDir: assets)
            superEngine = created
            setSuperState(.ready)
            stateLock.lock()
            initStepsText = "dựng engine Supertonic trong \(Int(Date().timeIntervalSince(t0) * 1000))ms · \(created.numSpeakers) giọng · \(created.sampleRate)Hz"
            stateLock.unlock()
            setEngineError(nil)
            return created
        } catch {
            setSuperState(.failed(error.localizedDescription))
            setEngineError(error.localizedDescription)
            throw error
        }
    }

    private func synthesizeSupertonic(text: String, voice: String) throws -> Data {
        guard let sid = Self.supertonicSid(voice) else {
            throw SupertonicEngine.EngineError.asset("không rõ giọng Supertonic: \(voice)")
        }
        let t0 = Date()
        let data = try superQueue.sync { try engineLocked().synthesize(text, sid: sid) }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        stateLock.lock()
        synthLastMs = ms
        synthLastChars = text.count
        synthAvgMs = synthAvgMs == 0 ? ms : (synthAvgMs * 3 + ms) / 4
        synthEngine = "supertonic"
        let seconds = Double(max(0, data.count - 44)) / 2.0 / 44100.0
        synthSteps = "supertonic sid \(sid) · wav \(String(format: "%.1f", seconds))s"
        stateLock.unlock()
        return data
    }

    // MARK: - Tổng hợp (định tuyến theo giọng)

    func synthesizeSync(text: String, voice: String) throws -> Data {
        if Self.isSupertonic(voice) {
            return try synthesizeSupertonic(text: text, voice: voice)
        }
        return try synthQueue.sync { try synthesizeSystem(text: text, voice: voice) }
    }

    private func synthesizeSystem(text: String, voice: String) throws -> Data {
        stateLock.lock()
        if case .notStarted = systemState { systemState = .loading }
        stateLock.unlock()
        let t0 = Date()
        guard let sysVoice = Self.resolveSystemVoice(voice) else {
            let msg = "Thiết bị không có giọng tiếng Việt"
            stateLock.lock(); systemState = .failed(msg); lastEngineError = msg; stateLock.unlock()
            throw NSError(domain: "TtsServer", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = sysVoice
        // Tốc độ/tông/âm lượng để tầng phát (TimePitch) lo — file render
        // phải trung tính để đổi tốc độ không phải render lại.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        var pcm = Data()
        var sampleRate = 22050
        let sem = DispatchSemaphore(value: 0)
        synthesizer.write(utterance) { buffer in
            // Callback nhận AVAudioBuffer; thực tế luôn là AVAudioPCMBuffer,
            // buffer 0 frame = dấu hết câu. Không ép được kiểu thì coi như
            // hết để không treo (pcm rỗng sẽ bị chặn ở cửa dưới).
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { sem.signal(); return }
            if pcmBuffer.frameLength == 0 { sem.signal(); return }
            sampleRate = Int(pcmBuffer.format.sampleRate)
            guard let ch = pcmBuffer.floatChannelData?[0] else { return }
            let n = Int(pcmBuffer.frameLength)
            pcm.reserveCapacity(pcm.count + n * 2)
            for i in 0..<n {
                let v = max(-1.0, min(1.0, ch[i]))
                var s = Int16(v * 32767)
                withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
            }
        }
        if sem.wait(timeout: .now() + 60) == .timedOut {
            synthesizer.stopSpeaking(at: .immediate)
            let msg = "Giọng hệ thống quá 60 giây không trả âm thanh"
            stateLock.lock(); lastEngineError = msg; stateLock.unlock()
            throw NSError(domain: "TtsServer", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard !pcm.isEmpty else {
            let msg = "Giọng hệ thống trả về âm thanh rỗng"
            stateLock.lock(); lastEngineError = msg; stateLock.unlock()
            throw NSError(domain: "TtsServer", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        stateLock.lock()
        systemState = .ready
        lastEngineError = nil
        synthLastMs = ms
        synthLastChars = text.count
        synthAvgMs = synthAvgMs == 0 ? ms : (synthAvgMs * 3 + ms) / 4
        synthEngine = "system"
        let seconds = Double(pcm.count) / 2.0 / Double(sampleRate)
        synthSteps = "giọng \(sysVoice.name) · wav \(String(format: "%.1f", seconds))s"
        stateLock.unlock()
        return Self.wavData(pcm16: pcm, sampleRate: sampleRate)
    }

    /// Đóng gói PCM16 mono thành WAV (44 byte header) — định dạng mọi tầng
    /// phía trên (NativePlayer/RenderStore) đã quen.
    static func wavData(pcm16: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        u32(UInt32(36 + pcm16.count))
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        u32(UInt32(pcm16.count))
        d.append(pcm16)
        return d
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
        let superText = text(superState)
        let systemText = text(systemState)
        stateLock.unlock()

        var assetsFound = false
        var missing: [String] = []
        if let assets = PackStore.supertonicAssetsURL() {
            assetsFound = true
            for name in SupertonicEngine.assetFiles where !FileManager.default.fileExists(atPath: assets.appendingPathComponent(name).path) {
                missing.append(name)
            }
        }
        let voices = Self.vietnameseVoices()
        var info: [String: Any] = [
            "engine": superText,
            "engineKind": "giọng hệ thống iOS (mặc định) + supertonic-3 (10 giọng, sherpa-onnx) + render trước cả cuốn",
            "lastSynthEngine": sEngine,
            "systemEngine": systemText,
            "systemVoices": voices.map { "\($0.name) (q\($0.quality.rawValue))" }.joined(separator: " · "),
            "engineError": ee,
            "initSteps": steps,
            "assetsFound": assetsFound,
            "assetsMissing": missing,
            "synthLastMs": sLast,
            "synthLastChars": sChars,
            "synthAvgMs": sAvg,
            "synthSteps": sSteps,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        for (k, v) in BookRenderer.shared.stats() { info[k] = v }
        return info
    }
}
