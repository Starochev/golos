import Foundation

/// Описание модели распознавания для окна выбора.
struct ModelInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let sizeBytes: Int64
    let speedNote: String
    let pros: [String]
    let cons: [String]
    let recommended: Bool

    var fileName: String { "ggml-\(id).bin" }

    var url: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var sizeText: String {
        let gb = Double(sizeBytes) / 1_073_741_824
        return gb < 1
            ? String(format: "%.0f МБ", Double(sizeBytes) / 1_048_576)
            : String(format: "%.1f ГБ", gb)
    }
}

enum ModelCatalog {
    /// Размеры сверены с HuggingFace, замеры скорости — на десяти секундах речи.
    static let all: [ModelInfo] = [
        ModelInfo(
            id: "large-v3",
            title: "Large v3",
            sizeBytes: 3_094_623_691,
            speedNote: "около 1 секунды на 10 секунд речи",
            pros: [
                "Лучшее качество русского из доступных",
                "Англицизмы почти всегда пишет латиницей, а не транслитом",
                "На современном Маке всё равно быстрая"
            ],
            cons: [
                "Занимает почти 3 ГБ на диске",
                "Держит около 3 ГБ памяти, пока приложение запущено"
            ],
            recommended: true
        ),
        ModelInfo(
            id: "large-v3-turbo",
            title: "Large v3 Turbo",
            sizeBytes: 1_624_555_275,
            speedNote: "около 0.35 секунды на 10 секунд речи",
            pros: [
                "Втрое быстрее большой модели",
                "Вдвое меньше места и памяти"
            ],
            cons: [
                "Чаще мажет по редким именам и терминам",
                "Словарь замен понадобится длиннее"
            ],
            recommended: false
        ),
        ModelInfo(
            id: "medium",
            title: "Medium",
            sizeBytes: 1_533_763_059,
            speedNote: "около 1.5 секунды на 10 секунд речи",
            pros: [
                "Умеренный расход памяти"
            ],
            cons: [
                "Русский заметно слабее большой модели",
                "Англицизмы регулярно уходят в транслит",
                "При этом не быстрее turbo — смысла мало"
            ],
            recommended: false
        ),
        ModelInfo(
            id: "small",
            title: "Small",
            sizeBytes: 487_601_967,
            speedNote: "около 0.5 секунды на 10 секунд речи",
            pros: [
                "Меньше полугигабайта, заведётся на любой машине",
                "Годится, когда важнее место, а не точность"
            ],
            cons: [
                "Для русского с англицизмами слабовата",
                "Правок руками будет много"
            ],
            recommended: false
        )
    ]

    static var recommended: ModelInfo { all.first { $0.recommended } ?? all[0] }

    /// Детектор речи. Мелкий, качается заодно с моделью и вопросов не задаёт.
    static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!
    static let vadFileName = "ggml-silero-v5.1.2.bin"

    /// Модели живут в Application Support: это не пользовательские документы,
    /// а кеш на несколько гигабайт.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Golos/models")
    }

    static func localURL(for model: ModelInfo) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    static func isInstalled(_ model: ModelInfo) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }
}

/// Качает модель с прогрессом. Отдельный класс, потому что URLSession
/// сообщает о ходе загрузки только через делегата.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    struct Progress {
        var fraction: Double
        var receivedBytes: Int64
        var totalBytes: Int64
    }

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var onProgress: ((Progress) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(from url: URL,
                  to destination: URL,
                  onProgress: @escaping (Progress) -> Void,
                  onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onFinish = onFinish

        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite
        let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
        let progress = Progress(fraction: fraction,
                                receivedBytes: totalBytesWritten,
                                totalBytes: total)
        DispatchQueue.main.async { self.onProgress?(progress) }
    }

    enum DownloadError: LocalizedError {
        case badStatus(Int)
        case tooSmall(Int64)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "Сервер ответил \(code) вместо файла модели"
            case .tooSmall(let bytes):
                return "Скачалось всего \(bytes) байт — это не модель"
            }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let destination else { return }
        let fm = FileManager.default

        // URLSession зовёт этот метод на любой завершённый ответ, включая 404.
        // Без проверки страница с ошибкой уехала бы в файл модели и выдалась
        // за успешную загрузку, а разбираться пришлось бы уже по невнятному
        // «сервер распознавания не готов».
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? fm.removeItem(at: location)
            DispatchQueue.main.async { self.onFinish?(.failure(DownloadError.badStatus(code))) }
            return
        }

        let attributes = try? fm.attributesOfItem(atPath: location.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        // Самая маленькая модель в каталоге — 450 МБ, детектор речи — 800 КБ.
        // Всё, что меньше сотни килобайт, это страница-заглушка, а не модель.
        guard size > 100_000 else {
            try? fm.removeItem(at: location)
            DispatchQueue.main.async { self.onFinish?(.failure(DownloadError.tooSmall(size))) }
            return
        }

        do {
            // Временный файл живёт до выхода из метода — переносим сразу.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            DispatchQueue.main.async { self.onFinish?(.success(destination)) }
        } catch {
            DispatchQueue.main.async { self.onFinish?(.failure(error)) }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if cancelled { return }
        DispatchQueue.main.async { self.onFinish?(.failure(error)) }
    }
}
