import AppKit
import SwiftUI

/// Окно выбора модели: показывается при первом запуске и по пункту меню.
@MainActor
final class SetupWindow {
    private var window: NSWindow?
    private let onReady: (String) -> Void

    init(onReady: @escaping (String) -> Void) {
        self.onReady = onReady
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ModelPickerView(
            onChosen: { [weak self] path in
                self?.onReady(path)
                self?.close()
            },
            onClose: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Голос — модель распознавания"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 580, height: 660))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

private struct ModelPickerView: View {
    let onChosen: (String) -> Void
    let onClose: () -> Void

    @State private var selected: ModelInfo = ModelCatalog.recommended
    @State private var downloader = ModelDownloader()
    @State private var progress: ModelDownloader.Progress?
    /// Растёт после удаления: SwiftUI сама не узнает, что файла не стало.
    @State private var installedRevision = 0
    @State private var pendingDelete: ModelInfo?
    @State private var stage: String = ""
    @State private var error: String?

    private var isDownloading: Bool { progress != nil }

    /// Модель, на которой сейчас работает распознавание. Её удалять нельзя:
    /// приложение останется без движка посреди работы.
    private func inUse(_ model: ModelInfo) -> Bool {
        Config.load().modelPath == ModelCatalog.localURL(for: model).path
    }

    private func askToDelete(_ model: ModelInfo) {
        pendingDelete = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ModelCatalog.all) { model in
                        ModelCard(model: model,
                                  isSelected: selected.id == model.id,
                                  isInstalled: ModelCatalog.isInstalled(model),
                                  inUse: inUse(model),
                                  onDelete: { askToDelete(model) })
                            .onTapGesture { if !isDownloading { selected = model } }
                    }
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 580, height: 660)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Выбери модель распознавания")
                .font(.system(size: 16, weight: .semibold))
            Text("Модель качается один раз и работает на твоём Маке — записи никуда не отправляются. Поменять можно потом в меню.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stage)
                        .font(.system(size: 12))
                    ProgressView(value: progress.fraction)
                    HStack {
                        Text(bytesText(progress))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Отменить") {
                            downloader.cancel()
                            self.progress = nil
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button("Закрыть", action: onClose)
                    Button(ModelCatalog.isInstalled(selected) ? "Использовать" : "Скачать и использовать") {
                        choose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .id(installedRevision)
        .alert("Удалить модель?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { model in
            Button("Удалить", role: .destructive) {
                ModelCatalog.remove(model)
                installedRevision += 1
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: { model in
            Text("«\(model.title)» освободит \(model.sizeText). Скачать заново можно в любой момент, но это опять \(model.sizeText) из сети.")
        }
    }

    private func bytesText(_ p: ModelDownloader.Progress) -> String {
        let received = Double(p.receivedBytes) / 1_048_576
        let total = Double(p.totalBytes) / 1_048_576
        return total > 0
            ? String(format: "%.0f из %.0f МБ", received, total)
            : String(format: "%.0f МБ", received)
    }

    private func choose() {
        error = nil
        let destination = ModelCatalog.localURL(for: selected)

        if ModelCatalog.isInstalled(selected) {
            ensureVad { onChosen(destination.path) }
            return
        }

        stage = "Качаю \(selected.title) — \(selected.sizeText)"
        progress = .init(fraction: 0, receivedBytes: 0, totalBytes: selected.sizeBytes)
        downloader.download(
            from: selected.url,
            to: destination,
            onProgress: { progress = $0 },
            onFinish: { result in
                switch result {
                case .success:
                    ensureVad {
                        progress = nil
                        onChosen(destination.path)
                    }
                case .failure(let e):
                    progress = nil
                    error = "Не скачалось: \(e.localizedDescription)"
                }
            }
        )
    }

    /// Детектор речи весит меньше мегабайта — тянем молча, если его ещё нет.
    private func ensureVad(then finish: @escaping () -> Void) {
        let vad = ModelCatalog.directory.appendingPathComponent(ModelCatalog.vadFileName)
        guard !FileManager.default.fileExists(atPath: vad.path) else { finish(); return }

        stage = "Качаю детектор речи"
        progress = .init(fraction: 0, receivedBytes: 0, totalBytes: 840_000)
        let vadDownloader = ModelDownloader()
        vadDownloader.download(
            from: ModelCatalog.vadURL,
            to: vad,
            onProgress: { progress = $0 },
            // Без детектора речи работать можно, поэтому ошибку не показываем.
            onFinish: { _ in finish() }
        )
    }
}

private struct ModelCard: View {
    let model: ModelInfo
    let isSelected: Bool
    let isInstalled: Bool
    /// На этой модели сейчас работает распознавание.
    let inUse: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(model.title)
                    .font(.system(size: 14, weight: .semibold))
                if model.recommended {
                    Text("рекомендуется")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                if isInstalled {
                    Text("уже скачана")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                Text(model.sizeText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                if isInstalled {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(inUse ? Color.secondary.opacity(0.4) : Color.secondary)
                    .disabled(inUse)
                    .help(inUse
                          ? "На этой модели сейчас работает распознавание"
                          : "Удалить с диска, освободить \(model.sizeText)")
                }
            }

            Text(model.speedNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.pros, id: \.self) { line in
                    Label(line, systemImage: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                ForEach(model.cons, id: \.self) { line in
                    Label(line, systemImage: "minus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15))
        )
        .contentShape(Rectangle())
    }
}
