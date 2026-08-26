import Foundation

/// Считает слова-паразиты в готовой расшифровке.
///
/// Смысл не в отчёте, а в том, чтобы показать их сразу после диктовки, пока
/// человек ещё помнит, что говорил. Внимание в момент произнесения меняет
/// привычку, сводка через неделю только сообщает о ней.
enum Speech {
    /// Список по умолчанию. Правится в конфиге: у каждого свои слова,
    /// и чужой набор тут так же бесполезен, как чужой словарь терминов.
    static let defaultFillers = [
        "допустим", "то есть", "как бы", "типа", "короче", "в общем",
        "в принципе", "по факту", "на самом деле", "условно", "реально",
        "собственно", "соответственно", "это самое", "так сказать",
    ]

    /// Слово и сколько раз оно прозвучало, частые сверху.
    static func count(_ text: String, words: [String]) -> [(word: String, times: Int)] {
        var found: [(String, Int)] = []
        for word in words {
            let times = occurrences(of: word, in: text)
            if times > 0 { found.append((word, times)) }
        }
        return found.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .map { (word: $0.0, times: $0.1) }
    }

    /// Ищем слово целиком: иначе «ну» поймается внутри «нужно».
    private static func occurrences(of word: String, in text: String) -> Int {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "(?<![А-Яа-яЁёA-Za-z])\(escaped)(?![А-Яа-яЁёA-Za-z])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Короткая строчка для окошка: «допустим ×3, типа ×1».
    /// Показываем не больше трёх слов, иначе это уже не подсказка, а отчёт.
    static func hint(for text: String, words: [String]) -> String? {
        let found = count(text, words: words)
        guard !found.isEmpty else { return nil }
        return found.prefix(3).map { "\($0.word) ×\($0.times)" }.joined(separator: ", ")
    }
}
