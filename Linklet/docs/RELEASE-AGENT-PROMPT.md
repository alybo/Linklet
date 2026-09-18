# Промпт для выпуска Linklet

Выпусти текущий подготовленный тег Linklet из публичного репозитория
https://github.com/alybo/Linklet. Работай на Mac издателя с Developer ID,
профилем `notarytool`, ключом Sparkle и GitHub CLI. Не печатай и не передавай
пароли, токены, закрытые ключи или сертификаты.

Сначала прочитай `RELEASING.md`. Проверь, что `MARKETING_VERSION`,
`CURRENT_PROJECT_VERSION`, тег `vVERSION`, локальный `HEAD` и `origin/main`
соответствуют друг другу. Не переписывай существующие публичные теги.

Запусти:

```sh
scripts/release-preflight.sh
scripts/publish-release.sh
```

Preflight выполняет дорогие тесты и проверку полного corresponding-source архива
один раз. Если коммит и архив не изменились, его квитанция переиспользуется.
Публикация обязана проверить квитанцию, собрать universal app, подписать Developer
ID, напрямую нотарифицировать приложение и DMG через `notarytool`, прикрепить
tickets, подписать DMG для Sparkle, опубликовать ровно два assets и appcast
последним. Organizer и вспомогательный «carrier archive» не использовать.

По умолчанию профиль нотарификации — `scribe-notary`. При другом сохранённом
профиле передай его только через `LINKLET_NOTARY_PROFILE`. Если процесс был
прерван, продолжи через `scripts/publish-release.sh --resume`: не создавай вручную
второй релиз и не меняй уже подписанный DMG.

В конце сообщи URL релиза, tag/commit, version/build, Team ID, архитектуры,
SHA-256 обоих assets, URL appcast и результаты подписи, нотарификации, Gatekeeper,
тестов и публичной повторной загрузки. Реальный old → new update повторяй при
изменении Sparkle, ключа, feed/config, `AppUpdateService`, формата appcast или
процесса установки, а также перед новой major/minor-линией.
