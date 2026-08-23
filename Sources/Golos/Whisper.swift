import Foundation

/// Держит whisper-server поднятым всё время работы приложения.
/// Модель на 3 ГБ грузится 3–4 секунды, поэтому дёргать CLI на каждую фразу
/// нельзя — резидентный сервер даёт около секунды на десять секунд речи.
final class Whisper {
    private let port: Int
    private let config: Config

    /// Состояние трогают два потока: главный читает ready перед записью,
    /// фоновый пишет его, дождавшись загрузки модели. Поэтому под замком.
    private let stateLock = NSLock()
    private var storedProcess: Process?
    private var storedReady = false
    private var storedError: String?
    /// Растёт на каждый stop(). Фоновый запуск сверяется с ним, чтобы не
    /// подсунуть процесс, который уже никому не нужен.
    private var generation = 0

    var ready: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return storedReady
    }

    var lastError: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return storedError
    }

    private func setError(_ message: String?) {
        stateLock.lock(); storedError = message; stateLock.unlock()
    }

    init(config: Config) {
        self.config = config
        self.port = config.port
    }

    /// PATH у приложения, запущенного из Finder, не содержит /opt/homebrew/bin.
    /// Дочерним процессам окружение задаём явно.
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extra + existing)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
        return env
    }

    /// Ищем бинарник сами: полагаться на PATH нельзя по той же причине.
    static func locate(_ name: String) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        return dirs.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Движок внутри бандла — основной путь. Homebrew остаётся запасным
    /// вариантом для сборки из исходников без ./build-engine.sh.
    static func enginePath() -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/whisper-server").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return locate("whisper-server")
    }

    enum WhisperError: LocalizedError {
        case serverMissing
        case modelMissing(String)
        case notReady
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .serverMissing:
                return "Движок распознавания не найден в приложении"
            case .modelMissing(let p):
                return p.isEmpty ? "Модель не указана в config.json" : "Модель не найдена: \(p)"
            case .notReady:
                return "Сервер распознавания ещё не готов"
            case .http(let code, let body):
                return "Сервер ответил \(code): \(body.prefix(200))"
            case .badResponse:
                return "Не разобрал ответ сервера"
            }
        }
    }

    /// Поднимает сервер и ждёт готовности. Вызывать при старте приложения,
    /// чтобы первая же диктовка была тёплой.
    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        stateLock.lock()
        let alreadyRunning = storedProcess != nil
        let launchGeneration = generation
        stateLock.unlock()
        guard !alreadyRunning else { completion(.success(())); return }

        guard let bin = Whisper.enginePath() else {
            setError(WhisperError.serverMissing.localizedDescription)
            completion(.failure(WhisperError.serverMissing)); return
        }
        guard !config.modelPath.isEmpty,
              FileManager.default.fileExists(atPath: config.modelPath) else {
            let e = WhisperError.modelMissing(config.modelPath)
            setError(e.localizedDescription)
            completion(.failure(e)); return
        }

        var args = [
            "-m", config.modelPath,
            "--port", String(port),
            "--host", "127.0.0.1",
            "-t", String(config.threads),
            "-nt"
        ]
        if config.language != "auto" { args += ["-l", config.language] }
        if !config.vadModelPath.isEmpty,
           FileManager.default.fileExists(atPath: config.vadModelPath) {
            args += ["--vad", "-vm", config.vadModelPath]
        }

        // Всё дальнейшее — на фоновой очереди. killStrays ждёт завершения
        // pkill и спит треть секунды, а start() вызывается с главного потока:
        // раньше на это время подвисали и меню, и окно настроек.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Прошлый экземпляр приложения мог умереть, не прибрав за собой:
            // сервер держит порт и зря занимает память под модель.
            Whisper.killStrays(port: self.port)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.environment = Whisper.childEnvironment
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice

            do {
                try p.run()
            } catch {
                self.setError(error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            // Пока поднимались, могли успеть вызвать stop() — тогда процесс
            // никому не нужен и его надо снять, а не записывать в поле.
            self.stateLock.lock()
            let stale = self.generation != launchGeneration
            if !stale { self.storedProcess = p }
            self.stateLock.unlock()
            if stale {
                p.terminate()
                return
            }

            // Ждём, пока модель прогрузится: сервер начинает отвечать только после этого.
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                if self.ping() {
                    self.stateLock.lock()
                    let current = self.generation == launchGeneration
                    if current {
                        self.storedReady = true
                        self.storedError = nil
                    }
                    self.stateLock.unlock()
                    guard current else { return }
                    DispatchQueue.main.async { completion(.success(())) }
                    return
                }
                if p.isRunning == false { break }

                self.stateLock.lock()
                let current = self.generation == launchGeneration
                self.stateLock.unlock()
                guard current else { return }

                Thread.sleep(forTimeInterval: 0.25)
            }
            let e = WhisperError.notReady
            self.setError(e.localizedDescription)
            DispatchQueue.main.async { completion(.failure(e)) }
        }
    }

    func stop() {
        stateLock.lock()
        let p = storedProcess
        storedProcess = nil
        storedReady = false
        generation += 1
        stateLock.unlock()
        p?.terminate()
    }

    /// Снимает whisper-server, оставшиеся от прошлых запусков на нашем порту.
    static func killStrays(port: Int) {
        guard let pkill = locate("pkill") ?? (FileManager.default.isExecutableFile(atPath: "/usr/bin/pkill") ? "/usr/bin/pkill" : nil) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pkill)
        p.arguments = ["-f", "whisper-server .*--port \(port)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        // Порт освобождается не мгновенно.
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func ping() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0)
        var alive = false
        URLSession.shared.dataTask(with: req) { _, response, _ in
            alive = response != nil
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return alive
    }

    /// Отправляет WAV на распознавание. prompt смещает декодер к латинице
    /// для терминов из словаря.
    func transcribe(wav: Data, prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard ready, let url = URL(string: "http://127.0.0.1:\(port)/inference") else {
            completion(.failure(WhisperError.notReady)); return
        }

        let boundary = "golos-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))

        field("response_format", "json")
        field("temperature", "0")
        if config.language != "auto" { field("language", config.language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 120

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                DispatchQueue.main.async { completion(.failure(WhisperError.badResponse)) }
                return
            }
            guard (200..<300).contains(code) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async { completion(.failure(WhisperError.http(code, body))) }
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String else {
                DispatchQueue.main.async { completion(.failure(WhisperError.badResponse)) }
                return
            }
            DispatchQueue.main.async { completion(.success(Whisper.clean(text))) }
        }.resume()
    }

    /// Сервер режет ответ по сегментам и вставляет переводы строк там, где в речи
    /// их не было; плюс whisper любит помечать тишину служебными скобками.
    static func clean(_ raw: String) -> String {
        var text = raw
        for marker in ["[BLANK_AUDIO]", "[ Тишина ]", "(тишина)", "[Music]", "[音楽]"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        let joined = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
