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
    private let hotkey = Hotkey()
    private var whisper: Whisper

    /// Отбрасывать ли результат текущей записи (короткий тап, Escape).
    private var discardCurrent = false
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
            settingsWindow = SettingsWindow(
                store: settingsStore,
                onOpenModelPicker: { [weak self] in self?.showModelPicker() },
                onCheckUpdates: { [weak self] in self?.onCheckUpdates?() }
            )
        }
        settingsWindow?.show()
    }

    /// Проверку обновлений держит AppDelegate — сюда приходит замыканием.
    var onCheckUpdates: (() -> Void)?

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
        discardCurrent = false

        do {
            try recorder.start()
            state = .recording
            play("Tink")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func endRecording(discard: Bool) {
        guard recorder.isRunning else { return }
        let wav = recorder.stop()

        if discard {
            state = .idle
            return
        }
        guard let wav else {
            // Слишком короткий фрагмент — молча возвращаемся в покой.
            state = .idle
            return
        }

        play("Pop")
        state = .transcribing

        whisper.transcribe(wav: wav, prompt: config.promptString) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let raw):
                let text = self.config.applyReplacements(to: raw)
                Log.write("распознано: \(text)")
                guard !text.isEmpty else {
                    self.state = .idle
                    return
                }
                self.lastText = text
                let mode = Inserter.Mode(rawValue: self.config.insertMode) ?? .paste
                Inserter.insert(text, mode: mode)
                if self.config.keepHistory { self.saveHistory(wav: wav, text: text) }
                self.state = .idle
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
                // Ошибку показываем, но работать продолжаем.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    if case .failed = self?.state { self?.state = .idle }
                }
            }
        }
    }

    // MARK: - Мелочи

    func copyLastAgain() {
        guard !lastText.isEmpty else { return }
        Inserter.insert(lastText, mode: .clipboard)
    }

    private func play(_ name: String) {
        guard config.sounds else { return }
        NSSound(named: name)?.play()
    }

    private func saveHistory(wav: Data, text: String) {
        let dir = Config.directory.appendingPathComponent("history")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        try? wav.write(to: dir.appendingPathComponent("\(stamp).wav"))
        try? text.write(to: dir.appendingPathComponent("\(stamp).txt"), atomically: true, encoding: .utf8)
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
