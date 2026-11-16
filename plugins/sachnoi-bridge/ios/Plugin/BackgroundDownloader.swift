import Foundation

/// BackgroundDownloader — tải gói core/giọng bằng URLSession NỀN.
/// Đây là một trong các chức năng chạy nền của bản iOS: người dùng bấm tải rồi
/// khoá máy / chuyển app / thậm chí app bị iOS đóng, hệ thống vẫn tải tiếp và
/// mở lại app khi tải xong (handleEventsForBackgroundURLSession ở AppDelegate).
/// Tiến độ + hoàn tất được plugin chuyển tiếp sang web qua sự kiện.
public final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate {
    public static let shared = BackgroundDownloader()
    public static var backgroundCompletionHandler: (() -> Void)?

    public var onProgress: ((_ packId: String, _ received: Int64, _ total: Int64) -> Void)?
    public var onFileFinished: ((_ packId: String, _ name: String, _ error: String?) -> Void)?
    public var onPackFinished: ((_ packId: String) -> Void)?

    private struct TaskInfo { let packId: String; let name: String; let dest: URL }
    private var taskInfos: [Int: TaskInfo] = [:]
    private var packTotals: [String: Int64] = [:]
    private var packReceived: [String: Int64] = [:]
    private var packRemainingFiles: [String: Int] = [:]
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.hieuka001.sachnoi.downloads")
        config.isDiscretionary = false          // tải ngay, không chờ điều kiện lý tưởng
        config.sessionSendsLaunchEvents = true  // tải xong khi app bị đóng -> iOS mở lại app
        config.allowsCellularAccess = true      // web hỏi ý người dùng trước ở tầng giao diện
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Bắt đầu tải 1 gói: files = [{url, name, size}] — mỗi file là 1 asset riêng
    /// trên GitHub Releases nên tải đứt đoạn nào nối lại đoạn đó, không cần giải nén.
    public func download(packId: String, files: [[String: Any]]) {
        PackStore.ensureRoot()
        let dir = PackStore.packURL(packId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock()
        packTotals[packId] = files.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) }
        packReceived[packId] = PackStore.directorySize(dir)
        packRemainingFiles[packId] = files.count
        lock.unlock()
        for f in files {
            guard let urlString = f["url"] as? String, let url = URL(string: urlString),
                  let name = f["name"] as? String else { continue }
            let dest = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path),
               let size = f["size"] as? NSNumber,
               ((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == size.intValue {
                fileDone(packId: packId, name: name, error: nil) // đã có từ lần tải trước
                continue
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 600
            let task = session.downloadTask(with: request)
            lock.lock(); taskInfos[task.taskIdentifier] = TaskInfo(packId: packId, name: name, dest: dest); lock.unlock()
            task.resume()
        }
    }

    public func cancel(packId: String) {
        session.getAllTasks { tasks in
            tasks.forEach { task in
                self.lock.lock(); let info = self.taskInfos[task.taskIdentifier]; self.lock.unlock()
                if info?.packId == packId { task.cancel() }
            }
        }
    }

    private func fileDone(packId: String, name: String, error: String?) {
        onFileFinished?(packId, name, error)
        lock.lock()
        let remaining = (packRemainingFiles[packId] ?? 1) - 1
        packRemainingFiles[packId] = remaining
        lock.unlock()
        if remaining <= 0 { onPackFinished?(packId) }
    }

    // MARK: URLSessionDownloadDelegate
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        lock.lock(); let info = taskInfos[downloadTask.taskIdentifier]; lock.unlock()
        guard let info else { return }
        // Tổng tiến độ gói = file đã xong trên đĩa + phần đang tải của file hiện tại (xấp xỉ theo từng file)
        let onDisk = PackStore.directorySize(PackStore.packURL(info.packId))
        lock.lock(); let total = packTotals[info.packId] ?? totalBytesExpectedToWrite; lock.unlock()
        onProgress?(info.packId, onDisk, total)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        lock.lock(); let info = taskInfos[downloadTask.taskIdentifier]; taskInfos.removeValue(forKey: downloadTask.taskIdentifier); lock.unlock()
        guard let info else { return }
        do {
            try? FileManager.default.removeItem(at: info.dest)
            try FileManager.default.moveItem(at: location, to: info.dest)
            fileDone(packId: info.packId, name: info.name, error: nil)
        } catch {
            fileDone(packId: info.packId, name: info.name, error: error.localizedDescription)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock(); let info = taskInfos[task.taskIdentifier]; taskInfos.removeValue(forKey: task.taskIdentifier); lock.unlock()
            if let info { fileDone(packId: info.packId, name: info.name, error: error.localizedDescription) }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = BackgroundDownloader.backgroundCompletionHandler
        BackgroundDownloader.backgroundCompletionHandler = nil
        DispatchQueue.main.async { handler?() }
    }
}
