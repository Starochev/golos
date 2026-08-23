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

    /// Заученные концовки. Проверяются только как хвост: «Всем привет»
    /// в начале речи законно, а после двадцати секунд диктовки — уже нет.
    private static let trailingPhrases: [String] = [
        "всем пока",
        "всем привет",
        "всем спасибо за просмотр",
        "спасибо за просмотр",
        "спасибо за внимание",
        "продолжение следует",
        "подписывайтесь на канал",
        "ставьте лайки",
        "до новых встреч",
        "субтитры сделал dimatorzok",
        "субтитры сделал",
        "редактор субтитров",
        "thanks for watching",
        "please subscribe"
    ]

    /// Столько слов должно остаться, чтобы отсечение имело смысл.
    private static let minimumRemainderWords = 3
    /// Дальше по словам вглубь хвост не ищем.
    private static let maxTailWords = 6

    /// Срезает заученную фразу, приклеенную в конец правильного текста.
    ///
    /// Второй способ, которым лезут субтитры: основной текст распознан верно,
    /// а в хвост добавляется концовка ролика. Плотность всего текста при этом
    /// нормальная, и проверка по нему такое не видит.
    ///
    /// Ищем по словам, а не по предложениям: разделителя перед выдумкой может
    /// не быть вовсе — «Как-то можно сделать, чтобы Спасибо за просмотр!».
    static func strippingTrailingInvention(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        while true {
            var cut = 0
            for tailCount in 1...maxTailWords where words.count - tailCount >= minimumRemainderWords {
                let tail = words.suffix(tailCount).joined(separator: " ")
                if trailingPhrases.contains(normalize(tail)) { cut = tailCount }
            }
            guard cut > 0 else { break }

            let removed = words.suffix(cut).joined(separator: " ")
            Log.write("срезал приклеенное в конец: «\(removed)»")
            words.removeLast(cut)
        }

        return words.joined(separator: " ")
    }
}
