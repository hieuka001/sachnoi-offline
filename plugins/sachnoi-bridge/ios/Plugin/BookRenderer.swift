import Foundation
import UIKit

/// BookRenderer — hàng đợi RENDER TRƯỚC audio của cả cuốn sách ra
/// RenderStore, chạy nền song song với việc phát (theo yêu cầu của người
/// dùng: "render trước 2–3 chương, trong lúc phát sẽ tiếp tục render cả
/// cuốn").
///
/// Thứ tự ưu tiên, tính lại mỗi lần vị trí phát đổi:
///   1) từ vị trí phát đến hết chương hiện tại + 2 chương kế (đệm 2–3 chương);
///   2) từ đó đến cuối sách (render cả cuốn);
///   3) phần trước vị trí phát còn thiếu (nghe lại không phải sinh trực tiếp).
/// 2 luồng render dùng 2 engine của TtsServer; tầng phát khi cần sinh trực
/// tiếp vẫn vào cùng hàng đợi engine — tệ nhất bằng hành vi cũ, thường thì
/// đoạn cần phát đã có sẵn file.
///
/// 3.2.0: đoạn được địa chỉ hoá theo NỘI DUNG (RenderStore.segmentID) —
/// renderer tính địa chỉ từng đoạn một lần khi gắn sách; "đã xong" đọc
/// thẳng từ kho chung nên render tiếp tục đúng chỗ sau khi app mở lại,
/// và configure() cũng được plugin gọi độc lập (ttsRenderBook) để render
/// tự chạy tiếp mà không cần phát.
///
/// An toàn nhiệt: thermal .critical thì cả hai luồng ngủ chờ; .serious thì
/// chỉ 1 luồng chạy. Đoạn render lỗi được đánh dấu bỏ qua trong phiên (phát
/// tới đó tầng phát vẫn sinh trực tiếp được) — không lặp lỗi vô hạn.
///
/// 3.2.1: renderer CHỈ chạy khi app ở TIỀN CẢNH. Bản 3.2.0 bị văng app +
/// mất chạy nền trên máy thật: khi khoá máy/app vào nền, iOS siết CPU và
/// bộ nhớ gắt hơn nhiều — renderer còn tổng hợp liên tục ở nền là tự rước
/// án tử (jetsam/CPU limit), kéo cả tầng phát chết theo. Vào nền là
/// renderer ngủ; thời gian nền thuộc về riêng tầng phát (đường đã kiểm
/// chứng từ 1.0.3). Mở app lại, renderer tự chạy tiếp đúng chỗ cũ.
public final class BookRenderer {
    public static let shared = BookRenderer()

    private let lock = NSLock()
    private var generation = 0
    private var key = ""
    private var items: [(text: String, chapter: String)] = []
    private var segmentIDs: [String] = []
    private var voice = ""
    private var playIndex = 0
    private var done = Set<Int>()
    private var inFlight = Set<Int>()
    private var failed = Set<Int>()
    private var workersAlive = 0

    private init() {}

    /// Gắn renderer vào một cuốn sách + giọng + khoảng nghỉ. Gọi lại khi
    /// đổi sách/giọng/khoảng nghỉ: vòng render cũ tự dừng theo generation.
    /// `label` chỉ để chẩn đoán; địa chỉ đoạn tính từ (text, voiceKey, gaps).
    public func configure(label: String, items: [(text: String, chapter: String)], voiceKey: String, synthVoice: String, gapPunct: Double, gapParagraph: Double, playIndex: Int) {
        RenderStore.sweepLegacy()
        let ids = items.map { RenderStore.segmentID(text: $0.text, voiceKey: voiceKey, gapPunct: gapPunct, gapParagraph: gapParagraph) }
        lock.lock()
        generation += 1
        let gen = generation
        self.key = label
        self.items = items
        self.segmentIDs = ids
        self.voice = synthVoice
        self.playIndex = playIndex
        done = RenderStore.renderedIndices(segmentIDs: ids)
        inFlight = []
        failed = []
        let need = done.count + failed.count < items.count ? 2 : 0
        workersAlive = need
        lock.unlock()
        guard need > 0 else { return }
        RenderStore.ensurePool()
        RenderStore.evictIfNeeded()
        for w in 0..<need {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.worker(gen: gen, workerId: w)
            }
        }
    }

    public func setPlayIndex(_ idx: Int) {
        lock.lock()
        playIndex = idx
        lock.unlock()
    }

    public func stats() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "renderKey": key,
            "rendered": done.count,
            "renderTotal": items.count,
            "renderActive": workersAlive > 0,
            "renderFailed": failed.count,
        ]
    }

    /// Ranh giới ưu tiên 1: chỉ số đầu tiên SAU (chương hiện tại + 2 chương).
    private func priorityEnd(from start: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        var chaptersSeen = 0
        var current = items[start].chapter
        var i = start
        while i < items.count {
            if items[i].chapter != current {
                chaptersSeen += 1
                if chaptersSeen > 2 { return i }
                current = items[i].chapter
            }
            i += 1
        }
        return items.count
    }

    /// Chọn đoạn render tiếp theo + giữ chỗ nguyên tử. nil = hết việc.
    private func nextIndex(gen: Int) -> (idx: Int, text: String, voice: String, segmentID: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation, !items.isEmpty else { return nil }
        let start = min(max(0, playIndex), items.count - 1)
        let pEnd = priorityEnd(from: start)
        let ranges = [start..<pEnd, pEnd..<items.count, 0..<start]
        for r in ranges {
            for i in r where !done.contains(i) && !inFlight.contains(i) && !failed.contains(i) {
                inFlight.insert(i)
                return (i, items[i].text, voice, segmentIDs[i])
            }
        }
        return nil
    }

    private func worker(gen: Int, workerId: Int) {
        defer {
            lock.lock()
            if gen == generation { workersAlive = max(0, workersAlive - 1) }
            lock.unlock()
        }
        while true {
            lock.lock()
            let alive = gen == generation
            lock.unlock()
            if !alive { return }
            // 3.2.1: vào nền/khoá máy là NGỦ — không nhận việc mới, không
            // tổng hợp. Chỉ phát tiếp bằng file đã render + sinh trực tiếp
            // của tầng phát. App active lại thì vòng lặp tự chạy tiếp.
            var appActive = true
            DispatchQueue.main.sync { appActive = UIApplication.shared.applicationState == .active }
            if !appActive {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .critical || (thermal == .serious && workerId == 1) {
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            guard let job = nextIndex(gen: gen) else { return }
            do {
                let wav = try TtsServer.shared.synthesizeSync(text: job.text, voice: job.voice)
                try RenderStore.saveWav(job.segmentID, wav: wav)
                lock.lock()
                inFlight.remove(job.idx)
                done.insert(job.idx)
                lock.unlock()
            } catch {
                lock.lock()
                inFlight.remove(job.idx)
                failed.insert(job.idx)
                lock.unlock()
            }
        }
    }
}
