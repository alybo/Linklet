# Linklet for Raycast

Select text in any app, run **Search Selected Text** (Linklet), and the results open directly in Linklet. Assign a hotkey in Raycast Settings → Extensions → Linklet. Choose a different shortcut from Linklet’s own quick-search shortcut.

The extension uses Raycast’s `getSelectedText()` API, just like the Arc extension. It has no clipboard fallback, polling, background command, or intermediate search view. Availability of selection depends on Raycast and the source app. Raycast may require Accessibility access; Linklet does not.

## Requirements

- macOS 14 or later, Raycast, and a Linklet build with `linklet://search` support.
- Select the installed Linklet app in the extension’s **Linklet Application** preference. Development copies can be selected there too.
- Set the search engine in **Linklet → Settings → Search**. The extension uses that setting automatically.

## Local installation

With Node.js 22.6 or later installed:

```sh
cd integrations/raycast-linklet
npm ci
npm run dev
```

Raycast imports the development extension. After the first successful import, stop the development watcher with Ctrl+C; the installed command remains available. Run it again after making source changes. Alternatively use Raycast’s **Import Extension** command and select this directory.

This extension is not published in the Raycast Store. Before store submission, replace the provisional `author: alybo` with the maintainer’s registered Raycast username (the current value is not a registered account) and follow Raycast’s publishing review.

## Checks

```sh
npm test
npm run typecheck
npm run build
npm run lint:source
# Store metadata validation additionally requires the registered author:
npm run lint
```

## Protocol

The extension explicitly opens the selected Linklet application with `linklet://search?text=<percent-encoded text>`. Text is encoded with `encodeURIComponent`, including spaces as `%20` and plus signs as `%2B`. Linklet treats all received text as a query, including text that resembles a URL. No text is logged or retained by this extension. The selected search engine receives the query when Linklet opens its results.

Linklet’s own hotkey always opens an empty input panel immediately. Built-in extraction of text from other applications is deferred to a future release.
