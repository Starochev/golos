import AppKit
import SwiftUI

/// Всплывающее окошко с живой волной во время записи.
///
/// Панель принципиально не активирующая и не принимающая мышь: приложение
/// вставляет текст в то окно, которое было активным, и любая кража фокуса
/// сломала бы главный сценарий.
@MainActor
final class RecorderHUD {
    enum Phase { case recording, transcribing }

    private var panel: NSPanel?
    private let model = HUDModel()
    private var levelTimer: Timer?
    private var levelSource: (() -> Float)?
    /// Номер показа. Затухание прячет панель не сразу, и без этого счётчика
    /// отложенный orderOut убирал бы окно, показанное уже для новой записи.
    private var generation = 0

    /// Показать окошко и начать опрашивать громкость.
    func show(color: NSColor, levelSource: @escaping () -> Float) {
        generation += 1
        self.levelSource = levelSource
        model.color = Color(color)
        model.reset()
        model.phase = .recording
        ensurePanel()
        position()
        appear()

        levelTimer?.invalidate()
        // 30 кадров в секунду: глазу достаточно, процессору незаметно.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.model.push(CGFloat(self.levelSource?() ?? 0))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// Запись кончилась, идёт распознавание — волна замирает.
    func markTranscribing() {
        levelTimer?.invalidate()
        levelTimer = nil
        model.phase = .transcribing
    }

    func hide() {
        levelTimer?.invalidate()
        levelTimer = nil
        guard let panel else { return }

        let hiding = generation
        model.visible = false

        // Окно убираем после того, как содержимое ужалось и погасло.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            // За это время могла начаться новая запись — тогда прятать уже
            // нечего, панель принадлежит ей.
            guard let self, self.generation == hiding else { return }
            panel.orderOut(nil)
        }
    }

    /// Появление: содержимое подрастает из центра и проявляется.
    ///
    /// Масштабируется именно содержимое, а не окно. У окна фиксированный
    /// размер, и его рост просто открывал бы вид на неподвижную картинку —
    /// получилось бы выезжание, а не масштаб.
    private func appear() {
        guard let panel else { return }
        model.visible = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Даём кадр на отрисовку в сжатом виде, иначе анимации нечего играть.
        DispatchQueue.main.async { [weak self] in
            self?.model.visible = true
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 70),
            // nonactivatingPanel — то самое, что не даёт увести фокус.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        self.panel = panel
    }

    /// Снизу по центру того экрана, где сейчас курсор.
    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + 110))
    }

}

@MainActor
private final class HUDModel: ObservableObject {
    @Published var levels: [CGFloat]
    @Published var phase: RecorderHUD.Phase = .recording
    @Published var color: Color = .white
    /// Управляет появлением и уходом: содержимое растёт из центра.
    @Published var visible: Bool = false

    private let count = 34
    private var tick: CGFloat = 0

    init() {
        levels = Array(repeating: 0.06, count: 34)
    }

    func reset() {
        levels = Array(repeating: 0.06, count: count)
        tick = 0
    }

    /// Лента едет справа налево: свежая громкость приходит в правый край.
    func push(_ level: CGFloat) {
        tick += 1

        // В тишине полоски не замирают в ноль, а еле заметно дышат — иначе
        // окошко выглядит сломанным, пока человек набирает воздух.
        let idle = 0.05 + 0.03 * sin(tick * 0.28)
        let target = max(idle, min(1, level))

        // Сглаживание: без него полосы дёргаются рывками.
        let previous = levels.last ?? idle
        levels.removeFirst()
        levels.append(previous * 0.3 + target * 0.7)
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.95))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)

            switch model.phase {
            case .recording:
                waveform
            case .transcribing:
                transcribing
            }
        }
        .frame(width: 260, height: 70)
        .scaleEffect(model.visible ? 1 : 0.86)
        .opacity(model.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.28), value: model.visible)
    }

    private var waveform: some View {
        HStack(spacing: 3.5) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(model.color.opacity(0.95))
                    .frame(width: 4, height: max(4, level * 44))
                    .shadow(color: model.color.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 46)
        .animation(.linear(duration: 0.05), value: model.levels)
    }

    private var transcribing: some View {
        HStack(spacing: 8) {
            PulsingDot(color: model.color)
            Text("Распознаю…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// Точка, которая дышит, пока идёт распознавание.
private struct PulsingDot: View {
    let color: Color
    @State private var big = false

    var body: some View {
        Circle()
            .fill(color.opacity(0.9))
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: 5)
            .scaleEffect(big ? 1.35 : 0.75)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: big)
            .onAppear { big = true }
    }
}
