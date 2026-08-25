import AppKit
import Foundation

/// Голосовое сообщение: запись сжимается и кладётся в буфер файлом.
/// Дальше её вставляют в чат обычным Cmd+V.
///
/// Формат ogg с opus, а не m4a: мессенджеры показывают голосовым сообщением
/// именно его, остальное приезжает вложением с плеером. 48 кГц моно, 24 кбит,
/// профиль voip — то же, что пишут сами мессенджеры. Выходит около 178 КБ
/// на минуту против 1875 у исходного WAV.
enum VoiceMessage {
    enum VoiceError: LocalizedError {
        case noEncoder
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noEncoder:
                return "Сжатие звука недоступно: в приложении нет ffmpeg"
            case .encodingFailed(let detail):
                return "Не удалось сжать запись: \(detail)"
            }
        }
    }

    /// Готовые файлы живут рядом с историей, а не во временной папке системы:
    /// в буфере лежит ссылка, и файл обязан пережить вставку.
    static var directory: URL {
        Config.directory.appendingPathComponent("voice")
    }

    /// Сколько держим отправленные файлы. Ссылка в буфере живёт, пока живёт
    /// файл, поэтому убирать сразу нельзя.
    private static let retentionHours = 24.0

    /// Сжимает запись и кладёт её в буфер. Возвращает путь к файлу.
    static func copyToClipboard(wav: Data, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try encode(wav: wav) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let url):
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.writeObjects([url as NSURL])
                    purge()
                    completion(.success(url))
                }
            }
        }
    }

    private static func encode(wav: Data) throws -> URL {
        guard let ffmpeg = MediaDecoder.ffmpegPath() else { throw VoiceError.noEncoder }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        let source = directory.appendingPathComponent("\(stamp).wav")
        let target = directory.appendingPathComponent("voice-\(stamp).ogg")
        try wav.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-loglevel", "error", "-i", source.path,
                             "-c:a", "libopus", "-b:a", "24k", "-ar", "48000",
                             "-ac", "1", "-application", "voip",
                             "-f", "ogg", target.path]
        process.environment = Whisper.childEnvironment
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let complaint = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int,
              size > 0
        else {
            let detail = String(data: complaint, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "код \(process.terminationStatus)"
            throw VoiceError.encodingFailed(detail.isEmpty ? "код \(process.terminationStatus)" : detail)
        }
        return target
    }

    /// Чистит вчерашние файлы. Свежий не трогаем никогда: на него смотрит буфер.
    private static func purge() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let deadline = Date().addingTimeInterval(-retentionHours * 3600)
        var removed = 0
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if modified < deadline, (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 { Log.write("голосовые: удалено файлов \(removed)") }
    }
}
