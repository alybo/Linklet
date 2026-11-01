import AppKit
import Carbon
import SwiftUI

@main
struct LinkletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // AppKit owns the status menu; the settings command uses our single window.
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) { appDelegate.model.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class LinkletMenuBarController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Linklet")
    private let model: AppModel
    private let readClipboard: () -> String?
    private var statusItem: NSStatusItem?

    init(model: AppModel, attachesToStatusBar: Bool = true,
         readClipboard: @escaping () -> String? = {
             NSPasteboard.general.string(forType: .URL) ?? NSPasteboard.general.string(forType: .string)
         }) {
        self.model = model
        self.readClipboard = readClipboard
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        buildMenu(clipboard: nil)
        if attachesToStatusBar {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.statusImage()
            item.button?.setAccessibilityLabel("Linklet")
            item.button?.toolTip = "Linklet"
            item.menu = menu
            statusItem = item
        }
    }

    static func statusImage() -> NSImage? {
        let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    // Read the pasteboard only when the user opens this menu, never on a timer.
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }
    func refreshMenu() {
        model.windowRegistry.refresh()
        buildMenu(clipboard: Self.clipboardURL(readClipboard()))
    }

    static func clipboardURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              URLPolicy.canPreview(url), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func buildMenu(clipboard: URL?) {
        menu.removeAllItems()
        let search = item("Quick Search", symbol: "magnifyingglass", action: #selector(quickSearch), id: "search")
        if let shortcut = model.searchSettings.shortcut {
            search.keyEquivalent = shortcut.keyLabel == "Space" ? " " : shortcut.keyLabel.lowercased()
            var mask: NSEvent.ModifierFlags = []
            for (carbon, flag) in [(cmdKey, NSEvent.ModifierFlags.command), (controlKey, .control), (optionKey, .option), (shiftKey, .shift)] {
                if shortcut.modifiers & UInt32(carbon) != 0 { mask.insert(flag) }
            }
            search.keyEquivalentModifierMask = mask
        }
        menu.addItem(search)
        let paste = item("Open Link from Clipboard", symbol: "doc.on.clipboard", action: #selector(openClipboard(_:)), id: "clipboard")
        paste.representedObject = clipboard
        paste.isEnabled = clipboard != nil
        menu.addItem(paste)
        menu.addItem(.separator())
        if model.linkLibrary.isEnabled {
            let sidebar = item(model.isSidebarPresented ? "Hide sidebar" : "Show sidebar", symbol: "sidebar.left",
                               action: #selector(sidebar(_:)), id: "sidebar")
            sidebar.representedObject = model.isSidebarPresented
            menu.addItem(sidebar)
        }
        let windows = item("Open Windows", symbol: "macwindow.on.rectangle", id: "windows")
        let windowMenu = NSMenu(title: windows.title)
        windowMenu.autoenablesItems = false
        for window in model.windowRegistry.windows {
            let title = window.title.count > 70 ? String(window.title.prefix(70)) + "…" : window.title
            let entry = NSMenuItem(title: title, action: #selector(activateWindow(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = window.id
            entry.state = window.id == model.windowRegistry.lastActiveWindowID ? .on : .off
            windowMenu.addItem(entry)
        }
        windows.submenu = windowMenu
        windows.isEnabled = !windowMenu.items.isEmpty
        menu.addItem(windows)
        let downloads = item("Downloads", symbol: "arrow.down.circle", action: #selector(showDownloads), id: "downloads")
        if model.downloads.activeCount > 0 { downloads.title = L("Downloads (%d)", model.downloads.activeCount) }
        menu.addItem(downloads)
        menu.addItem(.separator())
        let settings = item("Settings…", symbol: "gearshape", action: #selector(settings), id: "settings")
        settings.keyEquivalent = ","
        menu.addItem(settings)
        if model.appUpdates.availableVersion != nil { menu.addItem(updateItem()) }
        let help = item("Help", symbol: "questionmark.circle", id: "help")
        let helpMenu = NSMenu(title: help.title)
        helpMenu.autoenablesItems = false
        helpMenu.addItem(item("How to Use Linklet", action: #selector(welcome), id: "welcome"))
        helpMenu.addItem(item("About Linklet", action: #selector(about), id: "about"))
        if model.appUpdates.availableVersion == nil { helpMenu.addItem(updateItem()) }
        help.submenu = helpMenu
        menu.addItem(help)
        menu.addItem(.separator())
        let quit = item("Quit Linklet", action: #selector(quit), id: "quit")
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ key: String, symbol: String? = nil, action: Selector? = nil, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: L(key), action: action, keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("Linklet.Menu." + id)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
    private func updateItem() -> NSMenuItem {
        let result = item("Check for Updates…", action: #selector(updates), id: "updates")
        if let version = model.appUpdates.availableVersion { result.title = L("Update to %@…", version) }
        result.isEnabled = model.appUpdates.canCheckForUpdates
        return result
    }
    @objc private func quickSearch() { model.openQuickSearch() }
    @objc private func openClipboard(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL, URLPolicy.canPreview(url) { model.handleIncoming(urls: [url]) }
    }
    @objc private func sidebar(_ sender: NSMenuItem) {
        if sender.representedObject as? Bool == true { model.hideSidebar() }
        else { model.showSidebar() }
    }
    @objc private func activateWindow(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { model.windowRegistry.activate(id) }
    }
    @objc private func showDownloads() { model.showDownloads() }
    @objc private func settings() { model.showSettings() }
    @objc private func welcome() { model.showWelcome() }
    @objc private func about() { model.showSettings(page: .about) }
    @objc private func updates() { model.appUpdates.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
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
        "Opening links, launch, and language.": "Открытие ссылок, запуск и язык приложения.",
        "Choose how windows and the sidebar work.": "Настройте окна и боковую панель.",
        "Quick Search and opening links in other browsers.": "Быстрый поиск и открытие ссылок в других браузерах.",
        "Website data, history, blocking, and permissions.": "Данные сайтов, история, блокировка и разрешения.",
        "Version, updates, and support.": "Версия, обновления и поддержка.",
        "Open Link from Clipboard": "Открыть ссылку из буфера",
        "Open Windows": "Открытые окна",
        "Hide sidebar": "Скрыть боковую панель",
        "Downloads (%d)": "Загрузки (%d)",
        "Help": "Справка",
        "Website Data": "Данные сайтов",
        "Website data is saved.": "Сохранение данных включено.",
        "Website data is temporary.": "Данные сайтов временные.",
        "Storage": "Хранение данных",
        "Browser order": "Порядок браузеров",
        "Back": "Назад",
        "Skip": "Пропустить",
        "Windows & Sidebar": "Окна и панель",
        "Search & Browsers": "Поиск и браузеры",
        "Privacy": "Приватность",
        "About Linklet": "О Linklet",
        "Opening Links": "Открытие ссылок",
        "Application": "Приложение",
        "Launch at login": "Запускать при входе в macOS",
        "Same as macOS": "Как в macOS",
        "Getting Started": "Знакомство",
        "How to Use Linklet": "Как пользоваться Linklet",
        "Opening links, search, and the sidebar.": "Открытие ссылок, поиск и боковая панель.",
        "Window mode": "Режим окон",
        "Single window": "Одно окно",
        "Multiple windows": "Несколько окон",
        "Windows": "Окна",
        "Each new link opens in a separate window.": "Каждая новая ссылка открывается в отдельном окне.",
        "New links replace the page in a single window.": "Новые ссылки заменяют страницу в одном окне.",
        "When switching between apps.": "При переключении между приложениями.",
        "Default browser": "Браузер по умолчанию",
        "Default": "По умолчанию",
        "Make Default…": "Использовать по умолчанию…",
        "Links open in Linklet.": "Ссылки открываются в Linklet.",
        "Links will open in Linklet.": "Ссылки будут открываться в Linklet.",
        "Enable sidebar": "Включить боковую панель",
        "Open sidebar": "Открыть боковую панель",
        "Hide in full screen": "Скрывать в полноэкранном режиме",
        "Move the pointer to the left edge of the screen to see windows, bookmarks, and history.": "Наведите указатель на левый край экрана, чтобы открыть окна, закладки и историю.",
        "Advanced settings": "Дополнительные настройки",
        "Show sidebar indicator": "Показывать индикатор панели",
        "Opening delay": "Задержка открытия",
        "s": "с",
        "History": "История",
        "Save browsing history": "Сохранять историю посещений",
        "History is kept on this Mac after you quit Linklet. Turning this off deletes saved history.": "История сохраняется на этом Mac после выхода из Linklet. При выключении сохранённая история удаляется.",
        "History is kept until you quit Linklet. This setting does not affect website sign-ins.": "История хранится до выхода из Linklet. Эта настройка не влияет на вход в аккаунты.",
        "Open Quick Search": "Открыть быстрый поиск",
        "Set Shortcut…": "Задать сочетание…",
        "Show bookmarks": "Показывать закладки",
        "Web addresses open directly. Other text is sent to your search engine.": "Адрес откроется напрямую, остальной текст — как поисковый запрос.",
        "Browser for sending links": "Браузер для отправки ссылок",
        "Browsers in the Open in menu": "Браузеры в меню «Открыть в…»",
        "Drag browsers to reorder when automatic sorting is off.": "Перетаскивайте браузеры для изменения порядка, когда автоматическая сортировка выключена.",
        "Opening in Another Browser": "Открытие в другом браузере",
        "The primary Open in button uses this browser. It opens the original link without transferring website data or page state.": "Основная кнопка «Открыть в…» использует этот браузер. Передаётся исходная ссылка, без данных и состояния страницы.",
        "Stay signed in and keep website preferences.": "Оставаться в аккаунтах и сохранять настройки сайтов.",
        "Website data is stored on this Mac. Turning this off deletes saved website data.": "Данные сайтов хранятся на этом Mac. При выключении сохранённые данные удаляются.",
        "Without saving, website data is deleted when all related windows close. Hiding the window when switching apps also ends the preview.": "Без сохранения данные сайта удаляются после закрытия всех связанных окон. Скрытие окна при переключении приложений также завершает просмотр.",
        "Automatically clear data": "Автоочистка данных",
        "Time since the last visit to a website.": "Срок после последнего посещения сайта.",
        "Ad Blocking": "Блокировка рекламы",
        "Uses AdGuard filters. Change blocking for the current website in its page menu.": "Используются фильтры AdGuard. Для текущего сайта блокировку можно изменить в меню страницы.",
        "Open links without losing context.": "Открывайте ссылки, не теряя контекст.",
        "You can skip the introduction.": "Знакомство можно пропустить.",
        "Links alongside your work": "Ссылки рядом с работой",
        "Pages open in a compact window.": "Страница открывается в компактном окне.",
        "Search and bookmarks": "Поиск и закладки",
        "Search, save, and return to what matters.": "Ищите, сохраняйте и возвращайтесь к нужному.",
        "Your other browsers, within reach": "Другой браузер — рядом",
        "Open the original link in your chosen browser.": "Открывайте исходную ссылку в выбранном браузере.",
        "Try it yourself": "Попробуйте сами",
        "This is a Linklet window. Try the highlighted controls.": "Так выглядит окно Linklet. Нажмите на выделенные элементы.",
        "Start using Linklet": "Начните пользоваться Linklet",
        "You can change these settings later.": "Эти настройки можно изменить позже.",
        "Website data is stored on this Mac. History has a separate setting.": "Данные сайтов хранятся на этом Mac. История настраивается отдельно.",
        "Website data is temporary. History has a separate setting.": "Данные сайтов временные. История настраивается отдельно.",
        "Find settings and this introduction in the Linklet menu bar icon.": "Настройки и знакомство доступны через значок Linklet в строке меню.",
        "You're ready": "Можно начинать",
        "Start with Quick Search or customize Linklet.": "Начните с быстрого поиска или настройте Linklet под себя.",
        "To open links automatically, make Linklet your default browser in settings.": "Для автоматического открытия ссылок выберите Linklet браузером по умолчанию в настройках.",
        "Try It": "Попробовать",
        "Get Started": "Начать",
        "Open Settings": "Открыть настройки",
        "Sample page": "Учебная страница",
        "Choose browser": "Выбрать браузер",
        "Click the address control or press ⌘L.": "Нажмите на адрес или используйте ⌘L.",
        "Enter a website address or a search query.": "Введите адрес сайта или поисковый запрос.",
        "The other browser opens the original link. Sign-ins and page state are not transferred.": "В другом браузере откроется исходная ссылка. Вход в аккаунт и состояние страницы не переносятся.",
        "Address and search": "Адрес и поиск",
        "Click the address control to enter a link or search query.": "Нажмите на адрес, чтобы ввести ссылку или поисковый запрос.",
        "Another browser": "Другой браузер",
        "Click to open the original link in another browser.": "Нажмите, чтобы открыть исходную ссылку в другом браузере.",
        "Your first page": "Ваша первая страница",
        "Read, search, and save links. Keep browsing here or in another browser.": "Читайте, ищите и сохраняйте ссылки. Продолжить можно здесь или в другом браузере.",
        "Hide": "Скрывать",
        "Add": "Добавить",
        "Open the sidebar with ⌃⌥B or from the Linklet menu.": "Откройте панель сочетанием ⌃⌥B или из меню Linklet.",
        "The sidebar shortcut ⌃⌥B is unavailable. Use the Linklet menu or the screen edge.": "Сочетание ⌃⌥B недоступно. Используйте меню Linklet или край экрана.",
        "Open the original site link in your chosen browser. Sign-in starts again there.": "Открыть исходную ссылку сайта в выбранном браузере. Вход начнётся заново в нём.",
        "This website refused access. If sign-in is blocked, continue in your chosen browser from the original site link.": "Сайт отказал в доступе. Если вход заблокирован, продолжите в выбранном браузере с исходной ссылки сайта.",
        "Continue in browser": "Продолжить в браузере",
        "Website window": "Окно сайта",
        "Sidebar": "Боковая панель",
        "Sidebar appearance": "Вид боковой панели",
        "Appearance": "Внешний вид",
        "Black": "Чёрный",
        "Glass (test)": "Стекло (тест)",
        "Test appearance: a full Liquid Glass panel, tinted black on the left and transparent on the right. The sidebar shape and row sizes stay the same.": "Тестовый вид: цельная панель Liquid Glass с чёрной тонировкой слева и прозрачной правой частью. Форма панели и размеры строк сохраняются.",
        "Reduce Transparency uses the black appearance.": "При включённом «Уменьшении прозрачности» используется чёрный вид.",
        "Liquid Glass requires macOS 26 or later. The black appearance is used on this Mac.": "Для Liquid Glass нужна macOS 26 или новее. На этом Mac используется чёрный вид.",
        "Show sidebar": "Показать боковую панель",
        "Close sidebar": "Закрыть боковую панель",
        "Search links": "Поиск ссылок",
        "Bookmarks": "Закладки",
        "Favorites": "Избранное",
        "Add bookmark": "Добавить закладку",
        "Edit bookmark": "Изменить закладку",
        "New folder": "Новая папка",
        "Add bookmark or folder": "Добавить закладку или папку",
        "Empty folder": "Пустая папка",
        "Rename folder": "Переименовать папку",
        "Remove folder; keep bookmarks": "Удалить папку, сохранив закладки",
        "Save links here or add the current page with the bookmark button.": "Сохраняйте ссылки здесь или добавляйте текущую страницу кнопкой закладки.",
        "Recent links": "Недавние",
        "Open windows": "Открытые",
        "Downloads": "Загрузки",
        "Download": "Файл",
        "No downloads.": "Загрузок нет.",
        "Save download": "Сохранить файл",
        "Upload files": "Прикрепить файлы",
        "Upload folder": "Прикрепить папку",
        "Choose": "Выбрать",
        "Choose files to share with %@.": "Выберите файлы для передачи сайту %@.",
        "Choose where to save": "Выберите папку для сохранения",
        "Saving file…": "Сохраняем файл…",
        "Download complete": "Загрузка завершена",
        "Download cancelled": "Загрузка отменена",
        "Download failed": "Не удалось скачать файл",
        "The server returned HTTP %d.": "Сервер вернул ошибку HTTP %d.",
        "Cancel download": "Отменить загрузку",
        "Show in Finder": "Показать в Finder",
        "Clear completed downloads": "Очистить завершённые",
        "Downloads in progress": "Есть незавершённые загрузки",
        "Quitting Linklet will stop unfinished downloads.": "При выходе из Linklet незавершённые загрузки остановятся.",
        "Keep downloading": "Продолжить загрузки",
        "Quit and stop downloads": "Выйти и остановить загрузки",
        "No open windows.": "Открытых окон нет.",
        "Minimized": "Свёрнуто",
        "Active window": "Активное окно",
        "Close window": "Закрыть окно",
        "No recent links.": "Недавних ссылок нет.",
        "Clear history": "Очистить историю",
        "Show more": "Показать ещё",
        "Show sidebar reveal indicator": "Показывать ярлык открытия панели",
        "Delay before opening": "Задержка перед открытием",
        "Clear all recent links?": "Очистить все недавние ссылки?",
        "This cannot be undone.": "Это действие нельзя отменить.",
        "Expanded": "Развёрнуто",
        "Collapsed": "Свёрнуто",
        "History is saved on this Mac.": "История сохраняется на этом Mac.",
        "History is kept until Linklet quits.": "История хранится до завершения Linklet.",
        "Move to folder": "Переместить в папку",
        "No folder": "Без папки",
        "Folder": "Папка",
        "Enable global sidebar": "Включить глобальную боковую панель",
        "Hover at the left edge of any screen to see open windows, bookmarks and recent links. Select an open window to return to it, or a saved link to open a preview.": "Наведите курсор на левый край любого экрана, чтобы увидеть открытые окна, закладки и недавние ссылки. Выберите открытое окно, чтобы вернуться к нему, или сохранённую ссылку, чтобы открыть предпросмотр.",
        "You can also open the sidebar from the Linklet menu.": "Панель также можно открыть из меню Linklet.",
        "Save history between launches": "Сохранять историю между запусками",
        "Only links opened in Linklet are listed. Page redirects and sign-in windows are excluded. Up to 200 links are kept; turning saving off removes history from disk.": "В списке только ссылки, открытые в Linklet. Переадресации страниц и окна входа не записываются. Сохраняется до 200 ссылок; выключение сохранения удаляет историю с диска.",
        "Bookmarks use the same saved links as Quick Search. Folders and bookmarks stay on this Mac and can be edited in the sidebar.": "Закладки используют те же ссылки, что и избранное быстрого поиска. Папки и закладки хранятся на этом Mac и редактируются в боковой панели.",
        "If sign-in is blocked, continue in your browser using Open in.": "Если вход заблокирован, продолжите в своём браузере через «Открыть в».",
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
        "Camera": "Камера",
        "Microphone": "Микрофон",
        "Location": "Геолокация",
        "your location": "вашу геопозицию",
        "Website permissions": "Разрешения сайтов",
        "Hide in fullscreen apps": "Не показывать в полноэкранных приложениях",
        "This WebKit version cannot provide location to websites.": "Эта версия WebKit не поддерживает передачу геопозиции сайтам.",
        "Websites appear here when they request camera, microphone or location access.": "Здесь появятся сайты, запросившие камеру, микрофон или геолокацию.",
        "Your location helps this website show nearby places and routes.": "Геопозиция нужна сайту для поиска мест поблизости и построения маршрутов.",
        "Changing location access reloads the page to stop its location requests.": "При отзыве доступа к геолокации страница обновится, чтобы остановить запросы геопозиции.",
        "the camera": "камеру",
        "the microphone": "микрофон",
        "the camera and microphone": "камеру и микрофон",
        "Camera and microphone": "Камера и микрофон",
        "Ask": "Спрашивать",
        "Allow": "Разрешить",
        "Block": "Запретить",
        "Don't Allow": "Не разрешать",
        "Not now": "Не сейчас",
        "Open System Settings…": "Открыть системные настройки…",
        "System Settings…": "Системные настройки…",
        "Allow %@ to use %@?": "Разрешить %@ использовать %@?",
        "macOS has blocked access to %@": "macOS не разрешает использовать %@",
        "Allow Linklet in System Settings → Privacy & Security, then try again on the website.": "Разрешите доступ для Linklet в системных настройках → «Конфиденциальность и безопасность», затем повторите попытку на сайте.",
        "This website is requesting access to your devices.": "Этот сайт запрашивает доступ к вашим устройствам.",
        "This request comes from content embedded in %@.": "Запрос поступил от содержимого, встроенного в %@.",
        "Remember for this website": "Запомнить для этого сайта",
        "Remember until all website windows close": "Запомнить до закрытия всех окон сайтов",
        "Reset permissions": "Сбросить разрешения",
        "Embedded in %@": "Встроено в %@",
        "Websites appear here when they request camera or microphone access.": "Здесь появятся сайты, запросившие камеру или микрофон.",
        "Remembered permissions stay on this Mac until you reset them or delete website data.": "Сохранённые разрешения остаются на этом Mac, пока вы не сбросите их или не удалите данные сайта.",
        "In private mode, remembered permissions are removed when the last website window closes.": "В приватном режиме запомненные разрешения удаляются после закрытия последнего окна сайта.",
        "Blocking access stops active capture. Reload the website if it needs to ask again.": "Запрет останавливает использование устройства. Обновите страницу, если сайту нужно запросить доступ заново.",
        "Allowed by macOS": "Разрешено в macOS",
        "Blocked by macOS": "Запрещено в macOS",
        "Restricted by macOS": "Ограничено в macOS",
        "macOS will ask when needed": "macOS спросит при необходимости",
        "Unknown": "Неизвестно",
        "About": "О программе",
        "Block ads": "Блокировать рекламу",
        "AdGuard filter lists": "Фильтры блокировки AdGuard",
        "Turn On AdGuard": "Включить AdGuard",
        "Turn Off AdGuard": "Выключить AdGuard",
        "Exceptions (%d)": "Исключения (%d)",
        "No exceptions": "Исключений нет",
        "Remove exception": "Удалить исключение",
        "Add website…": "Добавить сайт…",
        "Website address": "Адрес сайта",
        "AdGuard will be turned off for this domain.": "AdGuard будет выключен для этого домена.",
        "Enter an HTTP(S) address or domain.": "Введите HTTP(S)-адрес или домен.",
        "Exceptions override the default for this exact domain. Open pages refresh automatically when a rule changes.": "Исключения задают состояние AdGuard для конкретного домена. При изменении правила открытые страницы автоматически обновляются.",
        "Could not apply AdGuard settings. Try again.": "Не удалось применить настройки AdGuard. Повторите попытку.",
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

        "Keep on top": "Поверх других окон",
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
        "The page stopped responding": "Страница перестала отвечать",
        "Check your internet connection and try again.": "Проверьте подключение к интернету и попробуйте ещё раз.",
        "The website took too long to respond. Try again.": "Сайт слишком долго не отвечал. Попробуйте ещё раз.",
        "The website could not be reached. Check the address or try again later.": "Не удалось связаться с сайтом. Проверьте адрес или попробуйте позже.",
        "A secure connection to this website could not be established.": "Не удалось установить защищённое соединение с сайтом.",
        "Restore this page to continue. Other windows are unaffected.": "Восстановите страницу, чтобы продолжить. Остальные окна продолжают работать.",
        "Return to page": "Вернуться на страницу",
        "Restore page": "Восстановить страницу",
        "Try again": "Повторить",
        "Retry submission": "Повторить отправку",
        "Submitting again may repeat an action on this website.": "Повторная отправка может повторить действие на этом сайте.",
        "Return to the website to submit the form again.": "Вернитесь на сайт, чтобы отправить форму заново.",
        "Visited pages and their scroll positions appear here. The last page of a closed window moves to the top. Up to 200 links are kept; turning saving off removes history from disk.": "Здесь появляются посещённые страницы и положение прокрутки. Последняя страница закрытого окна поднимается наверх. Сохраняется до 200 ссылок; выключение сохранения удаляет историю с диска.",
        "OK": "ОК",
        "Unknown error": "Неизвестная ошибка",
        "Preview": "Просмотр",
        "Close preview": "Закрыть просмотр",
        "Back — ⌘[": "Назад — ⌘[",
        "Forward — ⌘]": "Вперёд — ⌘]",
        "Copied": "Скопировано",
        "Copied!": "Скопировано!",
        "Saved bookmark": "Сохранено в закладках",
        "Not bookmarked": "Нет в закладках",
        "Copy current URL": "Скопировать ссылку",
        "Show full address": "Показать полный адрес",
        "Full address": "Полный адрес",
        "Find on page": "Найти на странице",
        "Previous match": "Предыдущее совпадение",
        "Next match": "Следующее совпадение",
        "Close search": "Закрыть поиск",
        "No matches": "Совпадений нет",
        "Found": "Найдено",
        "%d+ matches": "%d+ совп.",
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
