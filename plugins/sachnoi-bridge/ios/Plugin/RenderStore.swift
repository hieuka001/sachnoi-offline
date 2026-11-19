import Foundation
import AVFoundation
import CryptoKit

/// RenderStore (2.2.0) — kho audio ĐÃ RENDER TRƯỚC trên đĩa: cơ chế đọc liền
/// mạch của các app sách nói lớn (ebook2audiobook...) áp vào Sách Nói Offline.
///
/// Vì sao: VieNeu Turbo trên iPhone sinh âm THANH CHẬM hơn tốc độ nghe ở
/// nhiều thời điểm (máy thật 1.9.6: ~9,8 giây cho 102 ký tự, máy nóng lên
/// thermal 2) — sinh đến đâu nghe đến đó thì không bao giờ liền mạch bền
/// vững. Render trước ra file thì phát lại là việc của riêng tầng phát (đã
/// kiểm chứng chạy nền từ 1.0.3), không còn phụ thuộc tốc độ sinh.
///
/// Mỗi đoạn phát (theo chỉ số đoạn của NativePlayer) = 1 file AAC .m4a
/// (~64kbps mono ≈ 29MB/giờ nghe — WAV thô 48kHz sẽ tốn ~345MB/giờ).
/// Khoá render gồm bookId + giọng + 2 khoảng nghỉ (nghỉ được engine nướng
/// vào audio nên đổi là phải render lại); tốc độ/âm lượng/tông là tầng phát
/// nên KHÔNG vào khoá.
public enum RenderStore {
    public static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SachNoi/TTSRender", isDirectory: true)
    }

    public static func key(bookId: String, voice: String, gapPunct: Double, gapParagraph: Double) -> String {
        let raw = "\(voice)|\(gapPunct)|\(gapParagraph)"
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(PackStore.sanitize(bookId))-\(digest.prefix(10))"
    }

    public static func dir(_ key: String) -> URL {
        rootURL.appendingPathComponent(key, isDirectory: true)
    }

    public static func fileURL(_ key: String, _ idx: Int) -> URL {
        dir(key).appendingPathComponent("\(idx).m4a")
    }

    public static func exists(_ key: String, _ idx: Int) -> Bool {
        !key.isEmpty && FileManager.default.fileExists(atPath: fileURL(key, idx).path)
    }

    public static func ensureDir(_ key: String) {
        var url = dir(key)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Số đoạn đã render trong [0, total).
    public static func renderedCount(_ key: String, total: Int) -> Int {
        guard !key.isEmpty, total > 0 else { return 0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir(key).path)) ?? []
        var n = 0
        for name in names where name.hasSuffix(".m4a") {
            if let idx = Int(name.dropLast(4)), idx >= 0, idx < total { n += 1 }
        }
        return n
    }

    /// Tập chỉ số đã render (renderer dùng để biết việc còn lại).
    public static func renderedIndices(_ key: String, total: Int) -> Set<Int> {
        guard !key.isEmpty, total > 0 else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir(key).path)) ?? []
        var out = Set<Int>()
        for name in names where name.hasSuffix(".m4a") {
            if let idx = Int(name.dropLast(4)), idx >= 0, idx < total { out.insert(idx) }
        }
        return out
    }

    /// Lưu WAV PCM16 (đầu ra của engine) thành file AAC .m4a — ghi file tạm
    /// rồi đổi tên nguyên tử để file dở dang không bao giờ bị phát.
    public static func saveWav(_ key: String, _ idx: Int, wav: Data) throws {
        guard let buffer = pcmBuffer(fromWav: wav) else {
            throw NSError(domain: "RenderStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "WAV không hợp lệ"])
        }
        ensureDir(key)
        let final = fileURL(key, idx)
        let tmp = dir(key).appendingPathComponent("\(idx).tmp.m4a")
        try? FileManager.default.removeItem(at: tmp)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]
        let file = try AVAudioFile(forWriting: tmp, settings: settings)
        try file.write(from: buffer)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)
    }

    /// Giải mã WAV RIFF PCM16 mono (định dạng engine viết) thẳng trong bộ nhớ.
    private static func pcmBuffer(fromWav data: Data) -> AVAudioPCMBuffer? {
        guard data.count > 44,
              data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
              data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45
        else { return nil }
        func u32(_ off: Int) -> Int { Int(data[off]) | Int(data[off + 1]) << 8 | Int(data[off + 2]) << 16 | Int(data[off + 3]) << 24 }
        func u16(_ off: Int) -> Int { Int(data[off]) | Int(data[off + 1]) << 8 }
        var off = 12
        var dataOff = -1
        var dataLen = 0
        while off + 8 <= data.count {
            let id = String(bytes: data[off..<(off + 4)], encoding: .ascii) ?? ""
            let len = u32(off + 4)
            if id == "data" { dataOff = off + 8; dataLen = len; break }
            off += 8 + len
        }
        guard dataOff > 0 else { return nil }
        let channels = u16(22)
        let sampleRate = u32(24)
        let bits = u16(34)
        guard channels == 1, bits == 16, sampleRate > 0 else { return nil }
        let frames = min(dataLen / 2, (data.count - dataOff) / 2)
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let src = base.advanced(by: dataOff).assumingMemoryBound(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(src[i]) / 32768.0 }
        }
        return buffer
    }

    /// Trần dung lượng toàn kho render: vượt thì xoá cả thư mục sách cũ nhất
    /// (theo ngày sửa gần nhất), chừa thư mục đang dùng.
    public static func evictIfNeeded(exceptKey: String, capBytes: Int64 = 2_500_000_000) {
        let fm = FileManager.default
        guard PackStore.directorySize(rootURL) > capBytes else { return }
        let dirs = ((try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent != exceptKey }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (da ?? .distantPast) < (db ?? .distantPast)
            }
        for d in dirs {
            if PackStore.directorySize(rootURL) <= capBytes { break }
            try? fm.removeItem(at: d)
        }
    }
}
