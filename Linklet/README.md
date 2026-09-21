# Linklet

Linklet is a native macOS link previewer and browser router. It receives web
links from other apps, opens them in a compact WebKit preview, and lets the user
continue in an installed browser or a specific Orion profile.

## Current MVP

- Registers as a handler for `http` and `https` links.
- Opens links in a native, resizable macOS preview window.
- Reuses the current preview window by default. An optional **Open links in new
  windows** setting gives every incoming link its own preview; new windows cascade
  from the previous one unless a saved position is available for the site.
- Keeps a separate window frame for each exact website host and restores it on a
  later visit. Saved frames are clamped to a visible display when monitors or their
  arrangement change.
- Appears in the Dock while any preview or Settings window is open, and otherwise
  remains available only from the menu bar. The Dock menu uses macOS's native window
  list and adds **Close All Windows**, which closes Linklet windows without quitting
  the app.
- Shows Back and Forward only when navigation in that direction is available,
  with trackpad gestures and Command-[ / Command-] shortcuts. Each new external
  link starts a fresh navigation history.
- Provides current-URL copying and a frequency-ranked Open in action.
- Discovers installed browsers through Launch Services.
- Discovers Orion profile proxy apps in the user's Applications folder.
- Opens the original incoming URL in an explicitly selected target app, even
  after redirects or navigation within the preview.
- Defaults to temporary website data, cleared when the preview closes or hides,
  including when switching apps in Hide mode. Each external link resets navigation history.
- Offers an explicit first-link choice to save sign-ins and site preferences locally.
  Settings can delete individual sites or all data, and expire sites after 7, 30,
  or 90 days without a top-level visit. Background requests do not renew visits.
- Provides five settings pages and a persistent manual browser order when usage
  sorting is disabled. About includes developer links and a support sheet.
- Offers three window behaviors when switching apps: hide (default on first launch), keep open, or keep on top. Saved preferences are preserved.
- Can launch at login when enabled in Settings.
- Closes the preview with `Escape` or the close button. Space is passed through
  to the page for text entry, scrolling, and media controls.
- Reserves protected viewport areas above and below the page so site controls,
  dialogs, and fixed elements never sit underneath Linklet's chrome.
- Provides Quick Search with configurable global shortcut, selectable search engine,
  and locally stored favorite sites.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer

## Run from Xcode

1. Open `Linklet.xcodeproj`.
2. Choose the `Linklet` scheme and `My Mac` as the destination.
3. Press **Run** (`Command-R`).
4. Open Linklet from its menu bar icon, then choose **Settings…**.
5. Press **Make Linklet Default Browser**.
6. Approve the macOS confirmation for both HTTP and HTTPS if it appears.
7. Click a link in Mail, Messages, Telegram, Slack, or another app.

The app must be installed in `/Applications` before default-browser behavior is
fully representative. Xcode development builds can still be tested, but macOS
may retain the path to a particular Derived Data build.

## Test without changing the default browser

Run the app from Xcode and use:

```bash
open -a Linklet "https://example.com"
```

If Launch Services has not registered the development build yet, replace
`Linklet` with the full path to the built `.app`.

## Orion profiles

Linklet looks for profile launchers below common Orion locations, including:

```text
~/Applications/Orion/Orion Profiles/
~/Applications/Orion RC/Orion RC Profiles/
~/Applications/Orion Profiles/
```

Orion has had version-specific bugs where an external URL is redirected to the
last active profile. Profile routing therefore needs to be tested on the exact
Orion release used for distribution.

## Privacy model

The preview defaults to `WKWebsiteDataStore.nonPersistent()`, rotated at every
close/hide boundary. Opting in uses Linklet's persistent WebKit store. Turning
saving off requires confirmation and deletes all stored website data. Cleanup
runs before the next preview; an active page is never cleared by a background timer.
Visit timestamps are stored only with saving enabled. Data for embedded domains
without a top-level visit ages from first discovery. The preview does not read cookies,
passwords, history, or extensions from Safari, Orion, Chrome, or Firefox.
Opening a target browser sends only the original incoming URL, so the page reloads in that
browser with its own profile and session.

Window position and size are stored separately as local interface preferences,
keyed by the exact host currently shown in the preview. They contain no website
content, cookies, sign-ins, or browsing history, and are retained when website data
is cleared or temporary preview data is rotated.

## Window management

The default single-window mode replaces the current preview when another external
link arrives. Enable **Open links in new windows** in Settings → General to keep
each incoming link in a separate preview. This setting is off by default.

With multiple windows, closing one keeps the remaining Linklet windows active. If
any preview or the Settings window is present, Linklet is a regular Dock app; when
the last window closes, it returns to menu-bar-only operation. **Close All Windows**
in the Dock menu closes previews and Settings without terminating the process, so
the global search shortcut and menu-bar controls remain available.

## Next milestones

- Remember favorite and last-used targets.
- Add automatic routing rules by domain and source application.
- Add dedicated Chrome and Firefox profile discovery.
- Publish signed builds and activate the prepared Sparkle update feed.

## App updates

Sparkle 2.9.6 provides Check for Updates in the menu bar and Settings, plus an
automatic-check preference. Automatic downloading/installation is disabled; downloading requires confirmation. Release
archives are signed with a dedicated EdDSA key; its public half is in Info.plist.
Only Debug disables library validation for local ad-hoc builds. Release retains
Hardened Runtime and must be distributed using Developer ID signing.

The repository includes the GitHub Pages feed and release preparation workflow;
public updates still require activating Pages and publishing signed releases. See
[Updates](docs/UPDATES.md) for setup, key ownership, and release instructions.

## Welcome page

On first launch, Linklet shows an offline welcome page inside the preview window.
Use **Знакомство с Linklet** in the menu bar or Settings to reopen it. The page
reports the default-browser status and opens native Settings. Status refreshes
when Linklet becomes active and after a default-browser change. Copy and browser
routing actions are hidden on this internal page; opening a web link replaces
it with a fresh normal preview. The Settings command is accepted only from the
current welcome document's main frame.

## Interface language and menu bar

Settings → Language supports System language, Русский and English. Changes apply
immediately to native views and the welcome page, and persist across launches.
The menu bar provides the three window behaviors; browser discovery can still
be refreshed in Settings. System-owned dialogs and system error descriptions
follow macOS language settings.

For release signing and notarization by another person, see
[Signing handoff](docs/SIGNING-HANDOFF.md).

## AdGuard ad blocking

Settings offers one switch: **Enable AdGuard ad blocker** (off by default).
It uses the AdGuard Base and Russian optimized filters with WebKit content
blocking. Local bundled rules are prepared before the first protected page
loads; no network connection is needed to enable blocking. Conversion runs
outside the main actor. Switching the setting reloads the current preview.

While enabled, Linklet checks the official AdGuard HTTPS endpoints at most
once every 24 hours (launch, activation, and an hourly deadline check while
running). Failed attempts also count toward this interval. No background daemon
runs when Linklet is closed. Updates replace the previous set only after
successful conversion, WebKit compilation, and atomic persistence. The last
working JSON is kept in Application Support/Linklet/AdGuard; bundled filters
are the fallback if the cache is absent or cannot compile. Existing previews
receive updated rules without an unsolicited reload; already loaded content
changes on the next navigation/reload. Turning the switch off removes the
rules and cancels the current update.

SafariConverterLib is pinned to an exact revision in the Xcode project;
Package.resolved pins its dependencies. The converter updates with the app,
while filter data updates independently. Native Safari 16.4-compatible rules
are used for macOS 14 and later. Advanced scriptlets/extended CSS and HTML
filtering are not enabled; this is not feature-equivalent to full AdGuard.
No separate tracker, cookie-banner, or annoyance lists are enabled.

Third-party notices and GPL v3 license texts are bundled in
Linklet/Resources/AdGuard. Distribution of the linked converter and filters
must comply with their licenses, including corresponding-source obligations.

## Quick Search

Press Control–Option–Space (configurable in Settings → Search) or choose
**Quick Search** from the menu bar. The native glass panel accepts search queries
and web addresses. Google is the initial search engine; Settings also offers
Yandex, DuckDuckGo, and Bing. The split button in the panel uses monochrome engine
marks and a popover, matching the preview’s browser selector. Its primary action
submits the query; the chevron changes the engine only for the current query.
Enter opens the destination through the ordinary Linklet preview flow. Escape,
switching focus, or pressing the shortcut again dismisses and clears the panel.
Every opening starts empty with the configured default engine; queries are not saved.

### Favorite sites

Settings → Search can store a locally ordered list of favorite HTTP(S) sites.
Each entry has a name, address, optional cached favicon, and a tile in Quick Search.
Users can add, edit, delete, or drag entries to reorder them. The **Show favorites
in Quick Search** toggle hides the tile row without deleting the list. The search
panel uses a fixed compact or expanded layout depending on whether this enabled
list has entries; extra tiles scroll horizontally.

Clicking a tile opens its address through the same ordinary preview flow as a typed
web address. Keyboard navigation is local to Quick Search: Down Arrow selects the
first tile, Left/Right move the selection, Up Arrow returns to the text field, and
Enter opens the selected site. Command-1 through Command-9 open the first nine
favorites directly. Moving the selection automatically reveals its tile;
vertical mouse-wheel and trackpad scrolling move the tile row horizontally.

Favicon loading is explicit: the user presses **Load favicon** for an individual
entry in Settings. Linklet makes one ephemeral, cookie-free request to that site's
`/favicon.ico` endpoint, validates the image, and stores it locally with the
favorite. It neither performs favicon requests automatically nor sends this request
through the preview's persistent website-data store. If loading fails, the tile
uses the generic globe icon.

The global shortcut opens the empty search panel synchronously on key-down.
The panel is prepared at startup. There is no selection inspection, clipboard
copying, polling, key-release wait, or Accessibility permission requirement.
Built-in search of selected text is deferred to a future release.

The optional [Raycast extension](../integrations/raycast-linklet/README.md) gets
selected text through Raycast and sends it to Linklet. Linklet uses its configured
default search engine and opens results in the normal preview window. The
integration accepts `linklet://search?text=<percent-encoded text>`. Selected text
is always searched; web addresses entered manually in the panel open directly.
Raycast is not required for Linklet’s own search panel or normal link previews.

The hotkey registration does not require Input Monitoring. Recording supports
Command, Option, or Control combinations and reports unavailable system/app
shortcuts. Linklet must be running. macOS 26 and later use native Liquid Glass,
with a native visual-effect material on macOS 14–15.

Web previews keep WebKit’s native desktop user agent and add Safari’s version
and product tokens so websites can recognize the embedded desktop browser.
