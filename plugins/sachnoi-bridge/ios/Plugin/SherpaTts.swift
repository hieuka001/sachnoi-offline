import Foundation
import SherpaOnnxC

/// Lõi tổng hợp giọng nói từ 2.0.0: sherpa-onnx (repo k2-fsa/sherpa-onnx,
/// bản đóng gói xcframework chính thức) + model Piper tiếng Việt
/// vi_VN-vais1000-medium gắn sẵn trong app.
///
/// Vì sao thay engine VieNeu tự port (đã xoá ở 2.0.0): VieNeu sinh tiếng
/// theo từng khung hình (autoregressive, ~17 lần chạy model/khung) — trên
/// máy anh tốn 9,8–13,5 giây cho 5–10 giây tiếng (số liệu Chẩn đoán
/// 1.9.4–1.9.6), không bao giờ đuổi kịp tốc độ phát nên đọc cứ dừng chờ.
/// Piper/VITS của sherpa-onnx sinh cả câu trong MỘT lượt chạy model,
/// nhanh hơn thời gian thực nhiều lần ngay trên máy yếu — đúng việc đọc
/// sách cần. Toàn bộ suy luận do thư viện gốc đảm nhiệm, app chỉ gọi C API.
final class SherpaTtsEngine {
    enum EngineError: Error, LocalizedError {
        case asset(String)
        case createFailed
        case generateFailed

        var errorDescription: String? {
            switch self {
            case .asset(let name): return "Thiếu file giọng trong app: \(name)"
            case .createFailed: return "sherpa-onnx không tạo được engine TTS"
            case .generateFailed: return "sherpa-onnx tổng hợp thất bại"
            }
        }
    }

    /// Tên hiển thị ở Chẩn đoán để đối chiếu bản thư viện/model đang chạy.
    static let kind = "sherpa-onnx 1.13.8 · Piper vi_VN-vais1000-medium"

    private var tts: UnsafePointer<SherpaOnnxOfflineTts>?
    let sampleRate: Int

    init(assetsDir: URL) throws {
        let fm = FileManager.default
        let model = assetsDir.appendingPathComponent("vi_VN-vais1000-medium.onnx")
        let tokens = assetsDir.appendingPathComponent("tokens.txt")
        let dataDir = assetsDir.appendingPathComponent("espeak-ng-data")
        for url in [model, tokens, dataDir] where !fm.fileExists(atPath: url.path) {
            throw EngineError.asset(url.lastPathComponent)
        }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.num_threads = 2
        config.max_num_sentences = 1
        config.silence_scale = 0.2
        let created = model.path.withCString { modelPtr in
            tokens.path.withCString { tokensPtr in
                dataDir.path.withCString { dataPtr in
                    config.model.vits.model = modelPtr
                    config.model.vits.tokens = tokensPtr
                    config.model.vits.data_dir = dataPtr
                    return SherpaOnnxCreateOfflineTts(&config)
                }
            }
        }
        guard let created else { throw EngineError.createFailed }
        tts = created
        sampleRate = Int(SherpaOnnxOfflineTtsSampleRate(created))
    }

    deinit {
        if let tts { SherpaOnnxDestroyOfflineTts(tts) }
    }

    /// Tổng hợp 1 đoạn -> WAV PCM16 mono (đúng định dạng NativePlayer đọc
    /// trong bộ nhớ). Engine KHÔNG an toàn đa luồng: nơi gọi (TtsServer)
    /// phải khoá nối tiếp mọi lần gọi vào đây.
    func synthesize(_ text: String) throws -> Data {
        guard let tts else { throw EngineError.createFailed }
        let audio = text.withCString { SherpaOnnxOfflineTtsGenerate(tts, $0, 0, 1.0) }
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

    /// WAV RIFF PCM16 mono — cùng định dạng bản VieNeu cũ từng viết để
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
