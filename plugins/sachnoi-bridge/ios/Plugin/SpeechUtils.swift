import Foundation

/// Các hàm phụ của pipeline: trần frame, chống "nói thêm" (babble guard),
/// ghép audio theo khoảng nghỉ, lịch sử phạt lặp — chép từ vieneu_utils/core_utils.py
/// và rep_history.py (đã đối chiếu trong proto.py).
enum SpeechUtils {
    static let codecSamplesPerFrame = 3840
    static let encoderPadCode = 455
    static let gapSilence: [String: Double] = ["para": 0.70, "sentence": 0.50, "minor": 0.30]
    static let babbleMaxRetries = 2

    private static let markupRegex = try! NSRegularExpression(pattern: "<\\|emotion_\\d+\\|>|</?en>")
    private static let ipaVowels: Set<Character> = Set("aeiouyæɐɑɒɔəɘɛɜɤɯɵøœʉʊʌɪɨɚɝᵻᵿ")

    static func stripMarkup(_ s: String) -> String {
        let ns = s as NSString
        return markupRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    static func isCueOnly(_ phonemes: String) -> Bool {
        phonemes.contains("<|emotion_") && !stripMarkup(phonemes).contains { $0.isLetter }
    }

    static func syllableCount(_ phonemes: String) -> Int {
        let stripped = stripMarkup(phonemes)
        var total = 0
        for tok in stripped.split(whereSeparator: { $0.isWhitespace }) {
            var groups = 0
            var inV = false
            var consonantSeen = true
            for ch in tok {
                if ipaVowels.contains(ch) {
                    if !inV && consonantSeen { groups += 1 }
                    inV = true
                    consonantSeen = false
                } else if ch == "ː" || ch == "ˈ" || ch == "ˌ" || ch.isNumber {
                    if (ch == "ˈ" || ch == "ˌ") && groups > 0 {
                        inV = false
                        consonantSeen = true
                    } else {
                        inV = false
                    }
                } else {
                    inV = false
                    consonantSeen = true
                }
            }
            if tok.contains(where: { $0.isLetter }) {
                total += max(1, groups)
            }
        }
        return total
    }

    static func maxExpectedFrames(_ phonemes: String) -> Int {
        let effLen = stripMarkup(phonemes).count
        var cap = 24 + Int(ceil(2.0 * Double(effLen)))
        if isCueOnly(phonemes) {
            return min(cap, 13)
        }
        if !phonemes.contains("<|emotion_") {
            let syl = max(1, syllableCount(phonemes))
            if syl <= 4 && effLen <= 24 * syl {
                cap = min(cap, 13 + 5 * (syl - 1))
            }
        }
        return cap
    }

    static func gapsToSilence(_ gaps: [String]) -> [Double] {
        gaps.map { gapSilence[$0] ?? gapSilence["sentence"]! }
    }

    /// 1.9.4: khoảng lặng tại dấu câu do NGƯỜI DÙNG đặt (một giá trị chung):
    /// "sentence" và "minor" đều dùng punct; "para" dùng para.
    static func gapsToSilence(_ gaps: [String], punct: Double, para: Double) -> [Double] {
        gaps.map { $0 == "para" ? para : punct }
    }

    // MARK: - Ghép chunk

    static func edgeSilence(_ wav: [Float], _ sr: Int, threshDb: Double = -45.0, winS: Double = 0.01) -> (Int, Int) {
        let nSamp = wav.count
        let win = max(1, Int(winS * Double(sr)))
        let nWin = nSamp / win
        if nWin == 0 { return (nSamp, 0) }
        let thresh = pow(10.0, threshDb / 20.0)
        var firstAbove: Int?
        var lastAbove: Int?
        for w in 0..<nWin {
            var sum: Float = 0
            for i in 0..<win { sum += abs(wav[w * win + i]) }
            if Double(sum / Float(win)) > thresh {
                if firstAbove == nil { firstAbove = w }
                lastAbove = w
            }
        }
        guard let first = firstAbove, let last = lastAbove else { return (nSamp, 0) }
        return (first * win, nSamp - (last + 1) * win)
    }

    static func pausePadSamples(_ prev: [Float], _ next: [Float], _ sr: Int, _ pauseS: Double) -> Int {
        let (leadPrev, tail0) = edgeSilence(prev, sr)
        var tail = tail0
        if leadPrev == prev.count { tail = prev.count }
        let (lead, _) = edgeSilence(next, sr)
        return max(0, Int(pauseS * Double(sr)) - tail - lead)
    }

    static func joinAudioChunks(_ chunks: [[Float]], _ sr: Int, silencePs: [Double]) -> [Float] {
        guard let first = chunks.first else { return [] }
        var out = first
        for i in 1..<chunks.count {
            let pauseS = i - 1 < silencePs.count ? silencePs[i - 1] : 0.0
            let pad = pausePadSamples(chunks[i - 1], chunks[i], sr, pauseS)
            if pad > 0 { out += [Float](repeating: 0, count: pad) }
            out += chunks[i]
        }
        return out
    }

    // MARK: - Babble guard

    static func countSpeechBursts(_ wav: [Float], _ sr: Int) -> Int {
        let hop = max(1, Int(Double(sr) * 0.010))
        let n = wav.count / hop
        if n == 0 { return 0 }
        var env = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Double = 0
            for j in 0..<hop {
                let v = Double(wav[i * hop + j])
                sum += v * v
            }
            env[i] = sqrt(sum / Double(hop))
        }
        guard let peak = env.max(), peak > 1e-6 else { return 0 }
        let thresh = peak * pow(10.0, -18.0 / 20.0)
        let minGap = max(1, 60 / 10)
        let minLen = max(1, 30 / 10)
        var bursts: [(Int, Int)] = []
        var start: Int?
        var lastOn: Int?
        for (i, e) in env.enumerated() where e > thresh {
            if start == nil {
                start = i
            } else if let lo = lastOn, i - lo > minGap {
                bursts.append((start!, lo))
                start = i
            }
            lastOn = i
        }
        if let s = start, let lo = lastOn { bursts.append((s, lo)) }
        return bursts.filter { $0.1 - $0.0 + 1 >= minLen }.count
    }

    /// (suspect, syllables, bursts, nFrames) cho một chunk vừa sinh.
    static func babbleSuspect(_ wav: [Float], _ sr: Int, _ phonemes: String, _ capFrames: Int,
                              nFrames: Int) -> (Bool, Int, Int, Int) {
        if isCueOnly(phonemes) {
            return (nFrames >= capFrames - 1, 0, 0, nFrames)
        }
        let syl = syllableCount(phonemes)
        if syl == 0 || syl > 3 || phonemes.contains("<|emotion_") {
            return (false, syl, 0, 0)
        }
        let bursts = countSpeechBursts(wav, sr)
        let hitCap = syl <= 2 && nFrames >= capFrames - 1
        return (bursts > syl || hitCap, syl, bursts, nFrames)
    }

    static func babblePrefer(_ new: (Bool, Int, Int, Int), _ old: (Bool, Int, Int, Int)) -> Bool {
        if new.0 != old.0 { return !new.0 }
        return new.2 < old.2 || (new.2 == old.2 && new.3 < old.3)
    }

    static func stripEncoderPadFrame(_ codes: [[Int]]) -> [[Int]] {
        if codes.count > 1, let first = codes.last?.first, first == encoderPadCode {
            return Array(codes.dropLast())
        }
        return codes
    }
}

/// Lịch sử phạt lặp trượt cửa sổ 64 frame/kênh (port rep_history.py).
final class RepetitionHistory {
    private struct Channel {
        var seen: [Int: Int] = [:]
        var order: [Int] = []
        var head = 0
    }
    private var channels: [Channel]
    private let window: Int

    init(nChannels: Int, window: Int = 64) {
        channels = [Channel](repeating: Channel(), count: nChannels)
        self.window = window
    }

    func codes(in channel: Int) -> [Int] {
        Array(channels[channel].seen.keys)
    }

    func add(_ code: Int, in channel: Int) {
        channels[channel].seen[code, default: 0] += 1
        if window > 0 {
            channels[channel].order.append(code)
            if channels[channel].order.count - channels[channel].head > window {
                let old = channels[channel].order[channels[channel].head]
                channels[channel].head += 1
                if let count = channels[channel].seen[old] {
                    if count <= 1 { channels[channel].seen.removeValue(forKey: old) }
                    else { channels[channel].seen[old] = count - 1 }
                }
            }
        }
    }
}

/// RNG SplitMix64 — chỉ cần phân phối đều cho sampling, không cần khớp numpy.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
