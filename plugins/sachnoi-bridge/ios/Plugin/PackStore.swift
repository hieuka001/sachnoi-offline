import Foundation
import CryptoKit

/// PackStore — nơi lưu các gói tải về (core engine + từng giọng) trên máy.
/// Khác Bút Nghiên (nhúng sẵn 260MB model trong IPA): app này cài mới KHÔNG có
/// model nào. Core/giọng tải từ GitHub Releases về Application Support/
/// SachNoi/TTSPacks/<packId>/ — iOS không tự xoá thư mục này như Caches,
/// và đã tắt backup iCloud (gói tải lại được, không tốn dung lượng backup).
public enum PackStore {
    public static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SachNoi/TTSPacks", isDirectory: true)
    }

    public static func packURL(_ packId: String) -> URL {
        rootURL.appendingPathComponent(sanitize(packId), isDirectory: true)
    }

    public static func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.unicodeScalars.filter { allowed.contains($0) }.map { String($0) }.joined()
    }

    public static func ensureRoot() {
        var url = rootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Thư mục assets của VieNeu: ưu tiên gói core đã tải (int8 trước, fp32 sau),
    /// cuối cùng mới tới TTSAssets trong bundle (bản dev nội bộ).
    public static func vieneuAssetsURL() -> URL? {
        for packId in ["vieneu-turbo-int8", "vieneu-turbo-fp32", "vieneu-nano"] {
            let dir = packURL(packId)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) {
                return dir
            }
        }
        return Bundle.main.url(forResource: "TTSAssets", withExtension: nil)
    }

    public static func installedPacks() -> [[String: Any]] {
        ensureRoot()
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map { dir in
            ["id": dir.lastPathComponent, "bytes": directorySize(dir), "path": dir.path]
        }
    }

    public static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public static func deletePack(_ packId: String) throws {
        let url = packURL(packId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Kiểm tra SHA-256 từng file của gói (gọi sau khi tải xong và trong BGProcessingTask).
    public static func verify(packId: String, files: [[String: Any]]) -> [String: String] {
        var result: [String: String] = [:]
        let dir = packURL(packId)
        for f in files {
            guard let name = f["name"] as? String, let expected = f["sha256"] as? String else { continue }
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { result[name] = "missing"; continue }
            result[name] = (sha256(url) == expected.lowercased()) ? "ok" : "hashMismatch"
        }
        return result
    }

    public static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1 << 20)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
