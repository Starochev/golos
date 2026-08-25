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

    /// Вторая клавиша: голосовое сообщение. Жестов у неё нет, только
    /// удержание — распознавать нечего, файл готов сразу после отпускания.
    enum VoiceEvent {
        case start
        case finish
        case cancel
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

    /// Какая клавиша слушается. Меняется на лету — перезапускать перехват
    /// ради этого не нужно.
    private var option: HotkeyOption = .fallback

    /// Клавиша голосового сообщения. nil — функция выключена.
    private var voiceOption: HotkeyOption?
    private var voiceHandler: ((VoiceEvent) -> Void)?
    private var voiceActive = false
    private var voiceDownAt: Date?

    func setOption(_ newOption: HotkeyOption) {
        guard newOption.id != option.id else { return }
        reset()
        option = newOption
        Log.write("клавиша записи: \(newOption.title)")
    }

    /// Одну клавишу на два дела не повесить: если совпала с клавишей записи,
    /// голосовое молча выключаем, диктовка важнее.
    func setVoiceOption(_ newOption: HotkeyOption?) {
        let resolved = (newOption?.id == option.id) ? nil : newOption
        guard resolved?.id != voiceOption?.id else { return }
        voiceActive = false
        voiceDownAt = nil
        voiceOption = resolved
        Log.write("клавиша голосового: \(resolved?.title ?? "выключена")")
    }

    func onVoice(_ handler: @escaping (VoiceEvent) -> Void) {
        voiceHandler = handler
    }

    /// Не запустится без разрешения «Универсальный доступ».
    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    @discardableResult
    func start(handler: @escaping (Event) -> Void) -> Bool {
        self.handler = handler
        guard tap == nil else { return true }

        // keyUp нужен для клавиш вроде F13: они, в отличие от модификаторов,
        // приходят обычными нажатиями, а не сменой флагов.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
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
        voiceActive = false
        voiceDownAt = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // Система глушит tap при перегрузке — поднимаем обратно.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let current = option

        if let voice = voiceOption, code == voice.keyCode {
            if let flagMask = voice.flagMask {
                if type == .flagsChanged {
                    let pressed = (event.flags.rawValue & flagMask) != 0
                    DispatchQueue.main.async { [weak self] in
                        pressed ? self?.voicePressed() : self?.voiceReleased()
                    }
                }
            } else if type == .keyDown {
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !repeated { DispatchQueue.main.async { [weak self] in self?.voicePressed() } }
            } else if type == .keyUp {
                DispatchQueue.main.async { [weak self] in self?.voiceReleased() }
            }
            return
        }

        // Обычная клавиша вроде F13 — приходит нажатиями, а не флагами.
        if !current.isModifier, code == current.keyCode {
            if type == .keyDown {
                // Удержание шлёт keyDown пачками — считаем только первый.
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !repeated { DispatchQueue.main.async { [weak self] in self?.keyPressed() } }
            } else if type == .keyUp {
                DispatchQueue.main.async { [weak self] in self?.keyReleased() }
            }
            return
        }

        if type == .keyDown {
            if code == Int64(kVK_Escape), voiceActive {
                DispatchQueue.main.async { [weak self] in self?.cancelVoice() }
                return
            }
            if code == Int64(kVK_Escape), toggleActive || holdActive {
                DispatchQueue.main.async { [weak self] in self?.cancelAll() }
                return
            }
            // Модификатор участвует в наборе спецсимволов (⌥+3 и подобное).
            // Раз при зажатой клавише пошёл обычный набор — это не диктовка,
            // запись сворачиваем молча. В режиме переключателя не мешаем:
            // там печатать во время записи может быть намеренно.
            if holdActive {
                DispatchQueue.main.async { [weak self] in self?.cancelAll() }
            }
            if voiceActive {
                DispatchQueue.main.async { [weak self] in self?.cancelVoice() }
            }
            return
        }

        guard type == .flagsChanged,
              current.isModifier,
              code == current.keyCode,
              let flagMask = current.flagMask
        else { return }

        let pressed = (event.flags.rawValue & flagMask) != 0
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

    private func voicePressed() {
        guard !voiceActive else { return }
        voiceActive = true
        voiceDownAt = Date()
        voiceHandler?(.start)
    }

    private func voiceReleased() {
        guard voiceActive, let downAt = voiceDownAt else { return }
        voiceActive = false
        voiceDownAt = nil
        // Случайный тычок не должен превращаться в сообщение на полсекунды.
        let held = Date().timeIntervalSince(downAt)
        voiceHandler?(held >= tapThreshold ? .finish : .cancel)
    }

    private func cancelVoice() {
        guard voiceActive else { return }
        voiceActive = false
        voiceDownAt = nil
        voiceHandler?(.cancel)
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
