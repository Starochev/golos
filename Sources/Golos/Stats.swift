import Foundation

/// Счётчик надиктованного. Живёт в `~/Documents/Golos/stats.json`.
///
/// Нужен не для отчётности, а чтобы было видно, сколько работы приложение
/// сняло с рук. Цифра «сто тысяч знаков» ничего не говорит, поэтому рядом
/// показываем то же самое в страницах и в часах у клавиатуры.
struct Stats: Codable {
    var characters: Int = 0
    var dictations: Int = 0
    var seconds: Double = 0
    var since: Date = Date()

    /// Знаков в минуту при уверенной слепой печати. Взято скромно: у кого-то
    /// быстрее, но завышать здесь нечестно.
    static let typingSpeed = 200.0
    /// Стандартная машинописная страница.
    static let pageSize = 1800.0

    static var fileURL: URL { Config.directory.appendingPathComponent("stats.json") }

    static func load() -> Stats {
        guard let data = try? Data(contentsOf: fileURL) else { return seededFromLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Stats.self, from: data)) ?? Stats()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Stats.fileURL, options: .atomic)
    }

    /// При первом запуске считаем то, что уже надиктовано: журнал хранит
    /// каждую расшифровку с начала времён, и начинать счёт с нуля значило бы
    /// выбросить настоящую историю.
    ///
    /// Длительность в журнале не записана, поэтому берём её из измеренной
    /// плотности живой речи: около десяти знаков в секунду, замерено
    /// по полусотне записей этого же приложения.
    private static func seededFromLog() -> Stats {
        guard let text = try? String(contentsOf: Log.fileURL, encoding: .utf8) else { return Stats() }

        var stats = Stats()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "  распознано: ") else { continue }
            let recognized = line[range.upperBound...]
            guard !recognized.isEmpty else { continue }
            stats.characters += recognized.count
            stats.dictations += 1
        }
        guard stats.dictations > 0 else { return Stats() }

        stats.seconds = Double(stats.characters) / 10
        stats.since = Date()
        stats.save()
        Log.write("счётчик надиктованного заведён по журналу: \(stats.characters) знаков за \(stats.dictations) диктовок")
        return stats
    }

    static func add(characters: Int, seconds: Double) {
        var stats = load()
        stats.characters += characters
        stats.dictations += 1
        stats.seconds += seconds
        stats.save()
    }

    /// Часы, которые ушли бы на набор этого руками.
    var typingHours: Double { Double(characters) / Stats.typingSpeed / 60 }

    /// Часы, потраченные на диктовку. Разница между ними и есть выигрыш.
    var speakingHours: Double { seconds / 3600 }

    var pages: Double { Double(characters) / Stats.pageSize }

    /// Сколько раз пальцы не ударили по клавише. Знак не равен нажатию,
    /// но для порядка величины годится.
    var keystrokes: Int { characters }
}
