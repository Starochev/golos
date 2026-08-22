import Foundation

/// Простой журнал в ~/Documents/Golos/golos.log.
/// Приложение живёт в строке меню без окон, поэтому без файла разбираться
/// в «почему ничего не происходит» нечем.
enum Log {
    private static let queue = DispatchQueue(label: "golos.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var fileURL: URL { Config.directory.appendingPathComponent("golos.log") }

    static func write(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: Config.directory, withIntermediateDirectories: true)

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                // Не даём журналу расти бесконечно.
                if (try? handle.seekToEnd()) ?? 0 > 512_000 {
                    try? data.write(to: fileURL)
                    return
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
