import UIKit
import Capacitor
import SachnoiBridge

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // === CHẠY NỀN 1/4: phiên âm thanh playback — nghe tiếp khi khoá màn hình ===
        BackgroundAudio.shared.configureSession()
        // === CHẠY NỀN 2/4: đăng ký BGTaskScheduler (bắt buộc trước khi launch xong) ===
        BackgroundTasks.register()
        BackgroundTasks.scheduleAll()
        // Nạp ấm giọng hệ thống sớm (3.3.0: model Supertonic gắn sẵn
        // nhưng engine Supertonic DỰNG LƯỜI ở lần chọn giọng đầu tiên —
        // xem TtsServer.warmup — nên ở đây chỉ nạp ấm giọng mặc định,
        // không dựng Supertonic để khỏi giữ ~145MB thường trực).
        SachNoiBridgePlugin.startTtsEngine()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BackgroundAudio.shared.reactivateSession()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Lên lịch lại các tác vụ nền mỗi lần vào background.
        BackgroundTasks.scheduleAll()
    }

    // === CHẠY NỀN 3/4: iOS mở lại app khi phiên tải nền có sự kiện ===
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == "com.hieuka001.sachnoi.downloads" {
            BackgroundDownloader.backgroundCompletionHandler = completionHandler
            _ = BackgroundDownloader.shared // khởi tạo lại session để nhận sự kiện tồn đọng
        } else {
            completionHandler()
        }
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }
}
