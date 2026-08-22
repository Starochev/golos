import AppKit
import Carbon.HIToolbox

/// Доставляет готовый текст в активное поле ввода.
enum Inserter {
    enum Mode: String {
        case paste       // подменить буфер, нажать Cmd+V, буфер вернуть
        case type        // набрать посимвольно, буфер не трогать
        case clipboard   // только положить в буфер
    }

    static func insert(_ text: String, mode: Mode) {
        guard !text.isEmpty else { return }
        switch mode {
        case .clipboard:
            copyOnly(text)
        case .type:
            typeText(text)
        case .paste:
            pasteViaClipboard(text)
        }
    }

    private static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Схема superwhisper: сохранить содержимое буфера, подставить своё,
    /// синтезировать Cmd+V, вернуть как было.
    private static func pasteViaClipboard(_ text: String) {
        let pb = NSPasteboard.general
        let saved = snapshot(of: pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        postCommandV()

        // Вернуть буфер сразу нельзя: приложение-получатель читает его асинхронно.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            restore(saved, to: pb)
        }
    }

    /// Снимок буфера: у одного элемента бывает несколько представлений
    /// (текст, RTF, картинка) — сохраняем все, иначе вернём обеднённое.
    private static func snapshot(of pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var repr: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { repr[type] = data }
            }
            return repr
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { repr in
            let item = NSPasteboardItem()
            for (type, data) in repr { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Не даём зажатым модификаторам (правый Option от хоткея) просочиться в Cmd+V.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Прямой ввод юникода в фокус. Буфер не трогается, но длинный текст
    /// печатается заметно и часть приложений глотает символы.
    private static func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Порциями по 20 UTF-16 единиц: больше за одно событие система не берёт.
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 20, units.count)
            var chunk = Array(units[index..<end])
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
            index = end
            usleep(1500)
        }
    }
}
