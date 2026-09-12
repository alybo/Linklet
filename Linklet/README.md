# Linklet

Linklet is a native macOS link previewer and browser router. It receives web
links from other apps, opens them in a compact WebKit preview, and lets the user
continue in an installed browser or a specific Orion profile.

## Current MVP

- Registers as a handler for `http` and `https` links.
- Opens links in a floating preview window.
- Shows Back and Forward only when navigation in that direction is available,
  with trackpad gestures and Command-[ / Command-] shortcuts. Each new external
  link starts a fresh navigation history.
- Provides current-URL copying and a frequency-ranked Open in action.
- Discovers installed browsers through Launch Services.
- Discovers Orion profile proxy apps in the user's Applications folder.
- Opens the original incoming URL in an explicitly selected target app, even
  after redirects or navigation within the preview.
- Uses an ephemeral WebKit data store: preview cookies and history are removed
  when the app process ends and are never shared with browsers.
- Reuses one preview window. Each external link gets a fresh WebView with the
  same temporary website data store, keeping cookies while resetting history.
- Offers three window behaviors when switching apps: hide (default on first launch), keep open, or keep on top. Saved preferences are preserved.
- Can launch at login when enabled in Settings.
- Closes the preview with `Escape` or the close button. Space is passed through
  to the page for text entry, scrolling, and media controls.
- Reserves protected viewport areas above and below the page so site controls,
  dialogs, and fixed elements never sit underneath Linklet's chrome.

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

The preview uses `WKWebsiteDataStore.nonPersistent()`. It does not read cookies,
passwords, history, or extensions from Safari, Orion, Chrome, or Firefox.
Opening a target browser sends only the original incoming URL, so the page reloads in that
browser with its own profile and session.

## Next milestones

- Remember favorite and last-used targets.
- Add automatic routing rules by domain and source application.
- Add dedicated Chrome and Firefox profile discovery.
- Add persistent and disposable preview modes.
- Publish signed builds and activate the prepared Sparkle update feed.

## App updates

Sparkle 2.9.6 checks for updates and installs downloaded releases automatically
by default. Both preferences remain user-controlled in Settings, and Check for
Updates is also available from the menu bar. Release
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
