# Передача Linklet для подписи и выпуска

Для выпуска 1.2 сначала прочитать [RELEASE-1.2.md](RELEASE-1.2.md).

## Рекомендуемый вариант

Передать весь каталог проекта через приватный Git-репозиторий с зафиксированным коммитом/тегом либо ZIP исходников. Включить Linklet.xcodeproj, Linklet, LinkletTests, README.md и docs. Не передавать DerivedData, xcuserdata, готовые промежуточные сборки, сертификаты .p12, закрытые ключи, пароли или токены. Все изображения уже входят в Assets.xcassets; путей к Downloads для сборки нет.

Лучше выпускать от вашей команды Apple Developer и дать человеку подходящий доступ к ней. Если он подписывает от собственной команды, издателем будет владелец этой команды; следующие релизы разумно подписывать той же командой. Заранее договоритесь, кто хранит доступ и делает обновления. Для обычной раздачи приложения нужен Developer ID Application из платной Apple Developer Program, а не Personal Team или только Apple Development.

## Что согласовать перед первым релизом

- Команда Apple Developer (Team ID) и имя издателя.
- Согласованный bundle identifier приложения: `Linklet`, тестового пакета: `LinkletTests`. Не менять между обновлениями без плана миграции.
- Подготовлена версия 1.2, номер сборки 3. См. [точный план выпуска](RELEASE-1.2.md).
- Формат раздачи: DMG вне Mac App Store и отдельный архив соответствующих исходников. Вручную в релиз загружаются только эти два файла.

## Порядок работы получателя

В проект включён Sparkle. Собирать с зафиксированными зависимостями из
Package.resolved; при экспорте Xcode должен подписать встроенный Sparkle и его
вспомогательные приложения. Компаньон также подписывает архив ключом Sparkle
на своём Mac и публикует его в GitHub Releases. До первого выпуска со Sparkle
создать ключ на Mac компаньона и согласовать его публичную часть в Info.plist.
В Release не включать Debug-entitlement
disable-library-validation. Подробнее: [Обновления](UPDATES.md).

1. Открыть Linklet.xcodeproj на Mac с Xcode 16 или новее, выбрать схему Linklet.
2. В Signing & Capabilities выбрать согласованную Team; проверить bundle identifier. Hardened Runtime уже включён, App Sandbox отключён намеренно для работы с браузерами.
3. Запустить тесты и проверить русский/английский интерфейс, приветствие, системный запрос браузера по умолчанию, режимы окна и открытие ссылки в установленном браузере.
4. Выбрать релизное назначение My Mac / Any Mac (как доступно в версии Xcode), Product → Archive. Для поддержки Intel и Apple Silicon проверить обе архитектуры в архиве.
5. В Organizer выбрать Distribute App → Direct Distribution либо Developer ID (название зависит от Xcode). Подписать Developer ID Application, отправить на notarization Apple, дождаться Accepted, экспортировать нотарифицированное приложение.
6. Прикрепить ticket к приложению. Создать DMG с приложением и ссылкой на /Applications, подписать и нотарифицировать образ, прикрепить его ticket. Подготовить полный архив исходников и запустить `scripts/prepare-sparkle-update.sh` с DMG, архивом исходников и путём к инструментам Sparkle.
7. Опубликовать только DMG и source.tar.gz из подготовленного каталога release/. Текст release-description.md с контрольными суммами добавить в описание релиза. Затем опубликовать feed/appcast.xml как updates/appcast.xml в репозитории. Сообщить владельцу ссылку на релиз, Team ID и результат нотарификации; сохранить .xcarchive и dSYM. Возвращать сборку владельцу для дополнительной подписи не требуется.

## Проверка готового приложения

В каталоге с экспортированным Linklet.app:

```sh
codesign --verify --deep --strict --verbose=2 Linklet.app
codesign -dv --verbose=4 Linklet.app
xcrun stapler validate Linklet.app
spctl --assess --type execute --verbose=4 Linklet.app
lipo -archs Linklet.app/Contents/MacOS/Linklet
```

Проверить установку в /Applications на другом Mac из реально скачанного DMG: Gatekeeper, первое открытие, приветствие, обработку ссылок после выбора браузером по умолчанию и запуск при входе. Неподписанная локальная сборка не заменяет эту проверку.

## Текст для передачи

«Выпусти Linklet по Linklet/docs/RELEASE-AGENT-PROMPT.md. Собери и нотарифицируй приложение и DMG, подпиши финальный DMG для Sparkle нашим скриптом. В релиз загрузи только DMG и полный архив исходников. Контрольные суммы помести в описание, appcast опубликуй последним. Для 1.2 используй существующий ключ Sparkle из выпуска 0.1.1; публичный ключ уже записан в проекте. Сохрани .xcarchive и dSYM; сообщи ссылку на релиз, Team ID, номер сборки и результаты проверок».

## Источники Apple

- https://developer.apple.com/developer-id/
- https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
