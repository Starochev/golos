import Foundation

/// Хранение записей: пережимает WAV в m4a, чтобы историю можно было держать
/// сутками, а не час.
///
/// Формат выбран ради двойного щелчка: m4a играет любой системный плеер,
/// а opus, хоть и вдвое меньше, macOS сама не откроет. Кодировщик системный,
/// доставлять ничего не надо.
enum History {
    /// Сколько запись лежит нетронутой, прежде чем её пережать.
    ///
    /// Свежие записи трогать нельзя: именно по ним разбираются жалобы
    /// «посмотри, он неправильно расшифровал», а m4a теряет часть звука,
    /// и тот же файл после пережатия распознаётся уже иначе. Полчаса хватает,
    /// чтобы человек успел заметить сбой и позвать разбираться.
    private static let untouchedMinutes: Double = 30

    /// Пережимает всё, что отлежалось. Свежие записи остаются как есть,
    /// чтобы сбой можно было воспроизвести на том самом звуке.
    static func compressLeftovers() {
        let dir = Config.directory.appendingPathComponent("history")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let deadline = Date().addingTimeInterval(-untouchedMinutes * 60)
        for file in files where file.pathExtension == "wav" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if modified < deadline { compress(file) }
        }
    }

    /// Пережимает и удаляет исходник. Ошибка не страшна: остаётся WAV.
    static func compress(_ wavURL: URL) {
        DispatchQueue.global(qos: .utility).async {
            let target = wavURL.deletingPathExtension().appendingPathExtension("m4a")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "m4af", "-d", "aac", "-b", "32000",
                                 wavURL.path, target.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do { try process.run() } catch { return }
            process.waitUntilExit()

            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
            guard process.terminationStatus == 0, (size ?? 0) > 0 else {
                try? FileManager.default.removeItem(at: target)
                return
            }
            try? FileManager.default.removeItem(at: wavURL)
        }
    }
}
