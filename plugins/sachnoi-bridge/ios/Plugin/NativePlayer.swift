import Foundation
import AVFoundation

/// NativePlayer — chuỗi phát NGHE chạy hoàn toàn bằng native (1.0.3), từ 1.0.6
/// phát qua AVAudioEngine + AVAudioUnitTimePitch để chỉnh được ÂM LƯỢNG và
/// TÔNG GIỌNG (cao/thấp) độc lập với tốc độ, và chèn khoảng nghỉ có thể chỉnh
/// sau dấu chấm (hết câu), dấu phẩy (giữa câu) và khi xuống đoạn.
///
/// Vì sao phải native: bản 1.0.x để web (WKWebView) nối câu — phát hết 1 câu,
/// JS mới gọi tổng hợp câu tiếp. Khi khoá màn hình/chuyển app, iOS treo JS của
/// WebView nên chuỗi đứt sau câu đang phát dở. NativePlayer tự tổng hợp +
/// tự chuyển câu, không phụ thuộc WebView còn thức hay không.
///
/// An toàn: nếu AVAudioEngine/đọc WAV lỗi ở bất kỳ điểm nào, tự rơi về đường
/// AVAudioPlayer cũ (đã kiểm chứng chạy nền trên máy thật) cho cả phiên chạy.
public final class NativePlayer: NSObject, AVAudioPlayerDelegate {
    /// cont (1.8.1): còn đoạn tiếp của CÙNG câu theo sau (câu dài bị chẻ nhỏ ở
    /// phía web) — hết đoạn này dùng khoảng nghỉ dấu phẩy thay vì nghỉ hết câu.
    public struct Item { let text: String; let chapter: String; let paraEnd: Bool; let cont: Bool }
    public struct AudioSettings {
        var volume: Float = 1.0        // 0..1
        var pitchCents: Float = 0      // -1200..1200 (100 cent = 1 bán âm)
        // 1.9.4: MỘT khoảng nghỉ chung cho mọi dấu câu (.,;!:"()?...) theo yêu
        // cầu của người dùng — trước đây tách nghỉ sau câu / sau phẩy.
        var gapPunct: Double = 0.25    // nghỉ tại mọi ranh giới dấu câu (giây)
        var gapParagraph: Double = 0.8 // nghỉ khi xuống đoạn
    }

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
    private var settings = AudioSettings()
    private var cache: [String: Data] = [:]
    private var generation: Int = 0
    private var wasPlayingBeforeInterruption = false

    // AVAudioEngine stack (đường chính từ 1.0.6)
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var engineAttached = false
    private var connectedFormat: AVAudioFormat?
    private var engineBusy = false          // đang có buffer xếp lịch cho gen hiện tại
    private var useEngine = true            // false vĩnh viễn sau lỗi engine đầu tiên

    // AVAudioPlayer (đường dự phòng)
    private var audioPlayer: AVAudioPlayer?
    private var fallbackDatas: [Data] = []
    private var fallbackClause: Int = 0
    private var fallbackGen: Int = 0

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
            if self.useEngine { self.node.pause() } else { self.audioPlayer?.pause() }
            self.updateNowPlaying()
            self.emitState()
        }
    }

    public func resume() {
        queue.async { [weak self] in
            guard let self, !self.items.isEmpty else { return }
            self.playing = true
            BackgroundAudio.shared.reactivateSession()
            if self.useEngine, self.engineBusy {
                if self.ensureEngineRunning() { self.node.play() }
                self.updateNowPlaying()
                self.emitState()
            } else if !self.useEngine, let p = self.audioPlayer, !p.isPlaying, p.currentTime > 0 {
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
        engineBusy = false
        if useEngine { node.stop() }
        audioPlayer?.stop()
        audioPlayer = nil
        fallbackDatas = []
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
            self.timePitch.rate = self.rate
            if let p = self.audioPlayer { p.rate = self.rate }
        }
    }

    public func setAudio(_ s: AudioSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.settings = s
            self.node.volume = s.volume
            self.timePitch.pitch = s.pitchCents
            if let p = self.audioPlayer { p.volume = s.volume }
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
                if self.useEngine { self.node.pause() } else { self.audioPlayer?.pause() }
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
                if self.useEngine {
                    if self.engineBusy, self.ensureEngineRunning() { self.node.play() }
                    else if self.index >= 0 { self.startCurrent() }
                } else if let p = self.audioPlayer { p.play() }
                else if self.index >= 0 { self.startCurrent() }
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
        engineBusy = false
        if useEngine { node.stop() }
        audioPlayer?.stop(); audioPlayer = nil
        emitSentence()
        updateNowPlaying()
        DispatchQueue.main.async { BackgroundAudio.shared.beginBackgroundAssertion(name: "SachNoiSynthesize") }
        queue.async { [weak self] in
            guard let self else { return }
            // 1.9.4: tổng hợp CẢ đoạn trong MỘT lần gọi engine. Trước đây khi
            // gapComma >= 0.05 đoạn bị chẻ theo dấu phẩy thành nhiều lần gọi —
            // mỗi lần gọi tốn một lượt prefill đầy đủ của engine nên tổng hợp
            // chậm hơn hẳn và không theo kịp tốc độ phát (máy thật 1.9.3: cứ
            // hết 1 đoạn lại ngưng lâu chờ tổng hợp). Dấu câu bên trong đoạn
            // do engine tự xử lý khi phiên âm; khoảng nghỉ tại ranh giới đoạn
            // dùng chung gapPunct.
            let key = "\(idx)"
            var datas: [Data] = []
            var ok = true
            if let d = self.cache[key] {
                datas = [d]
            } else if let d = try? TtsServer.shared.synthesizeSync(text: item.text, voice: self.voice) {
                self.cache[key] = d
                datas = [d]
            } else { ok = false }
            DispatchQueue.main.async { BackgroundAudio.shared.endBackgroundAssertion() }
            guard gen == self.generation, self.playing, self.index == idx else { return }
            guard ok, !datas.isEmpty else {
                // Tổng hợp lỗi 1 câu: bỏ qua câu đó, đọc câu tiếp để không chết cả sách
                self.advance()
                return
            }
            // 1.9.3 (P0-B): nhìn trước 5 đoạn thay vì 2 — tổng hợp chậm biến thiên
            // thì vẫn còn đệm, không im lặng chờ giữa câu.
            for n in 1...5 { self.prefetch(next: idx + n) }
            self.trimCache(around: idx)
            if self.useEngine {
                if !self.scheduleOnEngine(datas: datas, item: item, gen: gen, idx: idx) {
                    self.useEngine = false // rơi về AVAudioPlayer cho cả phiên
                    self.playFallback(datas: datas, item: item, gen: gen, idx: idx)
                }
            } else {
                self.playFallback(datas: datas, item: item, gen: gen, idx: idx)
            }
        }
    }

    private func prefetch(next nextIdx: Int) {
        guard nextIdx < items.count else { return }
        let v = voice
        let text = items[nextIdx].text
        // 1.9.3 (P0-B): prefetch chạy ở QoS .default thay vì .utility để
        // tổng hợp đoạn kế không bị hệ thống dìm xuống khi máy bận.
        // 1.9.4: một lần gọi engine cho cả đoạn, khoá cache là chỉ số đoạn.
        DispatchQueue.global(qos: .default).async { [weak self] in
            let key = "\(nextIdx)"
            var exists = false
            self?.queue.sync { exists = self?.cache[key] != nil }
            if exists { return }
            if let d = try? TtsServer.shared.synthesizeSync(text: text, voice: v) {
                self?.queue.async { if self?.cache[key] == nil { self?.cache[key] = d } }
            }
        }
    }

    private func trimCache(around idx: Int) {
        // 1.9.3 (P0-B): cửa sổ ±6 khớp với prefetch sâu 5 — đoạn đã tổng hợp
        // trước không bị xoá ngay trước khi phát tới.
        for k in cache.keys {
            if let n = Int(k.split(separator: "#").first ?? ""), abs(n - idx) > 6 {
                cache.removeValue(forKey: k)
            }
        }
    }

    // MARK: - Đường AVAudioEngine (âm lượng + tông + khoảng nghỉ bằng buffer im lặng)
    private func ensureEngine(format: AVAudioFormat) -> Bool {
        if !engineAttached {
            engine.attach(node)
            engine.attach(timePitch)
            engineAttached = true
        }
        if connectedFormat == nil || connectedFormat!.sampleRate != format.sampleRate || connectedFormat!.channelCount != format.channelCount {
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(node, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            connectedFormat = format
            node.volume = settings.volume
            timePitch.pitch = settings.pitchCents
            timePitch.rate = rate
        }
        return ensureEngineRunning()
    }

    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }
        BackgroundAudio.shared.reactivateSession()
        engine.prepare()
        do { try engine.start(); return true } catch { return false }
    }

    private func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        if let b = makeBufferInMemory(from: data) { return b }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sachnoi-\(UUID().uuidString).wav")
        do {
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
            try file.read(into: buffer)
            buffer.frameLength = frames
            return buffer
        } catch { return nil }
    }

    /// 1.9.4: WAV do chính VieNeuEngine.wavData viết (RIFF, PCM16, mono) —
    /// giải mã thẳng trong bộ nhớ thay vì ghi file tạm rồi đọc lại bằng
    /// AVAudioFile ở mỗi đoạn (đỡ một vòng đĩa ngay tại ranh giới phát).
    /// Parse không khớp thì trả nil, nơi gọi tự rơi về đường file cũ.
    private func makeBufferInMemory(from data: Data) -> AVAudioPCMBuffer? {
        guard data.count > 44,
              data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
              data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45
        else { return nil }
        func u32(_ off: Int) -> Int { Int(data[off]) | Int(data[off + 1]) << 8 | Int(data[off + 2]) << 16 | Int(data[off + 3]) << 24 }
        func u16(_ off: Int) -> Int { Int(data[off]) | Int(data[off + 1]) << 8 }
        var off = 12
        var dataOff = -1
        var dataLen = 0
        while off + 8 <= data.count {
            let id = String(bytes: data[off..<(off + 4)], encoding: .ascii) ?? ""
            let len = u32(off + 4)
            if id == "data" { dataOff = off + 8; dataLen = len; break }
            off += 8 + len
        }
        guard dataOff > 0 else { return nil }
        let channels = u16(22)
        let sampleRate = u32(24)
        let bits = u16(34)
        guard channels == 1, bits == 16, sampleRate > 0 else { return nil }
        let frames = min(dataLen / 2, (data.count - dataOff) / 2)
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let src = base.advanced(by: dataOff).assumingMemoryBound(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(src[i]) / 32768.0 }
        }
        return buffer
    }

    private func silenceBuffer(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * max(0.01, seconds))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames // dữ liệu mặc định toàn 0 = im lặng
        return buffer
    }

    /// Xếp lịch: [buffer đoạn, nghỉ cuối đoạn]. Hoàn thành phát của buffer
    /// CUỐI mới chuyển câu. Trả false nếu engine lỗi.
    private func scheduleOnEngine(datas: [Data], item: Item, gen: Int, idx: Int) -> Bool {
        var buffers: [AVAudioPCMBuffer] = []
        for d in datas {
            guard let b = makeBuffer(from: d) else { return false }
            buffers.append(b)
        }
        guard let format = buffers.first?.format, ensureEngine(format: format) else { return false }
        // 1.9.4: mỗi đoạn là 1 buffer duy nhất (không còn chẻ mệnh đề); khoảng
        // nghỉ cuối đoạn: xuống đoạn dùng gapParagraph, mọi ranh giới dấu câu
        // còn lại dùng chung gapPunct.
        var plan: [AVAudioPCMBuffer] = buffers
        let endGap = item.paraEnd ? settings.gapParagraph : settings.gapPunct
        if endGap >= 0.02, let s = silenceBuffer(format: format, seconds: endGap) { plan.append(s) }
        guard !plan.isEmpty else { return false }
        engineBusy = true
        for (i, b) in plan.enumerated() {
            if i == plan.count - 1 {
                node.scheduleBuffer(b, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async {
                        guard let self, gen == self.generation, self.playing, self.index == idx else { return }
                        self.engineBusy = false
                        self.advance()
                    }
                }
            } else {
                node.scheduleBuffer(b, at: nil, options: [], completionCallbackType: .dataPlayedBack, completionHandler: nil)
            }
        }
        if !node.isPlaying { node.play() }
        return true
    }

    // MARK: - Đường AVAudioPlayer (dự phòng khi engine lỗi)
    private func playFallback(datas: [Data], item: Item, gen: Int, idx: Int) {
        fallbackDatas = datas
        fallbackClause = 0
        fallbackGen = gen
        playFallbackClause(item: item, gen: gen, idx: idx)
    }

    private func playFallbackClause(item: Item, gen: Int, idx: Int) {
        guard fallbackClause < fallbackDatas.count,
              let player = try? AVAudioPlayer(data: fallbackDatas[fallbackClause]) else {
            // Hết đoạn: chờ khoảng nghỉ rồi chuyển (đường này không chèn được
            // buffer im lặng nên dùng hẹn giờ trên hàng đợi phát)
            let gap = item.paraEnd ? settings.gapParagraph : settings.gapPunct
            queue.asyncAfter(deadline: .now() + max(0, gap)) { [weak self] in
                guard let self, gen == self.generation, self.playing, self.index == idx else { return }
                self.advance()
            }
            return
        }
        BackgroundAudio.shared.reactivateSession()
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.volume = settings.volume
        player.prepareToPlay()
        audioPlayer = player
        player.play()
    }

    // MARK: AVAudioPlayerDelegate
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        queue.async { [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            guard self.playing else { return }
            self.fallbackClause += 1
            if self.fallbackClause < self.fallbackDatas.count {
                // Nghỉ giữa các phần ở đường dự phòng (1.9.4: dùng gapPunct chung)
                let gen = self.fallbackGen, idx = self.index
                let item = self.items[idx]
                self.queue.asyncAfter(deadline: .now() + max(0, self.settings.gapPunct)) { [weak self] in
                    guard let self, gen == self.generation, self.playing, self.index == idx else { return }
                    self.playFallbackClause(item: item, gen: gen, idx: idx)
                }
            } else if self.index >= 0, self.index < self.items.count {
                self.playFallbackClause(item: self.items[self.index], gen: self.fallbackGen, idx: self.index)
            }
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        queue.async { [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            if self.playing { self.advance() }
        }
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
        engineBusy = false
        audioPlayer = nil
        BackgroundAudio.shared.updatePlayback(isPlaying: false, elapsed: Double(index))
        emitState()
        onEnded?()
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
