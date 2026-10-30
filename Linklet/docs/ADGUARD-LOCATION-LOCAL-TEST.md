# AdGuard site rules and native geolocation — local preview

No GitHub push, release, version change or TCC reset is part of this preview.

## AdGuard

- Right-click a loaded HTTP(S) page. The existing WebKit menu keeps its native
  commands and adds **Turn On AdGuard / Turn Off AdGuard** (localized in Russian).
- The action changes the current top-level hostname and automatically reloads
  that page after WebKit compiles and installs the rule list. Returning to the
  default removes the context-menu exception.
- Settings → General → AdGuard has a default switch and a native disclosure group
  for exceptions. Add a domain or HTTP(S) URL, toggle a site's rule, or remove it.
  Changes here refresh open pages of that hostname; changing the default refreshes
  open pages. Reloading intentionally discards unsent form edits.
- Site rules use the exact ASCII/Punycode hostname, across HTTP(S) and ports.
  `example.org` and `www.example.org` have separate rules. A site's override can
  enable AdGuard even when the default is off.
- The WKWebView, original browser-handoff URL, back/forward list and JavaScript
  opener relationships survive. Rules use `if-top-url` / `unless-top-url` inside
  the same compiled list, so a popup sharing a content controller can have a
  different policy. Subresources follow their top-level page's rule.
- Menu customization uses the existing macOS WebKit SPI delegate family, since
  WKUIDelegate has no public macOS context-menu customization hook. This small
  adapter must be rechecked on WebKit updates; it does not replace native menu
  commands or intercept page scripts.

## Location

- Managed site geolocation uses the public macOS 27 WKUIDelegate callback.
  Older supported macOS versions retain WebKit's default geolocation behavior;
  the managed location picker is only exposed on macOS 27 and later.
- On a secure website, press its own location action (for example, My Location
  in a map). Linklet presents a standard NSAlert site-consent sheet. A separate
  native macOS Location Services prompt may follow if access is not determined.
  WebKit starts Linklet's native Core Location adapter after consent. The adapter
  forwards fixes transiently to the engine; coordinates are not saved in history,
  preferences, diagnostics or other files. `navigator.geolocation` is not replaced.
- Denying site consent must produce a permission-denied result on the page.
  Camera, microphone and location decisions remain independent. Embedded content
  is scoped to both its requesting origin and the top-level website.
- Settings → Website data → Website permissions exposes Ask / Allow / Block for
  location alongside camera and microphone, plus System Settings when macOS has
  denied access. Blocking/resetting an already granted location permission
  reloads the document to destroy its active location watches; WebKit has no
  public per-page geolocation-stop API.
- Remember is opt-in. In private mode, remembered site permissions are memory
  only and disappear after the last website window closes. Persistent website
  data mode saves opted-in decisions. Old camera/microphone records decode with
  location set to Ask.

## Verification

Required command:

```
xcodebuild -project Linklet/Linklet.xcodeproj -scheme Linklet -sdk macosx test CODE_SIGNING_ALLOWED=NO
```

New checks exercise real WebKit rule compilation and CSS blocking on two views
sharing a content controller, default-off site overrides, persistence and rapid
policy changes. Native event delivery opens a real WebKit context menu and checks
the appended AdGuard action. The menu action is separately checked for reload
without replacing the view, history or original URL.

Location checks include actual `navigator.geolocation.getCurrentPosition` denial
through the public delegate, successful `watchPosition` delivery from a synthetic
native fix through WebKit's provider, independent site consent, revocation/stop,
private expiry and old-record migration. Automated tests do not grant Location
Services, read physical coordinates, or modify system privacy settings. A real
allowed map location remains a manual check on this Mac.

Local validation on 2026-10-30: the full command passed **145 tests, 0 failures**
on macOS 27.2 / macOS 27.0 SDK. The local preview and extracted ZIP both pass
`codesign --verify --deep --strict`, retain bundle identifier `Linklet`, and carry
the camera, microphone and location entitlements. No physical coordinates were
requested by automated tests.

## Follow-up: coordinate source, cursor ownership and fullscreen sidebar

The first preview handled site permission but missed macOS WebKit's coordinate
provider. Unlike its iOS implementation, macOS's `providerStartUpdating` returns
without a client provider. `Services/NativeLocationProvider.m` now connects public
Core Location APIs to WebKit's C provider SPI, with symbol-availability checks and
one adapter per process pool. Popups keep the same pool. Native updates begin
only after WebKit requests them for a permitted page, and stop when the engine
has no remaining watches. Transient `kCLErrorLocationUnknown` is left to Core
Location's retry behavior rather than immediately failing the site's request.
There is no JavaScript geolocation shim or coordinate persistence.

This adapter uses `WKContextGetGeolocationManager`,
`WKGeolocationManagerSetProvider`, `WKGeolocationPositionCreate`, provider result
callbacks and `WKRelease`. They are not public SDK APIs and must be checked on
WebKit updates. Reference implementations:
[WebGeolocationManagerProxy](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebGeolocationManagerProxy.cpp),
[provider ABI](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/C/WKGeolocationManager.h).
Debug-only synthetic input never creates a real CLLocationManager and is not
reachable from website JavaScript.

WebKit rejects its cursor updates while AppKit owns a cursor rectangle. A local
event monitor now yields native cursor rectangles only over the hit-tested live
WKWebView, restoring them over window chrome, address/find fields, other windows
and on teardown. No CSS cursor is guessed or overridden. The input/drag regression
wraps both main and popup windows in a native I-beam cursor rectangle and checks
typing, map grab/release, normal pointer and returning to native chrome.

Settings → Sidebar → **Hide in fullscreen apps** is opt-in and uses AppKit's
`currentSystemPresentationOptions`, its KVO notifications and active-space
notifications. When the active app is fullscreen, the panel, edge indicator,
hotkey and downloads entry point all remain hidden. An already visible sidebar
is dismissed immediately; leaving fullscreen restores normal availability.
No Accessibility or Screen Recording authorization is required. Automatically
hidden Dock/menu preferences alone do not count as fullscreen.

Follow-up validation on 2026-10-30: the full required command passed **147 tests,
0 failures**, including successful synthetic coordinate delivery through the
installed native provider, revocation/stop, native cursor behavior in both window
types and every fullscreen sidebar entry point. Native Core Location fixes still
need a manual map check in the packaged preview; automated checks use no physical
coordinates. The installed previous preview was confirmed to have the same Mach-O
UUID as its delivered build, ruling out a stale installed executable.
