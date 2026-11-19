import Foundation
import AVFoundation
import CryptoKit

/// RenderStore — kho audio ĐÃ RENDER TRƯỚC trên đĩa: cơ chế đọc liền mạch
/// của các app sách nói lớn (ebook2audiobook, VoiceStudio...) áp vào Sách
/// Nói Offline.
///
/// Vì sao: VieNeu Turbo trên iPhone sinh âm THANH CHẬM hơn tốc độ nghe ở
/// nhiều thời điểm (máy thật 1.9.6: ~9,8 giây cho 102 ký tự, máy nóng lên
/// thermal 2) — sinh đến đâu nghe đến đó thì không bao giờ liền mạch bền
/// vững. Render trước ra file thì phát lại là việc của riêng tầng phát (đã
/// kiểm chứng chạy nền từ 1.0.3), không còn phụ thuộc tốc độ sinh.
///
/// 3.2.0 — ĐỊA CHỈ HOÁ THEO NỘI DUNG (chắt lọc từ VoiceStudio
/// debpalash/VoiceStudio, segment cache của họ): mỗi đoạn được lưu theo
/// HASH của (nội dung câu + giọng + khoảng nghỉ) trong MỘT kho chung, thay
/// cho (sách + chỉ số đoạn) như 2.2.0. Hệ quả:
///   * sửa/trích lại 1 câu chỉ render lại đúng câu đó, cả cuốn còn nguyên;
///   * câu lặp lại trong sách (hoặc trùng giữa các sách) dùng chung 1 file;
///   * render bị ngắt (tắt app, hết pin) mở lại là tiếp tục từ đúng các
///     đoạn đã xong — vì file được ghi ngay khi từng đoạn hoàn thành.
/// Khoảng nghỉ vẫn nằm trong khoá vì engine Turbo nướng nghỉ vào audio;
/// tốc độ/âm lượng/tông là tầng phát nên KHÔNG vào khoá.
///
/// Mỗi đoạn = 1 file AAC .m4a (~64kbps mono ≈ 29MB/giờ nghe — WAV thô
/// 48kHz sẽ tốn ~345MB/giờ). Ghi file tạm rồi đổi tên nguyên tử để file
/// dở dang không bao giờ bị phát; trước khi phát còn kiểm tra file mở
/// được thật (bài học wav_is_complete của VoiceStudio) — file hỏng bị
/// xoá và sinh lại thay vì phát ra im lặng.
public enum RenderStore {
    public static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SachNoi/TTSRender", isDirectory: true)
    }

    /// Thư mục kho đoạn chung (3.2.0). Bố cục cũ 2.2.0 là thư mục con theo
    /// từng sách — sweepLegacy() dọn chúng khi gặp lần đầu.
    public static var segmentsURL: URL { rootURL.appendingPathComponent("segments", isDirectory: true) }

    /// Nhãn hiển thị/thống kê cho một (sách + giọng + nghỉ) — chỉ dùng cho
    /// tab Chẩn đoán, KHÔNG còn là địa chỉ lưu trữ.
    public static func key(bookId: String, voice: String, gapPunct: Double, gapParagraph: Double) -> String {
        let raw = "\(voice)|\(gapPunct)|\(gapParagraph)"
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(PackStore.sanitize(bookId))-\(digest.prefix(10))"
    }

    /// Địa chỉ nội dung của MỘT đoạn: hash(text + giọng + khoảng nghỉ).
    /// Đổi bất kỳ yếu tố nào làm đổi audio -> địa chỉ mới -> render lại
    /// đúng đoạn đó (nguyên tắc cache key của VoiceStudio).
    public static func segmentID(text: String, voiceKey: String, gapPunct: Double, gapParagraph: Double) -> String {
        let raw = "v1|\(voiceKey)|\(gapPunct)|\(gapParagraph)|\(text)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func fileURL(_ segmentID: String) -> URL {
        segmentsURL.appendingPathComponent("\(segmentID).m4a")
    }

    public static func exists(_ segmentID: String) -> Bool {
        let url = fileURL(segmentID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }

    /// File có dùng được thật không: mở được bằng AVAudioFile và có dữ
    /// liệu. File hỏng/trống bị XOÁ để tầng gọi rơi về sinh trực tiếp —
    /// không bao giờ phát ra im lặng vì cache hỏng.
    public static func usable(_ segmentID: String) -> Bool {
        guard exists(segmentID) else { return false }
        let url = fileURL(segmentID)
        if let file = try? AVAudioFile(forReading: url), file.length > 0 { return true }
        try? FileManager.default.removeItem(at: url)
        return false
    }

    public static func ensurePool() {
        var url = segmentsURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Dọn bố cục cũ (thư mục theo sách của 2.2.0) — địa chỉ theo chỉ số
    /// không ánh xạ được sang địa chỉ nội dung, render lại là cái giá
    /// một lần. Chỉ xoá thư mục con, không đụng kho segments mới.
    public static func sweepLegacy() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for e in entries where e.lastPathComponent != "segments" {
            if (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.removeItem(at: e)
            }
        }
    }

    /// Tập chỉ số (trong danh sách địa chỉ truyền vào) đã có file render.
    public static func renderedIndices(segmentIDs: [String]) -> Set<Int> {
        var out = Set<Int>()
        for (i, id) in segmentIDs.enumerated() where exists(id) { out.insert(i) }
        return out
    }

    public static func renderedCount(segmentIDs: [String]) -> Int {
        renderedIndices(segmentIDs: segmentIDs).count
    }

    /// Lưu WAV PCM16 (đầu ra của engine) thành file AAC .m4a trong kho
    /// chung — ghi file tạm rồi đổi tên nguyên tử.
    public static func saveWav(_ segmentID: String, wav: Data) throws {
        guard let buffer = pcmBuffer(fromWav: wav) else {
            throw NSError(domain: "RenderStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "WAV không hợp lệ"])
        }
        ensurePool()
        let final = fileURL(segmentID)
        let tmp = segmentsURL.appendingPathComponent("\(segmentID).tmp.m4a")
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

    /// Trần dung lượng toàn kho: vượt thì xoá các FILE đoạn cũ nhất (theo
    /// ngày sửa) cho tới khi dưới trần — kho chung một cấp nên dọn theo
    /// file, sách nào ít nghe tự rơi ra trước (LRU toàn cục).
    public static func evictIfNeeded(capBytes: Int64 = 2_500_000_000) {
        let fm = FileManager.default
        guard PackStore.directorySize(segmentsURL) > capBytes else { return }
        let files = ((try? fm.contentsOfDirectory(at: segmentsURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (da ?? .distantPast) < (db ?? .distantPast)
            }
        var size = PackStore.directorySize(segmentsURL)
        for f in files {
            if size <= capBytes { break }
            let s = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? fm.removeItem(at: f)) != nil { size -= Int64(s ?? 0) }
        }
    }
}
