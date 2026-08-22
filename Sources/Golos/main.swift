import AppKit

/// Приложение живёт в строке меню: окон нет, Dock-иконки нет.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = Controller()
    private var statusLine: NSMenuItem!
    private var signalSources: [DispatchSourceSignal] = []
    private let updater = Updater()
    private var toggleItem: NSMenuItem!
    private var autostartItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        controller.onStateChange = { [weak self] state in
            self?.render(state)
        }
        installSignalHandlers()
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

        let hint = NSMenuItem(title: "Правый ⌥ — держать; двойной тап — переключатель",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: "Модель распознавания…",
                                   action: #selector(openModelPicker), keyEquivalent: "")
        modelItem.target = self
        menu.addItem(modelItem)

        let configItem = NSMenuItem(title: "Словарь и настройки…",
                                    action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let historyItem = NSMenuItem(title: "Папка истории",
                                     action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let reloadItem = NSMenuItem(title: "Перезапустить распознавание",
                                    action: #selector(reload), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        autostartItem = NSMenuItem(title: "Запускать при входе",
                                   action: #selector(toggleAutostart), keyEquivalent: "")
        autostartItem.target = self
        menu.addItem(autostartItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Проверить обновления…",
                                    action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self
        refreshAutostartItem()
    }

    private func refreshAutostartItem() {
        autostartItem.state = Autostart.isEnabled ? .on : .off
        autostartItem.title = Autostart.blockedBySystem
            ? "Запускать при входе (запрещено в настройках)"
            : "Запускать при входе"
    }

    private func render(_ state: Controller.State) {
        guard let button = statusItem.button else { return }

        switch state {
        case .starting:
            symbol("hourglass", tint: .secondaryLabelColor, on: button)
            statusLine.title = "Гружу модель…"
            toggleItem.isEnabled = false
            toggleItem.title = "Начать запись"
        case .idle:
            symbol("mic", tint: .labelColor, on: button)
            statusLine.title = "Готово"
            toggleItem.isEnabled = true
            toggleItem.title = "Начать запись"
        case .recording:
            symbol("mic.fill", tint: .systemRed, on: button)
            statusLine.title = "Идёт запись"
            toggleItem.isEnabled = true
            toggleItem.title = "Остановить и распознать"
        case .transcribing:
            symbol("waveform", tint: .systemBlue, on: button)
            statusLine.title = "Распознаю…"
            toggleItem.isEnabled = false
            toggleItem.title = "Начать запись"
        case .needsModel:
            symbol("arrow.down.circle", tint: .systemBlue, on: button)
            statusLine.title = "Нужно выбрать модель"
            toggleItem.isEnabled = false
            toggleItem.title = "Начать запись"
        case .failed(let message):
            symbol("exclamationmark.triangle", tint: .systemOrange, on: button)
            statusLine.title = message
            toggleItem.isEnabled = true
            toggleItem.title = "Начать запись"
        }
    }

    private func symbol(_ name: String, tint: NSColor, on button: NSStatusBarButton) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = false
        button.image = image?.tinted(with: tint)
        button.imagePosition = .imageOnly
    }

    @objc private func toggleRecording() { controller.toggleFromMenu() }
    @objc private func copyLast() { controller.copyLastAgain() }
    @objc private func reload() { controller.reload() }

    @objc private func openConfig() {
        _ = Config.load()   // создаст файл, если его ещё нет
        NSWorkspace.shared.open(Config.fileURL)
    }

    @objc private func openHistory() {
        let dir = Config.directory.appendingPathComponent("history")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func openModelPicker() { controller.showModelPicker() }

    @objc private func checkForUpdates() { updater.checkNowBringingToFront() }

    @objc private func toggleAutostart() {
        if let error = Autostart.set(!Autostart.isEnabled) {
            statusLine.title = "Автозапуск: \(error)"
        }
        refreshAutostartItem()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshAutostartItem()
    }
}

private extension NSImage {
    /// SF Symbol в строке меню перекрашиваем сами: шаблонный режим красит всё в чёрный.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            self.draw(in: rect)
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
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
