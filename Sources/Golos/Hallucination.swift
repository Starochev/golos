import Foundation

/// Ловит выдумки распознавания.
///
/// На неудачном декодировании whisper выдаёт частую фразу из обучающих
/// данных — модель училась на субтитрах, и оттуда лезут концовки роликов:
/// «Всем пока!», «Спасибо за просмотр!», «Субтитры сделал DimaTorzok».
/// Звук при этом нормальный: тот же файл со второй попытки распознаётся верно.
enum Hallucination {
    /// Подписи из субтитровых файлов. Такое не диктуют вовсе, поэтому
    /// длина и плотность значения не имеют — это выдумка всегда.
    private static let alwaysInvented: [String] = [
        "субтитры сделал",
        "субтитры делал",
        "субтитры создавал",
        "редактор субтитров",
        "корректор а егорова",
        "dimatorzok",
        "subtitles by the amara"
    ]

    /// Ядра фраз, которые человек мог сказать и сам. Здесь решает плотность.
    ///
    /// Ищем вхождение, а не совпадение целиком: модель приделывает к ним
    /// приставки. Первая версия проверяла точное равенство и пропустила
    /// «Всем спасибо за просмотр!» — в списке было «спасибо за просмотр».
    private static let suspiciousCores: [String] = [
        "всем пока",
        "спасибо за просмотр",
        "спасибо за внимание",
        "продолжение следует",
        "продолжение в следующем видео",
        "подписывайтесь на канал",
        "ставьте лайки",
        "до новых встреч",
        "thanks for watching",
        "thank you for watching",
        "please subscribe"
    ]

    /// Короче этого фраза могла быть сказана всерьёз — не трогаем.
    private static let minimumSeconds: TimeInterval = 1.5

    /// Знаков в секунду, ниже которых текст явно не покрывает записанное.
    ///
    /// Обычная речь идёт около десяти знаков в секунду — замерено по полусотне
    /// живых записей. Выдумка даёт полтора: «Всем пока!» на семи секундах речи.
    /// Порог посередине с запасом в обе стороны.
    private static let minimumDensity: Double = 4.0

    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return stripped
    }

    /// Похоже ли, что модель выдумала это вместо реальной речи.
    ///
    /// Одного совпадения с заученной фразой мало: «Спасибо за просмотр этого
    /// макета» человек мог сказать сам. Решает плотность — сколько знаков
    /// приходится на секунду записи.
    static func looksInvented(text: String, audioDuration: TimeInterval) -> Bool {
        let normalized = normalize(text)

        if alwaysInvented.contains(where: { normalized.contains($0) }) { return true }

        guard audioDuration >= minimumSeconds else { return false }
        guard suspiciousCores.contains(where: { normalized.contains($0) }) else { return false }

        return Double(text.count) / audioDuration < minimumDensity
    }

    /// Максимальная длина хвоста, который считаем приклеенным.
    private static let maxTailLength = 30
    /// Столько слов должно остаться, чтобы отсечение имело смысл.
    /// Считаем слова, а не знаки: «Сделай панель настроек» короче любого
    /// разумного порога в символах, но это законченная мысль.
    private static let minimumRemainderWords = 3

    /// Срезает заученную фразу, приклеенную в конец правильного текста.
    ///
    /// Второй способ, которым лезут субтитры: основной текст распознан верно,
    /// а в хвост добавляется концовка ролика. Общая плотность при этом
    /// нормальная, и проверка по всему тексту такое не ловит.
    ///
    /// Режем только короткое последнее предложение и только если до него
    /// осталось достаточно текста: «Спасибо за просмотр этого макета»
    /// целиком не трогаем.
    static func strippingTrailingInvention(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while true {
            guard let cut = lastSentenceStart(in: result) else { return result }
            let tail = String(result[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let head = String(result[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)

            let headWords = head.split(whereSeparator: { $0.isWhitespace }).count
            guard tail.count <= maxTailLength, headWords >= minimumRemainderWords else { return result }

            let normalized = normalize(tail)
            let stock = alwaysInvented.contains { normalized.contains($0) }
                || suspiciousCores.contains { normalized.contains($0) }
            guard stock else { return result }

            Log.write("срезал приклеенное в конец: «\(tail)»")
            result = head
        }
    }

    /// Позиция, с которой начинается последнее предложение.
    private static func lastSentenceStart(in text: String) -> String.Index? {
        let enders = CharacterSet(charactersIn: ".!?…")
        // Точку в конце самого текста пропускаем — ищем разделитель до неё.
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous].unicodeScalars.allSatisfy({ enders.contains($0) }) == false {
                break
            }
            index = previous
        }
        guard index > text.startIndex else { return nil }

        var search = index
        while search > text.startIndex {
            let previous = text.index(before: search)
            if text[previous].unicodeScalars.allSatisfy({ enders.contains($0) }) {
                return search
            }
            search = previous
        }
        return nil
    }
}
