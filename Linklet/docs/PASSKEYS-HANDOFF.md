# Passkeys и ключи безопасности в Linklet

Состояние на 2026-10-06: **не поддерживаются для произвольных сторонних сайтов в текущей сборке**. Исправление popup-layout в сборке 10 относится к отображению окна; не выдавать его за исправление QR/passkey-авторизации.

## Подтверждённые ограничения

WebKit выполняет WebAuthn через системные AuthenticationServices. Для обычного приложения нужны связанные домены (`webcredentials` + подтверждение со стороны владельца сайта). Linklet не владеет Google, Pinterest и другими сайтами, поэтому этот подход не даёт общей поддержки.

Для macOS-браузера предусмотрено managed entitlement `com.apple.developer.web-browser.public-key-credential`. Оно разрешает запросы passkeys и security keys для любого relying party. По документации Apple запрос должен отправить Account Holder **организационной** команды Apple Developer; Apple рассматривает заявку и добавляет разрешение к аккаунту. Добавление ключа в локальный plist без одобрения не заменяет этот процесс.

В текущем Debug/Release проекте разрешения нет. Локальная сборка из `xcodebuild ... CODE_SIGNING_ALLOWED=NO` также не содержит application identity и managed entitlement. WebKit-тест на localhost проверяет собственный `isUserVerifyingPlatformAuthenticatorAvailable()` без создания или чтения пользовательских ключей.

QR-вход с телефона может использовать WebAuthn с transport `hybrid`. Успешность также зависит от самого телефона, сетевого соединения и Bluetooth. Отсутствие entitlement — установленное ограничение Linklet; конкретную причину ошибки Google после QR нельзя доказать только скриншотом. Не добавлять Bluetooth usage descriptions или вымышленные разрешения как обещание исправления.

Владелец подтвердил, что подписывающая команда использует личный Apple Developer аккаунт. По текущим условиям формы Apple это не даёт возможности подать заявку через такую команду. Подготовленные сведения ниже пригодятся, если появится подходящая организационная команда; менять издателя/идентификатор приложения без отдельного плана нельзя.

## Подготовленные сведения для заявки

Официальная форма: https://developer.apple.com/contact/request/macos-browsers-passkeys/

- Приложение: Linklet.
- Bundle identifier: `Linklet` (не менять идентификатор существующих выпусков).
- Платформа: macOS, WebKit/WKWebView.
- Репозиторий: https://github.com/alybo/Linklet
- В Info.plist зарегистрированы схемы HTTP и HTTPS.
- Пользователь может открывать URL и искать в интернете через Quick Search, сохранять избранные ссылки, пользоваться глобальной панелью закладок. Ссылки отображаются в WebKit по исходному назначению.
- Требование: стандартная WebAuthn-авторизация на сторонних сайтах, включая passkeys, cross-device QR/hybrid и аппаратные ключи, без перехвата паролей и без доступа к профилям других браузеров.

Имя организации, Team ID и контакт Account Holder заполняются владельцем подписывающей команды. Заявка **не отправлялась**.

## После одобрения Apple

1. Компаньон с правами Developer проверяет, что managed capability доступна для App ID, которым подписываются текущие релизы.
2. Использует поддерживаемый Apple процесс managed capabilities для подходящей подписи/профиля. По AGENTS.md не создавать и не менять вручную сертификаты, ключи, токены или provisioning profiles.
3. Добавляет entitlement в конфигурацию подписи приложения; не переносит Debug `disable-library-validation` в Release. Обновление release-процесса предварительно проверяется на фактическом профиле — нынешний скрипт не гарантирует сохранение managed entitlement.
4. Проверяет доступ приложения через `ASAuthorizationWebBrowserPublicKeyCredentialManager.authorizationStateForPlatformCredentials`; если требуется пользовательское разрешение, запрашивает его через `requestAuthorizationForPublicKeyCredentials`. WebKit должен сам обрабатывать веб-запросы, без JS-подмены `navigator.credentials`.
5. Проверяет фактические entitlements в подписанной `.app` и на устройстве: Google/Pinterest, локальный ключ из «Паролей», ключ с телефона через QR, аппаратный ключ, отмена/повторная попытка, оба режима данных и закрытие родительского окна. Не читать содержимое пользовательских ключей и не создавать тестовые ключи в реальных аккаунтах автоматически.
6. Только после этих проверок отмечает passkey-поддержку как готовую.

Пока пользователь может продолжить вход с исходной ссылки в выбранном полноценном браузере. Сессия этого браузера не переносится в Linklet.

## Первичные источники

- Apple: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential
- Apple: https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers
- Apple: https://developer.apple.com/documentation/authenticationservices/authenticating-people-by-using-passkeys-in-browser-apps
- Apple: https://developer.apple.com/documentation/authenticationservices/supporting-passkeys
- WebKit: https://bugs.webkit.org/show_bug.cgi?id=250912
