import AppKit
import Carbon.HIToolbox

/// Слушает правый Option и различает два жеста одним хоткеем:
/// удержание — рация (пишем, пока держишь), двойной тап — переключатель.
/// Escape во время записи отменяет её без вставки.
final class Hotkey {
    enum Event {
        case startHold      // клавишу зажали, пошла запись «рацией»
        case finishHold     // отпустили после долгого удержания — распознать
        case toggleOn       // двойной тап — запись до следующего тапа
        case toggleOff      // ещё один тап — распознать
        case cancel         // Escape
        case discard        // одиночный короткий тап — записанное выбросить
    }

    /// Короче этого удержание считается тапом, а не рацией.
    private let tapThreshold: TimeInterval = 0.4
    /// Окно, внутри которого второй тап образует двойной.
    private let doubleTapWindow: TimeInterval = 0.35

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: ((Event) -> Void)?

    private var keyDownAt: Date?
    private var pendingDiscard: DispatchWorkItem?
    private var toggleActive = false
    private var holdActive = false

    /// Правый Option: в flagsChanged приходит keyCode 61 и свой бит в маске.
    private let rightOptionKeyCode: Int64 = 61
    private let rightOptionMask: UInt64 = 0x00000040

    /// Не запустится без разрешения «Универсальный доступ».
    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    @discardableResult
    func start(handler: @escaping (Event) -> Void) -> Bool {
        self.handler = handler
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let this = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: this
        ) else { return false }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        runLoopSource = nil
    }

    /// Сообщить хоткею, что запись закончилась не по клавише (через меню).
    func reset() {
        pendingDiscard?.cancel()
        pendingDiscard = nil
        toggleActive = false
        holdActive = false
        keyDownAt = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // Система глушит tap при перегрузке — поднимаем обратно.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Int64(kVK_Escape), toggleActive || holdActive {
                DispatchQueue.main.async { [weak self] in self?.cancelAll() }
                return
            }
            // Правый ⌥ участвует в наборе спецсимволов (⌥+3 и подобное).
            // Раз при зажатой клавише пошёл обычный набор — это не диктовка,
            // запись сворачиваем молча. В режиме переключателя не мешаем:
            // там печатать во время записи может быть намеренно.
            if holdActive {
                DispatchQueue.main.async { [weak self] in self?.cancelAll() }
            }
            return
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == rightOptionKeyCode
        else { return }

        let pressed = (event.flags.rawValue & rightOptionMask) != 0
        DispatchQueue.main.async { [weak self] in
            pressed ? self?.keyPressed() : self?.keyReleased()
        }
    }

    private func cancelAll() {
        pendingDiscard?.cancel()
        pendingDiscard = nil
        toggleActive = false
        holdActive = false
        keyDownAt = nil
        handler?(.cancel)
    }

    private func keyPressed() {
        // Идёт запись «переключателем» — этот тап её завершает.
        if toggleActive {
            toggleActive = false
            keyDownAt = nil
            handler?(.toggleOff)
            return
        }

        // Второй тап внутри окна: одиночный тап уже успел запустить запись,
        // остаётся отменить её выброс и перевести в режим переключателя.
        if let pending = pendingDiscard {
            pending.cancel()
            pendingDiscard = nil
            toggleActive = true
            keyDownAt = nil
            handler?(.toggleOn)
            return
        }

        keyDownAt = Date()
        holdActive = true
        handler?(.startHold)
    }

    private func keyReleased() {
        guard holdActive, let downAt = keyDownAt else { return }
        holdActive = false
        keyDownAt = nil

        let held = Date().timeIntervalSince(downAt)
        if held >= tapThreshold {
            handler?(.finishHold)
            return
        }

        // Короткий тап: ждём напарника. Не пришёл — записанное выбрасываем.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDiscard = nil
            self.handler?(.discard)
        }
        pendingDiscard = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
    }
}
