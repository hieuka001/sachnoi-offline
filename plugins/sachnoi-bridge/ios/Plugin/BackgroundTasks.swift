import Foundation
import BackgroundTasks

/// BackgroundTasks — các tác vụ nền theo lịch của iOS (BGTaskScheduler):
/// - refresh (BGAppRefreshTask): khi có mạng, kiểm tra voices.json trên GitHub
///   có bản mới không, lưu cờ để lần mở app sau web báo "có giọng/gói mới".
/// - prepare (BGProcessingTask): kiểm tra tính toàn vẹn các gói đã tải (file đủ
///   + dung lượng khớp), nạp ấm engine VieNeu nếu core đã có — để lần bấm Nghe
///   tiếp theo có tiếng gần như ngay.
/// Cả hai identifier phải khai trong Info.plist ở BGTaskSchedulerPermittedIdentifiers
/// và register() phải chạy TRƯỚC khi didFinishLaunchingWithOptions kết thúc.
public enum BackgroundTasks {
    public static let refreshId = "com.hieuka001.sachnoi.refresh"
    public static let prepareId = "com.hieuka001.sachnoi.prepare"
    private static let manifestURL = URL(string: "https://raw.githubusercontent.com/hieuka001/sachnoi-offline/main/voices/voices.json")!
    private static let manifestVersionKey = "sachnoi.manifestVersionSeen"

    public static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { task in
            handleRefresh(task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: prepareId, using: nil) { task in
            handlePrepare(task as! BGProcessingTask)
        }
    }

    public static func scheduleAll() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshId)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        try? BGTaskScheduler.shared.submit(refresh)

        let prepare = BGProcessingTaskRequest(identifier: prepareId)
        prepare.requiresNetworkConnectivity = false
        prepare.requiresExternalPower = false
        prepare.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(prepare)
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleAll()
        let work = URLSession.shared.dataTask(with: manifestURL) { data, _, _ in
            defer { task.setTaskCompleted(success: true) }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else { return }
            let seen = UserDefaults.standard.string(forKey: manifestVersionKey)
            if seen != version {
                UserDefaults.standard.set(version, forKey: "sachnoi.manifestVersionAvailable")
            }
        }
        task.expirationHandler = { work.cancel() }
        work.resume()
    }

    /// Web gọi khi đã nạp manifest mới, để dọn cờ "có bản mới".
    public static func markManifestSeen(_ version: String) {
        UserDefaults.standard.set(version, forKey: manifestVersionKey)
        UserDefaults.standard.removeObject(forKey: "sachnoi.manifestVersionAvailable")
    }

    public static func availableManifestVersion() -> String? {
        UserDefaults.standard.string(forKey: "sachnoi.manifestVersionAvailable")
    }

    private static func handlePrepare(_ task: BGProcessingTask) {
        scheduleAll()
        let queue = DispatchQueue.global(qos: .background)
        var finished = false
        task.expirationHandler = { finished = true }
        queue.async {
            // 1) Toàn vẹn gói: thư mục còn, dung lượng > 0 (hash đầy đủ chạy khi tải xong)
            for pack in PackStore.installedPacks() {
                if finished { return }
                _ = pack
            }
            // 2) Nạp ấm engine nếu core đã tải — lần nghe sau nhanh hơn
            if PackStore.vieneuAssetsURL() != nil, !finished {
                TtsServer.shared.warmup()
            }
            if !finished { task.setTaskCompleted(success: true) }
        }
    }
}
