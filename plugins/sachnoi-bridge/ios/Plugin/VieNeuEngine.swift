import Foundation
import Accelerate
import onnxruntime_objc

/// Engine VieNeu-TTS v3 Turbo chạy hoàn toàn trên máy (ONNX Runtime, bản int8):
/// chép 1-1 OnnxV3LiteEngine + V3TurboVieNeuTTS.infer của bản Python — cùng đồ thị,
/// cùng thuật toán lấy mẫu, cùng ghép chunk — đã đối chiếu đầu ra giống hệt trong
/// bản mẫu proto.py (maxdiff 0.0 trên mọi văn bản kiểm chứng).
final class VieNeuEngine {
    static let sampleRate = 48000

    /// Thời gian từng bước nạp engine của lần init gần nhất (đợt 29) — chẩn đoán
    /// đọc qua TtsServer để biết chính xác bước nào chậm trên máy thật.
    static var lastInitSteps = ""

    enum EngineError: Error, CustomStringConvertible {
        case asset(String)
        case ort(String)
        var description: String {
            switch self {
            case .asset(let m): return "Thiếu/không đọc được tài sản TTS: \(m)"
            case .ort(let m): return "ONNX Runtime: \(m)"
            }
        }
    }

    // Cấu hình kiến trúc (từ config.json của model)
    private let nVq: Int
    private let hidden: Int
    private let layers: Int
    private let audioPad: Int
    private let tps: Int
    private let tpe: Int
    private let sgs: Int
    private let eosSpeech: Int
    private let refSlot: Int
    private let styleId: Int

    private let heads: HeadsStore
    private let tokenizer: BpeTokenizer
    let phonemizer: Phonemizer
    let voices: VoiceStore

    /// ORTEnv phải sống lâu bằng các session (tài liệu ONNX Runtime: tạo trước,
    /// huỷ sau cùng) — giữ làm thuộc tính, không để giải phóng sau init.
    private let env: ORTEnv
    private let sessPrefill: ORTSession
    private let sessDecode: ORTSession
    private let sessAcoustic: ORTSession
    private let sessCodec: ORTSession

    private var rng = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000) ^ 0x5DEECE66D)

    init(assetsDir: URL) throws {
        // Đo từng bước nạp (đợt 29): nạp engine là điểm nghẽn duy nhất còn lại
        // của trải nghiệm nghe — phải biết mili-giây của từng bước trên máy thật.
        var stepLog: [String] = []
        var stepT = Date()
        func mark(_ name: String) {
            stepLog.append("\(name) \(Int(Date().timeIntervalSince(stepT) * 1000))ms")
            stepT = Date()
        }
        defer { Self.lastInitSteps = stepLog.joined(separator: " · ") }

        // ── config ──
        let cfgData = try Data(contentsOf: assetsDir.appendingPathComponent("config.json"))
        let cfg = (try JSONSerialization.jsonObject(with: cfgData) as? [String: Any]) ?? [:]
        func intVal(_ key: String, _ def: Int) -> Int { (cfg[key] as? NSNumber)?.intValue ?? def }
        nVq = intVal("n_vq", 16)
        hidden = intVal("hidden_size", 768)
        layers = intVal("num_hidden_layers", 12)
        audioPad = intVal("audio_pad_token_id", 1024)
        tps = intVal("text_prompt_start_token_id", 3)
        tpe = intVal("text_prompt_end_token_id", 4)
        sgs = intVal("speech_generation_start_token_id", 5)
        eosSpeech = intVal("speech_generation_end_token_id", 6)
        refSlot = intVal("audio_ref_slot_token_id", 7)
        styleId = intVal("default_style_token_id", 16)
        mark("config")

        heads = try HeadsStore(dir: assetsDir)
        mark("heads")
        tokenizer = try BpeTokenizer(jsonData: Data(contentsOf: assetsDir.appendingPathComponent("tokenizer.json")))
        mark("tokenizer")

        let g2p = SeaG2pEngine(dictPath: assetsDir.appendingPathComponent("sea_g2p.bin").path)
        guard g2p.isOpen else { throw EngineError.asset("sea_g2p.bin") }
        phonemizer = Phonemizer(g2p: g2p)
        mark("g2p")
        voices = try VoiceStore(url: assetsDir.appendingPathComponent("voices_v3_turbo.json"))
        mark("voices")

        // ── ONNX sessions ──
        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env
        mark("env")
        func makeSession(_ name: String, _ level: ORTGraphOptimizationLevel = .all) throws -> ORTSession {
            let opts = try ORTSessionOptions()
            try opts.setIntraOpNumThreads(4)
            try opts.setGraphOptimizationLevel(level)
            return try ORTSession(env: env,
                                  modelPath: assetsDir.appendingPathComponent(name).path,
                                  sessionOptions: opts)
        }
        // Hai session backbone dùng chung dữ liệu 99MB: mức .all bắt ORT tối ưu
        // sâu ngay lúc nạp (rất chậm trên model lớn) — .basic nạp nhanh hơn hẳn,
        // hiệu năng suy luận gần như nguyên vẹn với workload này (đợt 29).
        sessPrefill = try makeSession("vieneu_prefill.onnx", .basic)
        mark("sess-prefill")
        sessDecode = try makeSession("vieneu_decode_step.onnx", .basic)
        mark("sess-decode")
        sessAcoustic = try makeSession("vieneu_acoustic_cached.onnx")
        mark("sess-acoustic")
        sessCodec = try makeSession("moss_audio_tokenizer_decode_full.onnx")
        mark("sess-codec")
    }

    // MARK: - Tổng hợp 1 đoạn văn (API cho TtsServer)

    func synthesize(text: String, voiceName: String?) throws -> Data {
        let preset = voices.resolve(voiceName)
        let (chunks, gaps) = phonemizer.chunksWithGaps(text)
        if chunks.isEmpty { return Self.wavData([]) }
        var wavs: [[Float]] = []
        for chunk in chunks {
            let ph = phonemizer.phonemizeWithEmotions(chunk)
            let cap = min(300, SpeechUtils.maxExpectedFrames(ph))
            let wav = try generate(phonemes: ph, speakerEmb: preset.speakerEmb,
                                   refCodes: preset.codes, maxNewFrames: cap)
            wavs.append(wav)
        }
        let joined = SpeechUtils.joinAudioChunks(wavs, Self.sampleRate,
                                                 silencePs: SpeechUtils.gapsToSilence(gaps))
        return Self.wavData(joined)
    }

    static func wavData(_ samples: [Float]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        let byteRate = sampleRate * 2
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            Swift.withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        appendLE(UInt32(36 + samples.count * 2))
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        appendLE(UInt32(16))
        appendLE(UInt16(1))            // PCM
        appendLE(UInt16(1))            // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(2))            // block align
        appendLE(UInt16(16))           // bits
        data.append(contentsOf: [UInt8]("data".utf8))
        appendLE(UInt32(samples.count * 2))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            appendLE(Int16((Double(clamped) * 32767.0).rounded()))
        }
        return data
    }

    // MARK: - Vòng sinh (port OnnxV3LiteEngine.infer)

    private func generate(phonemes: String, speakerEmb: [Float], refCodes: [[Int]]?,
                          maxNewFrames inputCap: Int) throws -> [Float] {
        let maxNewFrames = min(inputCap, SpeechUtils.maxExpectedFrames(phonemes))
        let anchor = speakerAnchor(speakerEmb)
        let rows = buildRows(phonemes: phonemes, refCodes: refCodes)
        let promptEmb = try embedRows(rows, anchor: anchor)

        func genOnce() throws -> [[Int]] {
            let pre = try run(sessPrefill, ["inputs_embeds": promptEmb])
            var pastK: [ORTValue] = try (0..<layers).map { try need(pre, "present_k_\($0)") }
            var pastV: [ORTValue] = try (0..<layers).map { try need(pre, "present_v_\($0)") }
            let hiddenAll = try readFloats(need(pre, "hidden"))
            var h = Array(hiddenAll.suffix(hidden))
            let tPrompt = rows.count
            let hist = RepetitionHistory(nChannels: nVq)
            var frames: [[Int]] = []
            for t in 0..<maxNewFrames {
                let (codes, eos) = try acousticFrame(h: h, hist: hist)
                frames.append(codes)
                if eos { break }
                var slotRow = [Int](repeating: audioPad, count: nVq + 1)
                slotRow[0] = sgs
                for (i, c) in codes.enumerated() { slotRow[i + 1] = c }
                let slotEmb = try embedRows([slotRow], anchor: anchor)
                var feed: [String: ORTValue] = [
                    "inputs_embeds": slotEmb,
                    "position_ids": try int64Tensor([Int64(tPrompt + t)], [1, 1]),
                ]
                for i in 0..<layers {
                    feed["past_k_\(i)"] = pastK[i]
                    feed["past_v_\(i)"] = pastV[i]
                }
                let out = try run(sessDecode, feed)
                h = try readFloats(need(out, "hidden"))
                pastK = try (0..<layers).map { try need(out, "present_k_\($0)") }
                pastV = try (0..<layers).map { try need(out, "present_v_\($0)") }
            }
            return frames
        }

        var frames = try genOnce()
        if frames.isEmpty { return [] }
        var wav = try decodeCodes(frames)
        // Babble guard: chunk ngắn "nói thêm" -> sinh lại tối đa 2 lần, giữ bản tốt hơn.
        var best = SpeechUtils.babbleSuspect(wav, Self.sampleRate, phonemes, maxNewFrames, nFrames: frames.count)
        var tries = 0
        while best.0 && tries < SpeechUtils.babbleMaxRetries {
            let f2 = try genOnce()
            tries += 1
            if f2.isEmpty { continue }
            let w2 = try decodeCodes(f2)
            let cand = SpeechUtils.babbleSuspect(w2, Self.sampleRate, phonemes, maxNewFrames, nFrames: f2.count)
            if SpeechUtils.babblePrefer(cand, best) {
                frames = f2
                wav = w2
                best = cand
            }
        }
        return wav
    }

    private func acousticFrame(h: [Float], hist: RepetitionHistory) throws -> ([Int], Bool) {
        var tok = [Float](repeating: 0, count: 2 * hidden)
        tok.replaceSubrange(0..<hidden, with: h)
        let txtRow = heads.row("text_emb", sgs, hidden)
        tok.replaceSubrange(hidden..<(2 * hidden), with: UnsafeBufferPointer(start: txtRow, count: hidden))

        var feed: [String: ORTValue] = [
            "token_emb": try floatTensor(tok, [1, 2, hidden]),
            "position_ids": try int64Tensor([0, 1], [1, 2]),
            "past_k_0": try floatTensor([], [1, 8, 0, hidden / 8]),
            "past_v_0": try floatTensor([], [1, 8, 0, hidden / 8]),
        ]
        var out = try run(sessAcoustic, feed)
        var hiddenF = try readFloats(need(out, "hidden"))
        var pk = try need(out, "present_k_0")
        var pv = try need(out, "present_v_0")
        let slot0 = Array(hiddenF[0..<hidden])

        func samp(_ ch: Int, _ vec: ArraySlice<Float>) -> Int {
            let logits = matvec(heads.audioEmbBase(ch), rows: 1024, vec: [Float](vec))
            let code = sample(logits: logits, temperature: 0.8, topK: 25, topP: 0.95,
                              repPen: 1.2, prev: hist.codes(in: ch))
            hist.add(code, in: ch)
            return code
        }

        var codes: [Int] = []
        codes.append(samp(0, hiddenF[hidden..<(2 * hidden)]))
        for ch in 1..<nVq {
            let embRow = heads.audioEmbRow(ch - 1, codes[ch - 1], hidden)
            feed = [
                "token_emb": try floatTensor([Float](UnsafeBufferPointer(start: embRow, count: hidden)), [1, 1, hidden]),
                "position_ids": try int64Tensor([Int64(ch + 1)], [1, 1]),
                "past_k_0": pk,
                "past_v_0": pv,
            ]
            out = try run(sessAcoustic, feed)
            hiddenF = try readFloats(need(out, "hidden"))
            pk = try need(out, "present_k_0")
            pv = try need(out, "present_v_0")
            codes.append(samp(ch, hiddenF[0..<hidden]))
        }
        let textLogits = matvec(heads.base("text_emb"), rows: 419, vec: slot0)
        let eos = textLogits.firstIndex(of: textLogits.max() ?? 0) == eosSpeech
        return (codes, eos)
    }

    private func decodeCodes(_ frames: [[Int]]) throws -> [Float] {
        let t = frames.count
        var flat = [Int32](repeating: 0, count: t * nVq)
        for (i, frame) in frames.enumerated() {
            for (j, c) in frame.enumerated() { flat[i * nVq + j] = Int32(c) }
        }
        let out = try run(sessCodec, [
            "audio_codes": try int32Tensor(flat, [1, t, nVq]),
            "audio_code_lengths": try int32Tensor([Int32(t)], [1]),
        ])
        let audioValue = try need(out, "audio")
        let shape = (try audioValue.tensorTypeAndShapeInfo()).shape.map { $0.intValue }
        let floats = try readFloats(audioValue)
        guard shape.count == 3 else { return [] }
        let channels = shape[1]
        let count = shape[2]
        if channels <= 1 { return Array(floats.prefix(count)) }
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channels {
            for s in 0..<count {
                mono[s] += floats[c * count + s] / Float(channels)
            }
        }
        return mono
    }

    // MARK: - Embeddings / anchor / sampling (port numpy của bản gốc)

    private func speakerAnchor(_ speakerEmb: [Float]) -> [Float] {
        // xvec_proj: Linear(192->768) + LayerNorm
        var v = matvec(heads.base("xvec_w"), rows: hidden, cols: speakerEmb.count, vec: speakerEmb)
        let b = heads.slice("xvec_b")
        for i in 0..<hidden { v[i] += b[i] }
        let mean = v.reduce(0, +) / Float(hidden)
        var varSum: Float = 0
        for x in v { varSum += (x - mean) * (x - mean) }
        let variance = varSum / Float(hidden)
        let eps = heads.slice("xvec_ln_eps").first ?? 0
        let denom = sqrt(variance + eps)
        let lnW = heads.slice("xvec_ln_w")
        let lnB = heads.slice("xvec_ln_b")
        for i in 0..<hidden {
            v[i] = (v[i] - mean) / denom * lnW[i] + lnB[i]
        }
        return v
    }

    private func buildRows(phonemes: String, refCodes: [[Int]]?) -> [[Int]] {
        let phoneIds = tokenizer.encode(phonemes)
        let textIds = [styleId, tps] + phoneIds + [tpe]
        var rows: [[Int]] = textIds.map { id in
            var row = [Int](repeating: audioPad, count: nVq + 1)
            row[0] = id
            return row
        }
        if let refCodes {
            for frame in refCodes {
                var row = [Int](repeating: audioPad, count: nVq + 1)
                row[0] = refSlot
                for (i, c) in frame.enumerated() where i < nVq { row[i + 1] = c }
                rows.append(row)
            }
        }
        return rows
    }

    private func embedRows(_ rows: [[Int]], anchor: [Float]?) throws -> ORTValue {
        let t = rows.count
        var emb = [Float](repeating: 0, count: t * hidden)
        let textBase = heads.base("text_emb")
        for (r, row) in rows.enumerated() {
            let dst = r * hidden
            emb.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.advanced(by: dst)
                    .update(from: textBase.advanced(by: row[0] * hidden), count: hidden)
            }
            for ch in 0..<nVq {
                let id = row[ch + 1]
                if id == audioPad { continue }
                let src = heads.audioEmbRow(ch, id, hidden)
                emb.withUnsafeMutableBufferPointer { buf in
                    let d = buf.baseAddress!.advanced(by: dst)
                    vDSP_vadd(src, 1, d, 1, d, 1, vDSP_Length(hidden))
                }
            }
            if let anchor {
                emb.withUnsafeMutableBufferPointer { buf in
                    let d = buf.baseAddress!.advanced(by: dst)
                    anchor.withUnsafeBufferPointer { a in
                        vDSP_vadd(a.baseAddress!, 1, d, 1, d, 1, vDSP_Length(hidden))
                    }
                }
            }
        }
        return try floatTensor(emb, [1, t, hidden])
    }

    /// logits = M(rows x cols) · vec — M là tensor phẳng hàng-chính (row-major).
    private func matvec(_ m: UnsafePointer<Float>, rows: Int, cols: Int = 768, vec: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: rows)
        vec.withUnsafeBufferPointer { v in
            out.withUnsafeMutableBufferPointer { o in
                vDSP_mmul(m, 1, v.baseAddress!, 1, o.baseAddress!, 1,
                          vDSP_Length(rows), 1, vDSP_Length(cols))
            }
        }
        return out
    }

    /// Lấy mẫu chép đúng _sample của bản gốc: phạt lặp -> chia nhiệt độ ->
    /// top-k trước -> softmax -> nucleus top-p -> rút thăm theo phân phối.
    private func sample(logits input: [Float], temperature: Double, topK: Int, topP: Double,
                        repPen: Float, prev: [Int]) -> Int {
        var logits = input
        if repPen != 1.0 && !prev.isEmpty {
            for idx in prev {
                let sel = logits[idx]
                logits[idx] = sel < 0 ? sel * repPen : sel / repPen
            }
        }
        if temperature <= 0 {
            return logits.firstIndex(of: logits.max() ?? 0) ?? 0
        }
        let temp = Float(temperature)
        for i in logits.indices { logits[i] /= temp }
        let v = logits.count
        var cand: [Int]
        if topK > 0 && topK < v {
            let threshold = logits.sorted(by: >)[topK - 1]
            cand = logits.indices.filter { logits[$0] >= threshold }
        } else {
            cand = Array(logits.indices)
        }
        cand.sort { logits[$0] > logits[$1] }
        var probs = cand.map { logits[$0] }
        let maxLogit = probs.max() ?? 0
        var sum: Float = 0
        for i in probs.indices {
            probs[i] = exp(probs[i] - maxLogit)
            sum += probs[i]
        }
        for i in probs.indices { probs[i] /= sum }
        if topP < 1.0 {
            // nucleus: giữ phần tử khi tổng xác suất TRƯỚC nó vẫn dưới topP
            var cumsum: Float = 0
            var keptSum: Float = 0
            var kept: [Float] = []
            for p in probs {
                let include = Double(cumsum) < topP
                kept.append(include ? p : 0)
                if include { keptSum += p }
                cumsum += p
            }
            if keptSum > 0 {
                for i in kept.indices { kept[i] /= keptSum }
            }
            probs = kept
        }
        let u = Float(rng.nextUniform())
        var acc: Float = 0
        for (i, p) in probs.enumerated() {
            acc += p
            if u <= acc { return cand[i] }
        }
        return cand.last ?? 0
    }

    // MARK: - ORT helpers

    private func run(_ session: ORTSession, _ inputs: [String: ORTValue]) throws -> [String: ORTValue] {
        try session.run(withInputs: inputs, outputNames: Set(try session.outputNames()), runOptions: nil)
    }

    private func need(_ outputs: [String: ORTValue], _ name: String) throws -> ORTValue {
        guard let v = outputs[name] else { throw EngineError.ort("thiếu output \(name)") }
        return v
    }

    private func floatTensor(_ data: [Float], _ shape: [Int]) throws -> ORTValue {
        let md = NSMutableData(bytes: data, length: data.count * MemoryLayout<Float>.size)
        return try ORTValue(tensorData: md, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    private func int64Tensor(_ data: [Int64], _ shape: [Int]) throws -> ORTValue {
        let md = NSMutableData(bytes: data, length: data.count * MemoryLayout<Int64>.size)
        return try ORTValue(tensorData: md, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
    }

    private func int32Tensor(_ data: [Int32], _ shape: [Int]) throws -> ORTValue {
        let md = NSMutableData(bytes: data, length: data.count * MemoryLayout<Int32>.size)
        return try ORTValue(tensorData: md, elementType: .int32, shape: shape.map { NSNumber(value: $0) })
    }

    private func readFloats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Kho tensor heads (text_emb/audio_emb/xvec_*) nạp bằng mmap từ heads.bin + heads.json.
final class HeadsStore {
    private let nsData: NSData
    private let basePtr: UnsafeRawPointer
    private let manifest: [String: (shape: [Int], offset: Int, count: Int)]

    init(dir: URL) throws {
        let manifestData = try Data(contentsOf: dir.appendingPathComponent("heads.json"))
        let raw = (try JSONSerialization.jsonObject(with: manifestData) as? [String: [String: Any]]) ?? [:]
        var manifest: [String: (shape: [Int], offset: Int, count: Int)] = [:]
        for (name, entry) in raw {
            let shape = (entry["shape"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            let offset = (entry["offset"] as? NSNumber)?.intValue ?? 0
            let count = (entry["count"] as? NSNumber)?.intValue ?? 0
            manifest[name] = (shape, offset, count)
        }
        self.manifest = manifest
        nsData = try NSData(contentsOf: dir.appendingPathComponent("heads.bin"),
                            options: [.mappedIfSafe])
        basePtr = UnsafeRawPointer(nsData.bytes)
    }

    func base(_ name: String) -> UnsafePointer<Float> {
        let entry = manifest[name]!
        return basePtr.advanced(by: entry.offset).assumingMemoryBound(to: Float.self)
    }

    func row(_ name: String, _ row: Int, _ cols: Int) -> UnsafePointer<Float> {
        base(name).advanced(by: row * cols)
    }

    func slice(_ name: String) -> [Float] {
        let entry = manifest[name]!
        return [Float](UnsafeBufferPointer(start: base(name), count: entry.count))
    }

    /// Con trỏ tới đầu khối audio_emb của kênh ch (ma trận 1024x768).
    func audioEmbBase(_ ch: Int) -> UnsafePointer<Float> {
        let entry = manifest["audio_emb"]!
        let perChannel = entry.count / 16
        return basePtr.advanced(by: entry.offset)
            .assumingMemoryBound(to: Float.self)
            .advanced(by: ch * perChannel)
    }

    func audioEmbRow(_ ch: Int, _ id: Int, _ cols: Int) -> UnsafePointer<Float> {
        audioEmbBase(ch).advanced(by: id * cols)
    }
}

/// Kho giọng preset: phân giải tên -> (speaker_emb, ref_codes) + nhãn hiển thị,
/// thứ tự như sorted_voices của bản gốc (featured trước theo hạng, còn lại giữ
/// nguyên thứ tự trong file JSON).
final class VoiceStore {
    struct Preset {
        let name: String
        let description: String
        let gender: String
        let featured: Int?
        let speakerEmb: [Float]
        let codes: [[Int]]
        var label: String {
            let base = description.isEmpty ? name : "\(name) — \(description)"
            return featured != nil ? "⭐ \(base)" : base
        }
    }

    let presets: [Preset]
    let defaultName: String
    private let byName: [String: Preset]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let presetsDict = (root["presets"] as? [String: Any]) ?? [:]
        let orderedNames = Self.orderedPresetNames(jsonText: String(data: data, encoding: .utf8) ?? "")
        var list: [Preset] = []
        var map: [String: Preset] = [:]
        for name in orderedNames {
            guard let v = presetsDict[name] as? [String: Any] else { continue }
            let emb = ((v["speaker_emb"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.floatValue }
            let rawCodes = ((v["codes"] as? [[Any]]) ?? []).map { frame in
                frame.compactMap { ($0 as? NSNumber)?.intValue }
            }
            let preset = Preset(
                name: name,
                description: (v["description"] as? String) ?? "",
                gender: (v["gender"] as? String) ?? "",
                featured: (v["featured"] as? NSNumber)?.intValue,
                speakerEmb: emb,
                codes: SpeechUtils.stripEncoderPadFrame(rawCodes)
            )
            list.append(preset)
            map[name] = preset
        }
        // sorted_voices: featured trước (theo hạng tăng dần), còn lại giữ thứ tự file.
        list.sort { a, b in
            switch (a.featured, b.featured) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            default: return false
            }
        }
        presets = list
        byName = map
        defaultName = (root["default_voice"] as? String) ?? (list.first?.name ?? "")
    }

    func resolve(_ name: String?) -> Preset {
        if let name, !name.isEmpty, name != "default", let p = byName[name] {
            return p
        }
        return byName[defaultName] ?? presets[0]
    }

    /// Thứ tự khóa của object "presets" trong file JSON (JSONSerialization làm mất
    /// thứ tự này) — quét văn bản thô theo độ sâu ngoặc.
    private static func orderedPresetNames(jsonText: String) -> [String] {
        guard let anchor = jsonText.range(of: "\"presets\"") else { return [] }
        let chars = Array(jsonText[anchor.upperBound...])
        var names: [String] = []
        var depth = 0
        var i = 0
        var inString = false
        var stringStart = 0
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                    if depth == 1 {
                        // Chuỗi ở độ sâu 1 (ngay trong object presets) vừa đóng: là
                        // tên preset nếu sau nó là ':' rồi '{' (object của preset đó).
                        var j = i + 1
                        while j < chars.count && (chars[j] == " " || chars[j] == ":" || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r") { j += 1 }
                        if j < chars.count && chars[j] == "{" {
                            names.append(String(chars[stringStart..<i]))
                        }
                    }
                }
            } else {
                if c == "\"" {
                    inString = true
                    stringStart = i + 1
                } else if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            i += 1
        }
        return names
    }
}
