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
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) { appDelegate.model.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

private struct MenuBarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel

    var body: some View {
        Button(L("Quick Search")) { model.toggleSearch() }

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
        "Search with %@": "Искать через %@",
        "Search": "Поиск",
        "Quick Search": "Быстрый поиск",
        "Yandex": "Яндекс",
        "Space": "Пробел",
        "Search or enter address": "Поиск или адрес сайта",
        "Search engine": "Поисковик",
        "Choose a search engine for this query": "Выбрать поисковик для этого запроса",
        "Open search": "Открыть поиск",
        "Press a shortcut…": "Нажмите сочетание…",
        "Record shortcut": "Задать сочетание",
        "Press Escape to cancel recording": "Нажмите Escape для отмены",
        "Remove shortcut": "Убрать сочетание",
        "Keyboard shortcut": "Горячая клавиша",
        "Default search engine": "Основной поисковик",
        "Choose a combination with ⌘, ⌥ or ⌃. Linklet must be running.": "Выберите сочетание с ⌘, ⌥ или ⌃. Linklet должен быть запущен.",
        "Choose a combination with ⌘, ⌥ or ⌃.": "Выберите сочетание с ⌘, ⌥ или ⌃.",
        "This shortcut is unavailable. Choose another combination.": "Это сочетание недоступно. Выберите другое.",
        "You can change the engine in the search bar for a single query. Web addresses open directly.": "В строке поиска можно выбрать другой поисковик для одного запроса. Адреса сайтов открываются напрямую.",
        "Open search bar": "Открыть строку поиска",
        "Results open in the usual Linklet window. Each search starts with an empty field.": "Результаты открываются в обычном окне Linklet. Каждый поиск начинается с пустой строки.",
        "Favorite websites": "Избранные сайты",
        "Show favorites in Quick Search": "Показывать избранное в быстром поиске",
        "Add websites you open often to show them in Quick Search.": "Добавьте часто открываемые сайты, чтобы видеть их в быстром поиске.",
        "Favorites are stored only in Linklet on this Mac. They open in the usual private preview.": "Избранные хранятся только в Linklet на этом Mac и открываются в обычном приватном просмотре.",
        "Add website": "Добавить сайт",
        "Add favorite website": "Добавить избранный сайт",
        "Edit favorite website": "Изменить избранный сайт",
        "Drag to reorder.": "Перетаскивайте для изменения порядка.",
        "Load favicon": "Загрузить favicon",
        "Web address": "Адрес сайта",
        "Name": "Название",
        "Save": "Сохранить",
        "Edit": "Изменить",
        "Remove": "Удалить",
        "Enter a valid HTTP or HTTPS address.": "Введите корректный адрес HTTP или HTTPS.",
        "This website is already in Favorites.": "Этот сайт уже есть в избранном.",
        "Couldn't load a favicon for this website.": "Не удалось загрузить favicon для этого сайта.",
        "General": "Основные",
        "Website data": "Данные сайтов",
        "About": "О программе",
        "Block ads": "Блокировать рекламу",
        "AdGuard filter lists": "Фильтры блокировки AdGuard",
        "Drag to reorder. The first enabled browser is the primary action.": "Перетаскивайте браузеры для изменения порядка. Первый включённый браузер — основной.",
        "Usage counts only links opened through Linklet.": "Учитываются только ссылки, открытые через Linklet.",
        "Show %@": "Показывать %@",
        "Primary": "Основной",
        "Opened through Linklet: %d": "Открыто через Linklet: %d",
        "Move up": "Переместить выше",
        "Move down": "Переместить ниже",
        "Turn off saving and delete website data?": "Выключить сохранение и удалить данные сайтов?",
        "Delete all website data?": "Удалить данные всех сайтов?",
        "Delete data for %@?": "Удалить данные сайта %@?",
        "Save website data": "Сохранять данные сайтов",
        "Keep sign-ins and website preferences between previews.": "Сохраняет вход в аккаунты и настройки сайтов между открытиями.",
        "When saving is off, closing or hiding the preview deletes its data, including when switching apps.": "Если сохранение выключено, данные удаляются при закрытии или скрытии окна, в том числе при переключении в другое приложение.",
        "Data is stored only in Linklet on this Mac, separately from your other browsers.": "Данные хранятся в Linklet на этом Mac, отдельно от других браузеров.",
        "Delete data for websites not visited for": "Удалять данные сайтов без посещений",
        "Never": "Никогда",
        "%d days": "%d дней",
        "Inactive website data is removed while Linklet is idle. Background requests do not count as visits.": "Данные неиспользуемых сайтов удаляются, когда Linklet не показывает страницы. Фоновые запросы не считаются посещениями.",
        "Stored websites": "Сохранённые данные",
        "Search websites": "Поиск сайтов",
        "Updating website data…": "Обновление данных сайтов…",
        "No stored website data.": "Сохранённых данных сайтов нет.",
        "No matching websites.": "Сайты не найдены.",
        "Last visited: %@": "Последнее посещение: %@",
        "Delete data…": "Удалить данные…",
        "Delete all data…": "Удалить все данные…",
        "Cancel": "Отмена",
        "Turn off and delete": "Выключить и удалить",
        "Delete data": "Удалить данные",
        "The current preview will close. You may need to sign in again. This does not affect your other browsers.": "Текущее окно просмотра закроется. Возможно, потребуется снова войти в аккаунт. Данные других браузеров не изменятся.",
        "Cookies": "Cookies",
        "Cache": "Кэш",
        "Local storage": "Локальное хранилище",
        "Version %@": "Версия %@",
        "Build %@": "Сборка %@",
        "Support development": "Благодарность",
        "Contact the author": "Написать автору",
        "Updates are downloaded and installed only after your confirmation.": "Скачивание и установка обновлений — только после вашего подтверждения.",
        "If you find the app useful, you can support its development.\nThank you for your support!": "Если приложение вам полезно,\nвы можете поддержать разработку.\nСпасибо за поддержку!",
        "TRON network": "Сеть TRON",
        "Copy address": "Скопировать адрес",
        "Send only USDT on the TRON (TRC20) network.": "Отправляйте только USDT\nв сети TRON (TRC20).",
        "Done": "Готово",
        "Keep website sign-ins?": "Сохранять вход на сайты?",
        "Choose how Linklet handles website data.": "Выберите, как Linklet будет обращаться с данными сайтов.",
        "Without saving": "Без сохранения",
        "With saving": "С сохранением",
        "For quick link previews. Website data is deleted when the window closes. You will need to sign in again the next time you open websites.": "Для быстрого просмотра ссылок. Данные сайтов удаляются при закрытии окна. При следующем открытии сайтов потребуется повторная авторизация.",
        "For websites you use regularly. Linklet remembers sign-ins and website preferences. Data stays on this Mac; you can delete it manually or set up automatic cleanup.": "Для сайтов, которыми вы пользуетесь регулярно. Linklet сохраняет вход в аккаунты и настройки сайтов. Данные хранятся на этом Mac; их можно удалить вручную или настроить автоматическую очистку.",
        "This choice applies to all websites in Linklet.": "Выбор действует для всех сайтов в Linklet.",
        "Continue": "Продолжить",
        "Selected": "Выбрано",
        "Not selected": "Не выбрано",
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
        "Open links in new windows": "Открывать ссылки в новых окнах",
        "Keep each incoming link in its own preview window.": "Открывать каждую входящую ссылку в отдельном окне просмотра.",
        "Close All Windows": "Закрыть все окна",
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
