import AppKit
import SwiftUI

/// Окно настроек с вкладками. Открывается из меню.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let store: SettingsStore
    private let onOpenModelPicker: () -> Void
    private let onCheckUpdates: () -> Void

    init(store: SettingsStore,
         onOpenModelPicker: @escaping () -> Void,
         onCheckUpdates: @escaping () -> Void) {
        self.store = store
        self.onOpenModelPicker = onOpenModelPicker
        self.onCheckUpdates = onCheckUpdates
    }

    func show() {
        // Файл могли править руками, пока окно было закрыто.
        store.reloadFromDisk()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(store: store,
                                onOpenModelPicker: onOpenModelPicker,
                                onCheckUpdates: onCheckUpdates)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Настройки Голоса"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 620, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WindowCloser.shared
        WindowCloser.shared.onClose = { [weak self] in self?.store.flush() }
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Записываем настройки на диск при закрытии окна, не дожидаясь задержки.
private final class WindowCloser: NSObject, NSWindowDelegate {
    static let shared = WindowCloser()
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let onOpenModelPicker: () -> Void
    let onCheckUpdates: () -> Void

    var body: some View {
        TabView {
            GeneralTab(store: store, onOpenModelPicker: onOpenModelPicker)
                .tabItem { Label("Основное", systemImage: "gearshape") }

            VocabularyTab(store: store)
                .tabItem { Label("Словарь", systemImage: "text.book.closed") }

            ReplacementsTab(store: store)
                .tabItem { Label("Замены", systemImage: "arrow.left.arrow.right") }

            AboutTab(onCheckUpdates: onCheckUpdates)
                .tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .padding(14)
        .frame(width: 620, height: 580)
    }
}

// MARK: - Основное

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    let onOpenModelPicker: () -> Void

    @State private var autostart = Autostart.isEnabled
    @State private var autostartError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: $autostart)
                    .onChange(of: autostart) { _, newValue in
                        autostartError = Autostart.set(newValue)
                        // Система могла отказать — показываем правду, а не галочку.
                        autostart = Autostart.isEnabled
                    }
                if let autostartError {
                    Text(autostartError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Toggle("Показывать волну во время записи", isOn: $store.config.showHUD)
                Text("Небольшое окошко внизу экрана с живой формой волны. Фокус не перехватывает — вставка в активное поле работает как обычно.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                WaveColorPicker(store: store)

                Toggle("Звук при начале и конце записи", isOn: $store.config.sounds)

                if store.config.sounds {
                    HStack {
                        Picker("Сигнал", selection: $store.config.soundTheme) {
                            ForEach(Sounds.themes, id: \.id) { theme in
                                Text(theme.title).tag(theme.id)
                            }
                        }
                        Button {
                            preview()
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Прослушать")
                    }
                    Text(Sounds.theme(id: store.config.soundTheme).note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Поведение").font(.system(size: 12, weight: .semibold))
            }

            Section {
                Toggle("Хранить записи и расшифровки", isOn: $store.config.keepHistory)
                Text("На каждую диктовку сохраняется аудиофайл с твоим голосом и текстовый файл с расшифровкой. Нужно, чтобы послушать, что распознавание услышало в неудачной фразе.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.config.keepHistory {
                    Picker("Удалять записи", selection: $store.config.historyRetentionHours) {
                        Text("Через час").tag(1)
                        Text("Через сутки").tag(24)
                        Text("Через неделю").tag(168)
                        Text("Не удалять").tag(0)
                    }
                    HStack {
                        Text(historySize)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Открыть папку") {
                            let dir = Config.directory.appendingPathComponent("history")
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(dir)
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("История").font(.system(size: 12, weight: .semibold))
            }

            Section {
                Picker("Куда девать текст", selection: $store.config.insertMode) {
                    Text("Вставлять в активное поле").tag("paste")
                    Text("Набирать посимвольно").tag("type")
                    Text("Только копировать в буфер").tag("clipboard")
                }
                Text(insertHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Вставка").font(.system(size: 12, weight: .semibold))
            }

            Section {
                Picker("Язык речи", selection: $store.config.language) {
                    Text("Русский").tag("ru")
                    Text("Английский").tag("en")
                    Text("Определять автоматически").tag("auto")
                }
                Text("Русский вариант распознаёт и англицизмы внутри русской речи — переключать не нужно. Автоопределение чуть медленнее и иногда ошибается на коротких фразах.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Модель")
                    Spacer()
                    Text(modelName)
                        .foregroundStyle(.secondary)
                    Button("Сменить…", action: onOpenModelPicker)
                }
            } header: {
                Text("Распознавание").font(.system(size: 12, weight: .semibold))
            }
        }
        .formStyle(.grouped)
    }

    /// Проигрываем обе метки подряд — так слышно пару целиком.
    private func preview() {
        Sounds.play(.start, themeID: store.config.soundTheme)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            Sounds.play(.stop, themeID: store.config.soundTheme)
        }
    }

    private var historySize: String {
        let dir = Config.directory.appendingPathComponent("history")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "Записей пока нет"
        }
        let recordings = files.filter { $0.pathExtension == "wav" }.count
        let bytes = files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard recordings > 0 else { return "Записей пока нет" }
        let mb = Double(bytes) / 1_048_576
        return String(format: "Сейчас %d записей, %.1f МБ", recordings, mb)
    }

    private var insertHint: String {
        switch store.config.insertMode {
        case "type":
            return "Буфер обмена не трогается, но длинный текст печатается заметно, и часть приложений глотает символы."
        case "clipboard":
            return "Текст кладётся в буфер, вставляешь сам через Cmd+V."
        default:
            return "Прежнее содержимое буфера обмена возвращается сразу после вставки."
        }
    }

    private var modelName: String {
        let file = (store.config.modelPath as NSString).lastPathComponent
        guard !file.isEmpty else { return "не выбрана" }
        let match = ModelCatalog.all.first { $0.fileName == file }
        return match?.title ?? file
    }
}

/// Палитра для волны. Один цвет красит и окошко записи, и иконку в меню.
private struct WaveColorPicker: View {
    @ObservedObject var store: SettingsStore

    private var currentColor: Color {
        Color(WaveTheme.color(for: store.config))
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { Color(NSColor(hex: store.config.customWaveColor) ?? WaveTheme.fallback.nsColor) },
            set: { store.config.customWaveColor = NSColor($0).hexString }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(WaveTheme.all) { theme in
                    swatch(color: theme.swiftUIColor,
                           selected: store.config.waveTheme == theme.id,
                           help: theme.title) {
                        store.config.waveTheme = theme.id
                    }
                }
                swatch(color: customBinding.wrappedValue,
                       selected: store.config.waveTheme == WaveTheme.customID,
                       help: "Свой цвет",
                       dashed: true) {
                    store.config.waveTheme = WaveTheme.customID
                }

                Spacer()
                WavePreview(color: currentColor)
            }

            if store.config.waveTheme == WaveTheme.customID {
                ColorPicker("Свой цвет", selection: customBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 60, alignment: .leading)
            }

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hint: String {
        if store.config.waveTheme == "mono" {
            return "Монохром в строке меню рисуется шаблоном — система сама подгонит его под светлую и тёмную тему."
        }
        if store.config.waveTheme == WaveTheme.customID {
            return "Свой цвет применяется и к окошку, и к иконке в меню. Слишком светлый плохо виден на светлой строке меню."
        }
        return "Красит окошко записи и иконку в строке меню, пока идёт запись."
    }

    private func swatch(color: Color, selected: Bool, help: String,
                        dashed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 22, height: 22)
                if dashed {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                Circle()
                    .strokeBorder(selected ? Color.primary : Color.secondary.opacity(0.25),
                                  lineWidth: selected ? 2 : 1)
                    .frame(width: 28, height: 28)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Маленькая статичная волна — чтобы выбор цвета был виден сразу.
private struct WavePreview: View {
    let color: Color
    private let heights: [CGFloat] = [6, 12, 20, 28, 20, 12, 6]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(color.opacity(0.95))
                    .frame(width: 3.5, height: h)
                    .shadow(color: color.opacity(0.5), radius: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.06))
        )
    }
}

// MARK: - Словарь

private struct VocabularyTab: View {
    @ObservedObject var store: SettingsStore
    @State private var newTerm = ""
    @State private var problem: String?
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Слова, которые нужно писать латиницей")
                .font(.system(size: 13, weight: .semibold))
            Text("Подсказка распознаванию: перечисленное здесь оно будет писать как написано, а не транслитом. Русские слова добавлять не нужно — они и так пишутся кириллицей.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Например: pull request", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Добавить", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            List(selection: $selection) {
                ForEach(store.config.vocabulary, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            store.removeTerm(term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
                .onDelete { store.removeTerms(at: $0) }
            }
            .frame(maxHeight: .infinity)

            budgetBar
        }
    }

    /// Показываем занятое место: у подсказки модели жёсткий потолок,
    /// и молча обрезанный хвост словаря — худший из возможных сюрпризов.
    private var budgetBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(store.config.vocabulary.count) слов, \(store.vocabularyUsage) из \(store.vocabularyBudget) символов")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(store.vocabularyOverflow ? .orange : .secondary)
                Spacer()
            }
            ProgressView(value: min(1, Double(store.vocabularyUsage) / Double(store.vocabularyBudget)))
                .tint(store.vocabularyOverflow ? .orange : .accentColor)
            if store.vocabularyOverflow {
                Text("Список длиннее, чем принимает распознавание. Лишние слова в конце не работают — убери что-нибудь.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func add() {
        problem = store.addTerm(newTerm)
        if problem == nil { newTerm = "" }
    }
}

// MARK: - Замены

private struct ReplacementsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Исправления готового текста")
                .font(.system(size: 13, weight: .semibold))
            Text("Если распознавание стабильно ошибается на каком-то слове, впиши, что слышится и чем это заменить. Замена применяется без учёта регистра.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Слышится").font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Писать").font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 28)
            }
            .foregroundStyle(.secondary)

            List {
                ForEach($store.config.replacements, id: \.from) { $item in
                    HStack(spacing: 8) {
                        TextField("верселе", text: $item.from)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("Vercel", text: $item.to)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            store.config.replacements.removeAll { $0.from == item.from && $0.to == item.to }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
                .onDelete { store.removeReplacements(at: $0) }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Добавить строку") { store.addReplacement() }
                Spacer()
                Text("\(store.config.replacements.count) замен")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - О программе

private struct AboutTab: View {
    let onCheckUpdates: () -> Void

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (сборка \(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Голос").font(.system(size: 20, weight: .semibold))
                Text("Версия \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Text("Голосовой ввод с распознаванием на этом Маке. Записи никуда не отправляются.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Горячие клавиши").font(.system(size: 12, weight: .semibold))
                shortcut("Держать правый ⌥", "запись, пока держишь")
                shortcut("Двойной тап по правому ⌥", "запись до следующего тапа")
                shortcut("Escape во время записи", "отменить без вставки")
            }

            Divider()

            HStack(spacing: 10) {
                Button("Проверить обновления…", action: onCheckUpdates)
                Button("Папка записей") {
                    let dir = Config.directory.appendingPathComponent("history")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
                Button("Журнал") { NSWorkspace.shared.open(Log.fileURL) }
            }

            Spacer()

            Link("github.com/Starochev/golos",
                 destination: URL(string: "https://github.com/Starochev/golos")!)
                .font(.system(size: 11))
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcut(_ keys: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 190, alignment: .leading)
            Text(what)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
