import Foundation
import SeaG2p

/// Bọc C ABI của sea-g2p (Rust): chuẩn hoá + phiên âm tiếng Việt từ sea_g2p.bin.
/// Handle không an toàn đa luồng — mọi lời gọi đi qua hàng đợi tuần tự của TtsServer.
final class SeaG2pEngine {
    private var handle: OpaquePointer?

    init(dictPath: String) {
        handle = dictPath.withCString { sea_g2p_open($0) }
    }

    deinit {
        if let h = handle { sea_g2p_close(h) }
    }

    var isOpen: Bool { handle != nil }

    func normalize(_ text: String, puncNorm: Bool) -> String {
        call(text, puncNorm: puncNorm, fn: sea_g2p_normalize)
    }

    func phonemize(_ text: String, puncNorm: Bool) -> String {
        call(text, puncNorm: puncNorm, fn: sea_g2p_phonemize)
    }

    private func call(_ text: String, puncNorm: Bool,
                      fn: (OpaquePointer?, UnsafePointer<CChar>, Int32) -> UnsafeMutablePointer<CChar>?) -> String {
        guard let h = handle, !text.isEmpty else { return "" }
        let result = text.withCString { fn(h, $0, puncNorm ? 1 : 0) }
        guard let ptr = result else { return "" }
        let out = String(cString: ptr)
        sea_g2p_string_free(ptr)
        return out
    }
}
