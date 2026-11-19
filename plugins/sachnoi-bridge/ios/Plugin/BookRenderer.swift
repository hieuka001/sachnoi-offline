import Foundation

/// BookRenderer (2.2.0) — hàng đợi RENDER TRƯỚC audio của cả cuốn sách ra
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
/// An toàn nhiệt: thermal .critical thì cả hai luồng ngủ chờ; .serious thì
/// chỉ 1 luồng chạy. Đoạn render lỗi được đánh dấu bỏ qua trong phiên (phát
/// tới đó tầng phát vẫn sinh trực tiếp được) — không lặp lỗi vô hạn.
public final class BookRenderer {
    public static let shared = BookRenderer()

    private let lock = NSLock()
    private var generation = 0
    private var key = ""
    private var items: [(text: String, chapter: String)] = []
    private var voice = ""
    private var playIndex = 0
    private var done = Set<Int>()
    private var inFlight = Set<Int>()
    private var failed = Set<Int>()
    private var workersAlive = 0

    private init() {}

    /// Gắn renderer vào một cuốn sách + giọng + khoá render. Gọi lại khi đổi
    /// sách/giọng/khoảng nghỉ: vòng render cũ tự dừng theo generation.
    public func configure(key: String, items: [(text: String, chapter: String)], voice: String, playIndex: Int) {
        lock.lock()
        generation += 1
        let gen = generation
        self.key = key
        self.items = items
        self.voice = voice
        self.playIndex = playIndex
        done = RenderStore.renderedIndices(key, total: items.count)
        inFlight = []
        failed = []
        let need = done.count + failed.count < items.count ? 2 : 0
        workersAlive = need
        lock.unlock()
        guard need > 0 else { return }
        RenderStore.ensureDir(key)
        RenderStore.evictIfNeeded(exceptKey: key)
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
    private func nextIndex(gen: Int) -> (idx: Int, text: String, voice: String, key: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation, !items.isEmpty else { return nil }
        let start = min(max(0, playIndex), items.count - 1)
        let pEnd = priorityEnd(from: start)
        let ranges = [start..<pEnd, pEnd..<items.count, 0..<start]
        for r in ranges {
            for i in r where !done.contains(i) && !inFlight.contains(i) && !failed.contains(i) {
                inFlight.insert(i)
                return (i, items[i].text, voice, key)
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
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .critical || (thermal == .serious && workerId == 1) {
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            guard let job = nextIndex(gen: gen) else { return }
            do {
                let wav = try TtsServer.shared.synthesizeSync(text: job.text, voice: job.voice)
                try RenderStore.saveWav(job.key, job.idx, wav: wav)
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
