import AppKit
import Foundation

/// Расшифровка готового файла: встречи, созвона, записи экрана.
///
/// Отличие от диктовки в том, что результат нужен с тайм-кодами и ложится
/// на диск, а не в поле ввода. Всё остальное — нарезка на куски, переспрос
/// без словаря, чистка выдумок — то же самое.
@MainActor
final class FileTranscriber {
    enum Stage {
        case reading        // достаём звук из файла
        case recognizing    // гоняем куски через движок
        case writing
    }

    struct Progress {
        var stage: Stage
        var fraction: Double
    }

    struct Result {
        var textFile: URL
        var subtitleFile: URL
        var audioFile: URL?
        var segments: Int
        var duration: TimeInterval
    }

    private let whisper: Whisper
    private var cancelled = false

    init(whisper: Whisper) {
        self.whisper = whisper
    }

    func cancel() { cancelled = true }

    func transcribe(url: URL,
                    config: Config,
                    onProgress: @escaping (Progress) -> Void,
                    onFinish: @escaping (Swift.Result<Result, Error>) -> Void) {
        cancelled = false
        onProgress(Progress(stage: .reading, fraction: 0))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let wav: Data
            do {
                wav = try MediaDecoder.wav(from: url) { fraction in
                    DispatchQueue.main.async {
                        onProgress(Progress(stage: .reading, fraction: fraction))
                    }
                }
            } catch {
                DispatchQueue.main.async { onFinish(.failure(error)) }
                return
            }

            DispatchQueue.main.async {
                self.recognize(wav: wav, source: url, config: config,
                               onProgress: onProgress, onFinish: onFinish)
            }
        }
    }

    // MARK: - Распознавание

    private func recognize(wav: Data, source: URL, config: Config,
                           onProgress: @escaping (Progress) -> Void,
                           onFinish: @escaping (Swift.Result<Result, Error>) -> Void) {
        let chunks = AudioSplit.chunksWithOffsets(wav: wav)
        Log.write("расшифровка файла «\(source.lastPathComponent)»: кусков \(chunks.count)")

        var segments: [Whisper.Segment] = []
        var index = 0

        func step() {
            guard !cancelled else {
                onFinish(.failure(CancellationError()))
                return
            }
            guard index < chunks.count else {
                onProgress(Progress(stage: .writing, fraction: 1))
                finish(segments: segments, wav: wav, source: source,
                       config: config, onFinish: onFinish)
                return
            }

            let chunk = chunks[index]
            onProgress(Progress(stage: .recognizing,
                                fraction: Double(index) / Double(chunks.count)))

            askChunk(chunk, prompt: config.promptString, attempt: 1) { pieces in
                segments.append(contentsOf: pieces)
                index += 1
                step()
            }
        }
        step()
    }

    /// Один кусок с теми же защитами, что и диктовка: заученная фраза,
    /// зацикливание и пустота лечатся переспросом без словаря.
    private func askChunk(_ chunk: AudioSplit.Chunk, prompt: String, attempt: Int,
                          completion: @escaping ([Whisper.Segment]) -> Void) {
        whisper.transcribeSegments(wav: chunk.wav, prompt: prompt) { [weak self] result in
            guard let self else { return }
            guard case .success(let raw) = result else {
                completion([])
                return
            }

            let joined = raw.map(\.text).joined(separator: " ")
            let seconds = Double(chunk.wav.count - 44) / 32000
            let suspicious = Hallucination.looksInvented(text: joined, audioDuration: seconds)
                || Hallucination.looksDegenerate(joined)

            if attempt == 1, suspicious || joined.isEmpty, !prompt.isEmpty {
                Log.write("кусок не разобрался: «\(joined.prefix(60))» — переспрашиваю без словаря")
                self.askChunk(chunk, prompt: "", attempt: 2, completion: completion)
                return
            }

            // Тайм-коды приходят от начала куска — сдвигаем к началу файла.
            let shifted = raw.map {
                Whisper.Segment(start: $0.start + chunk.startSeconds,
                                end: $0.end + chunk.startSeconds,
                                text: $0.text,
                                joinsPreviousWord: $0.joinsPreviousWord)
            }
            completion(shifted)
        }
    }

    // MARK: - Запись результата

    private func finish(segments: [Whisper.Segment], wav: Data, source: URL, config: Config,
                        onFinish: @escaping (Swift.Result<Result, Error>) -> Void) {
        let base = source.deletingPathExtension().lastPathComponent
        let cleaned = clean(segments, config: config)

        // Папка рядом с исходником бывает недоступна для записи: диктофон,
        // флешка, сетевой диск, образ. Терять из-за этого сорок минут работы
        // нельзя, поэтому дальше спрашиваем, куда положить, а если человек
        // отказался — кладём в Загрузки, лишь бы не пропало.
        let preferred = outputFolder(for: source, config: config)
        var folders = [preferred]
        if !FileTranscriber.writable(preferred), let chosen = askWhereToSave(base: base, source: source) {
            folders.append(chosen)
        }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            folders.append(downloads)
        }
        folders.append(Config.directory.appendingPathComponent("Расшифровки"))

        var lastError: Error?
        for (index, folder) in folders.enumerated() {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                let textFile = folder.appendingPathComponent("\(base).txt")
                try plainText(cleaned).write(to: textFile, atomically: true, encoding: .utf8)

                let subtitleFile = folder.appendingPathComponent("\(base).srt")
                try subtitles(cleaned).write(to: subtitleFile, atomically: true, encoding: .utf8)

                var audioFile: URL?
                if config.keepConvertedAudio {
                    let target = folder.appendingPathComponent("\(base).wav")
                    try wav.write(to: target)
                    audioFile = target
                }

                if index > 0 {
                    Log.write("папка «\(folders[0].path)» недоступна для записи (\(lastError?.localizedDescription ?? "?")), расшифровка сохранена в \(folder.path)")
                }
                let duration = cleaned.last?.end ?? 0
                Log.write("расшифровка готова: \(textFile.path), отрезков \(cleaned.count)")
                onFinish(.success(Result(textFile: textFile, subtitleFile: subtitleFile,
                                         audioFile: audioFile, segments: cleaned.count,
                                         duration: duration)))
                return
            } catch {
                lastError = error
                // Мусор от половины записи убираем, чтобы рядом с исходником
                // не оставался обрезанный txt без субтитров.
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(base).txt"))
            }
        }

        Log.write("расшифровку не удалось сохранить никуда: \(lastError?.localizedDescription ?? "?")")
        onFinish(.failure(lastError ?? DecodeFailure.nowhereToWrite))
    }

    enum DecodeFailure: LocalizedError {
        case nowhereToWrite
        var errorDescription: String? { "Некуда сохранить расшифровку" }
    }

    private func clean(_ segments: [Whisper.Segment], config: Config) -> [Whisper.Segment] {
        segments.compactMap { segment in
            let text = config.applyReplacements(to: segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Whisper.Segment(start: segment.start, end: segment.end, text: text,
                                   joinsPreviousWord: segment.joinsPreviousWord)
        }
    }

    /// Пусто в настройках — кладём рядом с исходником, как и договаривались.
    /// Можно ли писать в папку. Проверяем заранее, чтобы спросить человека
    /// до того, как он увидит ошибку, а не после.
    static func writable(_ folder: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            // Папки ещё нет: создастся ли она, покажет попытка.
            guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
            else { return false }
        }
        return fm.isWritableFile(atPath: folder.path)
    }

    /// Спрашивает, куда положить расшифровку. Возвращает nil, если отказались.
    private func askWhereToSave(base: String, source: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Куда сохранить расшифровку"
        panel.message = "Рядом с «\(source.lastPathComponent)» записать нельзя: том только для чтения."
        panel.nameFieldStringValue = "\(base).txt"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            Log.write("сохранение отменили, кладу в Загрузки")
            return nil
        }
        // Имя файла складывает сама запись: рядом лягут ещё .srt и, может, .wav.
        return url.deletingLastPathComponent()
    }

    private func outputFolder(for source: URL, config: Config) -> URL {
        let stored = config.fileOutputFolder.trimmingCharacters(in: .whitespaces)
        guard !stored.isEmpty else { return source.deletingLastPathComponent() }
        return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath)
    }

    /// Текст абзацами: whisper режет речь на куски по несколько слов,
    /// и построчно читать это невозможно. Склеиваем до конца предложения,
    /// время берём от первого отрезка в абзаце.
    private func plainText(_ segments: [Whisper.Segment]) -> String {
        let minimumLine = 90
        let maximumLine = 400

        var lines: [String] = []
        var buffer = ""
        var start: Double = 0

        for segment in segments {
            if buffer.isEmpty { start = segment.start }
            if buffer.isEmpty {
                buffer = segment.text
            } else {
                // Разорванное слово склеиваем без пробела, иначе выходит
                // «стар ую версию».
                buffer += segment.joinsPreviousWord ? segment.text : " " + segment.text
            }

            let ended = buffer.last.map { ".!?…".contains($0) } ?? false
            if (ended && buffer.count >= minimumLine) || buffer.count >= maximumLine {
                lines.append("[\(timecode(start))] \(buffer)")
                buffer = ""
            }
        }
        if !buffer.isEmpty { lines.append("[\(timecode(start))] \(buffer)") }
        return lines.joined(separator: "\n\n")
    }

    private func subtitles(_ segments: [Whisper.Segment]) -> String {
        segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(srtTime(segment.start)) --> \(srtTime(segment.end))
            \(segment.text)
            """
        }.joined(separator: "\n\n") + "\n"
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func srtTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let milliseconds = Int((seconds - Double(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d",
                      total / 3600, (total % 3600) / 60, total % 60, milliseconds)
    }
}
