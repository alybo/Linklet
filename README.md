# Linklet

Native macOS link previewer and browser router built with Swift and WebKit.
Preview links in a compact window and open them in your preferred browser or
Orion profile. Includes English and Russian interfaces and optional AdGuard
content blocking.

## Development

Development repository (private): https://github.com/alybo/Linklet-dev.
Public distribution repository: https://github.com/alybo/Linklet.
The local `origin` must point to `Linklet-dev`.
See [release plan](PeekRoute-0.1.0-source/docs/RELEASE-PLAN.md) for the agreed repository roles and next steps.

Requirements: macOS 14 or newer and Xcode 16 or newer.

1. Open `PeekRoute-0.1.0-source/Linklet.xcodeproj` in Xcode.
2. Select the `Linklet` scheme and `My Mac` destination.
3. Run with Command-R.

See the [application README](PeekRoute-0.1.0-source/README.md) for setup,
features, and privacy details, and the
[signing handoff](PeekRoute-0.1.0-source/docs/SIGNING-HANDOFF.md) for distribution.

Run tests from the repository root:

```sh
xcodebuild -project PeekRoute-0.1.0-source/Linklet.xcodeproj \
  -scheme Linklet -destination 'platform=macOS' \
  -derivedDataPath /tmp/LinkletDerivedData test CODE_SIGNING_ALLOWED=NO
```

## Repository contents

- `PeekRoute-0.1.0-source/`: application source, Xcode project, tests, and documentation.
- `design/`: additional design assets.

Build products, exported applications, source ZIP backups, credentials, and
personal Xcode settings are excluded from Git. Swift package versions are
tracked in `Package.resolved`.

Third-party license texts and notices are included in
`PeekRoute-0.1.0-source/Linklet/Resources/AdGuard/`.
