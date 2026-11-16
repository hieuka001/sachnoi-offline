import Foundation
import AVFoundation
import MediaPlayer

/// BackgroundAudio — toàn bộ phần "nghe nền" phía native:
/// 1) AVAudioSession .playback/.spokenAudio: phát tiếp khi khoá màn hình, chuyển app.
/// 2) Now Playing (màn hình khoá / Control Center / tai nghe): tên sách, chương, trạng thái.
/// 3) Remote Command: play/pause/next/prev từ tai nghe, AirPods, xe hơi -> chuyển sang web.
/// 4) Ngắt quãng: cuộc gọi/Siri/báo thức -> báo web tạm dừng; hết ngắt -> tự phát tiếp nếu đang nghe.
/// 5) Đổi đường tiếng: rút tai nghe -> báo web dừng (không phát loa bất ngờ).
public final class BackgroundAudio {
    public static let shared = BackgroundAudio()
    public var onRemoteCommand: ((_ command: String) -> Void)?
    public var onInterruption: ((_ phase: String, _ shouldResume: Bool) -> Void)?
    public var onRoutePause: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    public func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            print("SachNoi: audio session setup failed: \(error)")
        }
        installInterruptionObservers()
        installRemoteCommands()
    }

    public func reactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: Now Playing
    public func setNowPlaying(title: String, author: String, chapter: String,
                              elapsed: Double, duration: Double, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.isEmpty ? title : chapter,
            MPMediaItemPropertyArtist: author.isEmpty ? title : "\(title) — \(author)",
            MPMediaItemPropertyAlbumTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        info[MPMediaItemPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func updatePlayback(isPlaying: Bool, elapsed: Double) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Remote commands (câu = đơn vị tua, không tua theo giây)
    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true       // câu tiếp theo
        center.previousTrackCommand.isEnabled = true   // câu trước
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.playCommand.addTarget { [weak self] _ in self?.onRemoteCommand?("play"); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.onRemoteCommand?("pause"); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onRemoteCommand?("toggle"); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.onRemoteCommand?("next"); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.onRemoteCommand?("prev"); return .success }
    }

    // MARK: Interruptions & route changes
    private func installInterruptionObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self?.onInterruption?("began", false)
            case .ended:
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                if shouldResume { self?.reactivateSession() }
                self?.onInterruption?("ended", shouldResume)
            @unknown default: break
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            self?.onRoutePause?() // rút tai nghe / ngắt Bluetooth -> dừng, không phát loa
        })
    }

    // MARK: Background task assertion
    /// Khi app sắp vào nền mà đang tổng hợp/phát dở 1 câu: xin thêm thời gian nền
    /// để hoàn tất câu hiện tại, tránh cắt tiếng giữa chừng. (Phát dài hạn dựa vào
    /// audio background mode, không dựa vào assertion này.)
    public func beginBackgroundAssertion(name: String) {
        endBackgroundAssertion()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.endBackgroundAssertion()
        }
    }

    public func endBackgroundAssertion() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}
