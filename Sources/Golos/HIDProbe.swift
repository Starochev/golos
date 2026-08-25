import Foundation
import IOKit.hid

/// Разведка сырых HID-устройств: что присылает железка, у которой своя,
/// не стандартная страница применения.
///
/// Приёмник RODE Wireless PRO виден системе как HID-устройство, но страница
/// у него вендорская (0xFF00), и в медиаклавиши система её не превращает.
/// Значит, если кнопка на передатчике вообще докладывает о себе хосту,
/// увидеть это можно только сырыми отчётами.
///
/// Запускается ключом `--probe-hid` и пишет в журнал каждый отчёт побайтно.
enum HIDProbe {
    private static var manager: IOHIDManager?
    private static var buffers: [UnsafeMutablePointer<UInt8>] = []
    private static let reportSize = 64

    /// Имена устройств по адресу: в обработчик отчёта контекст не передать,
    /// он должен быть чистой функцией без замыкания.
    private static var names: [UnsafeRawPointer: String] = [:]
    /// Последний отчёт по каждой паре «устройство и номер отчёта».
    private static var previous: [String: [UInt8]] = [:]
    /// Байты, которые и без нажатий всё время меняются: счётчики, время,
    /// уровень сигнала. Их шевеление ничего не значит.
    private static var volatileBytes: [String: Set<Int>] = [:]
    /// До этого момента только смотрим, что шевелится само по себе.
    private static var calibrationEnds = Date()

    /// Сырой поток пишем в файл целиком: фильтр может не заметить кнопку,
    /// если её признак сидит в байте, который и так всё время меняется.
    /// Файл потом разбирается по секундам, когда известно, когда жали.
    private static var dump: FileHandle?
    private static let dumpURL = Config.directory.appendingPathComponent("hid-dump.txt")
    private static var started = Date()

    static func start(seconds: Double) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Без фильтра: интересно всё, что не клавиатура и не мышь.
        IOHIDManagerSetDeviceMatching(manager, nil)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
            HIDProbe.attach(device)
        }, nil)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        HIDProbe.manager = manager

        if status != kIOReturnSuccess {
            Log.write(String(format: "HID: открыть не дали, код 0x%08X. Скорее всего нужно разрешение «Мониторинг ввода»", status))
            return
        }
        // Первые пять секунд молчим и запоминаем, что шевелится само.
        calibrationEnds = Date().addingTimeInterval(5)
        started = Date()
        FileManager.default.createFile(atPath: dumpURL.path, contents: nil)
        dump = try? FileHandle(forWritingTo: dumpURL)
        Log.write("HID: пять секунд слушаю тишину, потом жми кнопки на передатчике")

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { stop() }
    }

    static func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        buffers.forEach { $0.deallocate() }
        buffers.removeAll()
        try? dump?.close()
        dump = nil
        Log.write("HID: закончил слушать, сырой поток в \(dumpURL.path)")
    }

    private static func attach(_ device: IOHIDDevice) {
        let name = string(device, kIOHIDProductKey) ?? "без имени"
        let page = number(device, kIOHIDPrimaryUsagePageKey) ?? -1
        let vendor = number(device, kIOHIDVendorIDKey) ?? -1
        let product = number(device, kIOHIDProductIDKey) ?? -1

        // Клавиатуру и мышь пропускаем: их отчёты завалят журнал, а нам
        // интересны железки со своей страницей.
        guard page != 1 && page != 7 else { return }

        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.write(String(format: "HID: устройство «%@» (vendor %d, product %d, страница %d) — %@",
                         name, vendor, product, page,
                         opened == kIOReturnSuccess ? "слушаю" : String(format: "открыть не дали, 0x%08X", opened)))
        guard opened == kIOReturnSuccess else { return }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
        buffers.append(buffer)
        // В подпись кладём и номера: имён у половины железок нет, а различать
        // их в дампе надо.
        let label = "\(name) [\(vendor):\(product), стр. \(page)]"
        if let raw = UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque()) as UnsafeRawPointer? {
            names[raw] = label
        }

        IOHIDDeviceRegisterInputReportCallback(device, buffer, reportSize, { _, _, sender, _, reportID, report, length in
            let owner = sender.flatMap { HIDProbe.names[UnsafeRawPointer($0)] } ?? "?"
            let key = "\(owner)#\(reportID)"
            let current = (0..<Int(length)).map { report[$0] }
            HIDProbe.consider(key: key, owner: owner, reportID: reportID, bytes: current)
        }, nil)
    }

    /// Решает, стоит ли писать отчёт в журнал.
    ///
    /// Пишем только тогда, когда изменился байт, который во время калибровки
    /// стоял на месте. Иначе журнал забьёт поток телеметрии: приёмник шлёт
    /// счётчик и уровень сигнала десять раз в секунду.
    static func consider(key: String, owner: String, reportID: UInt32, bytes: [UInt8]) {
        // В файл пишем всё подряд, с меткой времени от старта.
        if let dump {
            let stamp = String(format: "%7.3f", Date().timeIntervalSince(started))
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let line = "\(stamp) \(owner) #\(reportID) \(hex)\n"
            if let data = line.data(using: .utf8) { try? dump.write(contentsOf: data) }
        }

        defer { previous[key] = bytes }
        guard let old = previous[key], old.count == bytes.count else { return }

        var changed = Set<Int>()
        for i in 0..<bytes.count where bytes[i] != old[i] { changed.insert(i) }
        guard !changed.isEmpty else { return }

        if Date() < calibrationEnds {
            volatileBytes[key, default: []].formUnion(changed)
            return
        }

        let interesting = changed.subtracting(volatileBytes[key] ?? [])
        guard !interesting.isEmpty else { return }

        let dump = interesting.sorted().map { i in
            String(format: "байт %d: %02X → %02X", i, old[i], bytes[i])
        }
        Log.write("HID: «\(owner)» отчёт \(reportID) — \(dump.joined(separator: ", "))")
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func number(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }
}
