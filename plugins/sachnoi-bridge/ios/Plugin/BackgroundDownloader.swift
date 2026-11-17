import Foundation

/// BackgroundDownloader — tải gói core/giọng bằng URLSession NỀN.
/// Người dùng bấm tải rồi khoá máy / chuyển app / app bị iOS đóng, hệ thống vẫn
/// tải tiếp và mở lại app khi xong (handleEventsForBackgroundURLSession).
///
/// Độ bền (bản 1.0.2, sau lỗi "Cannot create file" trên máy thật):
/// - Mỗi task gắn taskDescription "packId|fileName" để app bị mở lại giữa chừng
///   vẫn nhận ra file thuộc gói nào (bản 1.0.x chỉ lưu trong RAM -> mất là mất file).
/// - File lỗi: tự thử lại 1 lần trên phiên nền; vẫn lỗi (đặc biệt NSURLError
///   -3000 CannotCreateFile của tiến trình tải nền) -> tải nốt bằng phiên thường
///   khi app đang mở, không để người dùng kẹt hẳn.
/// - Lỗi báo về web kèm tên file + domain + code để chẩn đoán được, không nuốt lỗi.
public final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate {
    public static let shared = BackgroundDownloader()
    public static var backgroundCompletionHandler: (() -> Void)?

    public var onProgress: ((_ packId: String, _ received: Int64, _ total: Int64) -> Void)?
    public var onFileFinished: ((_ packId: String, _ name: String, _ error: String?) -> Void)?
    public var onPackFinished: ((_ packId: String) -> Void)?

    private struct TaskInfo { let packId: String; let name: String; let dest: URL; let url: URL; var retried: Bool; var gen: Int = 0 }
    private var taskInfos: [Int: TaskInfo] = [:]
    private var packTotals: [String: Int64] = [:]
    private var packRemainingFiles: [String: Int] = [:]
    private var lastReportedPct: [String: Int] = [:]
    private var packGeneration: [String: Int] = [:]
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.hieuka001.sachnoi.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Phiên thường (chỉ chạy khi app đang mở) — đường dự phòng khi phiên nền lỗi.
    private lazy var foregroundSession: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    public func download(packId: String, files: [[String: Any]]) {
        // Huỷ mọi task cũ của gói trước: bấm tải chồng / xoá giữa chừng sinh task
        // trùng cùng ghi 1 file là một nguồn lỗi -3000 (bản 1.0.2 chưa huỷ).
        cancel(packId: packId)
        lock.lock()
        packGeneration[packId] = (packGeneration[packId] ?? 0) + 1
        lock.unlock()
        PackStore.ensureRoot()
        let dir = PackStore.packURL(packId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock()
        packTotals[packId] = files.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) }
        packRemainingFiles[packId] = files.count
        lastReportedPct[packId] = -1
        lock.unlock()
        for f in files {
            guard let urlString = f["url"] as? String, let url = URL(string: urlString),
                  let name = f["name"] as? String else { continue }
            let dest = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path),
               let size = f["size"] as? NSNumber,
               ((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == size.intValue {
                fileDone(packId: packId, name: name, error: nil)
                continue
            }
            startTask(packId: packId, name: name, url: url, dest: dest, foreground: false, retried: false)
        }
    }

    private func startTask(packId: String, name: String, url: URL, dest: URL, foreground: Bool, retried: Bool) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        let task = foreground ? foregroundSession.downloadTask(with: request) : session.downloadTask(with: request)
        task.taskDescription = "\(packId)|\(name)"
        lock.lock()
        taskInfos[task.taskIdentifier] = TaskInfo(packId: packId, name: name, dest: dest, url: url, retried: retried, gen: packGeneration[packId] ?? 0)
        lock.unlock()
        task.resume()
    }

    public func cancel(packId: String) {
        for s in [session, foregroundSession] {
            s.getAllTasks { tasks in
                tasks.forEach { task in
                    if task.taskDescription?.hasPrefix("\(packId)|") == true { task.cancel() }
                }
            }
        }
    }

    private func info(for task: URLSessionTask) -> TaskInfo? {
        lock.lock(); let cached = taskInfos[task.taskIdentifier]; lock.unlock()
        if let cached { return cached }
        // App bị hệ thống mở lại: khôi phục từ taskDescription
        guard let desc = task.taskDescription, let sep = desc.firstIndex(of: "|") else { return nil }
        let packId = String(desc[..<sep])
        let name = String(desc[desc.index(after: sep)...])
        let dir = PackStore.packURL(packId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let url = task.originalRequest?.url else { return nil }
        let recovered = TaskInfo(packId: packId, name: name, dest: dir.appendingPathComponent(name), url: url, retried: true)
        lock.lock(); taskInfos[task.taskIdentifier] = recovered; lock.unlock()
        return recovered
    }

    private func fileDone(packId: String, name: String, error: String?, gen: Int? = nil) {
        if let gen {
            lock.lock(); let current = packGeneration[packId] ?? 0; lock.unlock()
            if gen != current { return } // sự kiện của lượt tải cũ đã bị thay thế
        }
        onFileFinished?(packId, name, error)
        lock.lock()
        let remaining = (packRemainingFiles[packId] ?? 1) - 1
        packRemainingFiles[packId] = remaining
        lock.unlock()
        if remaining <= 0 { onPackFinished?(packId) }
    }

    private func handleFailure(_ info: TaskInfo, error: Error, foreground: Bool) {
        let ns = error as NSError
        // Lỗi huỷ do người dùng bấm Huỷ -> không thử lại, không báo lỗi
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if !info.retried {
            // Thử lại 1 lần: lỗi CannotCreateFile (-3000) của phiên nền -> đổi phiên thường
            let useForeground = foreground || (ns.domain == NSURLErrorDomain && ns.code == -3000)
            startTask(packId: info.packId, name: info.name, url: info.url, dest: info.dest,
                      foreground: useForeground, retried: true)
            return
        }
        fileDone(packId: info.packId, name: info.name,
                 error: "\(info.name) · \(ns.domain) \(ns.code) · \(error.localizedDescription)", gen: info.gen)
    }

    // MARK: URLSessionDownloadDelegate
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let info = info(for: downloadTask) else { return }
        let onDisk = PackStore.directorySize(PackStore.packURL(info.packId))
        lock.lock(); let total = packTotals[info.packId] ?? 0; lock.unlock()
        guard total > 0 else { return }
        let pct = Int((onDisk * 100) / total)
        lock.lock(); let last = lastReportedPct[info.packId] ?? -1; if pct != last { lastReportedPct[info.packId] = pct }; lock.unlock()
        if pct != last { onProgress?(info.packId, onDisk, total) } // chỉ báo khi % đổi — tránh spam sự kiện
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let info = info(for: downloadTask) else { return }
        lock.lock(); taskInfos.removeValue(forKey: downloadTask.taskIdentifier); lock.unlock()
        do {
            try FileManager.default.createDirectory(at: info.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: info.dest.path) {
                try FileManager.default.removeItem(at: info.dest)
            }
            try FileManager.default.moveItem(at: location, to: info.dest)
            fileDone(packId: info.packId, name: info.name, error: nil, gen: info.gen)
        } catch {
            handleFailure(info, error: error, foreground: session == foregroundSession)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let info = info(for: task) else { return }
        lock.lock(); taskInfos.removeValue(forKey: task.taskIdentifier); lock.unlock()
        handleFailure(info, error: error, foreground: session == foregroundSession)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = BackgroundDownloader.backgroundCompletionHandler
        BackgroundDownloader.backgroundCompletionHandler = nil
        DispatchQueue.main.async { handler?() }
    }
}
