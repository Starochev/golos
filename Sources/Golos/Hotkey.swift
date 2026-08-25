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
        case flipMode       // вторая клавиша во время записи — сменить режим
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

    /// Вторая клавиша записи. Работает наравне с основной: провод гарнитуры
    /// не всегда под рукой, а менять настройку ради каждого случая — дичь.
    private var secondOption: HotkeyOption?

    /// Обе клавиши записи. Порядок важен только для поиска совпадения.
    private var recordKeys: [HotkeyOption] { [option, secondOption].compactMap { $0 } }

    /// Какая клавиша начала текущий жест. Вторая в чужой жест не лезет.
    private var activeKeyID: String?

    /// Клавиша, которая во время записи переключает «текст или звук».
    /// Ничего не запускает и не останавливает, поэтому и настройки под неё нет:
    /// правый ⌘ рядом с правым ⌥, дотягивается большим пальцем той же руки.
    /// Если запись и так на правом ⌘, меняемся местами.
    /// Берём первый свободный модификатор: занятый под запись не годится.
    private var modeKey: HotkeyOption {
        let taken = Set(recordKeys.map(\.id))
        let order = ["rightCommand", "rightOption", "rightControl", "rightShift"]
        return HotkeyOption.named(order.first { !taken.contains($0) } ?? "rightCommand")
    }


    func setOption(_ newOption: HotkeyOption) {
        guard newOption.id != option.id else { return }
        reset()
        option = newOption
        if secondOption?.id == newOption.id { secondOption = nil }
        Log.write("клавиша записи: \(newOption.title)")
    }

    /// Вторая клавиша. nil — выключена. Совпасть с основной не может.
    func setSecondOption(_ newOption: HotkeyOption?) {
        let resolved = (newOption?.id == option.id) ? nil : newOption
        guard resolved?.id != secondOption?.id else { return }
        reset()
        secondOption = resolved
        Log.write("вторая клавиша записи: \(resolved?.title ?? "выключена")")
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
        // Тип 14 — системные события: кнопки пульта на проводе гарнитуры
        // и медиаклавиши клавиатуры. Своей константы у него в CGEventType нет.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << 14)
        let this = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Активный перехват: кнопку гарнитуры надо проглотить, иначе она
            // заодно поставит музыку на паузу или изменит громкость.
            // Всё остальное пропускается как было.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
                let swallow = me.handle(type: type, event: event)
                return swallow ? nil : Unmanaged.passUnretained(event)
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
        activeKeyID = nil
    }

    /// Возвращает true, если событие надо проглотить.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Система глушит tap при перегрузке — поднимаем обратно.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        if type.rawValue == 14 { return handleMedia(event) }

        let code = event.getIntegerValueField(.keyboardEventKeycode)

        // Обычная клавиша вроде F13 — приходит нажатиями, а не флагами.
        if type == .keyDown || type == .keyUp,
           let hit = recordKeys.first(where: { !$0.isModifier && !$0.isMedia && $0.keyCode == code }) {
            if type == .keyDown {
                // Удержание шлёт keyDown пачками — считаем только первый.
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !repeated { DispatchQueue.main.async { [weak self] in self?.keyPressed(from: hit.id) } }
            } else {
                DispatchQueue.main.async { [weak self] in self?.keyReleased(from: hit.id) }
            }
            return false
        }

        if type == .flagsChanged {
            // Смена режима: только пока идёт запись, только на нажатие.
            if holdActive || toggleActive, code == modeKey.keyCode, let mask = modeKey.flagMask,
               (event.flags.rawValue & mask) != 0 {
                DispatchQueue.main.async { [weak self] in self?.handler?(.flipMode) }
                return false
            }

            if let hit = recordKeys.first(where: { $0.isModifier && $0.keyCode == code }),
               let flagMask = hit.flagMask {
                let pressed = (event.flags.rawValue & flagMask) != 0
                DispatchQueue.main.async { [weak self] in
                    pressed ? self?.keyPressed(from: hit.id) : self?.keyReleased(from: hit.id)
                }
            }
            return false
        }

        if type == .keyDown {
            if code == Int64(kVK_Escape), toggleActive || holdActive {
                DispatchQueue.main.async { [weak self] in self?.cancelAll() }
                return false
            }
            // Модификатор участвует в наборе спецсимволов (⌥+3 и подобное).
            // Раз при зажатой клавише пошёл обычный набор — это не диктовка,
            // запись сворачиваем молча. В режиме переключателя не мешаем:
            // там печатать во время записи может быть намеренно.
            if holdActive {
                DispatchQueue.main.async { [weak self] in self?.cancelAll() }
            }
        }
        return false
    }

    /// Кнопки на проводе гарнитуры и медиаклавиши клавиатуры.
    ///
    /// Приходят системным событием: в data1 упакованы код кнопки и её
    /// состояние. Своё событие глотаем — иначе центральная кнопка заодно
    /// поставит музыку на паузу, а боковые изменят громкость.
    ///
    /// Двойного тапа у этих кнопок не будет: быстрое двойное нажатие система
    /// сама превращает в «следующий трек» и присылает уже другой код.
    /// Остаётся удержание, ради которого всё и затевалось.
    private func handleMedia(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }

        let data = ns.data1
        let code = Int((data & 0xFFFF_0000) >> 16)
        guard let hit = recordKeys.first(where: { $0.mediaCode == code }) else { return false }

        let flags = data & 0x0000_FFFF
        let pressed = ((flags & 0xFF00) >> 8) == 0x0A
        // Отпускание не нужно: у кнопки пульта жест другой, см. mediaPressed.
        if pressed { DispatchQueue.main.async { [weak self] in self?.mediaPressed(from: hit.id) } }
        return true
    }

    /// Кнопка пульта работает переключателем, а не рацией, и это не прихоть.
    ///
    /// На четырёхконтактном проводе кнопка устроена так, что пока её держат,
    /// микрофонная линия замкнута и микрофон молчит. Замерено: три записи
    /// подряд с зажатой кнопкой дали пик ровно 0.0000, а та же гарнитура
    /// с клавиши на клавиатуре пишет нормально.
    ///
    /// Поэтому: нажал — пошла запись, нажал ещё раз — закончилась. Между
    /// нажатиями кнопка отпущена, и микрофон слышит.
    private func mediaPressed(from id: String) {
        if let active = activeKeyID, active != id { return }

        if toggleActive {
            toggleActive = false
            activeKeyID = nil
            handler?(.toggleOff)
        } else {
            toggleActive = true
            activeKeyID = id
            handler?(.toggleOn)
        }
    }

    private func cancelAll() {
        pendingDiscard?.cancel()
        pendingDiscard = nil
        toggleActive = false
        holdActive = false
        keyDownAt = nil
        activeKeyID = nil
        handler?(.cancel)
    }

    private func keyPressed(from id: String) {
        // Чужой жест не перебиваем: одна запись за раз.
        if let active = activeKeyID, active != id { return }
        activeKeyID = id

        // Идёт запись «переключателем» — этот тап её завершает.
        if toggleActive {
            toggleActive = false
            keyDownAt = nil
            activeKeyID = nil
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

    private func keyReleased(from id: String) {
        guard activeKeyID == id else { return }
        guard holdActive, let downAt = keyDownAt else { return }
        holdActive = false
        keyDownAt = nil

        let held = Date().timeIntervalSince(downAt)
        if held >= tapThreshold {
            activeKeyID = nil
            handler?(.finishHold)
            return
        }

        // Короткий тап: ждём напарника. Не пришёл — записанное выбрасываем.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDiscard = nil
            self.activeKeyID = nil
            self.handler?(.discard)
        }
        pendingDiscard = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
    }
}
