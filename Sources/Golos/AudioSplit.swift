import Foundation

/// Режет длинную запись на куски короче окна распознавания.
///
/// Whisper разбирает звук окнами по 30 секунд. На стыке окон декодер срывается:
/// замерено, что запись на 47 секунд со словарём давала 128 знаков вместо 830.
/// Без словаря та же запись распознавалась целиком, но словарь нужнее — он
/// держит англицизмы латиницей. Поэтому режем сами, до границы окна.
enum AudioSplit {
    private static let sampleRate = 16000
    private static let headerBytes = 44

    /// Длиннее этого — режем. С запасом до тридцати секунд.
    static let maxChunkSeconds: Double = 22
    /// Раньше этого рез не ищем, иначе куски выйдут рваные.
    private static let minChunkSeconds: Double = 14

    static func chunks(wav: Data) -> [Data] {
        let samples = decode(wav)
        let maxLength = Int(maxChunkSeconds * Double(sampleRate))
        guard samples.count > maxLength else { return [wav] }

        var parts: [Data] = []
        var start = 0
        while start < samples.count {
            let remaining = samples.count - start
            if remaining <= maxLength {
                parts.append(encode(Array(samples[start...])))
                break
            }
            let cut = start + quietestCut(in: samples, from: start)
            parts.append(encode(Array(samples[start..<cut])))
            start = cut
        }
        return parts
    }

    /// Ищет самое тихое место в допустимом окне — чтобы рез не пришёлся
    /// на середину слова.
    private static func quietestCut(in samples: [Float], from start: Int) -> Int {
        let window = sampleRate / 10                 // 100 мс
        let earliest = Int(minChunkSeconds * Double(sampleRate))
        let latest = Int(maxChunkSeconds * Double(sampleRate))

        var bestOffset = latest
        var bestEnergy = Float.greatestFiniteMagnitude

        var offset = earliest
        while offset + window <= latest, start + offset + window <= samples.count {
            var sum: Float = 0
            for i in (start + offset)..<(start + offset + window) {
                sum += samples[i] * samples[i]
            }
            if sum < bestEnergy {
                bestEnergy = sum
                bestOffset = offset + window / 2
            }
            offset += window
        }
        return bestOffset
    }

    private static func decode(_ wav: Data) -> [Float] {
        guard wav.count > headerBytes else { return [] }
        let body = wav.advanced(by: headerBytes)
        var samples = [Float]()
        samples.reserveCapacity(body.count / 2)
        body.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for value in ints { samples.append(Float(Int16(littleEndian: value)) / 32768) }
        }
        return samples
    }

    private static func encode(_ samples: [Float]) -> Data {
        Recorder.wav(from: samples, sampleRate: sampleRate)
    }
}
