import Foundation
import SherpaOnnxC

/// Engine Supertonic 3 (3.3.0 — BẢN THỬ theo lệnh của anh) qua sherpa-onnx
/// 1.13.8 (repo k2-fsa/sherpa-onnx, xcframework tĩnh chính thức, CI tải +
/// kiểm SHA-256) + model Supertonic 3 int8 gắn sẵn (SupertonicAssets:
/// 7 file, ~145MB, xuất bởi chính sherpa-onnx từ model của Supertone).
///
/// Vì sao thử engine này: VieNeu Turbo sinh âm từng khung hình
/// (autoregressive) — số liệu máy thật 3.2.1: 3,5 giây sinh cho 0,8 giây
/// tiếng (chậm hơn thời gian thực ~4,4 lần), nghe phải chờ từng đoạn và
/// không chạy nền nổi. Supertonic là mô hình FLOW (số bước cố định, không
/// sinh từng khung): nhà sản xuất công bố RTF 0,3 trên máy đọc sách yếu —
/// kỳ vọng nhanh hơn thời gian thực nhiều lần trên iPhone. 10 giọng style
/// F1–F5 (nữ, sid 0–4) và M1–M5 (nam, sid 5–9), dùng chung mọi ngôn ngữ;
/// tiếng Việt chọn bằng extra {"lang":"vi"} khi sinh. Chất giọng tiếng
/// Việt là ẩn số của bản thử — anh nghe và quyết định.
///
/// Engine KHÔNG an toàn đa luồng: nơi gọi (TtsServer) phải khoá nối tiếp.
final class SupertonicEngine {
    enum EngineError: Error, LocalizedError {
        case asset(String)
        case createFailed
        case generateFailed

        var errorDescription: String? {
            switch self {
            case .asset(let name): return "Thiếu file giọng Supertonic trong app: \(name)"
            case .createFailed: return "sherpa-onnx không tạo được engine Supertonic"
            case .generateFailed: return "sherpa-onnx (Supertonic) tổng hợp thất bại"
            }
        }
    }

    /// Tên hiển thị ở Chẩn đoán để đối chiếu bản thư viện/model đang chạy.
    static let kind = "sherpa-onnx 1.13.8 · Supertonic 3 int8"

    /// 7 file của gói model (khớp CI + diagnostics kiểm trong bundle).
    static let assetFiles = ["duration_predictor.int8.onnx", "text_encoder.int8.onnx",
                             "vector_estimator.int8.onnx", "vocoder.int8.onnx",
                             "tts.json", "unicode_indexer.bin", "voice.bin"]

    private var tts: UnsafePointer<SherpaOnnxOfflineTts>?
    let sampleRate: Int
    let numSpeakers: Int

    init(assetsDir: URL) throws {
        let fm = FileManager.default
        for name in Self.assetFiles where !fm.fileExists(atPath: assetsDir.appendingPathComponent(name).path) {
            throw EngineError.asset(name)
        }
        // Chuỗi C phải sống tới khi Create xong (hàm sao chép đồng bộ) —
        // strdup rồi free ngay sau khi tạo engine.
        let cPaths = Self.assetFiles.map { strdup(assetsDir.appendingPathComponent($0).path) }
        defer { cPaths.forEach { free($0) } }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.num_threads = 2
        config.max_num_sentences = 1
        config.silence_scale = 0.2
        config.model.supertonic.duration_predictor = UnsafePointer(cPaths[0])
        config.model.supertonic.text_encoder = UnsafePointer(cPaths[1])
        config.model.supertonic.vector_estimator = UnsafePointer(cPaths[2])
        config.model.supertonic.vocoder = UnsafePointer(cPaths[3])
        config.model.supertonic.tts_json = UnsafePointer(cPaths[4])
        config.model.supertonic.unicode_indexer = UnsafePointer(cPaths[5])
        config.model.supertonic.voice_style = UnsafePointer(cPaths[6])
        guard let created = SherpaOnnxCreateOfflineTts(&config) else {
            throw EngineError.createFailed
        }
        tts = created
        sampleRate = Int(SherpaOnnxOfflineTtsSampleRate(created))
        numSpeakers = Int(SherpaOnnxOfflineTtsNumSpeakers(created))
    }

    deinit {
        if let tts { SherpaOnnxDestroyOfflineTts(tts) }
    }

    /// Tổng hợp 1 đoạn bằng giọng sid (0–4 nữ F1–F5, 5–9 nam M1–M5),
    /// ngôn ngữ tiếng Việt -> WAV PCM16 mono (định dạng NativePlayer đọc
    /// thẳng trong bộ nhớ, 44100Hz — tầng phát tự đổi định dạng).
    func synthesize(_ text: String, sid: Int32) throws -> Data {
        guard let tts else { throw EngineError.createFailed }
        var gen = SherpaOnnxGenerationConfig()
        gen.sid = sid
        gen.speed = 1.0
        gen.silence_scale = 0.2
        let audio = text.withCString { textPtr in
            "{\"lang\":\"vi\"}".withCString { extraPtr in
                gen.extra = extraPtr
                return SherpaOnnxOfflineTtsGenerateWithConfig(tts, textPtr, &gen, nil, nil)
            }
        }
        guard let audio else { throw EngineError.generateFailed }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let n = Int(audio.pointee.n)
        let rate = Int(audio.pointee.sample_rate)
        guard n > 0, let src = audio.pointee.samples else {
            return Self.wavData([], sampleRate: rate > 0 ? rate : sampleRate)
        }
        let samples = Array(UnsafeBufferPointer(start: src, count: n))
        return Self.wavData(samples, sampleRate: rate)
    }

    /// WAV RIFF PCM16 mono — cùng định dạng các engine trước từng viết để
    /// NativePlayer.makeBufferInMemory giải mã thẳng, không đổi phía phát.
    static func wavData(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        appendLE(UInt32(36 + samples.count * 2))
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(contentsOf: [UInt8]("data".utf8))
        appendLE(UInt32(samples.count * 2))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            let clamped = max(-1.0, min(1.0, s))
            pcm[i] = Int16((Double(clamped) * 32767.0).rounded())
        }
        pcm.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: UInt8.self, capacity: pcm.count * 2) { p in
                data.append(p, count: pcm.count * 2)
            }
        }
        return data
    }
}
