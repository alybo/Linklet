# Linklet product brief

## Website description

**Linklet — Quick Look for links.**

Linklet для macOS открывает ссылки из других приложений в компактном окне поверх
текущей задачи. Быстро посмотрите страницу, закройте её или откройте в нужном
браузере — без лишних вкладок и переключений. По умолчанию Linklet использует одно
окно; при необходимости пользователь включает отдельные окна для новых ссылок.

## Promise

Open any external link without losing context. Preview it immediately, then
send it to the browser and identity that belong to the task.

## Core flow

1. Another macOS app opens an HTTP or HTTPS URL.
2. Linklet appears over the current workspace and loads the page.
3. The bottom target shelf shows browsers and profiles.
4. The user dismisses the preview or opens its original incoming URL in a target.

## Windows and presence

- The default mode replaces the current preview with the next incoming link.
- An optional setting opens every incoming link in its own native macOS window.
  New windows cascade from the preceding one; the first opens centred.
- Linklet remembers a preview's frame separately for each exact website host. On a
  future visit it restores that frame, or clamps it into a currently visible display.
- Linklet is visible in the Dock whenever a preview or Settings window exists. With
  no windows it continues as a menu-bar app. The Dock menu retains macOS's normal
  window list and includes **Close All Windows**, which never quits the app.

## MVP boundary

The preview is an independent browser session. A live tab cannot be transferred
between WebKit and another browser. Forms, playback position, scroll state, and
preview cookies are not transferred; the selected browser reloads the URL.
Website-data privacy and window geometry are independent: a stored frame is only
local UI metadata, not website content or session data, so clearing website data
does not remove it.

## Product principles

- The first useful pixels should appear quickly.
- The user should never wonder which identity receives the link.
- Preview data should be private by default.
- Explicit routing must never fall back silently to Linklet itself.
- Browser-specific integrations live behind adapters so one browser's behavior
  cannot break every target.

## Planned target adapters

| Target | MVP | Later |
| --- | --- | --- |
| Installed macOS browsers | Launch app explicitly | Favorites and rules |
| Orion profiles | Discover proxy `.app` bundles | Compatibility fallback |
| Chromium profiles | Browser only | `--profile-directory` discovery |
| Firefox profiles | Browser only | Profile manager integration |
| Safari profiles | Browser only | Use supported system routing rules |
