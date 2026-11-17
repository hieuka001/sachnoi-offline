import Foundation
import AVFoundation

/// NativePlayer — chuỗi phát NGHE chạy hoàn toàn bằng native (bản 1.0.3).
///
/// Vì sao phải có: bản 1.0.x để web (WKWebView) nối câu — phát hết 1 câu, JS mới
/// gọi tổng hợp câu tiếp. Khi khoá màn hình/chuyển app, iOS treo JS của WebView
/// nên chuỗi đứt sau câu đang phát dở -> "không chạy nền được" trên máy thật.
/// NativePlayer tự tổng hợp (engine VieNeu native) + phát bằng AVAudioPlayer +
/// tự chuyển câu, không phụ thuộc WebView còn thức hay không. Web chỉ nhận sự
/// kiện để vẽ highlight/lưu tiến độ khi quay lại app.
public final class NativePlayer: NSObject, AVAudioPlayerDelegate {
    public struct Item { let text: String; let chapter: String }

    public var onSentence: ((_ index: Int) -> Void)?
    public var onState: ((_ playing: Bool) -> Void)?
    public var onEnded: (() -> Void)?

    private let queue = DispatchQueue(label: "app.sachnoi.player", qos: .userInitiated)
    private var items: [Item] = []
    private var voice: String = "default"
    private var bookTitle: String = ""
    private var bookAuthor: String = ""
    private(set) var index: Int = -1
    private(set) var playing: Bool = false
    private var rate: Float = 1.0
    private var audioPlayer: AVAudioPlayer?
    private var cache: [Int: Data] = [:]
    private var generation: Int = 0
    private var wasPlayingBeforeInterruption = false

    private enum SleepMode { case off, minutes(Date), chapter }
    private var sleepMode: SleepMode = .off

    public var count: Int { items.count }
    public var currentIndex: Int { index }

    // MARK: - Điều khiển từ plugin / remote / ngắt quãng
    public func load(items: [Item], voice: String, title: String, author: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal(notify: false)
            self.items = items
            self.voice = voice
            self.bookTitle = title
            self.bookAuthor = author
            self.index = -1
        }
    }

    public func play(from startIndex: Int) {
        queue.async { [weak self] in
            guard let self, !self.items.isEmpty else { return }
            self.index = min(max(0, startIndex), self.items.count - 1)
            self.playing = true
            self.startCurrent()
            self.emitState()
        }
    }

    public func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.playing = false
            self.audioPlayer?.pause()
            self.updateNowPlaying()
            self.emitState()
        }
    }

    public func resume() {
        queue.async { [weak self] in
            guard let self, !self.items.isEmpty else { return }
            self.playing = true
            if let p = self.audioPlayer, !p.isPlaying, p.currentTime > 0 {
                BackgroundAudio.shared.reactivateSession()
                p.play()
                self.updateNowPlaying()
                self.emitState()
            } else {
                if self.index < 0 { self.index = 0 }
                self.startCurrent()
                self.emitState()
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopInternal(notify: true) }
    }

    private func stopInternal(notify: Bool) {
        generation += 1
        playing = false
        audioPlayer?.stop()
        audioPlayer = nil
        cache.removeAll()
        if notify {
            BackgroundAudio.shared.clearNowPlaying()
            emitState()
        }
    }

    public func next() { step(by: 1) }
    public func prev() { step(by: -1) }

    private func step(by delta: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let target = self.index + delta
            guard target >= 0, target < self.items.count else { return }
            self.index = target
            if self.playing { self.startCurrent() }
            else { self.emitSentence(); self.updateNowPlaying() }
        }
    }

    public func seek(to target: Int) {
        queue.async { [weak self] in
            guard let self, target >= 0, target < self.items.count else { return }
            self.index = target
            if self.playing { self.startCurrent() }
            else { self.emitSentence(); self.updateNowPlaying() }
        }
    }

    public func setRate(_ newRate: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rate = min(max(0.5, newRate), 2.0)
            if let p = self.audioPlayer { p.rate = self.rate }
        }
    }

    public func setVoice(_ newVoice: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.voice = newVoice
            self.cache.removeAll()
            if self.playing, self.index >= 0 { self.startCurrent() }
        }
    }

    public func setSleep(mode: String, minutes: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            switch mode {
            case "minutes": self.sleepMode = .minutes(Date().addingTimeInterval(minutes * 60))
            case "chapter": self.sleepMode = .chapter
            default: self.sleepMode = .off
            }
        }
    }

    // MARK: - Ngắt quãng (cuộc gọi/Siri) — plugin chuyển vào
    public func interruptionBegan() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wasPlayingBeforeInterruption = self.playing
            if self.playing {
                self.playing = false
                self.audioPlayer?.pause()
                self.updateNowPlaying()
                self.emitState()
            }
        }
    }

    public func interruptionEnded(shouldResume: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if shouldResume, self.wasPlayingBeforeInterruption {
                self.wasPlayingBeforeInterruption = false
                self.playing = true
                BackgroundAudio.shared.reactivateSession()
                if let p = self.audioPlayer { p.play() } else if self.index >= 0 { self.startCurrent() }
                self.updateNowPlaying()
                self.emitState()
            }
        }
    }

    // MARK: - Phát câu hiện tại
    private func startCurrent() {
        guard index >= 0, index < items.count else { finishBook(); return }
        generation += 1
        let gen = generation
        let idx = index
        let item = items[idx]
        emitSentence()
        updateNowPlaying()
        DispatchQueue.main.async { BackgroundAudio.shared.beginBackgroundAssertion(name: "SachNoiSynthesize") }
        queue.async { [weak self] in
            guard let self else { return }
            let data = self.cache[idx] ?? (try? TtsServer.shared.synthesizeSync(text: item.text, voice: self.voice))
            DispatchQueue.main.async { BackgroundAudio.shared.endBackgroundAssertion() }
            guard gen == self.generation, self.playing, self.index == idx else { return }
            if let data { self.cache[idx] = data }
            // Prefetch câu tiếp theo trong lúc phát câu này
            let nextIdx = idx + 1
            if nextIdx < self.items.count, self.cache[nextIdx] == nil {
                let nextText = self.items[nextIdx].text
                let v = self.voice
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    if let d = try? TtsServer.shared.synthesizeSync(text: nextText, voice: v) {
                        self?.queue.async { if self?.cache[nextIdx] == nil { self?.cache[nextIdx] = d } }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation, self.playing, self.index == idx else { return }
                guard let data, let player = try? AVAudioPlayer(data: data) else {
                    // Tổng hợp lỗi 1 câu: bỏ qua câu đó, đọc câu tiếp để không chết cả sách
                    self.queue.async { self.advance() }
                    return
                }
                BackgroundAudio.shared.reactivateSession()
                player.delegate = self
                player.enableRate = true
                player.rate = self.rate
                player.prepareToPlay()
                self.audioPlayer = player
                player.play()
                self.queue.async { self.trimCache(around: idx) }
            }
        }
    }

    private func trimCache(around idx: Int) {
        for k in cache.keys where abs(k - idx) > 3 { cache.removeValue(forKey: k) }
    }

    private func advance() {
        guard playing else { return }
        // Hẹn giờ ngủ: kiểm tra tại biên câu (chạy native nên khoá máy vẫn đúng)
        switch sleepMode {
        case .minutes(let deadline) where Date() >= deadline:
            sleepMode = .off; pause(); return
        case .chapter:
            let nextIdx = index + 1
            if nextIdx >= items.count || items[nextIdx].chapter != items[index].chapter {
                sleepMode = .off; pause(); return
            }
        default: break
        }
        if index + 1 >= items.count { finishBook(); return }
        index += 1
        startCurrent()
    }

    private func finishBook() {
        playing = false
        audioPlayer = nil
        BackgroundAudio.shared.updatePlayback(isPlaying: false, elapsed: Double(index))
        emitState()
        onEnded?()
    }

    // MARK: AVAudioPlayerDelegate
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        queue.async { [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            if self.playing { self.advance() }
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        queue.async { [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            if self.playing { self.advance() }
        }
    }

    // MARK: - Sự kiện + Now Playing
    private func emitSentence() {
        let idx = index
        DispatchQueue.main.async { [weak self] in self?.onSentence?(idx) }
    }

    private func emitState() {
        let s = playing
        DispatchQueue.main.async { [weak self] in self?.onState?(s) }
    }

    private func updateNowPlaying() {
        guard index >= 0, index < items.count else { return }
        let item = items[index]
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            BackgroundAudio.shared.setNowPlaying(
                title: self.bookTitle, author: self.bookAuthor, chapter: item.chapter,
                elapsed: Double(self.index), duration: Double(self.items.count), isPlaying: self.playing)
        }
    }
}
