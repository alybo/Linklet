# AdGuard integration — 2026-09-05

One localized settings switch, disabled by default. Base + Russian optimized
filters are bundled and fetched from official AdGuard endpoints. The daily
limit is persisted across launches and includes failed attempts. No updates
are requested while disabled. Local rules are attached before page loading;
updates are converted off the main actor, compiled by WebKit, atomically saved,
and then applied. The existing list survives download/conversion failures.

Validation: 17 macOS XCTest tests passed with Xcode 26.6, including:
- 24-hour boundary and system-clock rollback;
- rejection of error pages and empty filters;
- actual bundled filter conversion and WebKit compilation offline;
- preservation of compiled rules and cached JSON after a network error;
- an injected successful update hiding a fixture element in WKWebView;
- disabling the blocker restoring that element after reloading;
- existing navigation, window behavior, preferences, and localization tests.

Test log: /tmp/linklet-test-final.log

The live official lists were downloaded successfully to create the bundled
snapshot. Scheduled network refresh was tested through an injected downloader;
the suite does not wait 24 real hours or depend on live advertising websites.

The implementation uses native content rules only. Scriptlets, extended CSS,
HTML filtering, and a full browser-extension runtime are outside this version.
Licenses and source attribution are bundled under Resources/AdGuard.
