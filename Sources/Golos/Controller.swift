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
    private lazy var settingsStore = SettingsStore()
    /// Смена языка или модели требует перезапуска движка. Гасим дребезг:
    /// пока пользователь щёлкает по списку, перезапускать нет смысла.
    private var engineReloadWork: DispatchWorkItem?

    init() {
        whisper = Whisper(config: config)
    }

    func start() {
        Log.write("запуск")
        purgeHistory()
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

        do {
            try recorder.start()
            state = .recording
            play(.start)
            if config.showHUD {
                hud.show(color: WaveTheme.color(for: config)) { [weak self] in
                    self?.recorder.level ?? 0
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func endRecording(discard: Bool) {
        guard recorder.isRunning else { return }
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
            if let piece, !piece.isEmpty { next.append(piece) }
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
        whisper.transcribe(wav: wav, prompt: config.promptString) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let raw):
                // Модель иногда подставляет вместо речи заученную фразу из
                // субтитров. Звук при этом нормальный, и со второй попытки
                // тот же файл распознаётся верно — поэтому переспрашиваем.
                if attempt == 1,
                   Hallucination.looksInvented(text: raw,
                                               audioDuration: Self.duration(ofWav: wav)) {
                    Log.write("похоже на выдумку модели: «\(raw)» — переспрашиваю")
                    self.transcribe(wav: wav, generation: generation, attempt: 2,
                                    completion: completion)
                    return
                }
                // Заученная фраза цепляется и в хвост куска — срезаем до склейки.
                completion(Hallucination.strippingTrailingInvention(raw))

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
        let text = config.applyReplacements(to: Hallucination.strippingTrailingInvention(raw))
        Log.write("распознано: \(text)")

        guard !text.isEmpty else {
            if current { hud.hide(); state = .idle }
            return
        }

        lastText = text
        if current { hud.hide() }
        let mode = Inserter.Mode(rawValue: config.insertMode) ?? .paste
        Inserter.insert(text, mode: mode)
        if config.keepHistory { saveHistory(wav: wav, text: text) }
        if current { state = .idle }
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
        try? wav.write(to: dir.appendingPathComponent("\(stamp).wav"))
        try? text.write(to: dir.appendingPathComponent("\(stamp).txt"), atomically: true, encoding: .utf8)
        purgeHistory()
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
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: file)
            removed += 1
        }
        if removed > 0 { Log.write("история: удалено файлов \(removed)") }
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
