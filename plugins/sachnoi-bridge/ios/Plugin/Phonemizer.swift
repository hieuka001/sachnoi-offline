import Foundation

/// Toàn bộ logic chia chunk + phiên âm chép 1-1 từ vieneu_utils (đã đối chiếu
/// khớp tuyệt đối với bản Python trong proto.py/harness.py):
///   normalize_to_chunks_v3_with_gaps -> phonemize_text_with_emotions -> engine.
/// Hai thao tác từ điển (normalize/phonemize từng câu) đi qua sea-g2p (Rust).
final class Phonemizer {
    private let g2p: SeaG2pEngine

    init(g2p: SeaG2pEngine) {
        self.g2p = g2p
    }

    // MARK: - API chính

    /// (chunks, gaps) — gaps[i] ∈ {"para","sentence","minor"} là ranh giới sau chunks[i].
    func chunksWithGaps(_ text: String, maxChars: Int = 256, minChunkChars: Int = 20) -> ([String], [String]) {
        if text.isEmpty { return ([], []) }
        let keepCues = text.contains("[") || text.contains("<|emotion_")
        var chunks: [String] = []
        var gaps: [String] = []
        for sentences in normalizedSentencesByPara(text, keepCues: keepCues) {
            let paraChunks = packSentencesIntoChunks(sentences, maxChars: maxChars)
            if paraChunks.isEmpty { continue }
            if !chunks.isEmpty { gaps.append("para") }
            for (j, ch) in paraChunks.enumerated() {
                if j > 0 { gaps.append("sentence") }
                chunks.append(ch)
            }
        }
        chunks = chunks.map { Phonemizer.puncNorm($0) }
        gaps = gaps.enumerated().map { (i, g) in g == "para" ? g : Phonemizer.classifyGap(chunks[i]) }
        return Phonemizer.mergeShortChunks(chunks, gaps, minChars: minChunkChars)
    }

    func phonemizeWithEmotions(_ text: String) -> String {
        if !text.contains("[") && !text.contains("<|emotion_") {
            return g2p.phonemize(text, puncNorm: true)
        }
        var out = ""
        let parts = Phonemizer.emotionSplit(text)
        for (i, part) in parts.enumerated() {
            let token = i % 2 == 1 ? Phonemizer.emotionTagToken(part) : nil
            if let token {
                out = out.isEmpty ? token : out + " " + token
                continue
            }
            let ph = (!part.isEmpty && !part.trimmingCharacters(in: .whitespaces).isEmpty)
                ? g2p.phonemize(part, puncNorm: false) : ""
            if ph.isEmpty { continue }
            if out.isEmpty {
                out = ph
            } else if let first = ph.first, Phonemizer.attachingPunct.contains(first) {
                out += ph
            } else {
                out += " " + ph
            }
        }
        return Phonemizer.puncNorm(out)
    }

    // MARK: - Chuẩn hoá theo đoạn/câu

    private func normalizedSentencesByPara(_ text: String, keepCues: Bool) -> [[String]] {
        let paragraphs = text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // components tách từng ký tự đơn — gộp lại các đoạn liên tiếp bị cắt bởi \r\n liên tục:
        // (tương đương regex [\r\n]+ của bản gốc: đoạn rỗng đã bị lọc ở trên)
        var out: [[String]] = []
        for para in paragraphs {
            let sentences = Phonemizer.splitIntoSentences(para)
            if sentences.isEmpty { continue }
            if keepCues {
                out.append(sentences.map { normalizeSentenceKeepCues($0) })
            } else {
                out.append(sentences.map { g2p.normalize($0, puncNorm: false) })
            }
        }
        return out
    }

    private func normalizeSentenceKeepCues(_ sentence: String) -> String {
        if !sentence.contains("[") && !sentence.contains("<|emotion_") {
            return g2p.normalize(sentence, puncNorm: false)
        }
        var parts: [String] = []
        for (i, part) in Phonemizer.emotionSplit(sentence).enumerated() {
            if i % 2 == 1 {
                parts.append(Phonemizer.emotionTagToken(part) ?? part)
            } else if !part.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append(g2p.normalize(part, puncNorm: false))
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Tách theo thẻ emotion ([cười] / <|emotion_k|>) — như re.split có 1 group

    static let emotionTagToK: [String: Int] = [
        "chuckle": 1, "cười": 1, "cuoi": 1,
        "sigh": 2, "thở dài": 2, "tho dai": 2,
        "clear throat": 3, "hắng giọng": 3, "hang giong": 3,
    ]
    static let attachingPunct: Set<Character> = Set(".,!?;:…)]}\"'’”")
    private static let emotionRegex = try! NSRegularExpression(pattern: "(\\[[^\\]]+\\]|<\\|emotion_\\d+\\|>)")

    static func emotionSplit(_ text: String) -> [String] {
        let ns = text as NSString
        var parts: [String] = []
        var last = 0
        for m in emotionRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            parts.append(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    static func emotionTagToken(_ tag: String) -> String? {
        let t = tag.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<|") { return t }
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
        if let k = emotionTagToK[inner] { return "<|emotion_\(k)|>" }
        return nil
    }

    static func effectiveLen(_ chunk: String) -> Int {
        let stripped = chunk.replacingOccurrences(of: "<\\|emotion_\\d+\\|>", with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespaces).count
    }

    static func mergeShortChunks(_ chunksIn: [String], _ gapsIn: [String], minChars: Int) -> ([String], [String]) {
        var chunks = chunksIn
        var gaps = gapsIn
        while chunks.count > 1 {
            let shortIdx = chunks.indices.filter { effectiveLen(chunks[$0]) < minChars }
            if shortIdx.isEmpty { break }
            let i = shortIdx.min(by: { effectiveLen(chunks[$0]) < effectiveLen(chunks[$1]) })!
            var sides: [((Bool, Int), String)] = []
            if i < chunks.count - 1 { sides.append(((gaps[i] != "para", -chunks[i + 1].count), "R")) }
            if i > 0 { sides.append(((gaps[i - 1] != "para", -chunks[i - 1].count), "L")) }
            var best = sides[0]
            for s in sides.dropFirst() where (s.0.0 && !best.0.0) || (s.0.0 == best.0.0 && s.0.1 > best.0.1) {
                best = s
            }
            if best.1 == "R" {
                chunks[i] = chunks[i] + " " + chunks.remove(at: i + 1)
                gaps.remove(at: i)
            } else {
                chunks[i - 1] = chunks[i - 1] + " " + chunks.remove(at: i)
                gaps.remove(at: i - 1)
            }
        }
        return (chunks, gaps)
    }

    static func classifyGap(_ chunk: String) -> String {
        let c = chunk.trimmingCharacters(in: .whitespaces)
        if let last = c.last, ".!?".contains(last) { return "sentence" }
        return "minor"
    }

    // MARK: - Tách câu nhận biết ngoặc/trích dẫn (port _scan_sentences)

    private static let openToClose: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "“": "”", "‘": "’", "«": "»", "‹": "›", "「": "」", "『": "』",
    ]
    private static let openers: Set<Character> = Set(openToClose.keys)
    private static let closers: Set<Character> = Set(openToClose.values)
    private static let sentEndChars: Set<Character> = Set(".!?…")
    private static let trailingClose: Set<Character> = closers.union(Set("\"'’”"))

    static func splitIntoSentences(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var (sentences, balanced) = scanSentences(text, quoteAware: true)
        if !balanced {
            (sentences, _) = scanSentences(text, quoteAware: false)
        }
        return sentences
    }

    private static func scanSentences(_ text: String, quoteAware: Bool) -> ([String], Bool) {
        let chars = Array(text)
        let n = chars.count
        var sentences: [String] = []
        var start = 0
        var i = 0
        var depth = 0
        var inQuote = false
        while i < n {
            let ch = chars[i]
            if quoteAware && ch == "\"" {
                inQuote.toggle()
            } else if quoteAware && openers.contains(ch) {
                depth += 1
            } else if quoteAware && closers.contains(ch) {
                if depth > 0 { depth -= 1 }
            } else if sentEndChars.contains(ch) && depth == 0 && !inQuote {
                var j = i + 1
                while j < n && sentEndChars.contains(chars[j]) { j += 1 }
                while j < n && trailingClose.contains(chars[j]) { j += 1 }
                if j >= n || chars[j].isWhitespace {
                    sentences.append(String(chars[start..<j]))
                    start = j
                    i = j
                    continue
                }
                i = j
                continue
            }
            i += 1
        }
        if start < n {
            sentences.append(String(chars[start..<n]))
        }
        let cleaned = sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (cleaned, depth == 0 && !inQuote)
    }

    // MARK: - Đóng gói câu thành chunk (port pack_sentences_into_chunks + helpers)

    private static let connWords: Set<String> = Set("và nhưng hoặc song rồi nên vì nếu khi để do bởi".split(separator: " ").map(String.init))
    private static let connPairs: Set<[String]> = Set([
        ["sau", "khi"], ["trước", "khi"], ["trong", "khi"], ["mỗi", "khi"],
        ["đến", "khi"], ["tới", "khi"], ["cho", "nên"], ["cho", "đến"],
        ["bởi", "vì"], ["nếu", "như"], ["tuy", "nhiên"], ["thế", "nhưng"],
        ["vì", "vậy"], ["vì", "thế"], ["do", "đó"], ["sau", "đó"],
    ])
    private static let connStrip: Set<Character> = Set("\"'“”‘’()[]«»…")
    private static let numberWords: Set<String> = Set(
        "không một mốt hai ba bốn tư năm lăm sáu bảy tám chín mười mươi trăm nghìn ngàn triệu tỷ tỉ linh lẻ phẩy chấm"
            .split(separator: " ").map(String.init))
    private static let minorPunct: Set<Character> = Set(",;:-\u{2013}\u{2014}")

    private static func connKey(_ token: String) -> String {
        var t = token
        while let f = t.first, connStrip.contains(f) { t.removeFirst() }
        while let l = t.last, connStrip.contains(l) { t.removeLast() }
        return t.lowercased()
    }

    private static func tailSlack(_ maxChars: Int) -> Int { min(15, maxChars / 8) }

    private static func fits(_ curLen: Int, _ addLen: Int, _ maxChars: Int) -> Bool {
        let total = curLen > 0 ? curLen + 1 + addLen : addLen
        let slack = tailSlack(maxChars)
        return total <= maxChars || (addLen <= slack && total <= maxChars + slack)
    }

    private static func isNumberWord(_ token: String) -> Bool {
        let key = connKey(token)
        return numberWords.contains(key) || (!key.isEmpty && key.allSatisfy { $0.isNumber })
    }

    private static func spanLen(_ words: [String], _ start: Int, _ end: Int) -> Int {
        if end <= start { return 0 }
        return words[start..<end].reduce(0) { $0 + $1.count } + (end - start - 1)
    }

    private static func tokenizeKeepEn(_ s: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            if String(chars[i...]).hasPrefix("<en>"),
               let close = s.range(of: "</en>", range: s.index(s.startIndex, offsetBy: i)..<s.endIndex) {
                let tok = String(s[s.index(s.startIndex, offsetBy: i)..<close.upperBound])
                tokens.append(tok)
                i += tok.count
                continue
            }
            var j = i
            while j < chars.count && !chars[j].isWhitespace { j += 1 }
            tokens.append(String(chars[i..<j]))
            i = j
        }
        return tokens
    }

    private static func balancedCut(_ words: [String], _ start: Int, _ target: Double, _ maxChars: Int, _ minLeft: Int) -> Int {
        var bestNat: (Double, Int)?
        var bestPlain: (Double, Int)?
        var endCap = start + 1
        var j = start + 1
        while j < words.count {
            let left = spanLen(words, start, j)
            if left > maxChars { break }
            endCap = j
            let key = connKey(words[j])
            let prev = connKey(words[j - 1])
            let nxt = j + 1 < words.count ? connKey(words[j + 1]) : ""
            let d = abs(Double(left) - target)
            let insidePair = connPairs.contains([prev, key])
            let natural = (connWords.contains(key) || connPairs.contains([key, nxt])) && !connWords.contains(prev)
            if natural && !insidePair && left >= minLeft && (bestNat == nil || d < bestNat!.0) {
                bestNat = (d, j)
            }
            let plainOk = !insidePair && !(isNumberWord(words[j - 1]) && isNumberWord(words[j]))
            if plainOk && (bestPlain == nil || d < bestPlain!.0) {
                bestPlain = (d, j)
            }
            j += 1
        }
        if let nat = bestNat { return nat.1 }
        if let plain = bestPlain { return plain.1 }
        var end = endCap
        while end > start + 1 && connPairs.contains([connKey(words[end - 1]), connKey(words[end])]) {
            end -= 1
        }
        return end
    }

    private static func splitLongPart(_ part: String, _ maxChars: Int) -> [String] {
        let words = tokenizeKeepEn(part)
        let minLeft = maxChars / 3
        var pieces: [String] = []
        var start = 0
        while start < words.count {
            let rest = spanLen(words, start, words.count)
            if rest <= maxChars {
                pieces.append(words[start...].joined(separator: " "))
                break
            }
            var full = start + 1
            while full < words.count && spanLen(words, start, full + 1) <= maxChars { full += 1 }
            if fits(spanLen(words, start, full), spanLen(words, full, words.count), maxChars) {
                pieces.append(words[start...].joined(separator: " "))
                break
            }
            let nPieces = Int(ceil(Double(rest) / Double(maxChars)))
            let end = balancedCut(words, start, Double(rest) / Double(nPieces), maxChars, minLeft)
            pieces.append(words[start..<end].joined(separator: " "))
            start = end
        }
        return pieces
    }

    private static func splitMinorPunct(_ sentence: String) -> [String] {
        var parts: [String] = []
        let chars = Array(sentence)
        var start = 0
        var i = 0
        while i < chars.count {
            if minorPunct.contains(chars[i]), i + 1 < chars.count, chars[i + 1].isWhitespace {
                parts.append(String(chars[start...i]))
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                start = j
                i = j
                continue
            }
            i += 1
        }
        if start < chars.count { parts.append(String(chars[start...])) }
        else if start == chars.count && !parts.isEmpty { /* không thêm mẩu rỗng ở đuôi */ }
        return parts
    }

    func packSentencesIntoChunks(_ sentences: [String], maxChars: Int = 256) -> [String] {
        var finalChunks: [String] = []
        var buffer = ""
        for raw in sentences {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            if sentence.isEmpty { continue }
            if sentence.count > maxChars {
                if !buffer.isEmpty {
                    finalChunks.append(buffer)
                    buffer = ""
                }
                for rawPart in Phonemizer.splitMinorPunct(sentence) {
                    let part = rawPart.trimmingCharacters(in: .whitespaces)
                    if part.isEmpty { continue }
                    if Phonemizer.fits(buffer.count, part.count, maxChars) {
                        buffer = buffer.isEmpty ? part : buffer + " " + part
                    } else {
                        if !buffer.isEmpty { finalChunks.append(buffer) }
                        buffer = part
                        if buffer.count > maxChars {
                            let pieces = Phonemizer.splitLongPart(buffer, maxChars)
                            finalChunks += pieces.dropLast()
                            buffer = pieces.last ?? ""
                        }
                    }
                }
            } else {
                if !buffer.isEmpty && !Phonemizer.fits(buffer.count, sentence.count, maxChars) {
                    finalChunks.append(buffer)
                    buffer = sentence
                } else {
                    buffer = buffer.isEmpty ? sentence : buffer + " " + sentence
                }
            }
        }
        if !buffer.isEmpty { finalChunks.append(buffer) }
        return finalChunks
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - punc_norm (port sea-g2p/src/punc.rs)

    private static let punctRunRegex = try! NSRegularExpression(pattern: "[.,!?;:](?:[ \\t]*[.,!?;:])+")
    private static let trailingPunct: Set<Character> = Set(",.!?;:…‥․")

    private static func punctRank(_ c: Character) -> Int {
        switch c {
        case "?": return 3
        case "!": return 2
        case ".": return 1
        default: return 0
        }
    }

    static func collapsePunctRuns(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in punctRunRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let run = ns.substring(with: m.range)
            var best: Character?
            for c in run where c != " " && c != "\t" {
                if best == nil || punctRank(c) > punctRank(best!) { best = c }
            }
            if let b = best { result.append(b) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { tok in tok.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
            .count
    }

    private static func softenShortSegments(_ text: String) -> String {
        let chars = Array(text)
        let n = chars.count
        // Tìm mọi '.' kết câu: '.' theo sau là khoảng trắng hoặc hết chuỗi (regex \.(\s+|$)).
        var dots: [(dot: Int, end: Int)] = []
        var i = 0
        while i < n {
            if chars[i] == "." && (i + 1 >= n || chars[i + 1].isWhitespace) {
                var j = i + 1
                while j < n && chars[j].isWhitespace { j += 1 }
                dots.append((i, j))
                i = j
                continue
            }
            i += 1
        }
        if dots.isEmpty { return text }
        var result = ""
        var last = 0
        for (dotPos, end) in dots {
            let segment = String(chars[last..<dotPos])
            let ws = String(chars[(dotPos + 1)..<end])
            let hasMore = end < n && chars[end...].contains {
                $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            }
            result += segment
            let wc = wordCount(segment)
            result += (hasMore && wc >= 1 && wc <= 2) ? "," : "."
            result += ws
            last = end
        }
        result += String(chars[last...])
        return result
    }

    static func puncNorm(_ text: String) -> String {
        var trimmed = text
        while let l = trimmed.last, l.isWhitespace { trimmed.removeLast() }
        if trimmed.isEmpty { return "" }
        var softened = softenShortSegments(trimmed)
        while let l = softened.last, l.isWhitespace { softened.removeLast() }
        trimmed = softened
        if wordCount(trimmed) <= 4 {
            var stripped = trimmed
            while let l = stripped.last, trailingPunct.contains(l) || l.isWhitespace {
                stripped.removeLast()
            }
            if stripped.isEmpty { return "." }
            return stripped + "."
        }
        if let last = trimmed.last, ",.!?".contains(last) { return trimmed }
        return trimmed + "."
    }
}
