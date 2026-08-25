import AppKit
import Foundation

/// Слово, в котором модель сомневалась. Кандидат в словарь.
struct Candidate: Codable, Identifiable, Equatable {
    /// Как модель его написала: «бэкап», хотя сказано было backup.
    var word: String
    /// Сколько раз спотыкалась. Спрашиваем не с первого раза.
    var hits: Int
    /// Худшая уверенность из всех встреч, от 0 до 1.
    var worst: Double
    /// Фраза, в которой встретилось. Без неё через день не вспомнить,
    /// что вообще было сказано.
    var context: String
    var firstSeen: Date
    var lastSeen: Date

    var id: String { word.lowercased() }

    /// Кусочек звука, в котором слово прозвучало. Хранится отдельным файлом:
    /// история живёт час, а кандидат неделю, и к моменту разбора слушать
    /// было бы уже нечего.
    var audioURL: URL {
        Candidates.audioDirectory.appendingPathComponent("\(Candidates.key(word)).wav")
    }

    var hasAudio: Bool { FileManager.default.fileExists(atPath: audioURL.path) }
}

/// Копилка сомнительных слов.
///
/// Главная трудность в том, чтобы не показывать всё подряд. Слов с уверенностью
/// ниже 0,8 набегает около 630 в час диктовки, и почти все это обычные русские
/// слова, сказанные быстро: «сейчас», «практически», «фотографий».
///
/// Отсекает их системный словарь русского языка. Замер на 91 собранном слове:
/// незнакомыми словарю оказались семь, и это ровно то, что нужно —
/// «деплой», «ретаргет», «Type-C», «рекомендацион». Остальные 84 отсеялись.
/// Обратная сторона: англицизм, уже вошедший в словарь, сюда не попадёт.
/// «Бэкап» словарь знает, и спрашивать о нём не будут.
@MainActor
final class Candidates: ObservableObject {
    /// Ниже этого уверенность считается сомнительной.
    static let threshold = 0.8
    /// Сколько раз слово должно споткнуться, прежде чем о нём спросят.
    /// Хватает одного: словарь русского языка отсеивает столько, что
    /// требовать повтора уже незачем.
    static let minimumHits = 1
    /// Сколько живёт кандидат, о котором не приняли решения.
    static let lifetimeDays = 7.0
    /// Сколько молчит слово, по которому решение принято. Не навсегда:
    /// нажать можно и по ошибке, а вечный список никто потом не разбирает.
    static let settledLifetimeDays = 90.0

    @Published private(set) var pending: [Candidate] = []

    private var seen: [String: Candidate] = [:]
    /// Слова, по которым решение уже принято: ушли в словарь или отмечены
    /// как верно распознанные. О них не спрашивают повторно.
    private var settled: [String: Date] = [:]

    private static var fileURL: URL {
        Config.directory.appendingPathComponent("candidates.json")
    }

    nonisolated static var audioDirectory: URL {
        Config.directory.appendingPathComponent("candidates-audio")
    }

    init() { load() }

    // MARK: - Сбор

    /// Служебные слова: они спотыкаются постоянно просто потому, что
    /// произносятся быстро и невнятно, а в словаре им делать нечего.
    private static let stopWords: Set<String> = [
        "это", "если", "можно", "надо", "нужно", "просто", "который", "которая",
        "которую", "которые", "потому", "поэтому", "тогда", "сейчас", "здесь",
        "туда", "сюда", "может", "будет", "было", "были", "есть", "чтобы",
        "когда", "пока", "уже", "ещё", "еще", "там", "тут", "все", "всё",
        "самый", "самое", "самой", "себя", "него", "неё", "нее", "них",
        "сказал", "сказала", "давай", "давайте", "допустим", "предположим",
        "вообще", "конечно", "наверное", "например", "также", "такой", "такое"
    ]

    /// Слово короче этого в словарь не просится: предлоги, союзы, обрывки.
    private static let minimumLength = 4

    /// `clip` отдаёт кусочек звука по границам отрезка. Вызывается только для
    /// слов, которые действительно попали в копилку: резать всё подряд незачем.
    func record(_ words: [Whisper.WordConfidence],
                clip: ((Double, Double) -> Data?)? = nil) {
        let now = Date()
        var changed = false

        for item in words {
            guard item.probability < Candidates.threshold else { continue }
            let key = Candidates.key(item.word)
            guard key.count >= Candidates.minimumLength,
                  !Candidates.stopWords.contains(key),
                  key.contains(where: { $0.isLetter }),
                  settled[key] == nil,
                  !RussianDictionary.shared.knows(key)
            else { continue }

            var freshAudio = false
            if var existing = seen[key] {
                if item.probability < existing.worst {
                    // Написание берём от самой неуверенной встречи: там ошибка виднее.
                    existing.worst = item.probability
                    existing.word = item.word
                    freshAudio = true
                }
                existing.hits += 1
                existing.context = item.context
                existing.lastSeen = now
                seen[key] = existing
            } else {
                seen[key] = Candidate(word: item.word, hits: 1, worst: item.probability,
                                      context: item.context, firstSeen: now, lastSeen: now)
                freshAudio = true
            }
            changed = true

            // Звук пишем от самой неуверенной встречи: слушать надо худший случай.
            if freshAudio, let clip, let audio = clip(item.start, item.end), let candidate = seen[key] {
                try? FileManager.default.createDirectory(at: Candidates.audioDirectory,
                                                         withIntermediateDirectories: true)
                try? audio.write(to: candidate.audioURL, options: .atomic)
            }
        }

        if changed { purgeAndSave() }
    }

    // MARK: - Ответы

    /// «Всё верно»: слово распознано правильно, вопрос закрыт.
    func markCorrect(_ candidate: Candidate) {
        try? FileManager.default.removeItem(at: candidate.audioURL)
        settled[candidate.id] = Date()
        seen[candidate.id] = nil
        purgeAndSave()
    }

    /// «Скрыть»: решения нет. Слово уходит из списка, но вернётся,
    /// когда распознавание споткнётся о него снова.
    func dismiss(_ candidate: Candidate) {
        try? FileManager.default.removeItem(at: candidate.audioURL)
        seen[candidate.id] = nil
        purgeAndSave()
    }

    /// Слово ушло в словарь. Спрашивать о нём больше не надо: даже если
    /// модель по-прежнему в нём сомневается, решение уже принято.
    func accepted(_ candidate: Candidate) {
        try? FileManager.default.removeItem(at: candidate.audioURL)
        settled[candidate.id] = Date()
        seen[candidate.id] = nil
        purgeAndSave()
    }

    func forgetAll() {
        for (_, candidate) in seen { try? FileManager.default.removeItem(at: candidate.audioURL) }
        seen.removeAll()
        purgeAndSave()
    }

    // MARK: - Хранение

    private struct Storage: Codable {
        var seen: [String: Candidate]
        /// Имя ключа в файле осталось прежним, чтобы уже собранное не потерялось.
        var ignored: [String: Date]
    }

    private func load() {
        guard let data = try? Data(contentsOf: Candidates.fileURL),
              let storage = try? JSONDecoder.golos.decode(Storage.self, from: data)
        else { refreshPending(); return }
        seen = storage.seen
        settled = storage.ignored
        purgeAndSave()
    }

    private func purgeAndSave() {
        let now = Date()
        let expired = seen.filter { now.timeIntervalSince($0.value.lastSeen) >= Candidates.lifetimeDays * 86400 }
        seen = seen.filter { now.timeIntervalSince($0.value.lastSeen) < Candidates.lifetimeDays * 86400 }
        // Звук за ушедшими кандидатами не тянем: он никому не нужен.
        for (_, candidate) in expired { try? FileManager.default.removeItem(at: candidate.audioURL) }
        settled = settled.filter { now.timeIntervalSince($0.value) < Candidates.settledLifetimeDays * 86400 }
        refreshPending()

        let storage = Storage(seen: seen, ignored: settled)
        if let data = try? JSONEncoder.golos.encode(storage) {
            try? FileManager.default.createDirectory(at: Config.directory,
                                                     withIntermediateDirectories: true)
            try? data.write(to: Candidates.fileURL, options: .atomic)
        }
    }

    private func refreshPending() {
        pending = seen.values
            .filter { $0.hits >= Candidates.minimumHits }
            .sorted { $0.worst < $1.worst }
    }

    /// Ключ для сравнения: регистр и пунктуация не важны.
    nonisolated static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}

private extension JSONDecoder {
    static var golos: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var golos: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}


/// Системный словарь русского языка — им отсеиваются обычные слова.
///
/// Работает как решето: слово, которое словарь знает, кандидатом не будет.
/// Если словаря в системе нет, решето отключается целиком — лучше показать
/// лишнее, чем молча не показать ничего.
@MainActor
final class RussianDictionary {
    static let shared = RussianDictionary()

    private let checker = NSSpellChecker.shared
    private let available: Bool

    private init() {
        // Проверка, что словарь действительно на месте: без него checkSpelling
        // объявляет незнакомым вообще всё, и список забьётся мусором.
        let control = ["привет", "работа", "сегодня"]
        available = control.allSatisfy { word in
            NSSpellChecker.shared.checkSpelling(
                of: word, startingAt: 0, language: "ru",
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
        if !available { Log.write("словаря русского языка нет, отбор кандидатов по одной уверенности") }
    }

    func knows(_ word: String) -> Bool {
        guard available else { return false }
        return checker.checkSpelling(of: word, startingAt: 0, language: "ru",
                                     wrap: false, inSpellDocumentWithTag: 0,
                                     wordCount: nil).location == NSNotFound
    }
}
