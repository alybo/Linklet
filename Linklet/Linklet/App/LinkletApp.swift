import AppKit
import SwiftUI

@main
struct LinkletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: appDelegate.model)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("Linklet")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel

    var body: some View {
        Button(L("Welcome to Linklet")) {
            model.showWelcome()
        }

        Button(L("Settings…")) {
            model.showSettings()
        }
        .keyboardShortcut(",")

        CheckForAppUpdatesButton(updates: model.appUpdates)

        Divider()

        Picker(L("Window behavior"), selection: Binding(
            get: { model.previewWindowBehavior },
            set: model.setPreviewWindowBehavior
        )) {
            ForEach(PreviewWindowBehavior.allCases) { behavior in
                Text(behavior.title).tag(behavior)
            }
        }
        .id(language.code)

        Divider()

        Button(L("Quit Linklet")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct CheckForAppUpdatesButton: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var updates: AppUpdateService

    var body: some View {
        Button(updates.availableVersion.map { L("Update to %@…", $0) } ?? L("Check for Updates…")) {
            updates.checkForUpdates()
        }
        .disabled(!updates.canCheckForUpdates)
    }
}

// Shared by native UI and the offline welcome document. User-facing source keys are English.
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    @Published private(set) var selection: String
    var code: String {
        Self.resolve(selection, preferredLanguages: Locale.preferredLanguages)
    }
    static func resolve(_ selection: String, preferredLanguages: [String]) -> String {
        if ["ru", "en"].contains(selection) { return selection }
        return preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en"
    }
    private init() {
        selection = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system"
    }
    func set(_ selection: String) {
        guard ["system", "ru", "en"].contains(selection) else { return }
        self.selection = selection
        UserDefaults.standard.set(selection, forKey: "interfaceLanguage")
    }
    static let russian: [String: String] = 
[
        "Welcome to Linklet": "Знакомство с Linklet",
        "Settings…": "Настройки…",
        "Check for Updates…": "Проверить обновления…",
        "Update to %@…": "Обновить до %@…",
        "Updates": "Обновления",
        "Check for updates automatically": "Автоматически проверять обновления",
        "Download and install updates automatically": "Автоматически скачивать и устанавливать обновления",
        "Downloaded updates are installed when Linklet quits.": "Скачанные обновления устанавливаются после завершения Linklet.",
        "Quit Linklet": "Завершить Linklet",
        "Window behavior": "Поведение окна",
        "Enable AdGuard ad blocker": "Включить блокировщик рекламы AdGuard",
        "Language": "Язык",
        "System language": "Как в системе",
        "Linklet Settings": "Настройки Linklet",
        "Hide preview": "Скрывать",
        "Keep open": "Оставлять открытым",
        "Keep on top": "Поверх всех окон",
        "The preview hides when you switch to another app.": "Окно скрывается при переходе в другое приложение.",
        "The preview stays open; other windows can appear in front of it.": "Окно остаётся открытым, но другие окна могут его перекрывать.",
        "The preview stays visible above other applications.": "Окно остаётся поверх других приложений.",
        "Preview first. Choose the right browser second.": "Сначала посмотрите, затем откройте в своём браузере.",
        "Default link handler": "Открытие ссылок",
        "Linklet handles web links on this Mac.": "Linklet открывает ссылки по умолчанию.",
        "Set Linklet as the default browser to preview external links.": "Выберите Linklet браузером по умолчанию для просмотра ссылок.",
        "Make Linklet Default Browser": "Использовать по умолчанию",
        "Preview window": "Окно просмотра",
        "When switching apps": "При переходе в другое приложение",
        "Browsers": "Браузеры",
        "Sort browsers by usage": "Сортировать по частоте использования",
        "The most-used browser becomes the primary Open in action; the others follow in the menu.": "Самый используемый браузер появится на основной кнопке открытия, остальные — в меню.",
        "Shown browsers": "Показываемые браузеры",
        "Reset usage": "Сбросить статистику",
        "Refresh": "Обновить",
        "No compatible browsers or Orion profile apps were found.": "Совместимые браузеры и профили Orion не найдены.",
        "Performance": "Запуск приложения",
        "Launch Linklet when I sign in": "Запускать Linklet при входе в систему",
        "Keeps the lightweight menu bar process ready and reuses the same preview window.": "Linklet будет готов к открытию ссылок сразу после входа в систему.",
        "Loading page": "Загрузка страницы",
        "Couldn't open the page": "Не удалось открыть страницу",
        "OK": "ОК",
        "Unknown error": "Неизвестная ошибка",
        "Preview": "Просмотр",
        "Close preview": "Закрыть просмотр",
        "Back — ⌘[": "Назад — ⌘[",
        "Forward — ⌘]": "Вперёд — ⌘]",
        "Copied": "Скопировано",
        "Copy current URL": "Скопировать ссылку",
        "Find browsers": "Найти браузеры",
        "Choose browsers": "Выбрать браузеры",
        "No other browsers": "Других браузеров нет",
        "Choose another browser": "Выбрать другой браузер",
        "Browser": "Браузер",
        "Linklet cannot route a link back to itself.": "Linklet не может открыть ссылку в самом себе.",
        "Linklet received no previewable web links.": "Не получено ссылок, доступных для просмотра.",
        "Linklet is now your default link handler.": "Linklet теперь открывает ссылки по умолчанию.",
        "macOS has not confirmed the default browser change yet.": "macOS пока не подтвердила смену браузера по умолчанию.",
        "Linklet will stay ready after you sign in.": "Linklet будет запускаться при входе в систему.",
        "Launch at login is turned off.": "Запуск при входе в систему отключён.",
        "Only HTTP and HTTPS links can be previewed.": "Просмотр доступен только для ссылок HTTP и HTTPS.",
        "Enter a valid web address.": "Введите корректный адрес сайта.",
        "Open in %@": "Открыть в %@",
        "%d of %d": "%d из %d",
        "Used %d×": "Открытий: %d"
    ]
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let text = AppLanguage.shared.code == "ru" ? (AppLanguage.russian[key] ?? key) : key
    return arguments.isEmpty ? text : String(format: text, locale: Locale(identifier: AppLanguage.shared.code), arguments: arguments)
}
