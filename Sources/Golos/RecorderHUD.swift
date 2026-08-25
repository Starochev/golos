import AppKit
import SwiftUI

/// Всплывающее окошко с живой волной во время записи.
///
/// Панель принципиально не активирующая: приложение вставляет текст в то окно,
/// которое было активным, и кража фокуса сломала бы главный сценарий. Мышь она
/// при этом принимает — переключателем выбирают, чем отдать надиктованное.
/// Одно другому не мешает: nonactivatingPanel не поднимает приложение,
/// а ключевым окно не становится, потому что borderless-панель на это
/// не претендует.
@MainActor
final class RecorderHUD {
    enum Phase: Equatable { case recording, transcribing, message(String) }

    /// Чем отдать запись: текстом в активное поле или звуком в буфер.
    enum Mode { case text, audio }

    private var panel: NSPanel?
    private let model = HUDModel()
    private var levelTimer: Timer?
    private var levelSource: (() -> Float)?
    /// Номер показа. Затухание прячет панель не сразу, и без этого счётчика
    /// отложенный orderOut убирал бы окно, показанное уже для новой записи.
    private var generation = 0

    /// Показать выбранный режим. Хозяин режима не окошко, а контроллер:
    /// выбирать можно и с выключенным окошком, тогда режим видно по значку
    /// в строке меню.
    func setMode(_ mode: Mode) {
        model.setQuietly(mode)
    }

    /// Щёлкнули по переключателю мышью.
    var onModeChange: ((Mode) -> Void)?

    /// Показать окошко и начать опрашивать громкость.
    func show(color: NSColor, mode: Mode, levelSource: @escaping () -> Float) {
        generation += 1
        self.levelSource = levelSource
        model.color = Color(color)
        model.onPill = RecorderHUD.contrastColor(for: color)
        model.setQuietly(mode)
        model.onChange = { [weak self] in self?.onModeChange?($0) }
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

    /// Короткая надпись вместо волны: «Пакую…», потом «В буфере».
    /// Без неё непонятно, сработало ли: сигнал конца записи одинаков
    /// и для текста, и для звука.
    func showMessage(_ text: String, hideAfter: TimeInterval? = nil) {
        levelTimer?.invalidate()
        levelTimer = nil
        model.phase = .message(text)
        guard let hideAfter else { return }
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.hide()
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 108),
            // nonactivatingPanel — то самое, что не даёт увести фокус.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // Мышь нужна переключателю. Фокус при этом не уезжает: панель
        // не активирующая и ключевой не становится.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = ClickableHostingView(rootView: HUDView(model: model))
        self.panel = panel
    }

    /// Белую волну не подписать белым по ней же. Считаем яркость и берём
    /// тот цвет надписи, который на этой пилюле будет видно.
    private static func contrastColor(for color: NSColor) -> Color {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? Color.black.opacity(0.85) : Color.white
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

/// Окно не может стать ключевым, и по умолчанию первый щелчок по такому
/// окну съедается системой. Переключателю это не годится: щелчок у него
/// всегда первый, второго человек делать не станет.
private final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class HUDModel: ObservableObject {
    @Published var levels: [CGFloat]
    @Published var phase: RecorderHUD.Phase = .recording
    @Published var color: Color = .white
    /// Цвет надписи на пилюле переключателя, подобранный под цвет волны.
    @Published var onPill: Color = .white
    @Published var mode: RecorderHUD.Mode = .text {
        didSet { if mode != oldValue, reporting { onChange?(mode) } }
    }
    /// Сообщать наружу только о щелчках мышью: смена из контроллера
    /// вернулась бы обратно и закольцевалась.
    var onChange: ((RecorderHUD.Mode) -> Void)?
    private var reporting = true
    /// Управляет появлением и уходом: содержимое растёт из центра.
    @Published var visible: Bool = false

    private let count = 34
    private var tick: CGFloat = 0

    init() {
        levels = Array(repeating: 0.06, count: 34)
    }

    /// Поставить режим, не рассказывая об этом наружу.
    func setQuietly(_ value: RecorderHUD.Mode) {
        reporting = false
        mode = value
        reporting = true
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
                VStack(spacing: 9) {
                    waveform
                    modeSwitch
                }
            case .transcribing:
                note("Распознаю…", pulsing: true)
            case .message(let text):
                note(text, pulsing: false)
            }
        }
        .frame(width: 260, height: 108)
        .scaleEffect(model.visible ? 1 : 0.86)
        .opacity(model.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.28), value: model.visible)
    }

    private var waveform: some View {
        HStack(spacing: 3.5) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(model.color.opacity(0.95))
                    .frame(width: 4, height: max(4, level * 40))
                    .shadow(color: model.color.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 42)
        .animation(.linear(duration: 0.05), value: model.levels)
    }

    /// Переключатель «Текст или Звук». Пилюля переезжает с пружиной,
    /// чтобы движение читалось как переключение, а не как перерисовка.
    private var modeSwitch: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.09))

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.color.opacity(0.92))
                .shadow(color: model.color.opacity(0.55), radius: 5)
                .frame(width: 74, height: 22)
                .offset(x: model.mode == .text ? 2 : 76)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: model.mode)

            HStack(spacing: 0) {
                label("Текст", .text)
                label("Звук", .audio)
            }
        }
        .frame(width: 152, height: 26)
    }

    private func label(_ title: String, _ mode: RecorderHUD.Mode) -> some View {
        let chosen = model.mode == mode
        return Text(title)
            .font(.system(size: 11, weight: chosen ? .semibold : .regular))
            .foregroundStyle(chosen ? model.onPill : Color.white.opacity(0.5))
            .frame(width: 76, height: 26)
            .contentShape(Rectangle())
            .onTapGesture { model.mode = mode }
            .animation(.easeOut(duration: 0.2), value: model.mode)
    }

    private func note(_ text: String, pulsing: Bool) -> some View {
        HStack(spacing: 8) {
            if pulsing {
                PulsingDot(color: model.color)
            } else {
                Circle()
                    .fill(model.color.opacity(0.9))
                    .frame(width: 8, height: 8)
                    .shadow(color: model.color.opacity(0.7), radius: 5)
            }
            Text(text)
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
