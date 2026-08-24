import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Окно расшифровки файлов: перетащил запись встречи — получил текст
/// с тайм-кодами рядом с ней.
@MainActor
final class TranscribeWindow {
    private var window: NSWindow?
    private let model: TranscribeModel

    init(makeTranscriber: @escaping () -> FileTranscriber?, currentConfig: @escaping () -> Config) {
        model = TranscribeModel(makeTranscriber: makeTranscriber, currentConfig: currentConfig)
    }

    /// Поставить файлы в очередь снаружи: из аргументов запуска или
    /// из «Открыть с помощью» в Finder.
    func enqueue(_ urls: [URL]) {
        show()
        model.add(urls)
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: TranscribeView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Расшифровка файла"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class TranscribeModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status: Status = .waiting
        var progress: Double = 0
        var note: String = ""
        var result: FileTranscriber.Result?

        enum Status { case waiting, reading, recognizing, done, failed }
    }

    @Published var items: [Item] = []
    @Published var isRunning = false

    private let makeTranscriber: () -> FileTranscriber?
    private let currentConfig: () -> Config
    private var transcriber: FileTranscriber?

    init(makeTranscriber: @escaping () -> FileTranscriber?, currentConfig: @escaping () -> Config) {
        self.makeTranscriber = makeTranscriber
        self.currentConfig = currentConfig
    }

    var outputHint: String {
        let folder = currentConfig().fileOutputFolder.trimmingCharacters(in: .whitespaces)
        return folder.isEmpty
            ? "Расшифровка ляжет рядом с исходным файлом"
            : "Расшифровка ляжет в \(folder)"
    }

    func add(_ urls: [URL]) {
        let fresh = urls.filter { url in
            MediaDecoder.supportedExtensions.contains(url.pathExtension.lowercased())
                && !items.contains { $0.url == url }
        }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh.map { Item(url: $0) })
        runNext()
    }

    func cancel() {
        transcriber?.cancel()
        isRunning = false
    }

    private func runNext() {
        guard !isRunning,
              let index = items.firstIndex(where: { $0.status == .waiting }) else { return }
        guard let transcriber = makeTranscriber() else {
            items[index].status = .failed
            items[index].note = "Распознавание ещё не готово"
            return
        }

        self.transcriber = transcriber
        isRunning = true
        items[index].status = .reading

        transcriber.transcribe(url: items[index].url, config: currentConfig()) { [weak self] progress in
            guard let self, index < self.items.count else { return }
            self.items[index].progress = progress.fraction
            self.items[index].status = progress.stage == .reading ? .reading : .recognizing
        } onFinish: { [weak self] result in
            guard let self, index < self.items.count else { return }
            switch result {
            case .success(let value):
                self.items[index].status = .done
                self.items[index].progress = 1
                self.items[index].result = value
                self.items[index].note = "\(value.segments) отрезков, \(Self.length(value.duration))"
            case .failure(let error):
                self.items[index].status = .failed
                self.items[index].note = (error is CancellationError)
                    ? "Отменено"
                    : error.localizedDescription
            }
            self.isRunning = false
            self.runNext()
        }
    }

    static func length(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d ч %02d мин", total / 3600, (total % 3600) / 60)
            : String(format: "%d мин %02d с", total / 60, total % 60)
    }
}

private struct TranscribeView: View {
    @ObservedObject var model: TranscribeModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropArea
            Text(model.outputHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !model.items.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.items) { item in ItemRow(item: item) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 460)
    }

    private var dropArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            Text("Перетащи сюда запись встречи или созвона")
                .font(.system(size: 13, weight: .medium))
            Text("Видео и звук: mp4, mov, m4a, mp3, wav и остальное, что читает система")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Выбрать файл…") { choose() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(targeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
        )
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            load(providers)
            return true
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.add(urls) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav]
        if panel.runModal() == .OK { model.add(panel.urls) }
    }
}

private struct ItemRow: View {
    let item: TranscribeModel.Item

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if item.status == .reading || item.status == .recognizing {
                    ProgressView(value: item.progress)
                        .frame(height: 4)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(item.status == .failed ? .red : .secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let result = item.result {
                Button("Показать") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.textFile])
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var icon: String {
        switch item.status {
        case .waiting: return "clock"
        case .reading: return "waveform"
        case .recognizing: return "text.bubble"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var subtitle: String {
        switch item.status {
        case .waiting: return "В очереди"
        case .reading: return "Достаю звук — \(Int(item.progress * 100))%"
        case .recognizing: return "Распознаю — \(Int(item.progress * 100))%"
        case .done, .failed: return item.note
        }
    }
}
