import Foundation

/// Tokenizer BPE (chỉ chiều encode) chép theo tokenizer.json của VieNeu v3 Turbo:
/// pre-tokenizer GPT-2 (regex tách) + ByteLevel + BPE 419 token / 119 merge.
/// Đã đối chiếu khớp 100% với thư viện `tokenizers` trong bản mẫu Python (proto.py).
final class BpeTokenizer {
    private let vocab: [String: Int]
    private let ranks: [PairKey: Int]
    private let added: [(content: String, id: Int)]   // sắp theo độ dài giảm dần
    private let splitter: NSRegularExpression
    private let byteEncoder: [UInt8: Character]

    private struct PairKey: Hashable {
        let a: String
        let b: String
    }

    init(jsonData: Data) throws {
        let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        let model = root?["model"] as? [String: Any]
        var vocab: [String: Int] = [:]
        for (k, v) in (model?["vocab"] as? [String: Any]) ?? [:] {
            if let n = v as? NSNumber { vocab[k] = n.intValue }
        }
        self.vocab = vocab

        var ranks: [PairKey: Int] = [:]
        let merges = (model?["merges"] as? [Any]) ?? []
        for (i, m) in merges.enumerated() {
            if let s = m as? String, let sp = s.firstIndex(of: " ") {
                ranks[PairKey(a: String(s[..<sp]), b: String(s[s.index(after: sp)...]))] = i
            } else if let pair = m as? [String], pair.count == 2 {
                ranks[PairKey(a: pair[0], b: pair[1])] = i
            }
        }
        self.ranks = ranks

        var added: [(String, Int)] = []
        for a in (root?["added_tokens"] as? [[String: Any]]) ?? [] {
            if let content = a["content"] as? String, let id = (a["id"] as? NSNumber)?.intValue {
                added.append((content, id))
            }
        }
        self.added = added.sorted { $0.0.count > $1.0.count }

        // Regex tách tiền tố lấy thẳng từ file tokenizer (pre_tokenizer dạng Sequence:
        // phần tử đầu là Split kiểu GPT-2) — khớp nguyên văn hành vi của bản gốc.
        var pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        if let pre = root?["pre_tokenizer"] as? [String: Any],
           let seq = pre["pretokenizers"] as? [[String: Any]],
           let first = seq.first,
           let pat = first["pattern"] as? [String: Any],
           let regex = pat["Regex"] as? String {
            pattern = regex
        }
        self.splitter = try NSRegularExpression(pattern: pattern)

        // Bảng byte -> ký tự unicode của ByteLevel (thuật toán GPT-2 gốc).
        var bs: [Int] = []
        bs += Array(33...126)
        bs += Array(161...172)
        bs += Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var enc: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) {
            enc[UInt8(b)] = Character(UnicodeScalar(c)!)
        }
        self.byteEncoder = enc
    }

    func encode(_ text: String) -> [Int] {
        if added.isEmpty { return encodePlain(text) }
        var ids: [Int] = []
        var buffer = ""
        var i = text.startIndex
        while i < text.endIndex {
            let rest = text[i...]
            var hit: (String, Int)?
            for (content, id) in added where rest.hasPrefix(content) {
                hit = (content, id)
                break
            }
            if let (content, id) = hit {
                if !buffer.isEmpty {
                    ids += encodePlain(buffer)
                    buffer = ""
                }
                ids.append(id)
                i = text.index(i, offsetBy: content.count)
            } else {
                buffer.append(text[i])
                i = text.index(after: i)
            }
        }
        if !buffer.isEmpty { ids += encodePlain(buffer) }
        return ids
    }

    private func encodePlain(_ text: String) -> [Int] {
        var ids: [Int] = []
        let ns = text as NSString
        let matches = splitter.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let piece = ns.substring(with: m.range)
            var word = ""
            for byte in piece.utf8 {
                if let ch = byteEncoder[byte] { word.append(ch) }
            }
            for symbol in bpe(word) {
                if let id = vocab[symbol] { ids.append(id) }
            }
        }
        return ids
    }

    /// Vòng merge BPE: mỗi lượt gộp MỘT cặp có hạng thấp nhất (chép đúng bản mẫu đã kiểm chứng).
    private func bpe(_ word: String) -> [String] {
        var symbols = word.map { String($0) }
        while symbols.count > 1 {
            var bestIndex: Int?
            var bestRank = Int.max
            for i in 0..<(symbols.count - 1) {
                if let r = ranks[PairKey(a: symbols[i], b: symbols[i + 1])], r < bestRank {
                    bestRank = r
                    bestIndex = i
                }
            }
            guard let i = bestIndex else { break }
            symbols[i] = symbols[i] + symbols[i + 1]
            symbols.remove(at: i + 1)
        }
        return symbols
    }
}
