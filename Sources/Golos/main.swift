import AppKit

/// Приложение живёт в строке меню: окон нет, Dock-иконки нет.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = Controller()
    private var statusLine: NSMenuItem!
    private var signalSources: [DispatchSourceSignal] = []
    private var animationTimer: Timer?
    private var transcribePhase: CGFloat = 0
    private let updater = Updater()
    private var toggleItem: NSMenuItem!
    private var hintItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        controller.onStateChange = { [weak self] state in
            self?.render(state)
        }
        installSignalHandlers()

        // Запуск с путями к файлам: «Golos --transcribe запись.mp4».
        // Годится и для пачек из терминала.
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let flag = arguments.firstIndex(of: "--transcribe") {
            let files = arguments[(flag + 1)...].map { URL(fileURLWithPath: $0) }
            if !files.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.controller.transcribeFiles(files) }
            }
        }

        // «Golos --settings» — то же, что пункт меню. Удобно, когда значок
        // в строке меню не виден, и одинаково с версией для Windows.
        if arguments.contains("--settings") {
            DispatchQueue.main.async { [weak self] in self?.controller.showSettings() }
        }

        controller.onCheckUpdates = { [weak self] in self?.updater.checkNowBringingToFront() }
        controller.onHotkeyChanged = { [weak self] in self?.refreshHint() }
        controller.start()
        render(controller.state)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    /// applicationWillTerminate не вызывается, когда процесс снимают сигналом
    /// (pkill при пересборке). Без этого whisper-server остаётся сиротой
    /// и держит в памяти трёхгигабайтную модель.
    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()

        statusLine = NSMenuItem(title: "Запускаюсь…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Начать запись",
                                action: #selector(toggleRecording),
                                keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let copyItem = NSMenuItem(title: "Скопировать последний текст",
                                  action: #selector(copyLast), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        menu.addItem(.separator())

        let transcribeItem = NSMenuItem(title: "Расшифровать файл…",
                                        action: #selector(openTranscribe), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Настройки…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Проверить обновления…",
                                    action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshHint()
    }

    /// Подсказка называет ту клавишу, что выбрана сейчас.
    private func refreshHint() {
        hintItem.title = "\(controller.hotkeyTitle) — держать; двойной тап — переключатель"
    }

    private func render(_ state: Controller.State) {
        guard let button = statusItem.button else { return }

        switch state {
        case .starting:
            button.image = MenuBarIcon.image(for: .loading)
            statusLine.title = "Гружу модель…"
            toggleItem.isEnabled = false
            toggleItem.title = "Начать запись"
        case .idle:
            button.image = MenuBarIcon.image(for: .idle)
            statusLine.title = "Готово"
            toggleItem.isEnabled = true
            toggleItem.title = "Начать запись"
        case .recording:
            statusLine.title = "Идёт запись"
            toggleItem.isEnabled = true
            toggleItem.title = "Остановить и распознать"
        case .transcribing:
            statusLine.title = "Распознаю…"
            toggleItem.isEnabled = false
            toggleItem.title = "Начать запись"
        case .needsModel:
            button.image = MenuBarIcon.image(for: .needsModel)
            statusLine.title = "Нужно выбрать модель"
            toggleItem.isEnabled = false
            toggleItem.title = "Начать запись"
        case .failed(let message):
            button.image = MenuBarIcon.image(for: .failed)
            statusLine.title = message
            toggleItem.isEnabled = true
            toggleItem.title = "Начать запись"
        }

        button.imagePosition = .imageOnly
        updateAnimation(for: state)
    }

    /// Иконка оживает только в двух состояниях — в покое таймер не нужен.
    private func updateAnimation(for state: Controller.State) {
        switch state {
        case .recording, .transcribing:
            guard animationTimer == nil else { return }
            transcribePhase = 0
            let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.animateIcon() }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        default:
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func animateIcon() {
        guard let button = statusItem.button else { return }
        switch controller.state {
        case .recording:
            button.image = MenuBarIcon.image(
                for: .recording(level: CGFloat(controller.micLevel),
                                color: controller.menuBarWaveColor))
        case .transcribing:
            transcribePhase += 0.32
            button.image = MenuBarIcon.image(for: .transcribing(phase: transcribePhase))
        default:
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    @objc private func toggleRecording() { controller.toggleFromMenu() }
    @objc private func copyLast() { controller.copyLastAgain() }

    @objc private func openSettings() { controller.showSettings() }

    @objc private func openTranscribe() { controller.showFileTranscription() }

    @objc private func checkForUpdates() { updater.checkNowBringingToFront() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// Код верхнего уровня исполняется на главном потоке, но компилятор об этом
// не знает — assumeIsolated объясняет ему это без лишней обвязки.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // Ссылка на делегата у NSApplication слабая — держим её сами.
    objc_setAssociatedObject(app, "golos.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
