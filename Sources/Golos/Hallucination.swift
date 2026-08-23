import Foundation

/// Ловит выдумки распознавания.
///
/// На неудачном декодировании whisper выдаёт частую фразу из обучающих
/// данных — модель училась на субтитрах, и оттуда лезут концовки роликов:
/// «Всем пока!», «Спасибо за просмотр!», «Субтитры сделал DimaTorzok».
/// Звук при этом нормальный: тот же файл со второй попытки распознаётся верно.
enum Hallucination {
    /// Фразы в нормализованном виде: без регистра, знаков и лишних пробелов.
    private static let stockPhrases: Set<String> = [
        "всем пока",
        "спасибо за просмотр",
        "спасибо за внимание",
        "продолжение следует",
        "субтитры сделал dimatorzok",
        "субтитры делал dimatorzok",
        "редактор субтитров а синецкая",
        "корректор а егорова",
        "подписывайтесь на канал",
        "ставьте лайки и подписывайтесь",
        "до новых встреч",
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
        "subtitles by the amaraorg community",
        "продолжение в следующем видео"
    ]

    /// Короче этого фраза могла быть сказана всерьёз — не трогаем.
    private static let suspiciousBelowSeconds: TimeInterval = 1.5

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
    /// Длительность важна: «Всем пока» на секундной записи человек мог
    /// сказать сам, а на семи секундах речи — уже нет.
    static func looksInvented(text: String, audioDuration: TimeInterval) -> Bool {
        guard audioDuration >= suspiciousBelowSeconds else { return false }
        return stockPhrases.contains(normalize(text))
    }
}
