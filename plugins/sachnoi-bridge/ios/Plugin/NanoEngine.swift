import Foundation
import onnxruntime_objc

/// Engine VieNeu-TTS v3 Nano (ONNX, CPU) — bản Swift bám sát bản tham chiếu
/// chính thức `src/vieneu/v3nano.py` của SDK vieneu (pnnbao97/VieNeu-TTS):
///
///   phonemize (sea-g2p, dùng chung Phonemizer với engine Turbo)
///   -> encode_phones: [bos] + vocab[char] + [eos]   (vocab 81 ký tự, config.json)
///   -> text_encoder(ids, style) = ctx
///   -> duration_predictor(ctx, mask, spk) = log(giây) -> số khung T (fps 15,625)
///   -> vòng flow Euler `steps` bước trên vector_estimator với CFG (cfg 3,0):
///        v = v_null + cfg * (v_cond - v_null);  x += dt * v
///   -> codec_decoder(x) = wav 24kHz -> clip [-1,1] -> trim_and_fade
///
/// Khác Turbo ở gốc: Nano KHÔNG sinh từng token nối tiếp — số bước cố định
/// (16) cho cả đoạn, nên nhanh hơn thời gian thực trên CPU yếu (tác giả công
/// bố RTF 0,11–0,22 trên CPU desktop; Turbo int8 là 0,37). Đánh đổi: 24kHz,
/// 11 giọng preset (không clone), chất lượng dưới Turbo ở đoạn xen tiếng Anh.
///
/// Giọng preset: voices_v3_nano.json (speaker_emb 192 số + style [50,256]).
/// constants.npz của upstream được chuyển thành constants.json lúc đóng gói
/// (chỉ cần null_spk + null_style cho đường CFG) — xem release vieneu-nano-v1.
final class NanoEngine {
    enum EngineError: Error, CustomStringConvertible {
        case asset(String)
        case ort(String)
        var description: String {
            switch self {
            case .asset(let m): return "Thiếu asset Nano: \(m)"
            case .ort(let m): return "ONNX Runtime (Nano): \(m)"
            }
        }
    }

    struct NanoVoice {
        let name: String
        let gender: String
        let description: String
        let speakerEmb: [Float]      // 192
        let style: [Float]           // 50 * 256, hàng-major
    }

    static let sampleRate = 24000
    static var lastInitSteps = ""
    static var lastSynthSteps = ""

    private let env: ORTEnv
    private let sessText: ORTSession
    private let sessDur: ORTSession
    private let sessVe: ORTSession
    private let sessDec: ORTSession
    private let phonemizer: Phonemizer

    private let vocab: [String: Int64]
    private let bos: Int64
    private let eos: Int64
    private let pad: Int64
    private let fps: Double

    private let nullSpkTensor: ORTValue
    private let nullStyleTensor: ORTValue
    private let nullCtx: ORTValue
    private let nullMaskTensor: ORTValue

    let voices: [NanoVoice]
    let defaultVoiceName: String
    private let steps = 16
    private let cfg: Float = 3.0
    private var rngState: UInt64 = 0x2E9B_4A17_C53D_8801

    init(assetsDir: URL, g2pPath: String) throws {
        var marks: [String] = []
        let t0 = Date()
        func mark(_ s: String) {
            marks.append("\(s) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            NanoEngine.lastInitSteps = marks.joined(separator: " · ")
        }

        let fm = FileManager.default
        for name in ["text_encoder.onnx", "duration_predictor.onnx", "vector_estimator.onnx",
                     "codec_decoder.onnx", "config.json", "constants.json", "voices_v3_nano.json"]
        where !fm.fileExists(atPath: assetsDir.appendingPathComponent(name).path) {
            throw EngineError.asset(name)
        }

        // ── config.json: vocab + id đặc biệt ──
        let cfgData = try Data(contentsOf: assetsDir.appendingPathComponent("config.json"))
        guard let cfg = try JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
              let vocabRaw = cfg["vocab"] as? [String: Any] else {
            throw EngineError.asset("config.json hỏng (thiếu vocab)")
        }
        var vocab: [String: Int64] = [:]
        for (k, v) in vocabRaw { if let n = v as? NSNumber { vocab[k] = n.int64Value } }
        self.vocab = vocab
        self.bos = (cfg["bos_id"] as? NSNumber)?.int64Value ?? 1
        self.eos = (cfg["eos_id"] as? NSNumber)?.int64Value ?? 2
        self.pad = (cfg["pad_id"] as? NSNumber)?.int64Value ?? 0
        self.fps = (cfg["flow_fps"] as? NSNumber)?.doubleValue ?? 15.625
        mark("config")

        // ── constants.json: null_spk [192] + null_style [50,256] ──
        let constData = try Data(contentsOf: assetsDir.appendingPathComponent("constants.json"))
        guard let consts = try JSONSerialization.jsonObject(with: constData) as? [String: Any],
              let nullSpkArr = consts["null_spk"] as? [Any],
              let nullStyleArr = consts["null_style"] as? [Any] else {
            throw EngineError.asset("constants.json hỏng")
        }
        let nullSpk = nullSpkArr.map { ($0 as? NSNumber)?.floatValue ?? 0 }
        var nullStyle: [Float] = []
        for row in nullStyleArr {
            for v in (row as? [Any]) ?? [] { nullStyle.append((v as? NSNumber)?.floatValue ?? 0) }
        }
        guard nullSpk.count == 192, nullStyle.count == 50 * 256 else {
            throw EngineError.asset("constants.json sai kích thước null_spk/null_style")
        }
        mark("constants")

        // ── voices_v3_nano.json: 11 giọng preset ──
        let voicesData = try Data(contentsOf: assetsDir.appendingPathComponent("voices_v3_nano.json"))
        guard let vj = try JSONSerialization.jsonObject(with: voicesData) as? [String: Any],
              let presets = vj["presets"] as? [String: Any] else {
            throw EngineError.asset("voices_v3_nano.json hỏng")
        }
        var parsed: [NanoVoice] = []
        // Giữ đúng thứ tự khai báo trong file (JSONSerialization không đảm
        // bảo thứ tự dict) -> sắp xếp theo thứ tự xuất hiện trong dữ liệu thô.
        let rawText = String(data: voicesData, encoding: .utf8) ?? ""
        func pos(_ name: String) -> Int {
            guard let r = rawText.range(of: "\"\(name)\"") else { return Int.max }
            return rawText.distance(from: rawText.startIndex, to: r.lowerBound)
        }
        let orderedNames = presets.keys.sorted { pos($0) < pos($1) }
        for name in orderedNames {
            guard let p = presets[name] as? [String: Any],
                  let emb = p["speaker_emb"] as? [Any], emb.count == 192,
                  let styleRows = p["style"] as? [Any], styleRows.count == 50 else { continue }
            var style: [Float] = []
            style.reserveCapacity(50 * 256)
            for row in styleRows { for v in (row as? [Any]) ?? [] { style.append((v as? NSNumber)?.floatValue ?? 0) } }
            guard style.count == 50 * 256 else { continue }
            parsed.append(NanoVoice(name: name,
                                    gender: (p["gender"] as? String) ?? "",
                                    description: (p["description"] as? String) ?? "",
                                    speakerEmb: emb.map { ($0 as? NSNumber)?.floatValue ?? 0 },
                                    style: style))
        }
        guard !parsed.isEmpty else { throw EngineError.asset("voices_v3_nano.json không có giọng hợp lệ") }
        self.voices = parsed
        self.defaultVoiceName = (vj["default_voice"] as? String).flatMap { d in parsed.first { $0.name == d }?.name }
            ?? parsed[0].name
        mark("voices(\(parsed.count))")

        // ── phiên âm: dùng chung sea-g2p của gói Turbo (đã gắn sẵn) ──
        let g2p = SeaG2pEngine(dictPath: g2pPath)
        guard g2p.isOpen else { throw EngineError.asset("sea_g2p.bin (trong TTSAssets)") }
        phonemizer = Phonemizer(g2p: g2p)
        mark("g2p")

        // ── ONNX sessions (luồng như SDK: ~nửa số nhân, trần 8 -> 3) ──
        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env
        func makeSession(_ name: String, _ threads: Int32 = 3) throws -> ORTSession {
            let opts = try ORTSessionOptions()
            try opts.setIntraOpNumThreads(threads)
            try opts.setGraphOptimizationLevel(.all)
            return try ORTSession(env: env,
                                  modelPath: assetsDir.appendingPathComponent(name).path,
                                  sessionOptions: opts)
        }
        sessText = try makeSession("text_encoder.onnx")
        mark("sess-text")
        sessDur = try makeSession("duration_predictor.onnx")
        mark("sess-dur")
        sessVe = try makeSession("vector_estimator.onnx", 4)
        mark("sess-ve")
        sessDec = try makeSession("codec_decoder.onnx")
        mark("sess-dec")

        // ── ngữ cảnh vô điều kiện cho CFG: dựng 1 lần (giọng-độc lập) ──
        nullSpkTensor = try Self.floatTensor(nullSpk, [1, 192])
        nullStyleTensor = try Self.floatTensor(nullStyle, [1, 50, 256])
        let nullIds = try Self.int64Tensor([bos, eos], [1, 2])
        nullMaskTensor = try Self.uint8Tensor([1, 1], [1, 2])
        let nullOut = try Self.run(sessText, ["ids": nullIds, "style": nullStyleTensor], cache: nil)
        guard let ctx = nullOut.values.first else { throw EngineError.ort("text_encoder không trả ctx (null)") }
        nullCtx = ctx
        mark("null-ctx")
    }

    func resolveVoice(_ name: String?) -> NanoVoice {
        if let name, let v = voices.first(where: { $0.name == name }) { return v }
        return voices.first { $0.name == defaultVoiceName } ?? voices[0]
    }

    /// Tổng hợp 1 đoạn văn (NativePlayer đưa vào, thường <= 180 ký tự) ->
    /// WAV PCM16 24kHz. Bên trong tự cắt <= 140 ký tự/mảnh như SDK
    /// (Nano huấn luyện trên clip <= 15 giây, mảnh dài làm sai thời lượng).
    func synthesize(text: String, voiceName: String?) throws -> Data {
        let voice = resolveVoice(voiceName)
        let spk = try Self.floatTensor(voice.speakerEmb, [1, 192])
        let style = try Self.floatTensor(voice.style, [1, 50, 256])
        var all: [Float] = []
        let pieces = Self.splitChunks(text, maxChars: 140)
        for (i, piece) in pieces.enumerated() {
            if i > 0 { all += [Float](repeating: 0, count: Self.sampleRate / 10) } // 0,1s nối mảnh
            let wav = try synthesizePiece(piece, spk: spk, style: style)
            all += wav
        }
        Self.lastSynthSteps = "nano · \(pieces.count) mảnh · \(steps) bước · cfg \(cfg)"
        return Self.wavData(all, sampleRate: Self.sampleRate)
    }

    private func synthesizePiece(_ text: String, spk: ORTValue, style: ORTValue) throws -> [Float] {
        let phones = phonemizer.phonemizeWithEmotions(text)
        // encode_phones: duyệt theo CODE POINT như Python (dấu phụ là ký tự
        // riêng trong vocab), bỏ qua ký tự ngoài vocab.
        var ids: [Int64] = [bos]
        for scalar in phones.unicodeScalars {
            if let id = vocab[String(scalar)] { ids.append(id) }
        }
        ids.append(eos)
        let idsT = try Self.int64Tensor(ids, [1, ids.count])
        let maskT = try Self.uint8Tensor([UInt8](repeating: 1, count: ids.count), [1, ids.count])

        let ctxOut = try Self.run(sessText, ["ids": idsT, "style": style], cache: nil)
        guard let ctx = ctxOut.values.first else { throw EngineError.ort("text_encoder không trả ctx") }

        let durOut = try Self.run(sessDur, ["ctx": ctx, "ctx_mask": maskT, "spk": spk], cache: nil)
        guard let durVal = durOut.values.first else { throw EngineError.ort("duration_predictor không trả kết quả") }
        let logS = try Self.readFloats(durVal).first ?? 0
        let secs = min(exp(Double(logS)), 15.0)
        let frames = max(2, Int((secs * fps).rounded()))

        // Vòng flow Euler: x ~ N(0,1) [1,144,T], sway = 0 -> lưới t đều.
        var x = gaussian(count: 144 * frames)
        let dt = Float(1.0 / Double(steps))
        for i in 0..<steps {
            let tT = try Self.floatTensor([Float(i) * dt], [1])
            let xT = try Self.floatTensor(x, [1, 144, frames])
            let vOut = try Self.run(sessVe, ["x": xT, "t": tT, "ctx": ctx, "ctx_mask": maskT, "spk": spk, "style": style], cache: nil)
            guard let vVal = vOut.values.first else { throw EngineError.ort("vector_estimator không trả v") }
            let vuOut = try Self.run(sessVe, ["x": xT, "t": tT, "ctx": nullCtx, "ctx_mask": nullMaskTensor, "spk": nullSpkTensor, "style": nullStyleTensor], cache: nil)
            guard let vuVal = vuOut.values.first else { throw EngineError.ort("vector_estimator không trả v (null)") }
            let v = try Self.readFloats(vVal)
            let vu = try Self.readFloats(vuVal)
            guard v.count == x.count, vu.count == x.count else { throw EngineError.ort("vector_estimator sai kích thước") }
            for j in 0..<x.count {
                x[j] += dt * (vu[j] + cfg * (v[j] - vu[j]))
            }
        }

        let decOut = try Self.run(sessDec, ["x": Self.floatTensor(x, [1, 144, frames])], cache: nil)
        guard let wavVal = decOut.values.first else { throw EngineError.ort("codec_decoder không trả wav") }
        let raw = try Self.readFloats(wavVal)
        let clipped = raw.map { max(-1, min(1, $0)) }
        return Self.trimAndFade(clipped, sampleRate: Self.sampleRate)
    }

    // MARK: - Cắt mảnh <= maxChars tại ranh giới câu/dấu (như SDK)

    static func splitChunks(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed.isEmpty ? [] : [trimmed] }
        var out: [String] = []
        var rest = trimmed
        while rest.count > maxChars {
            let prefix = String(rest.prefix(maxChars))
            var cut = -1
            for (i, ch) in prefix.enumerated() where ".!?…;,:".contains(ch) { cut = i }
            if cut < maxChars / 3 {
                // Không có dấu thích hợp -> cắt tại khoảng trắng cuối.
                if let sp = prefix.lastIndex(of: " ") {
                    cut = prefix.distance(from: prefix.startIndex, to: sp)
                } else {
                    cut = maxChars - 1
                }
            }
            let idx = rest.index(rest.startIndex, offsetBy: cut + 1)
            let piece = String(rest[..<idx]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { out.append(piece) }
            rest = String(rest[idx...]).trimmingCharacters(in: .whitespaces)
        }
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    // MARK: - trim_and_fade (bám core_utils.py: -45dB, giữ 0,04s, fade 0,015s)

    static func trimAndFade(_ wav: [Float], sampleRate: Int) -> [Float] {
        guard !wav.isEmpty else { return wav }
        let win = max(1, sampleRate / 100)               // cửa sổ 10ms
        let nWin = wav.count / win
        var lead = wav.count
        var tail = 0
        if nWin > 0 {
            let thresh: Float = 0.0056234                // 10^(-45/20)
            var first = -1
            var last = -1
            for w in 0..<nWin {
                var sum: Float = 0
                for s in (w * win)..<((w + 1) * win) { sum += abs(wav[s]) }
                if sum / Float(win) > thresh {
                    if first < 0 { first = w }
                    last = w
                }
            }
            if first >= 0 {
                lead = first * win
                tail = wav.count - (last + 1) * win
            } // toàn im lặng: giữ lead = wav.count, tail = 0 như bản gốc
        }
        let keep = Int(0.04 * Double(sampleRate))
        let a = max(0, lead - keep)
        let b = wav.count - max(0, tail - keep)
        guard b > a else { return wav }
        var out = Array(wav[a..<b])
        let n = min(Int(0.015 * Double(sampleRate)), out.count / 2)
        if n > 1 {
            for i in 0..<n {
                let ramp = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(n - 1)))
                out[i] *= ramp
                out[out.count - 1 - i] *= ramp
            }
        }
        return out
    }

    // MARK: - RNG gaussian xác định (SplitMix64 + Box-Muller)

    private func gaussian(count: Int) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count {
            let u1 = max(nextUniform(), 1e-12)
            let u2 = nextUniform()
            let r = sqrt(-2.0 * log(u1))
            let theta = 2.0 * Double.pi * u2
            out.append(Float(r * cos(theta)))
            if out.count < count { out.append(Float(r * sin(theta))) }
        }
        return out
    }

    private func nextUniform() -> Double {
        rngState &+= 0x9E37_79B9_7F4A_7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) * (1.0 / 9007199254740992.0)
    }

    // MARK: - ORT helpers (cùng khuôn với VieNeuEngine)

    private static var outputNamesCache: [ObjectIdentifier: Set<String>] = [:]
    private static let outputNamesLock = NSLock()

    static func run(_ session: ORTSession, _ inputs: [String: ORTValue], cache: Bool?) throws -> [String: ORTValue] {
        let key = ObjectIdentifier(session)
        outputNamesLock.lock()
        var names = outputNamesCache[key]
        if names == nil {
            names = Set(try session.outputNames())
            outputNamesCache[key] = names
        }
        outputNamesLock.unlock()
        return try session.run(withInputs: inputs, outputNames: names!, runOptions: nil)
    }

    static func floatTensor(_ data: [Float], _ shape: [Int]) throws -> ORTValue {
        let md = NSMutableData(bytes: data, length: data.count * MemoryLayout<Float>.size)
        return try ORTValue(tensorData: md, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    static func int64Tensor(_ data: [Int64], _ shape: [Int]) throws -> ORTValue {
        let md = NSMutableData(bytes: data, length: data.count * MemoryLayout<Int64>.size)
        return try ORTValue(tensorData: md, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
    }

    static func uint8Tensor(_ data: [UInt8], _ shape: [Int]) throws -> ORTValue {
        // ctx_mask: onnxruntime-objc 1.20.0 KHÔNG tạo được tensor bool
        // (enum thiếu case .bool; ép rawValue 9 thì runtime văng
        // "unsupported tensor element type" — phán quyết máy thật 2.1.0).
        // Hai graph nhận mask (duration_predictor, vector_estimator) đã
        // được vá ở release vieneu-nano-v2: input ctx_mask là UINT8, node
        // Cast(bool) ở đầu graph khôi phục mask bool bên trong — kết quả
        // số học giống hệt bản gốc (đã kiểm chứng bằng onnxruntime CPU).
        let md = NSMutableData(bytes: data, length: data.count)
        return try ORTValue(tensorData: md, elementType: .uInt8, shape: shape.map { NSNumber(value: $0) })
    }

    static func readFloats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// WAV RIFF PCM16 mono (NativePlayer.makeBufferInMemory đọc được).
    static func wavData(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let n = samples.count
        let byteRate = sampleRate * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + n * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(n * 2))
        var pcm = Data(capacity: n * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            var x = v.littleEndian
            pcm.append(Data(bytes: &x, count: 2))
        }
        data.append(pcm)
        return data
    }
}
