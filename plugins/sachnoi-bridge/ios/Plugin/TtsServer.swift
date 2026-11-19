import Foundation
import AVFoundation

/// Mặt tiền tổng hợp giọng nói của app (NativePlayer, BookRenderer và
/// plugin gọi: start / warmup / synthesizeSync / diagnostics / systemVoices).
///
/// 3.0.0 — NHẸ NHẤT CÓ THỂ (lệnh của anh sau khi xoá bản 2.2.0: "hoạt động
/// nhẹ nhất có thể, và chạy thật tốt"): BỎ TOÀN BỘ engine VieNeu (Turbo
/// 260MB, sinh chậm hơn tốc độ nghe, đốt CPU làm máy nóng và bị iOS giết
/// khi chạy nền; Nano chết vì tensor bool). Engine duy nhất là GIỌNG HỆ
/// THỐNG iOS qua AVSpeechSynthesizer.write:
///  * 0 MB model trong app (giọng "Linh" có sẵn trong mọi iPhone; bản
///    "Linh nâng cao" do người dùng tải trong Cài đặt iOS nếu muốn);
///  * là engine của chính Apple: nhẹ CPU, không nóng máy, chạy nền là
///    sân nhà của nó — khoá màn hình vẫn đọc (NativePlayer giữ nguyên);
///  * sinh nhanh hơn thời gian thực nên cơ chế render trước cả cuốn
///    (BookRenderer + RenderStore) chạy nhẹ nhàng, không tranh CPU.
/// Đánh đổi nói thẳng: chỉ có giọng hệ thống (không còn 10 giọng 3 miền
/// của VieNeu). synthesizeSync vẫn trả WAV PCM16 như cũ nên NativePlayer,
/// RenderStore và BookRenderer không phải đổi một dòng nào.
final class TtsServer {
    static let shared = TtsServer()

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

    /// Mọi id giọng lạ (giọng VieNeu cũ, "default") đều rơi về giọng hệ
    /// thống tốt nhất hiện có — không bao giờ lỗi.
    static func resolveSystemVoice(_ voice: String) -> AVSpeechSynthesisVoice? {
        let list = vietnameseVoices()
        if let match = list.first(where: { $0.identifier == voice || $0.name == voice }) { return match }
        return list.first ?? AVSpeechSynthesisVoice(language: "vi-VN")
    }

    /// Danh sách giọng cho plugin/web: id = identifier của iOS.
    func systemVoices() -> [[String: String]] {
        Self.vietnameseVoices().map {
            ["id": $0.identifier, "name": $0.name, "language": $0.language]
        }
    }

    // Tổng hợp nối tiếp qua MỘT synthesizer (AVSpeechSynthesizer.write
    // không an toàn khi gọi chồng nhau) — engine hệ thống đủ nhanh nên
    // nối tiếp vẫn nhanh hơn thời gian thực nhiều lần.
    private let synthQueue = DispatchQueue(label: "app.sachnoi.systemtts", qos: .userInitiated)
    private let synthesizer = AVSpeechSynthesizer()

    private enum EngineState {
        case notStarted, loading, ready, failed(String)
    }
    private let stateLock = NSLock()
    private var engineState: EngineState = .notStarted
    private var lastEngineError: String?

    // Thống kê tốc độ tổng hợp cho tab Chẩn đoán (giữ tên khoá như cũ).
    private var synthLastMs = 0
    private var synthLastChars = 0
    private var synthAvgMs = 0
    private var synthSteps = ""
    private var synthEngine = ""
    private var lastSampleRate = 22050

    /// Khoảng lặng tại dấu câu do người dùng đặt — từ 3.0.0 do NativePlayer
    /// áp giữa các đoạn khi phát (giọng hệ thống tự xử lý dấu câu bên trong
    /// đoạn); giữ thuộc tính để plugin/mặt tiền không đổi.
    var punctPauseSeconds: Double = 0.3
    var paraPauseSeconds: Double = 0.7

    private init() {}

    func start() {
        warmup()
    }

    /// Nạp giọng hệ thống sẵn ở nền ngay khi app mở (lần write đầu tiên
    /// thường chậm vì iOS phải nạp giọng).
    func warmup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.synthesizeSync(text: "Sẵn sàng.", voice: "default")
        }
    }

    // MARK: - Tổng hợp

    func synthesizeSync(text: String, voice: String) throws -> Data {
        try synthQueue.sync { try synthesizeSerialized(text: text, voice: voice) }
    }

    private func synthesizeSerialized(text: String, voice: String) throws -> Data {
        stateLock.lock()
        if case .notStarted = engineState { engineState = .loading }
        stateLock.unlock()
        let t0 = Date()
        guard let sysVoice = Self.resolveSystemVoice(voice) else {
            let msg = "Thiết bị không có giọng tiếng Việt"
            stateLock.lock(); engineState = .failed(msg); lastEngineError = msg; stateLock.unlock()
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
        engineState = .ready
        lastEngineError = nil
        synthLastMs = ms
        synthLastChars = text.count
        synthAvgMs = synthAvgMs == 0 ? ms : (synthAvgMs * 3 + ms) / 4
        synthEngine = "system"
        lastSampleRate = sampleRate
        let seconds = Double(pcm.count) / 2.0 / Double(sampleRate)
        synthSteps = "giọng \(sysVoice.name) · wav \(String(format: "%.1f", seconds))s"
        stateLock.unlock()
        return Self.wavData(pcm16: pcm, sampleRate: sampleRate)
    }

    /// Đóng gói PCM16 mono thành WAV (44 byte header) — định dạng mọi tầng
    /// phía trên (NativePlayer/RenderStore) đã quen từ thời VieNeu.
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
        let sLast = synthLastMs, sChars = synthLastChars, sAvg = synthAvgMs
        let sSteps = synthSteps, sEngine = synthEngine
        let stateText: String
        switch engineState {
        case .notStarted: stateText = "notStarted"
        case .loading: stateText = "loading"
        case .ready: stateText = "ready"
        case .failed(let m): stateText = "failed: \(m)"
        }
        stateLock.unlock()
        let voices = Self.vietnameseVoices()
        var info: [String: Any] = [
            "engine": stateText,
            "engineKind": "giọng hệ thống iOS (AVSpeechSynthesizer) + render trước cả cuốn",
            "lastSynthEngine": sEngine,
            "engineError": ee,
            "initSteps": voices.map { "\($0.name) (\($0.language), q\($0.quality.rawValue))" }.joined(separator: " · "),
            "assetsFound": true,
            "assetsMissing": [String](),
            "synthLastMs": sLast,
            "synthLastChars": sChars,
            "synthAvgMs": sAvg,
            "synthSteps": sSteps,
            "engines": "1 (hệ thống)",
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        for (k, v) in BookRenderer.shared.stats() { info[k] = v }
        return info
    }
}
