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
    private var configurationObserver: NSObjectProtocol?

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

    /// Микрофон из настроек. Пусто — тот, что выбран в системе.
    var preferredDevice = ""

    func start() throws {
        guard !isRunning else { return }

        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        applyPreferredDevice(to: input)
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
        watchConfigurationChanges()
    }

    /// Поднимает движок обратно, если система его остановила.
    ///
    /// Стоит начаться воспроизведению или переключиться гарнитуре — macOS
    /// перенастраивает аудиоустройство и глушит движок. Захват при этом
    /// прекращается молча: запись обрывается на середине, а человек узнаёт
    /// об этом только по куску текста вместо всей фразы.
    private func watchConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    private func restartAfterConfigurationChange() {
        guard isRunning else { return }
        Log.write("аудиоустройство перенастроено, поднимаю запись заново")

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)

        // Формат мог смениться вместе с устройством — конвертер тоже.
        guard inputFormat.sampleRate > 0,
              let conv = AVAudioConverter(from: inputFormat, to: target) else {
            Log.write("после перенастройки формат не поддержан, запись прервана")
            isRunning = false
            return
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, from: inputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.write("движок не поднялся после перенастройки: \(error.localizedDescription)")
            isRunning = false
        }
    }

    /// Останавливает запись и отдаёт готовый WAV. nil — если писать было нечего.
    func stop() -> Data? {
        guard isRunning else { return nil }
        isRunning = false

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil

        lock.lock()
        let collected = samples
        samples.removeAll()
        lock.unlock()

        // Меньше 0.3 с — это случайное нажатие, а не речь.
        guard collected.count > 4800 else { return nil }

        // Совсем тихая запись — микрофон не тот, выключен или человек
        // передумал говорить. Отправлять такое нельзя: на тишине whisper
        // выдаёт выдуманную фразу из обучающих данных.
        //
        // Считаем не пик, а сколько окон содержат звук: пик бесполезен,
        // потому что приложение само играет сигнал в начале записи и
        // микрофон его слышит. По той же причине начало пропускаем.
        guard Recorder.hasSpeech(collected) else {
            // Пишем замер, а не просто отказ: иначе не отличить «человек
            // молчал» от «микрофон не тот и не слышит вовсе».
            let seconds = Double(collected.count) / target.sampleRate
            let peak = collected.map(abs).max() ?? 0
            let loudness = Recorder.loudWindows(collected)
            Log.write(String(format: "в записи нет речи, не отправляю: %.1f с, пик %.4f, громких окон %d, микрофон «%@»",
                             seconds, peak, loudness, activeInputName()))
            return nil
        }

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

    /// Есть ли в записи хоть треть секунды звука.
    ///
    /// Окно 100 мс, порог примерно −42 дБ: комнатная тишина держится ниже
    /// −55 дБ, речь идёт в районе −30 дБ, так что порог лежит с запасом
    /// между ними. Короткий сигнал старта даёт одно окно и не проходит.
    /// Ставит выбранный микрофон на вход движка. Делать это надо до чтения
    /// формата: иначе конвертер настроится на прежнее устройство.
    private func applyPreferredDevice(to input: AVAudioInputNode) {
        guard !preferredDevice.isEmpty else { return }
        guard let id = AudioDevices.find(named: preferredDevice) else {
            Log.write("микрофон «\(preferredDevice)» не найден, беру системный")
            return
        }
        guard let unit = input.audioUnit else { return }
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            Log.write("микрофон «\(preferredDevice)» не встал: код \(status)")
        }
    }

    /// Имя микрофона, который сейчас слушаем.
    func activeInputName() -> String {
        preferredDevice.isEmpty ? AudioDevices.defaultInputName() : preferredDevice
    }

    /// Имя микрофона, который система отдаёт по умолчанию. Нужно в журнале:
    /// «звук не пишется» чаще всего означает, что слушается не то устройство.
    /// Сколько стомиллисекундных окон содержат звук. Для диагностики.
    static func loudWindows(_ samples: [Float]) -> Int {
        let window = 1600
        let skipStart = 3200
        let threshold: Float = 0.008
        guard samples.count > skipStart + window else { return 0 }
        var loud = 0
        var index = skipStart
        while index + window <= samples.count {
            var sum: Float = 0
            for i in index..<(index + window) { sum += samples[i] * samples[i] }
            if sqrt(sum / Float(window)) > threshold { loud += 1 }
            index += window
        }
        return loud
    }

    static func hasSpeech(_ samples: [Float]) -> Bool {
        let window = 1600                       // 100 мс при 16 кГц
        let skipStart = 3200                    // 200 мс на собственный сигнал
        let threshold: Float = 0.008
        let needed = 3

        guard samples.count > skipStart + window else { return false }

        var loud = 0
        var index = skipStart
        while index + window <= samples.count {
            var sum: Float = 0
            for i in index..<(index + window) { sum += samples[i] * samples[i] }
            if sqrt(sum / Float(window)) > threshold {
                loud += 1
                if loud >= needed { return true }
            }
            index += window
        }
        return false
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
