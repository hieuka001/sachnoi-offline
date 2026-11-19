import Foundation
import AVFoundation
import UIKit

/// Mặt tiền tổng hợp giọng nói của app (NativePlayer, BookRenderer và
/// plugin gọi: start / warmup / synthesizeSync / diagnostics).
///
/// 3.1.0 — LAI theo lệnh của anh: nền NHẸ của 3.0.0 + thêm 4 giọng VieNeu.
///  * **Giọng hệ thống iOS** (AVSpeechSynthesizer, giọng "Linh") là MẶC
///    ĐỊNH: 0 MB model, nhẹ CPU, không nóng máy, khoá màn hình vẫn đọc —
///    đường an toàn cho việc nghe hằng ngày.
///  * **4 giọng VieNeu Turbo** chọn tường minh mới đi đường engine cũ:
///    Trúc Ly (Bắc, nữ), Hải Đăng (Bắc, nam), Thùy Dung (Nam, nữ),
///    Thái Sơn (Nam, nam). Core Turbo int8 260MB gắn sẵn như trước; hồ
///    2 engine như 1.9.5. Đánh đổi đã biết: đường VieNeu sinh chậm và
///    nóng máy hơn — cơ chế render trước cả cuốn (BookRenderer +
///    RenderStore) gánh phần liền mạch cho cả hai đường.
/// Nano vẫn bỏ hẳn (đã chết trên máy thật ở 2.1.0). synthesizeSync luôn
/// trả WAV PCM16 nên NativePlayer/RenderStore/BookRenderer không đổi.
final class TtsServer {
    static let shared = TtsServer()

    /// 4 giọng VieNeu Turbo của bản 3.1.0 (Bắc/Nam × nam/nữ). Phải khớp
    /// voices.json. Mọi id khác (giọng VieNeu ngoài bộ 4, "default", id
    /// giọng hệ thống) đều đi đường giọng hệ thống.
    static let vieneuVoices = ["Trúc Ly", "Hải Đăng", "Thùy Dung", "Thái Sơn"]

    static func isVieNeu(_ voice: String) -> Bool { vieneuVoices.contains(voice) }

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

    // MARK: - Hồ engine VieNeu Turbo (1.9.5)

    private let maxEngines: Int
    private let poolLock = NSLock()
    private var idleEngines: [VieNeuEngine] = []
    private var totalEngines = 0

    private init() {
        maxEngines = ProcessInfo.processInfo.physicalMemory >= 3_000_000_000 ? 2 : 1
        // 3.2.1: vòng đời hồ engine theo vòng đời app — vào nền/cảnh báo
        // bộ nhớ thì xả hồ (nhả RAM cho tầng phát), quay lại tiền cảnh thì
        // cho phép giữ hồ trở lại.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.drainPool()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.drainPool()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refillPoolAllowed()
        }
    }

    /// Khoảng lặng tại dấu câu do người dùng đặt — engine Turbo áp bên
    /// trong; đường hệ thống do NativePlayer áp giữa các đoạn khi phát.
    var punctPauseSeconds: Double = 0.3
    var paraPauseSeconds: Double = 0.7

    private enum EngineState {
        case notStarted, loading, ready, failed(String)
    }
    private let stateLock = NSLock()
    private var turboState: EngineState = .notStarted
    private var systemState: EngineState = .notStarted
    private var lastEngineError: String?
    private var initStepsText = ""
    private var voiceStore: VoiceStore?

    // Thống kê tốc độ tổng hợp cho tab Chẩn đoán (giữ tên khoá như cũ).
    private var synthLastMs = 0
    private var synthLastChars = 0
    private var synthAvgMs = 0
    private var synthSteps = ""
    private var synthEngine = ""

    private func setTurboState(_ v: EngineState) { stateLock.lock(); turboState = v; stateLock.unlock() }
    private func setEngineError(_ v: String?) { stateLock.lock(); lastEngineError = v; stateLock.unlock() }

    func start() {
        warmup()
    }

    /// Nạp ấm ở nền ngay khi app mở: CHỈ giọng hệ thống (nhẹ, là mặc định).
    /// 3.2.1: KHÔNG dựng hồ Turbo lúc mở app nữa — 2 engine ONNX giữ hàng
    /// trăm MB RAM thường trực dù người dùng không hề chọn giọng VieNeu,
    /// và khi app vào nền iOS siết bộ nhớ gắt -> jetsam giết app (máy thật
    /// 3.2.0: văng app + mất chạy nền). Hồ chỉ dựng LƯỜI khi có yêu cầu
    /// giọng VieNeu thật (acquireEngine tự dựng), và bị XẢ khi app vào
    /// nền hoặc hệ thống cảnh báo bộ nhớ (xem drainPool).
    func warmup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = try? self.synthesizeSync(text: "Sẵn sàng.", voice: "default")
        }
    }

    /// Xả hồ engine Turbo: huỷ mọi engine đang rảnh và cấm giữ lại engine
    /// vừa dùng xong (releaseEngine thả rơi thay vì cất hồ) cho tới khi
    /// app quay lại tiền cảnh. Engine đang bận tổng hợp thì dùng xong tự
    /// rơi. Gọi khi app vào nền + khi iOS cảnh báo bộ nhớ.
    private var poolDrained = false
    func drainPool() {
        poolLock.lock()
        poolDrained = true
        totalEngines -= idleEngines.count
        idleEngines.removeAll()
        poolLock.unlock()
    }

    func refillPoolAllowed() {
        poolLock.lock()
        poolDrained = false
        poolLock.unlock()
    }

    // MARK: - VieNeu Turbo

    func assetsURL() throws -> URL {
        guard let assets = PackStore.vieneuAssetsURL() else {
            throw VieNeuEngine.EngineError.asset("TTSAssets (chưa tải gói core VieNeu)")
        }
        return assets
    }

    /// Danh sách giọng Turbo đọc thẳng từ file preset — không cần dựng engine.
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
        poolLock.lock()
        if poolDrained {
            // Hồ đang xả (app ở nền / thiếu bộ nhớ): thả rơi engine thay vì
            // giữ lại — nhả RAM ngay. Lần cần tới acquireEngine dựng mới.
            totalEngines -= 1
            poolLock.unlock()
            return
        }
        idleEngines.append(e)
        poolLock.unlock()
    }

    // MARK: - Tổng hợp (định tuyến theo giọng)

    func synthesizeSync(text: String, voice: String) throws -> Data {
        if Self.isVieNeu(voice) {
            return try synthesizeTurbo(text: text, voice: voice)
        }
        return try synthQueue.sync { try synthesizeSystem(text: text, voice: voice) }
    }

    private func synthesizeTurbo(text: String, voice: String) throws -> Data {
        let t0 = Date()
        let engine = try acquireEngine()
        let data: Data
        do {
            data = try engine.synthesize(text: text, voiceName: voice,
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
        let seconds = Double(max(0, data.count - 44)) / 2.0 / Double(VieNeuEngine.sampleRate)
        synthSteps += " · wav \(String(format: "%.1f", seconds))s"
        stateLock.unlock()
        return data
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
        let turboText = text(turboState)
        let systemText = text(systemState)
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
        let voices = Self.vietnameseVoices()
        var info: [String: Any] = [
            "engine": turboText,
            "engineKind": "giọng hệ thống iOS (mặc định) + vieneu-turbo (4 giọng) + render trước cả cuốn",
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
            "engines": "\(poolTotal)/\(maxEngines) (rảnh \(poolIdle))",
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        for (k, v) in BookRenderer.shared.stats() { info[k] = v }
        return info
    }
}
