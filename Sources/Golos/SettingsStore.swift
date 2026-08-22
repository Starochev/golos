import Foundation
import SwiftUI

/// Обёртка над конфигом для окна настроек.
///
/// Кнопки «Сохранить» нет намеренно: приложение перечитывает конфиг перед
/// каждой диктовкой, поэтому правка вступает в силу сразу. Запись на диск
/// с небольшой задержкой, чтобы набор текста в поле не бил по файлу
/// на каждую букву.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var config: Config {
        didSet { handleChange(from: oldValue) }
    }

    /// Язык и модель — аргументы запуска движка, их смена требует перезапуска.
    var onEngineRelevantChange: (() -> Void)?

    private var saveWorkItem: DispatchWorkItem?

    init() {
        config = Config.load()
    }

    /// Перечитать с диска — если файл правили руками, пока окно было закрыто.
    func reloadFromDisk() {
        saveWorkItem?.cancel()
        config = Config.load()
    }

    private func handleChange(from old: Config) {
        scheduleSave()
        if old.language != config.language || old.modelPath != config.modelPath {
            onEngineRelevantChange?()
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = config
        let work = DispatchWorkItem { snapshot.save() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Записать немедленно — при закрытии окна ждать задержку незачем.
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        config.save()
    }

    // MARK: - Словарь

    /// Сколько символов словаря уже занято из доступных модели.
    var vocabularyUsage: Int {
        config.vocabulary.reduce(0) { $0 + $1.count + 2 }
    }

    var vocabularyBudget: Int { Config.promptCharacterBudget }

    var vocabularyOverflow: Bool { vocabularyUsage > vocabularyBudget }

    /// Возвращает причину отказа или nil, если слово добавлено.
    @discardableResult
    func addTerm(_ raw: String) -> String? {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return "Пустая строка" }
        guard !config.vocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame })
        else { return "«\(term)» уже в списке" }

        config.vocabulary.append(term)
        return nil
    }

    func removeTerms(at offsets: IndexSet) {
        config.vocabulary.remove(atOffsets: offsets)
    }

    func removeTerm(_ term: String) {
        config.vocabulary.removeAll { $0 == term }
    }

    // MARK: - Замены

    func addReplacement() {
        config.replacements.append(Config.Replacement(from: "", to: "", ignoreCase: true))
    }

    func removeReplacements(at offsets: IndexSet) {
        config.replacements.remove(atOffsets: offsets)
    }
}
