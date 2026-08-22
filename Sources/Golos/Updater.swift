import AppKit
import Foundation
import Sparkle

/// Автообновления через Sparkle.
///
/// Приложение раздаётся мимо App Store, поэтому обновления тянутся из релизов
/// GitHub: там лежит appcast.xml со списком версий и подписью каждой сборки.
/// Приватный ключ EdDSA живёт в связке ключей автора и в репозиторий не
/// попадает — подделать обновление без него нельзя.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// Проверка по требованию — из меню.
    func checkNow() {
        controller.checkForUpdates(nil)
    }

    /// Приложение живёт в строке меню, поэтому окно обновления надо
    /// вытаскивать поверх остальных — иначе оно откроется где-то позади.
    func checkNowBringingToFront() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        checkNow()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }
}
