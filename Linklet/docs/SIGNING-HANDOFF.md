# Передача Linklet для подписи и выпуска

## Рекомендуемый вариант

Передать весь каталог проекта через приватный Git-репозиторий с зафиксированным коммитом/тегом либо ZIP исходников. Включить Linklet.xcodeproj, Linklet, LinkletTests, README.md и docs. Не передавать DerivedData, xcuserdata, готовые промежуточные сборки, сертификаты .p12, закрытые ключи, пароли или токены. Все изображения уже входят в Assets.xcassets; путей к Downloads для сборки нет.

Лучше выпускать от вашей команды Apple Developer и дать человеку подходящий доступ к ней. Если он подписывает от собственной команды, издателем будет владелец этой команды; следующие релизы разумно подписывать той же командой. Заранее договоритесь, кто хранит доступ и делает обновления. Для обычной раздачи приложения нужен Developer ID Application из платной Apple Developer Program, а не Personal Team или только Apple Development.

## Что согласовать перед первым релизом

- Команда Apple Developer (Team ID) и имя издателя.
- Согласованный bundle identifier приложения: `Linklet`, тестового пакета: `LinkletTests`. Не менять между обновлениями без плана миграции.
- Версия сейчас 0.1.0, номер сборки 1. Для нового выпуска установить нужные значения.
- Формат раздачи: ZIP или DMG вне Mac App Store. Этот проект сейчас не настроен для публикации в Mac App Store.

## Порядок работы получателя

1. Открыть Linklet.xcodeproj на Mac с Xcode 16 или новее, выбрать схему Linklet.
2. В Signing & Capabilities выбрать согласованную Team; проверить bundle identifier. Hardened Runtime уже включён, App Sandbox отключён намеренно для работы с браузерами.
3. Запустить тесты и проверить русский/английский интерфейс, приветствие, системный запрос браузера по умолчанию, режимы окна и открытие ссылки в установленном браузере.
4. Выбрать релизное назначение My Mac / Any Mac (как доступно в версии Xcode), Product → Archive. Для поддержки Intel и Apple Silicon проверить обе архитектуры в архиве.
5. В Organizer выбрать Distribute App → Direct Distribution либо Developer ID (название зависит от Xcode). Подписать Developer ID Application, отправить на notarization Apple, дождаться Accepted, экспортировать нотарифицированное приложение.
6. Убедиться, что ticket прикреплён (stapled), затем упаковать экспортированное приложение через Finder Compress или ditto. При DMG отдельно проверить финальный образ.
7. Передать обратно ZIP/DMG, SHA-256, версию/номер сборки, Team ID, bundle identifier, результат нотарификации. Сохранить .xcarchive и dSYM для диагностики и воспроизводимости.

## Проверка готового приложения

В каталоге с экспортированным Linklet.app:

```sh
codesign --verify --deep --strict --verbose=2 Linklet.app
codesign -dv --verbose=4 Linklet.app
xcrun stapler validate Linklet.app
spctl --assess --type execute --verbose=4 Linklet.app
lipo -archs Linklet.app/Contents/MacOS/Linklet
```

Проверить установку в /Applications на другом Mac из реально скачанного ZIP/DMG: Gatekeeper, первое открытие, приветствие, обработку ссылок после выбора браузером по умолчанию и запуск при входе. Неподписанная локальная сборка не заменяет эту проверку.

## Текст для передачи

«Передаю исходники Linklet для релиза 0.1.0. Нужно собрать Release из согласованной версии исходников, подписать Developer ID Application от согласованной команды, пройти notarization Apple, прикрепить ticket и вернуть ZIP/DMG. Прошу сохранить .xcarchive и dSYM, сообщить Team ID, bundle identifier, номер сборки и SHA-256. Сертификат и закрытый ключ остаются у подписывающей команды».

## Источники Apple

- https://developer.apple.com/developer-id/
- https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
