# Linklet product brief

## Website description

**Linklet — Quick Look for links.**

Linklet для macOS открывает ссылки из других приложений в компактном окне поверх
текущей задачи. Быстро посмотрите страницу, закройте её или откройте в нужном
браузере — без лишних вкладок и переключений.

## Promise

Open any external link without losing context. Preview it immediately, then
send it to the browser and identity that belong to the task.

## Core flow

1. Another macOS app opens an HTTP or HTTPS URL.
2. Linklet appears over the current workspace and loads the page.
3. The bottom target shelf shows browsers and profiles.
4. The user dismisses the preview or opens its original incoming URL in a target.

## MVP boundary

The preview is an independent browser session. A live tab cannot be transferred
between WebKit and another browser. Forms, playback position, scroll state, and
preview cookies are not transferred; the selected browser reloads the URL.

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
