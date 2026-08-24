import AVFoundation
import Foundation

/// Приводит любой звуковой или видеофайл к тому, что ест распознавание:
/// моно 16 кГц, 16 бит.
///
/// Сперва системным декодером: mp3, m4a, mp4, mov, wav, aiff, caf и flac
/// AVFoundation читает сама, и звать ради них постороннее незачем.
/// Matroska и Ogg она не берёт вовсе, поэтому для webm, mkv, ogg и opus
/// в бандле лежит свой ffmpeg, урезанный до разбора звука (см. build-ffmpeg.sh).
enum MediaDecoder {
    enum DecodeError: LocalizedError {
        case unreadable(String)
        case noAudioTrack
        case converterFailed

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Не удалось прочитать «\(name)»"
            case .noAudioTrack: return "В файле нет звуковой дорожки"
            case .converterFailed: return "Не удалось преобразовать звук"
            }
        }
    }

    static let sampleRate = 16000

    /// Расширения, которые предлагаем перетаскивать.
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac",
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "ogg", "opus", "wma"
    ]

    /// Отдаёт WAV моно 16 кГц. Долгие файлы читаются потоком, целиком
    /// в память не поднимаются.
    static func wav(from url: URL, progress: ((Double) -> Void)? = nil) throws -> Data {
        do {
            return try decodeWithAVFoundation(url, progress: progress)
        } catch {
            // Системный декодер не взял формат — пробуем ffmpeg, если он есть.
            if let converted = try? decodeWithFFmpeg(url) { return converted }
            throw error
        }
    }

    private static func decodeWithAVFoundation(_ url: URL, progress: ((Double) -> Void)?) throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw DecodeError.noAudioTrack
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw DecodeError.unreadable(url.lastPathComponent) }

        // Просим сразу нужный формат: перекодирование берёт на себя система.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw DecodeError.converterFailed }
        reader.add(output)
        guard reader.startReading() else { throw DecodeError.converterFailed }

        let total = CMTimeGetSeconds(asset.duration)
        var pcm = Data()
        pcm.reserveCapacity(Int(max(1, total)) * sampleRate * 2)

        while let buffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                               totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                   let pointer {
                    pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                                                   count: length))
                }
            }
            if total > 0 {
                let done = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
                progress?(min(1, done / total))
            }
            CMSampleBufferInvalidate(buffer)
        }

        guard reader.status == .completed else { throw DecodeError.unreadable(url.lastPathComponent) }
        progress?(1)
        return wrapInWav(pcm)
    }

    /// Свой ffmpeg внутри бандла — основной путь для webm, mkv, ogg и opus.
    /// Системный остаётся запасным: для сборки из исходников без ./build-ffmpeg.sh.
    static func ffmpegPath() -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ffmpeg").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return Whisper.locate("ffmpeg")
    }

    /// Запасной путь для форматов, которые система не читает.
    private static func decodeWithFFmpeg(_ url: URL) throws -> Data {
        guard let ffmpeg = ffmpegPath() else { throw DecodeError.converterFailed }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("golos-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        // -vn -sn -dn: в урезанной сборке видеодекодеров нет, и просить их не надо.
        process.arguments = ["-y", "-loglevel", "error", "-i", url.path,
                             "-vn", "-sn", "-dn",
                             "-ar", String(sampleRate), "-ac", "1", "-c:a", "pcm_s16le", output.path]
        process.environment = Whisper.childEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, let data = try? Data(contentsOf: output) else {
            throw DecodeError.converterFailed
        }
        let which = ffmpeg.hasPrefix(Bundle.main.bundleURL.path) ? "свой" : "системный"
        Log.write("файл прочитан через ffmpeg (\(which)): \(url.lastPathComponent)")
        return data
    }

    private static func wrapInWav(_ pcm: Data) -> Data {
        var data = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
