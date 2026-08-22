import Foundation
import ServiceManagement

/// Автозапуск при входе в систему.
/// SMAppService держит регистрацию по идентификатору бандла, поэтому
/// приложение нельзя переносить после включения — перенёс, перерегистрируй.
enum Autostart {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Возвращает текст ошибки, если система отказала.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // Повторная регистрация уже включённого даёт ошибку — проверяем.
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
                Log.write("автозапуск включён")
            } else {
                guard SMAppService.mainApp.status == .enabled else { return nil }
                try SMAppService.mainApp.unregister()
                Log.write("автозапуск выключен")
            }
            return nil
        } catch {
            let message = error.localizedDescription
            Log.write("автозапуск не переключился: \(message)")
            return message
        }
    }

    /// Пользователь мог запретить автозапуск в системных настройках —
    /// тогда галочка в меню должна об этом сказать, а не молчать.
    static var blockedBySystem: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
