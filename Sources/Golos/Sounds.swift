import AVFoundation
import Foundation

/// Сигналы начала и конца записи.
///
/// Тоны синтезируются в коде, а не лежат файлами: их проще подобрать на слух
/// и не надо тащить ресурсы в бандл. Системные Tink и Pop звучат как отказ
/// ввода — для действия, которое повторяется десятки раз в день, это плохо.
enum Sounds {
    enum Moment { case start, stop }

    struct Theme {
        let id: String
        let title: String
        let note: String
        let start: Tone
        let stop: Tone
    }

    struct Tone {
        var frequency: Double
        var duration: Double = 0.11
        var amplitude: Double = 0.22
        /// Доля второй гармоники: немного делает звук «телесным», много — резким.
        var harmonic: Double = 0.18
        /// Скорость затухания. Больше — короче хвост.
        var decay: Double = 5.0
    }

    static let themes: [Theme] = [
        Theme(id: "soft",
              title: "Мягкий",
              note: "Ниже и глуше остальных, меньше привлекает внимание",
              start: Tone(frequency: 523.25, duration: 0.13, harmonic: 0.10, decay: 4.0),
              stop:  Tone(frequency: 392.00, duration: 0.13, harmonic: 0.10, decay: 4.0)),
        Theme(id: "bell",
              title: "Колокольчик",
              note: "Ясно слышно даже в шумном месте",
              start: Tone(frequency: 783.99),
              stop:  Tone(frequency: 587.33)),
        Theme(id: "quiet",
              title: "Тихий",
              note: "Совсем короткий отклик, не мешает в тишине",
              start: Tone(frequency: 659.25, duration: 0.07, amplitude: 0.15, harmonic: 0.05, decay: 7.0),
              stop:  Tone(frequency: 493.88, duration: 0.07, amplitude: 0.15, harmonic: 0.05, decay: 7.0))
    ]

    static let defaultThemeID = "soft"

    static func theme(id: String) -> Theme {
        themes.first { $0.id == id } ?? themes[0]
    }

    static func play(_ moment: Moment, themeID: String) {
        let theme = theme(id: themeID)
        let tone = moment == .start ? theme.start : theme.stop
        play(tone: tone, key: "\(theme.id).\(moment == .start ? "start" : "stop")")
    }

    // MARK: - Синтез

    private static var cache: [String: Data] = [:]
    private static var players: [AVAudioPlayer] = []
    private static let lock = NSLock()

    private static func play(tone: Tone, key: String) {
        lock.lock()
        let data: Data
        if let cached = cache[key] {
            data = cached
        } else {
            data = wav(for: tone)
            cache[key] = data
        }
        lock.unlock()

        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.prepareToPlay()
        player.play()

        // Плеер должен дожить до конца воспроизведения — держим ссылку.
        lock.lock()
        players.append(player)
        players.removeAll { !$0.isPlaying && $0.currentTime > 0 }
        lock.unlock()
    }

    private static func wav(for tone: Tone) -> Data {
        let sampleRate = 44100.0
        let count = Int(sampleRate * tone.duration)
        // Плавный вход убирает щелчок в начале.
        let attack = 0.006

        var samples: [Int16] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = min(1.0, t / attack) * exp(-tone.decay * t / tone.duration)
            var value = sin(2 * .pi * tone.frequency * t)
            value += tone.harmonic * sin(4 * .pi * tone.frequency * t)
            let scaled = max(-1, min(1, value * envelope * tone.amplitude))
            samples.append(Int16(scaled * 32767))
        }
        return wavData(samples: samples, sampleRate: Int(sampleRate))
    }

    private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2

        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)                       // PCM
        append16(1)                       // моно
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(byteCount))
        for s in samples { append16(UInt16(bitPattern: s)) }
        return data
    }
}
