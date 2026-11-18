import Foundation
import Network
import CryptoKit

/// Server HTTP nội bộ 127.0.0.1:3900 — đúng bề mặt API của TTS Bridge trên máy
/// tính (đợt 13) để web app dùng nguyên pipeline cũ, nhưng engine VieNeu chạy
/// NGAY TRONG APP (VieNeuEngine), không cần máy tính, không cần mạng.
/// Cache WAV theo (giọng + nội dung) trong thư mục Caches, tối đa 300 file.
final class TtsServer {
    static let shared = TtsServer()

    // 1.9.5: HỒ ENGINE. Số liệu Chẩn đoán trên máy anh (1.9.4): tổng hợp 1
    // đoạn trung bình 13,5s, lần lâu nhất 32s — trong khi đoạn đó phát chỉ
    // ~10s ở tốc độ 1,25×. MỘT engine vì vậy không bao giờ theo kịp, đệm
    // sâu bao nhiêu cũng cạn. Hai engine độc lập (session ONNX, g2p, rng
    // riêng từng engine) tổng hợp 2 đoạn SONG SONG -> thông lượng gần gấp
    // đôi. Máy RAM < 3GB giữ 1 engine để tránh bị iOS giết vì bộ nhớ.
    private let maxEngines: Int
    private let poolLock = NSLock()
    private var idleEngines: [VieNeuEngine] = []
    private var totalEngines = 0 // đã tạo + đang tạo

    private init() {
        maxEngines = ProcessInfo.processInfo.physicalMemory >= 3_000_000_000 ? 2 : 1
    }

    private var listener: NWListener?
    private let synthQueue = DispatchQueue(label: "app.sachnoi.tts", qos: .userInitiated)

    /// 1.9.4: khoảng lặng tại dấu câu do người dùng đặt (plugin ghi vào mỗi
    /// khi áp cài đặt âm thanh). Mặc định khớp hành vi gốc của engine.
    var punctPauseSeconds: Double = 0.3
    var paraPauseSeconds: Double = 0.7

    // 1.9.4: thống kê thời gian tổng hợp để chẩn đoán tốc độ thật trên máy
    // (tab Chẩn đoán): lần gần nhất + trung bình, kèm số ký tự của lần đó.
    private var synthLastMs = 0
    private var synthLastChars = 0
    private var synthAvgMs = 0

    private enum EngineState {
        case notStarted, loading, ready, failed(String)
    }
    private var engineState: EngineState = .notStarted

    // Trạng thái để chẩn đoán từ phía web (plugin ttsDiagnostics): server có nghe
    // thật không, engine lỗi ở đâu — thay vì im lặng rơi về giọng trình duyệt.
    private let stateLock = NSLock()
    private var listenerState = "chưa khởi động"
    private var lastEngineError: String?
    private var voiceStore: VoiceStore?

    private func setListenerState(_ value: String) {
        stateLock.lock(); listenerState = value; stateLock.unlock()
    }

    private func setEngineError(_ value: String?) {
        stateLock.lock(); lastEngineError = value; stateLock.unlock()
    }

    // engineState đọc/ghi qua stateLock (đợt 29): chẩn đoán và /health KHÔNG còn
    // phải xếp hàng sau synthQueue — engine đang bận nạp/tổng hợp thì chẩn đoán
    // vẫn trả lời ngay thay vì treo theo.
    private var initStepsText = ""

    private func setEngineState(_ value: EngineState) {
        stateLock.lock(); engineState = value; stateLock.unlock()
    }

    private func engineStateSnapshot() -> EngineState {
        stateLock.lock(); defer { stateLock.unlock() }
        return engineState
    }

    private func setInitSteps(_ value: String) {
        stateLock.lock(); initStepsText = value; stateLock.unlock()
    }

    /// Đợt 31: app KHÔNG lưu lại âm thanh đã đọc — lõi tổng hợp trực tiếp mỗi
    /// lần nghe. Dọn một lần hai kho đĩa của các đợt trước nếu còn sót trên máy.
    private func purgeLegacyAudioStores() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: caches.appendingPathComponent("tts-cache", isDirectory: true))
        try? fm.removeItem(at: support.appendingPathComponent("tts-audio", isDirectory: true))
    }

    func start() {
        guard listener == nil else { return }
        purgeLegacyAudioStores()
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 3900)
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.setListenerState("ready")
                case .failed(let error): self?.setListenerState("failed: \(error)")
                case .waiting(let error): self?.setListenerState("waiting: \(error)")
                case .cancelled: self?.setListenerState("cancelled")
                default: self?.setListenerState("setup")
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: DispatchQueue(label: "app.sachnoi.tts.http"))
            self.listener = listener
        } catch {
            // Cổng bận/không mở được — web app sẽ rơi về giọng trình duyệt như cũ.
            setListenerState("start threw: \(error.localizedDescription)")
        }
        warmup()
    }

    /// Nạp model ở nền ngay khi app mở để lần bấm Nghe đầu tiên không phải chờ.
    /// 1.9.5: nạp sẵn CẢ HAI engine của hồ (tuần tự, tránh tranh CPU lúc mở app).
    func warmup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for _ in 0..<self.maxEngines {
                self.poolLock.lock()
                if self.totalEngines >= self.maxEngines { self.poolLock.unlock(); break }
                self.totalEngines += 1
                self.poolLock.unlock()
                if let e = try? self.makeEngine() {
                    self.releaseEngine(e)
                } else {
                    self.poolLock.lock(); self.totalEngines -= 1; self.poolLock.unlock()
                    break
                }
            }
        }
    }

    func assetsURL() throws -> URL {
        // Bản nhẹ: assets nằm ở gói core đã tải (PackStore), bundle chỉ là dự phòng dev.
        guard let assets = PackStore.vieneuAssetsURL() else {
            throw VieNeuEngine.EngineError.asset("TTSAssets (chưa tải gói core VieNeu)")
        }
        return assets
    }

    /// Danh sách giọng đọc thẳng từ file preset — KHÔNG cần dựng engine (4 session
    /// ONNX) nên /v1/audio/voices và cầu plugin trả nhanh + độc lập: engine có lỗi
    /// thì giọng vẫn liệt kê được, lỗi nằm riêng ở mục chẩn đoán.
    func getVoiceStore() throws -> VoiceStore {
        if let voiceStore { return voiceStore }
        let store = try VoiceStore(url: assetsURL().appendingPathComponent("voices_v3_turbo.json"))
        voiceStore = store
        return store
    }

    private func makeEngine() throws -> VieNeuEngine {
        setEngineState(.loading)
        do {
            let created = try VieNeuEngine(assetsDir: assetsURL())
            setEngineState(.ready)
            setInitSteps(VieNeuEngine.lastInitSteps)
            setEngineError(nil)
            return created
        } catch {
            setEngineState(.failed(error.localizedDescription))
            setInitSteps(VieNeuEngine.lastInitSteps)
            setEngineError(error.localizedDescription)
            throw error
        }
    }

    /// Lấy 1 engine rảnh khỏi hồ; chưa có thì tạo mới nếu còn suất; cả hai
    /// đang bận thì chờ (mỗi engine chỉ phục vụ 1 lần tổng hợp tại một thời
    /// điểm nên rng/phonemizer của nó không bao giờ bị dùng đồng thời).
    private func acquireEngine() throws -> VieNeuEngine {
        let deadline = Date().addingTimeInterval(30)
        while true {
            poolLock.lock()
            if let e = idleEngines.popLast() { poolLock.unlock(); return e }
            if totalEngines < maxEngines {
                totalEngines += 1
                poolLock.unlock()
                do { return try makeEngine() }
                catch {
                    poolLock.lock(); totalEngines -= 1; poolLock.unlock()
                    throw error
                }
            }
            poolLock.unlock()
            if case .failed(let msg) = engineStateSnapshot() {
                throw VieNeuEngine.EngineError.asset("engine lỗi: \(msg)")
            }
            if Date() > deadline { throw VieNeuEngine.EngineError.asset("engine chưa sẵn sàng sau 30s") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func releaseEngine(_ e: VieNeuEngine) {
        poolLock.lock(); idleEngines.append(e); poolLock.unlock()
    }

    /// Ảnh chụp trạng thái cho web hiển thị khi dò giọng thất bại (plugin
    /// ttsDiagnostics gọi, kèm tự kiểm tra loopback ở phía plugin).
    func diagnostics() -> [String: Any] {
        stateLock.lock()
        let ls = listenerState
        let ee = lastEngineError ?? ""
        let steps = initStepsText
        let sLast = synthLastMs, sChars = synthLastChars, sAvg = synthAvgMs
        stateLock.unlock()
        poolLock.lock()
        let poolTotal = totalEngines, poolIdle = idleEngines.count
        poolLock.unlock()
        var engineText = "notStarted"
        switch engineStateSnapshot() {
        case .notStarted: engineText = "notStarted"
        case .loading: engineText = "loading"
        case .ready: engineText = "ready"
        case .failed(let message): engineText = "failed: \(message)"
        }
        var assetsFound = false
        var missing: [String] = []
        if let assets = PackStore.vieneuAssetsURL() {
            assetsFound = true
            let expected = ["config.json", "heads.bin", "heads.json", "tokenizer.json", "sea_g2p.bin",
                            "voices_v3_turbo.json", "vieneu_prefill.onnx", "vieneu_decode_step.onnx",
                            "vieneu_acoustic_cached.onnx", "vieneu_backbone_shared.data",
                            "moss_audio_tokenizer_decode_full.onnx", "moss_audio_tokenizer_decode_shared.data"]
            for name in expected where !FileManager.default.fileExists(atPath: assets.appendingPathComponent(name).path) {
                missing.append(name)
            }
        }
        return [
            "listener": ls,
            "engine": engineText,
            "engineError": ee,
            "initSteps": steps,
            "assetsFound": assetsFound,
            "assetsMissing": missing,
            "synthLastMs": sLast,
            "synthLastChars": sChars,
            "synthAvgMs": sAvg,
            "synthSteps": VieNeuEngine.lastSynthSteps,
            "engines": "\(poolTotal)/\(maxEngines) (rảnh \(poolIdle))",
        ]
    }

    // MARK: - HTTP tối thiểu

    private struct Request {
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var body = Data()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "app.sachnoi.tts.conn"))
        receive(conn, accumulated: Data())
    }

    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer += data }
            if let request = self.tryParse(buffer) {
                self.respond(conn, request)
                return
            }
            if isComplete || error != nil {
                self.respondError(conn, status: 400, message: "Yêu cầu không hợp lệ")
                return
            }
            self.receive(conn, accumulated: buffer)
        }
    }

    private func tryParse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) ?? ""
        var lines = headerText.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var request = Request()
        request.method = String(first[0])
        request.path = String(first[1])
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                request.headers[key] = value
            }
        }
        let bodyStart = headerEnd.upperBound
        let contentLength = Int(request.headers["content-length"] ?? "0") ?? 0
        if buffer.count - bodyStart < contentLength { return nil }
        request.body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return request
    }

    private func respond(_ conn: NWConnection, _ request: Request) {
        if request.method == "OPTIONS" {
            send(conn, status: 204, contentType: nil, body: Data(), extra: [
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
            ])
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            var loaded = false
            var loading = false
            var errorText: String?
            switch engineStateSnapshot() {
            case .ready: loaded = true
            case .loading: loading = true
            case .failed(let message): errorText = message
            case .notStarted: break
            }
            sendJson(conn, status: 200, object: [
                "ok": errorText == nil,
                "engine": "vieneu",
                "model": "VieNeu-TTS v3 Turbo (trong app)",
                "model_loaded": loaded,
                "loading": loading,
                "sample_rate": VieNeuEngine.sampleRate,
                "error": errorText as Any,
            ])
        case ("GET", "/v1/audio/voices"):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let store = try self.getVoiceStore()
                    let voices = store.presets.map {
                        ["id": $0.name, "name": $0.label, "language": "vi"] as [String: Any]
                    }
                    self.sendJson(conn, status: 200, object: ["voices": voices])
                } catch {
                    self.sendJson(conn, status: 503, object: ["error": "Không đọc được danh sách giọng",
                                                              "detail": error.localizedDescription])
                }
            }
        case ("POST", "/v1/audio/speech"):
            handleSpeech(conn, request)
        default:
            sendJson(conn, status: 404, object: ["error": "Không tìm thấy đường này"])
        }
    }

    private func handleSpeech(_ conn: NWConnection, _ request: Request) {
        guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            sendJson(conn, status: 400, object: ["error": "Body phải là JSON"])
            return
        }
        let text = ((payload["input"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = (payload["voice"] as? String) ?? "default"
        if text.isEmpty {
            sendJson(conn, status: 400, object: ["error": "Thiếu trường input"])
            return
        }
        if text.count > 2000 {
            sendJson(conn, status: 400, object: ["error": "Đoạn văn quá dài (tối đa 2000 ký tự/lần)"])
            return
        }
        synthQueue.async { [weak self] in
            guard let self else { return }
            do {
                let wav = try self.synthesizeNow(text: text, voice: voice)
                self.send(conn, status: 200, contentType: "audio/wav", body: wav)
            } catch {
                self.sendJson(conn, status: 500, object: ["error": "Tổng hợp thất bại: \(error.localizedDescription)"])
            }
        }
    }

    /// Cho cầu plugin gọi từ thread khác. 1.9.5: KHÔNG còn xếp hàng serial
    /// qua synthQueue — chính hàng đợi đó từng ép mọi lần tổng hợp chạy nối
    /// tiếp trên 1 engine. Nay lấy engine từ hồ và tổng hợp song song.
    func synthesizeSync(text: String, voice: String) throws -> Data {
        try synthesizeNow(text: text, voice: voice)
    }

    /// Tổng hợp TRỰC TIẾP bằng lõi (đợt 31): không đọc/ghi đĩa, không lưu lại
    /// âm thanh đã đọc. Engine đã nạp sẵn từ lúc mở app nên đây là suy luận thuần.
    func synthesizeNow(text: String, voice: String) throws -> Data {
        let engine = try acquireEngine()
        defer { releaseEngine(engine) }
        let preset = engine.voices.resolve(voice.isEmpty ? nil : voice)
        let t0 = Date()
        let data = try engine.synthesize(text: text, voiceName: preset.name,
                                         punctPause: punctPauseSeconds, paraPause: paraPauseSeconds)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        stateLock.lock()
        synthLastMs = ms
        synthLastChars = text.count
        synthAvgMs = synthAvgMs == 0 ? ms : (synthAvgMs * 3 + ms) / 4
        stateLock.unlock()
        return data
    }


    // MARK: - Gửi phản hồi

    private func sendJson(_ conn: NWConnection, status: Int, object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        send(conn, status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    private func respondError(_ conn: NWConnection, status: Int, message: String) {
        sendJson(conn, status: status, object: ["error": message])
    }

    private func send(_ conn: NWConnection, status: Int, contentType: String?, body: Data,
                      extra: [String: String] = [:]) {
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found",
                       500: "Internal Server Error", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "")\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(head.utf8)
        packet += body
        conn.send(content: packet, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
