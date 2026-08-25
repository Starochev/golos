import AVFoundation
import AppKit
import SwiftUI

/// Окно настроек с вкладками. Открывается из меню.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let store: SettingsStore
    private let candidates: Candidates
    private let onOpenModelPicker: () -> Void
    private let onCheckUpdates: () -> Void

    init(store: SettingsStore,
         candidates: Candidates,
         onOpenModelPicker: @escaping () -> Void,
         onCheckUpdates: @escaping () -> Void) {
        self.store = store
        self.candidates = candidates
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
                                candidates: candidates,
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
    @ObservedObject var candidates: Candidates
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

            CandidatesTab(store: store, candidates: candidates)
                .tabItem { Label("Кандидаты", systemImage: "questionmark.bubble") }

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
                HStack {
                    Text("Куда класть расшифровки")
                    Spacer()
                    Text(folderTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Выбрать…") { chooseFolder() }
                    if !store.config.fileOutputFolder.isEmpty {
                        Button("Рядом с файлом") { store.config.fileOutputFolder = "" }
                    }
                }
                Text("По умолчанию расшифровка ложится рядом с исходным файлом. Рядом же появляется файл субтитров.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Оставлять переконвертированный звук", isOn: $store.config.keepConvertedAudio)
                Text("Для распознавания файл приводится к моно 16 кГц. Обычно этот wav не нужен, но иногда удобно послушать ровно то, что слышала модель.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Расшифровка файлов").font(.system(size: 12, weight: .semibold))
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

                Picker("Знак в конце фразы", selection: $store.config.finalPunctuation) {
                    Text("Как распознано").tag("keep")
                    Text("Убирать точку").tag("period")
                    Text("Убирать любой знак").tag("any")
                }
                Text("Знаки препинания расставляет сама модель, по интонации и смыслу. Отдельной ручки у неё нет, и вопросительный знак она иногда пропускает. Убрать лишнее с конца можно, доставить нужное — нет. На расшифровку файлов не влияет.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Вставка").font(.system(size: 12, weight: .semibold))
            }

            Section {
                Picker("Микрофон", selection: $store.config.inputDevice) {
                    Text("Как в системе").tag("")
                    ForEach(AudioDevices.inputs()) { device in
                        Text(device.name).tag(device.name)
                    }
                }
                Text("Система меняет микрофон сама, стоит подключиться новому устройству, и запись уходит не туда. Выбранный здесь не поменяется без спроса. Сейчас система отдаёт «\(AudioDevices.defaultInputName())».")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Микрофон").font(.system(size: 12, weight: .semibold))
            }

            Section {
                Picker("Клавиша записи", selection: $store.config.hotkey) {
                    ForEach(HotkeyOption.all) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                Text(HotkeyOption.named(store.config.hotkey).note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Список закрыт намеренно: обычную букву назначить нельзя, иначе каждое её нажатие уходило бы в диктовку. Применяется сразу.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Вторая клавиша", selection: $store.config.secondHotkey) {
                    Text("Выключено").tag("")
                    ForEach(HotkeyOption.all.filter { $0.id != store.config.hotkey }) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                Text("Работает наравне с основной. Удобно, когда до основной не всегда дотянуться, а лезть в настройки ради этого не хочется.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Горячая клавиша").font(.system(size: 12, weight: .semibold))
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

    private var folderTitle: String {
        let stored = store.config.fileOutputFolder
        return stored.isEmpty ? "рядом с файлом" : (stored as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.config.fileOutputFolder = url.path
        }
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

// MARK: - Кандидаты

/// Слова, в которых модель сомневалась, с предложением занести их в словарь.
///
/// Показываем не всё подряд: спрашиваем только про те, что споткнулись
/// повторно. Иначе список забивается обычными русскими словами, сказанными
/// быстро — их в час диктовки набирается несколько сотен.
private struct CandidatesTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var candidates: Candidates
    /// Латинское написание, которое человек набирает для конкретного слова.
    @State private var drafts: [String: String] = [:]
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Слова, в которых распознавание сомневалось")
                .font(.system(size: 13, weight: .semibold))
            Text("Модель отдаёт уверенность по каждому слову. Сюда попадает то, что она разобрала неуверенно и чего нет в словаре русского языка: обычно это англицизм, записанный кириллицей. Напиши, как слово пишется на самом деле, и оно уйдёт в словарь распознавания.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if candidates.pending.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(candidates.pending) { candidate in
                        row(candidate)
                            .padding(.vertical, 4)
                    }
                }
                .frame(maxHeight: .infinity)
            }

            footer
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            Text(store.config.collectCandidates
                 ? "Пока пусто. Слово попадает сюда, когда распознавание о него спотыкается, а словарь русского языка его не знает."
                 : "Сбор выключен. Включи его внизу, и после нескольких диктовок здесь появятся слова.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ candidate: Candidate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(candidate.word)
                    .font(.system(size: 13, weight: .medium))
                Text(candidate.hits > 1
                     ? "\(candidate.hits) раза, уверенность \(percent(candidate.worst))"
                     : "уверенность \(percent(candidate.worst))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !candidate.context.isEmpty {
                Text("«\(candidate.context)»")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if candidate.hasAudio {
                    Button {
                        CandidateSound.play(candidate.audioURL)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.borderless)
                    .help("Послушать, что было сказано на самом деле")
                }
                TextField("как пишется на самом деле", text: binding(for: candidate))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { accept(candidate) }
                Button("В словарь") { accept(candidate) }
                    .disabled(draft(for: candidate).isEmpty)
                    .help("Занести написание в словарь распознавания")
                Button("Всё верно") { candidates.markCorrect(candidate) }
                    .help("Слово распознано правильно. Больше о нём не спросят")
                Button("Скрыть") { candidates.dismiss(candidate) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Убрать из списка сейчас. Слово вернётся, если распознавание споткнётся о него снова")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Toggle("Собирать сомнительные слова", isOn: Binding(
                get: { store.config.collectCandidates },
                set: { store.config.collectCandidates = $0 }
            ))
            Text("Разбор идёт фоном, уже после того как текст вставлен: на саму диктовку он не влияет. Кандидат без ответа исчезает сам через неделю, решённое молчит три месяца.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !candidates.pending.isEmpty {
                Button("Очистить список") { candidates.forgetAll() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func draft(for candidate: Candidate) -> String {
        (drafts[candidate.id] ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func binding(for candidate: Candidate) -> Binding<String> {
        Binding(get: { drafts[candidate.id] ?? "" },
                set: { drafts[candidate.id] = $0 })
    }

    private func accept(_ candidate: Candidate) {
        let term = draft(for: candidate)
        guard !term.isEmpty else { return }
        problem = store.addTerm(term)
        guard problem == nil else { return }
        drafts[candidate.id] = nil
        candidates.accepted(candidate)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

/// Сколько наговорено за всё время. Цифра в знаках сама по себе пустая,
/// поэтому рядом то же самое в страницах и в сэкономленном времени.
private struct StatsView: View {
    private let stats = Stats.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Сколько наговорено").font(.system(size: 12, weight: .semibold))

            if stats.dictations == 0 {
                Text("Пока ничего. Счёт пойдёт с первой диктовки.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(number(stats.characters)) знаков за \(number(stats.dictations)) \(plural(stats.dictations, "диктовку", "диктовки", "диктовок"))")
                    .font(.system(size: 13, weight: .medium))

                Text(comparison)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Сравнения, ради которых всё и затевалось: голая цифра ни о чём.
    private var comparison: String {
        var lines: [String] = []
        lines.append("Это \(pages) и столько же несделанных нажатий на клавиши.")

        let saved = stats.typingHours - stats.speakingHours
        if saved > 0.05 {
            lines.append("Набирать это руками со скоростью 200 знаков в минуту заняло бы \(hours(stats.typingHours)), наговорил ты за \(hours(stats.speakingHours)). Разница \(hours(saved)).")
        }
        return lines.joined(separator: " ")
    }

    private var pages: String {
        let value = stats.pages
        if value < 1 { return "меньше страницы текста" }
        return String(format: "%.0f %@ текста", value.rounded(), plural(Int(value.rounded()), "страница", "страницы", "страниц"))
    }

    private func hours(_ value: Double) -> String {
        if value < 1 {
            let minutes = Int((value * 60).rounded())
            return "\(minutes) \(plural(minutes, "минуту", "минуты", "минут"))"
        }
        return String(format: "%.1f %@", value, plural(Int(value.rounded()), "час", "часа", "часов"))
    }

    private func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = n % 100
        if tens >= 11 && tens <= 14 { return many }
        switch n % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }
}

/// Проигрывает кусочек записи из копилки кандидатов.
///
/// Проигрыватель один на всех и переиспользуется: у AVAudioPlayer нет
/// надёжного признака «доиграл», а копить их по одному на нажатие значит
/// течь памятью.
@MainActor
private enum CandidateSound {
    private static var player: AVAudioPlayer?

    static func play(_ url: URL) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
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
                ForEach($store.config.replacements) { $item in
                    HStack(spacing: 8) {
                        TextField("верселе", text: $item.from)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("Vercel", text: $item.to)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            store.config.replacements.removeAll { $0.id == item.id }
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

            StatsView()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Горячие клавиши").font(.system(size: 12, weight: .semibold))
                shortcut("Держать \(HotkeyOption.named(Config.load().hotkey).title)", "запись, пока держишь")
                shortcut("Двойной тап", "запись до следующего тапа")
                shortcut("Escape во время записи", "отменить без вставки")
                shortcut("Правый ⌘ во время записи", "переключить: текст или звук")
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

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Разработчик").font(.system(size: 12, weight: .semibold))
                Text("Станислав Рочев").font(.system(size: 12))
                HStack(spacing: 12) {
                    Link("Телеграм", destination: URL(string: "https://t.me/starochev")!)
                    Link("Instagram", destination: URL(string: "https://instagram.com/starochev")!)
                }
                .font(.system(size: 11))
                Text("Пиши, если что-то не работает или чего-то не хватает.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
