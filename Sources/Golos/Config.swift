import Foundation

/// Настройки лежат в ~/Documents/Golos/config.json и перечитываются при каждой
/// записи — правку словаря видно сразу, перезапуск не нужен.
struct Config: Codable {
    /// Язык распознавания. "ru" — русский с вкраплениями латиницы, "auto" — определять.
    var language: String = "ru"
    /// Путь к ggml-модели whisper.
    var modelPath: String = ""
    /// Путь к модели Silero VAD. Пусто — VAD выключен.
    var vadModelPath: String = ""
    /// Слова, которые whisper должен писать латиницей, а не транслитом.
    /// Уходят в initial prompt и смещают декодер в нужную сторону.
    var vocabulary: [String] = []
    /// Замены по готовому тексту: whisper всё равно иногда мажет по редким именам.
    var replacements: [Replacement] = []
    /// "paste" — положить в буфер и нажать Cmd+V, "type" — набрать посимвольно,
    /// "clipboard" — только положить в буфер, вставит пользователь.
    var insertMode: String = "paste"
    /// Порт локального whisper-server.
    var port: Int = 8178
    /// Сколько потоков отдать whisper.
    var threads: Int = 8
    /// Звуковые сигналы старта и конца записи.
    var sounds: Bool = true
    /// Какой набор тонов играть: см. Sounds.themes.
    var soundTheme: String = Sounds.defaultThemeID
    /// Показывать ли окошко с живой волной во время записи.
    var showHUD: Bool = true
    /// Клавиша записи: идентификатор из HotkeyOption.all.
    var hotkey: String = "rightOption"
    /// Цвет волны: идентификатор темы из WaveTheme.all либо "custom".
    var waveTheme: String = "red"
    /// Свой цвет в виде "#RRGGBB" — используется, когда waveTheme = "custom".
    var customWaveColor: String = "#7CE0FF"
    /// Куда класть расшифровки файлов. Пусто — рядом с исходником.
    var fileOutputFolder: String = ""
    /// Оставлять ли рядом с расшифровкой переконвертированный wav.
    var keepConvertedAudio: Bool = false
    /// Хранить ли wav и расшифровку в ~/Documents/Golos/history.
    var keepHistory: Bool = true
    /// Через сколько часов удалять записи. 0 — не удалять никогда.
    /// По умолчанию час: история нужна, чтобы разобрать свежую ошибку
    /// распознавания, а не копить гигабайты голоса на диске.
    var historyRetentionHours: Int = 1

    struct Replacement: Codable, Identifiable {
        /// Собственный идентификатор, а не поле from: в списке настроек from
        /// редактируется, и если опознавать строки по нему, то две пустые
        /// строки станут неразличимы, а ввод текста будет ронять фокус.
        var id: UUID = UUID()
        var from: String
        var to: String
        /// true — сопоставлять без учёта регистра.
        var ignoreCase: Bool = true

        init(from: String, to: String, ignoreCase: Bool = true) {
            self.from = from
            self.to = to
            self.ignoreCase = ignoreCase
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
            to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
            ignoreCase = try c.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? true
        }
    }

    init() {}

    /// Разбираем конфиг по одному полю с запасным значением.
    ///
    /// Синтезированный Codable требует в файле все ключи разом: стоит добавить
    /// в новой версии одно поле — и конфиг от прошлой версии перестаёт читаться.
    /// Раньше это означало молчаливую потерю словаря при обновлении.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()

        language = try c.decodeIfPresent(String.self, forKey: .language) ?? fallback.language
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? fallback.modelPath
        vadModelPath = try c.decodeIfPresent(String.self, forKey: .vadModelPath) ?? fallback.vadModelPath
        // Словарь показывается списком, где строка сама себе идентификатор,
        // поэтому дубли из правленого руками файла надо убрать сразу.
        let rawVocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? fallback.vocabulary
        var seen = Set<String>()
        vocabulary = rawVocabulary.filter { seen.insert($0.lowercased()).inserted }
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? fallback.replacements
        insertMode = try c.decodeIfPresent(String.self, forKey: .insertMode) ?? fallback.insertMode
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? fallback.port
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? fallback.threads
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? fallback.sounds
        soundTheme = try c.decodeIfPresent(String.self, forKey: .soundTheme) ?? fallback.soundTheme
        showHUD = try c.decodeIfPresent(Bool.self, forKey: .showHUD) ?? fallback.showHUD
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? fallback.hotkey
        waveTheme = try c.decodeIfPresent(String.self, forKey: .waveTheme) ?? fallback.waveTheme
        customWaveColor = try c.decodeIfPresent(String.self, forKey: .customWaveColor)
            ?? fallback.customWaveColor
        fileOutputFolder = try c.decodeIfPresent(String.self, forKey: .fileOutputFolder)
            ?? fallback.fileOutputFolder
        keepConvertedAudio = try c.decodeIfPresent(Bool.self, forKey: .keepConvertedAudio)
            ?? fallback.keepConvertedAudio
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? fallback.keepHistory
        historyRetentionHours = try c.decodeIfPresent(Int.self, forKey: .historyRetentionHours)
            ?? fallback.historyRetentionHours
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Golos")
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Читает конфиг, а если его нет — создаёт с разумными значениями.
    static func load() -> Config {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: fileURL) {
            do {
                var cfg = try JSONDecoder().decode(Config.self, from: data)
                if cfg.modelPath.isEmpty { cfg.modelPath = defaultModelPath() ?? "" }
                if cfg.vadModelPath.isEmpty { cfg.vadModelPath = defaultVadPath() ?? "" }
                return cfg
            } catch {
                // Файл есть, но разобрать не вышло — не затираем его молча:
                // там мог быть словарь, который человек набирал руками.
                let broken = directory.appendingPathComponent("config.broken.json")
                try? fm.removeItem(at: broken)
                try? fm.copyItem(at: fileURL, to: broken)
                Log.write("конфиг не разобрался, копия сохранена в config.broken.json: \(error)")
            }
        }

        var cfg = Config()
        cfg.modelPath = defaultModelPath() ?? ""
        cfg.vadModelPath = defaultVadPath() ?? ""
        cfg.vocabulary = [
            "Claude", "Cursor", "Next.js", "React", "TypeScript", "Prisma",
            "Postgres", "Docker", "Vercel", "GitHub", "pull request", "merge",
            "commit", "deploy", "environment variables", "endpoint", "API",
            "frontend", "backend", "фича", "баг", "билд", "релиз"
        ]
        cfg.replacements = [
            .init(from: "верселе", to: "Vercel"),
            .init(from: "клод", to: "Claude")
        ]
        cfg.save()
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        // Атомарно: обрыв записи не должен оставить обрезанный конфиг.
        try? enc.encode(self).write(to: Config.fileURL, options: .atomic)
    }

    /// Строка, которую whisper получает как initial prompt.
    ///
    /// У whisper initial prompt ограничен 224 токенами — всё сверх этого
    /// отбрасывается молча, и хвост словаря просто перестаёт работать.
    /// Режем сами и пишем об этом в журнал, чтобы обрезка не была сюрпризом.
    var promptString: String {
        guard !vocabulary.isEmpty else { return "" }

        var kept: [String] = []
        var length = 0
        var dropped = 0
        for term in vocabulary {
            let addition = term.count + 2
            if length + addition > Config.promptCharacterBudget {
                dropped += 1
                continue
            }
            kept.append(term)
            length += addition
        }
        if dropped > 0 {
            Log.write("словарь длиннее лимита whisper: \(dropped) терминов не вошло")
        }
        return kept.joined(separator: ", ") + "."
    }

    /// 224 токена — это примерно 700 символов латиницы вперемешку с кириллицей.
    /// Берём с запасом: кириллица дороже в токенах.
    static let promptCharacterBudget = 600

    /// Применяет пользовательские замены к распознанному тексту.
    func applyReplacements(to text: String) -> String {
        var result = text
        for r in replacements where !r.from.isEmpty {
            let options: String.CompareOptions = r.ignoreCase ? [.caseInsensitive] : []
            result = result.replacingOccurrences(of: r.from, with: r.to, options: options)
        }
        return result
    }

    /// Ищем уже скачанную модель. Порядок — от лучшей к худшей, чтобы после
    /// удаления конфига приложение подобрало самое качественное из имеющегося.
    private static func defaultModelPath() -> String? {
        let fm = FileManager.default
        var candidates = ModelCatalog.all.map { ModelCatalog.localURL(for: $0) }
        // Модели могли остаться от других приложений — незачем качать заново.
        let home = fm.homeDirectoryForCurrentUser
        candidates += [
            home.appendingPathComponent("Library/Application Support/github.com.thewh1teagle.vibe/ggml-large-v3.bin"),
            home.appendingPathComponent("Library/Application Support/github.com.thewh1teagle.vibe/ggml-large-v3-turbo.bin")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }?.path
    }

    private static func defaultVadPath() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            ModelCatalog.directory.appendingPathComponent(ModelCatalog.vadFileName),
            home.appendingPathComponent("Library/Application Support/github.com.thewh1teagle.vibe/ggml-silero-v6.2.0.bin")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }?.path
    }
}
