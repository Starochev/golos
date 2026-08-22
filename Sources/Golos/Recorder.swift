import AVFoundation
import Foundation

/// Пишет микрофон в моно 16 кГц — ровно то, что ест whisper.
/// Железо обычно отдаёт 48 кГц стерео, поэтому конвертация идёт на лету.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRunning = false

    /// Формат, в котором копим сэмплы.
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000,
                                       channels: 1,
                                       interleaved: false)!

    enum RecorderError: LocalizedError {
        case noConverter
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .noConverter: return "Не удалось создать конвертер аудио"
            case .engineFailed(let m): return "Аудиодвижок не запустился: \(m)"
            }
        }
    }

    func start() throws {
        guard !isRunning else { return }

        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.noConverter
        }
        converter = conv

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, from: inputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        isRunning = true
    }

    /// Останавливает запись и отдаёт готовый WAV. nil — если писать было нечего.
    func stop() -> Data? {
        guard isRunning else { return nil }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil

        lock.lock()
        let collected = samples
        samples.removeAll()
        lock.unlock()

        // Меньше 0.3 с — это случайное нажатие, а не речь.
        guard collected.count > 4800 else { return nil }
        return Recorder.wav(from: collected, sampleRate: 16000)
    }

    /// Длительность накопленного, в секундах. Для индикатора в меню.
    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16000.0
    }

    /// Текущая громкость 0…1 по последним сэмплам — для живой волны.
    ///
    /// Шкала логарифмическая: линейная даёт почти плоскую линию, потому что
    /// речь по амплитуде занимает крошечную часть диапазона, а ухо и глаз
    /// воспринимают громкость в децибелах.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        let tail = samples.suffix(1600)
        guard !tail.isEmpty else { return 0 }
        let rms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
        guard rms > 1e-6 else { return 0 }

        // −60 дБ — комнатная тишина, −10 дБ — громкая речь вплотную.
        // Диапазон шире, чем кажется нужным: иначе обычная речь упирается
        // в потолок и волна превращается в сплошную стену.
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 50))
    }

    private func append(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat) {
        guard let conv = converter else { return }

        let ratio = target.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }

        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }

    /// Собирает 16-битный PCM WAV вручную — тащить ради этого AVAudioFile незачем.
    static func wav(from samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2

        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)                                  // размер fmt-блока
        append16(1)                                   // PCM
        append16(1)                                   // моно
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))              // байт в секунду
        append16(2)                                   // выравнивание блока
        append16(16)                                  // бит на сэмпл
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(byteCount))

        data.reserveCapacity(data.count + byteCount)
        for s in samples {
            let clamped = max(-1, min(1, s))
            append16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}
