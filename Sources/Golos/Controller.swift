import AppKit
import AVFoundation

/// Связывает хоткей, запись, распознавание и вставку.
@MainActor
final class Controller {
    enum State {
        case starting
        case idle
        case recording
        case transcribing
        case needsModel
        case failed(String)
    }

    private(set) var state: State = .starting {
        didSet {
            onStateChange?(state)
            if case .failed(let message) = state { Log.write("ошибка: \(message)") }
        }
    }
    var onStateChange: ((State) -> Void)?
    private(set) var lastText: String = ""

    private var config = Config.load()
    private let recorder = Recorder()
    private let hud = RecorderHUD()
    private let hotkey = Hotkey()
    private var whisper: Whisper

    /// Номер текущей записи. Распознавание идёт асинхронно, и к моменту
    /// ответа пользователь мог начать следующую диктовку — тогда результат
    /// старой не должен трогать ни окошко, ни состояние.
    private var recordingGeneration = 0
    /// Опрос разрешения, пока его не выдадут.
    private var permissionTimer: Timer?
    private var hotkeyAttached = false
    private var setupWindow: SetupWindow?
    private var settingsWindow: SettingsWindow?
    private var transcribeWindow: TranscribeWindow?
    /// Файлы, пришедшие до готовности движка.
    private var pendingFiles: [URL] = []
    private lazy var settingsStore = SettingsStore()
    /// Слова, в которых модель сомневалась. Заполняется фоном после диктовки.
    private lazy var candidates = Candidates()
    /// Чем отдать текущую запись: текстом в поле или звуком в буфер.
    /// Хозяин здесь, а не в окошке: переключать можно и с выключенным окошком,
    /// тогда режим видно по значку в строке меню.
    private(set) var captureMode: RecorderHUD.Mode = .text

    /// Живой разбор речи: докуда уже разобрано, что нашлось и не занят ли
    /// сервер прошлым куском.
    private var liveTimer: Timer?
    private var liveCursor: Double = 0
    private var liveFillers: [String: Int] = [:]
    private var liveBusy = false
    /// Кусок, который отдаём на разбор. Меньше четырёх секунд смысла нет:
    /// на коротких обрывках распознавание начинает выдумывать.
    private static let liveSegment: Double = 4
    /// Смена языка или модели требует перезапуска движка. Гасим дребезг:
    /// пока пользователь щёлкает по списку, перезапускать нет смысла.
    private var engineReloadWork: DispatchWorkItem?

    init() {
        whisper = Whisper(config: config)
    }

    func start() {
        Log.write("запуск")
        purgeHistory()
        History.compressLeftovers()
        requestMicrophone()
        startHotkey()

        // Без модели распознавать нечем — сначала окно выбора.
        guard hasModel else {
            Log.write("модель не установлена, показываю выбор")
            state = .needsModel
            showModelPicker()
            return
        }
        bootWhisper()
    }

    private var hasModel: Bool {
        !config.modelPath.isEmpty && FileManager.default.fileExists(atPath: config.modelPath)
    }

    /// Окно настроек: словарь, замены, поведение.
    func showSettings() {
        if settingsWindow == nil {
            settingsStore.onEngineRelevantChange = { [weak self] in
                self?.scheduleEngineReload()
            }
            settingsStore.onHotkeyChange = { [weak self] in
                self?.applyHotkey()
                self?.onHotkeyChanged?()
            }
            settingsWindow = SettingsWindow(
                store: settingsStore,
                candidates: candidates,
                onOpenModelPicker: { [weak self] in self?.showModelPicker() },
                onCheckUpdates: { [weak self] in self?.onCheckUpdates?() }
            )
        }
        settingsWindow?.show()
    }

    /// Текущая громкость микрофона — для живой иконки в строке меню.
    var micLevel: Float { recorder.level }

    /// Цвет волны в строке меню. nil — рисовать шаблоном.
    var menuBarWaveColor: NSColor? { WaveTheme.menuBarColor(for: config) }

    /// Подсказку в меню обновляет AppDelegate — сюда приходит замыканием.
    var onHotkeyChanged: (() -> Void)?

    /// Текущая клавиша записи — для подсказки в меню.
    var hotkeyTitle: String { HotkeyOption.named(config.hotkey).title }

    /// Проверку обновлений держит AppDelegate — сюда приходит замыканием.
    var onCheckUpdates: (() -> Void)?

    /// Клавишу применяем сразу: перезапускать перехват ради неё не нужно.
    func applyHotkey() {
        config = Config.load()
        hotkey.setOption(HotkeyOption.named(config.hotkey))
        hotkey.setSecondOption(config.secondHotkey.isEmpty ? nil : HotkeyOption.named(config.secondHotkey))
    }

    private func scheduleEngineReload() {
        engineReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Настройки пишутся с задержкой — дожимаем на диск перед чтением.
            self.settingsStore.flush()
            self.reload()
        }
        engineReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Поставить файлы в очередь расшифровки.
    func transcribeFiles(_ urls: [URL]) {
        showFileTranscription()
        // Движок мог ещё не подняться — тогда ждём и ставим в очередь потом.
        if whisper.ready {
            transcribeWindow?.enqueue(urls)
        } else {
            pendingFiles += urls
        }
    }

    /// Окно расшифровки файлов.
    func showFileTranscription() {
        if transcribeWindow == nil {
            transcribeWindow = TranscribeWindow(
                makeTranscriber: { [weak self] in
                    guard let self, self.whisper.ready else { return nil }
                    return FileTranscriber(whisper: self.whisper)
                },
                currentConfig: { Config.load() }
            )
        }
        transcribeWindow?.show()
    }

    /// Окно выбора модели: при первом запуске и по пункту меню.
    func showModelPicker() {
        if setupWindow == nil {
            setupWindow = SetupWindow { [weak self] path in
                guard let self else { return }
                var updated = Config.load()
                updated.modelPath = path
                updated.vadModelPath = ""      // подберётся заново при загрузке
                updated.save()
                Log.write("выбрана модель: \(path)")
                self.settingsStore.reloadFromDisk()
                self.reload()
            }
        }
        setupWindow?.show()
    }

    func shutdown() {
        permissionTimer?.invalidate()
        hotkey.stop()
        whisper.stop()
    }

    // MARK: - Запуск подсистем

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    private func startHotkey() {
        if Hotkey.hasAccessibilityPermission(prompt: true) {
            Log.write("разрешение «Универсальный доступ» есть")
            attachHotkey()
            return
        }

        // Раньше здесь требовался перезапуск. Но momentом выдачи разрешения
        // система с приложением не делится, а проверка дешёвая — просто ждём.
        Log.write("нет разрешения «Универсальный доступ», жду выдачи")
        state = .failed("Нет доступа в «Универсальный доступ»")
        waitForAccessibility()
    }

    private func waitForAccessibility() {
        guard permissionTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard Hotkey.hasAccessibilityPermission(prompt: false) else { return }
            t.invalidate()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.permissionTimer = nil
                Log.write("разрешение «Универсальный доступ» выдано")
                self.attachHotkey()
                if self.whisper.ready { self.state = .idle }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func attachHotkey() {
        guard !hotkeyAttached else { return }
        hotkey.setOption(HotkeyOption.named(config.hotkey))
        let ok = hotkey.start { [weak self] event in
            self?.handle(event)
        }
        hotkey.setSecondOption(config.secondHotkey.isEmpty ? nil : HotkeyOption.named(config.secondHotkey))
        if ok {
            hotkeyAttached = true
            Log.write("горячая клавиша слушается")
        } else {
            Log.write("CGEvent.tapCreate вернул nil")
            state = .failed("Не удалось перехватить клавиатуру")
        }
    }

    private func bootWhisper() {
        whisper.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Log.write("сервер распознавания готов")
                if !self.pendingFiles.isEmpty {
                    let waiting = self.pendingFiles
                    self.pendingFiles = []
                    self.transcribeWindow?.enqueue(waiting)
                }
                // Пока нет доступа к клавиатуре, предупреждение важнее готовности.
                guard self.hotkeyAttached else { return }
                self.state = .idle
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Перечитывает конфиг и поднимает сервер заново — после правки модели или языка.
    func reload() {
        whisper.stop()
        config = Config.load()
        whisper = Whisper(config: config)
        guard hasModel else {
            state = .needsModel
            showModelPicker()
            return
        }
        state = .starting
        bootWhisper()
    }

    // MARK: - Реакция на хоткей

    private func handle(_ event: Hotkey.Event) {
        switch event {
        case .startHold, .toggleOn:
            beginRecording()
        case .finishHold, .toggleOff:
            endRecording(discard: false)
        case .discard, .cancel:
            endRecording(discard: true)
        case .flipMode:
            guard case .recording = state else { return }
            setCaptureMode(captureMode == .text ? .audio : .text)
            hud.setMode(captureMode)
        }
    }

    /// Разбирает речь прямо во время диктовки, кусками по четыре секунды.
    ///
    /// Каждый кусок разбирается ровно один раз: курсор двигается вперёд,
    /// назад не возвращаемся. Иначе на длинной диктовке пришлось бы каждый
    /// раз перемалывать всё сказанное заново.
    private func startLiveSpeech() {
        stopLiveSpeech()
        liveCursor = 0
        liveFillers = [:]
        liveBusy = false

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepLiveSpeech() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveSpeech() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func stepLiveSpeech() {
        guard !liveBusy, recorder.isRunning, whisper.ready else { return }
        let now = recorder.duration
        let until = liveCursor + Controller.liveSegment
        guard now >= until else { return }

        guard let excerpt = recorder.excerpt(from: liveCursor, to: until) else { return }
        liveCursor = until
        liveBusy = true

        // Без словаря: он тут только замедлил бы и подсказал модели лишнего.
        whisper.transcribe(wav: excerpt, prompt: "") { [weak self] result in
            guard let self else { return }
            self.liveBusy = false
            guard case .success(let text) = result, !text.isEmpty else { return }
            let found = Speech.count(text, words: self.config.fillerWords)
            guard !found.isEmpty else { return }
            for (word, times) in found { self.liveFillers[word, default: 0] += times }
            Log.write("живой разбор: " + found.map { "\($0.word) ×\($0.times)" }.joined(separator: ", "))
            self.hud.setFillers(self.liveSummary())
        }
    }

    /// Частые сверху, показываем не больше трёх: это подсказка, не отчёт.
    private func liveSummary() -> String {
        liveFillers
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: "  ")
    }

    private func setCaptureMode(_ mode: RecorderHUD.Mode) {
        guard mode != captureMode else { return }
        captureMode = mode
        Log.write("режим записи: \(mode == .audio ? "звук" : "текст")")
        onCaptureModeChange?()
    }

    /// Значку в строке меню надо перерисоваться: без окошка он единственный,
    /// кто показывает выбранный режим.
    var onCaptureModeChange: (() -> Void)?

    /// Пакует запись в голосовое и кладёт в буфер файлом.
    private func exportVoice(wav: Data) {
        VoiceMessage.copyToClipboard(wav: wav) { [weak self] result in
            switch result {
            case .success(let url):
                let seconds = Int(Controller.duration(ofWav: wav).rounded())
                Log.write("голосовое в буфере: \(url.lastPathComponent), \(seconds) с")
                self?.hud.showMessage("В буфере, \(seconds) с", hideAfter: 1.4)
            case .failure(let error):
                Log.write("голосовое не собралось: \(error.localizedDescription)")
                self?.hud.hide()
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Ручной старт-стоп из меню.
    func toggleFromMenu() {
        hotkey.reset()
        if recorder.isRunning {
            endRecording(discard: false)
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !recorder.isRunning else { return }
        guard hasModel else {
            state = .needsModel
            showModelPicker()
            return
        }
        guard whisper.ready else {
            state = .failed(whisper.lastError ?? "Модель ещё грузится")
            return
        }
        // Словарь мог поменяться между диктовками — перечитываем.
        config = Config.load()
        recordingGeneration += 1
        // Каждый раз с чистого листа: звук уходит только по осознанному выбору.
        captureMode = .text

        do {
            recorder.preferredDevice = config.inputDevice
            try recorder.start()
            Log.write("запись пошла, микрофон «\(recorder.activeInputName())»")
            state = .recording
            play(.start)
            if config.showHUD {
                hud.onModeChange = { [weak self] mode in self?.setCaptureMode(mode) }
                hud.show(color: WaveTheme.color(for: config), mode: captureMode) { [weak self] in
                    self?.recorder.level ?? 0
                }
                if config.speechHints { startLiveSpeech() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func endRecording(discard: Bool) {
        guard recorder.isRunning else { return }
        stopLiveSpeech()
        let wav = recorder.stop()

        if discard {
            hud.hide()
            state = .idle
            return
        }
        guard let wav else {
            // Слишком короткий фрагмент — молча возвращаемся в покой.
            hud.hide()
            state = .idle
            return
        }

        // Переключатель в окошке решает, чем отдать надиктованное.
        // Звуком — значит распознавать нечего, сразу пакуем и кладём в буфер.
        if captureMode == .audio {
            state = .idle
            play(.stop)
            hud.showMessage("Пакую…")
            exportVoice(wav: wav)
            return
        }

        play(.stop)
        hud.markTranscribing()
        state = .transcribing

        let generation = recordingGeneration
        let parts = AudioSplit.chunks(wav: wav)
        if parts.count > 1 {
            Log.write("запись длинная, режу на \(parts.count) куска")
        }
        transcribeChunks(parts, index: 0, collected: [], wav: wav, generation: generation)
    }

    /// Куски идут по очереди: сервер один и обрабатывает запросы
    /// последовательно, параллелить нечего.
    private func transcribeChunks(_ parts: [Data], index: Int, collected: [String],
                                  wav: Data, generation: Int) {
        guard index < parts.count else {
            finish(text: collected.joined(separator: " "), wav: wav, generation: generation)
            return
        }
        transcribe(wav: parts[index], generation: generation, attempt: 1) { [weak self] piece in
            guard let self else { return }
            var next = collected
            if var piece, !piece.isEmpty {
                // Первый кусок начинается там же, где речь: приветствие в нём
                // законно. Со второго начало — это середина разрезанной фразы,
                // и приветствие там придумано.
                if index > 0 { piece = Hallucination.strippingLeadingInvention(piece) }
                if !piece.isEmpty { next.append(piece) }
            }
            self.transcribeChunks(parts, index: index + 1, collected: next,
                                  wav: wav, generation: generation)
        }
    }

    /// Длительность записи по размеру WAV: 16 кГц, 16 бит, моно.
    private static func duration(ofWav wav: Data) -> TimeInterval {
        max(0, Double(wav.count - 44) / (16000 * 2))
    }

    private func transcribe(wav: Data, generation: Int, attempt: Int,
                            completion: @escaping (String?) -> Void) {
        // Со второй попытки идём без словаря. Именно он и рушит распознавание:
        // замерено на живом куске в 15 секунд речи — со словарём три попытки
        // дали три разные выдумки, без словаря текст распознался целиком.
        // Замены по готовому тексту при этом никуда не деваются.
        let prompt = attempt == 1 ? config.promptString : ""
        whisper.transcribe(wav: wav, prompt: prompt) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let raw):
                // Модель иногда подставляет вместо речи заученную фразу из
                // субтитров. Звук при этом нормальный, и со второй попытки
                // тот же файл распознаётся верно — поэтому переспрашиваем.
                let invented = Hallucination.looksInvented(
                    text: raw, audioDuration: Self.duration(ofWav: wav))
                // Отдельный сбой: декодер срывается в повтор и весь ответ
                // состоит из одной зациклившейся фразы.
                let degenerate = Hallucination.looksDegenerate(raw)
                // Текста меньше, чем было речи. Самый общий признак потери:
                // работает и на выдумках, которых нет ни в одном списке.
                let thin = Hallucination.looksThin(
                    text: raw, audioDuration: Self.duration(ofWav: wav))

                if attempt == 1, invented || degenerate || thin {
                    let reason = degenerate ? "зациклилось" : (invented ? "заученная фраза" : "текста меньше, чем речи")
                    Log.write("похоже на выдумку модели (\(reason)): «\(raw)» — переспрашиваю без словаря")
                    self.transcribe(wav: wav, generation: generation, attempt: 2,
                                    completion: completion)
                    return
                }

                // Повтор и заученная фраза цепляются в хвост куска — чистим
                // до склейки, иначе в середине текста их уже не отличить
                // от живой речи.
                let cleaned = Hallucination.strippingTrailingInvention(
                    Hallucination.collapsingTrailingRepeats(raw))

                // Кусок вычистился в ноль — значит весь ответ был выдумкой,
                // а под ним осталась незаписанная речь. Молча терять её нельзя:
                // так пятнадцать секунд диктовки уходили в пустоту.
                if attempt == 1, cleaned.isEmpty, !raw.isEmpty {
                    Log.write("кусок вычистился в ноль: «\(raw)» — переспрашиваю без словаря")
                    self.transcribe(wav: wav, generation: generation, attempt: 2,
                                    completion: completion)
                    return
                }
                completion(cleaned)

            case .failure(let error):
                // Окошко и состояние трогаем, только если новая запись
                // не началась: иначе погасим чужое.
                guard generation == self.recordingGeneration else { completion(nil); return }
                self.hud.hide()
                let message = error.localizedDescription
                self.state = .failed(message)
                // Ошибку показываем несколько секунд и возвращаемся в покой.
                // Сверяем текст: за это время могла случиться другая, ещё
                // не решённая беда, и гасить её сообщение нельзя.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, case .failed(let shown) = self.state, shown == message else { return }
                    self.state = .idle
                }
                completion(nil)
            }
        }
    }

    /// Всё распознано — вставляем и прибираем состояние.
    private func finish(text raw: String, wav: Data, generation: Int) {
        let current = generation == recordingGeneration
        let text = config.applyingFinalPunctuation(
            to: config.applyReplacements(
                to: Hallucination.strippingTrailingInvention(
                    Hallucination.collapsingTrailingRepeats(raw))))
        Log.write("распознано: \(text)")

        guard !text.isEmpty else {
            if current { hud.hide(); state = .idle }
            return
        }

        lastText = text

        if current { hud.hide() }

        let mode = Inserter.Mode(rawValue: config.insertMode) ?? .paste
        Inserter.insert(text, mode: mode)
        // Пишем длину: если текст не появился в поле, по журналу видно,
        // что приложение своё дело сделало и текст можно достать заново
        // пунктом меню «Скопировать последний текст».
        Log.write("вставлено \(text.count) знаков, способ «\(config.insertMode)»")
        Stats.add(characters: text.count, seconds: Controller.duration(ofWav: wav))
        if config.keepHistory { saveHistory(wav: wav, text: text) }
        if current { state = .idle }
        if current { collectCandidates(wav: wav, generation: generation) }
    }

    /// Разбор слов, в которых модель сомневалась.
    ///
    /// Идёт после вставки, а не вместо неё: уверенность живёт только
    /// в подробном ответе сервера, а он на записи в 17 секунд отвечает
    /// на полсекунды дольше. Ждать эти полсекунды на каждой фразе незачем,
    /// поэтому платим лишним проходом, но уже в фоне.
    ///
    /// Куски те же, что при распознавании: whisper разбирает окнами по
    /// 30 секунд, и целую длинную запись одним запросом отдавать нельзя.
    /// Словарь при этом не передаём: он и так подсказывает модели ответ,
    /// а нам нужна её собственная неуверенность.
    private func collectCandidates(wav: Data, generation: Int) {
        guard config.collectCandidates else { return }
        analyzeChunks(AudioSplit.chunks(wav: wav), index: 0, generation: generation)
    }

    private func analyzeChunks(_ parts: [Data], index: Int, generation: Int) {
        // Начали новую диктовку — разбор бросаем: сервер один, и свежая
        // запись важнее копилки.
        guard index < parts.count, generation == recordingGeneration else { return }
        let chunk = parts[index]
        whisper.analyzeWords(wav: chunk, prompt: "") { [weak self] words in
            guard let self, generation == self.recordingGeneration else { return }
            self.candidates.record(words) { from, to in
                AudioSplit.slice(wav: chunk, from: from, to: to)
            }
            self.analyzeChunks(parts, index: index + 1, generation: generation)
        }
    }

    // MARK: - Мелочи

    func copyLastAgain() {
        guard !lastText.isEmpty else { return }
        Inserter.insert(lastText, mode: .clipboard)
    }

    private func play(_ moment: Sounds.Moment) {
        guard config.sounds else { return }
        Sounds.play(moment, themeID: config.soundTheme)
    }

    private func saveHistory(wav: Data, text: String) {
        let dir = Config.directory.appendingPathComponent("history")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        let wavURL = dir.appendingPathComponent("\(stamp).wav")
        try? wav.write(to: wavURL)
        try? text.write(to: dir.appendingPathComponent("\(stamp).txt"), atomically: true, encoding: .utf8)
        purgeHistory()

        // WAV весит 1,9 МБ на минуту, и при хранении сутками история пухнет
        // до гигабайта. Пережимаем в m4a: в семь раз меньше, играет двойным
        // щелчком в любом плеере. Фоном, чтобы не задерживать диктовку.
        History.compress(wavURL)
    }

    /// Чистит старые записи. Голос на диске — вещь чувствительная, и держать
    /// его дольше нужного незачем: история решает одну задачу — посмотреть,
    /// что распознавание услышало в только что сказанной фразе.
    func purgeHistory() {
        let hours = config.historyRetentionHours
        guard hours > 0 else { return }

        let dir = Config.directory.appendingPathComponent("history")
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        var removed = 0
        for file in files {
            // Расшифровки не трогаем никогда. Место они занимают копеечное,
            // а по ним видно, как меняется речь: сколько было слов-паразитов
            // месяц назад и сколько стало. Стирать такое ради килобайтов глупо.
            guard file.pathExtension != "txt" else { continue }

            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: file)
            removed += 1
        }
        if removed > 0 { Log.write("история: удалено записей \(removed), расшифровки оставлены") }
    }
}

extension ISO8601DateFormatter {
    /// Метка времени без двоеточий — иначе Finder показывает их как слэши.
    static let filenameSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime,
                           .withDashSeparatorInDate, .withTimeZone]
        f.timeZone = .current
        return f
    }()
}
