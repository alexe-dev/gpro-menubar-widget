# GPRO for Android

The same account arithmetic as the desktop widget, on the phone: a home screen tile with
the account value, health and both prices, and an app with the full breakdown.

It computes from Yahoo quotes, so the figures keep moving outside Trading 212's session —
the same reason the desktop widget computes them.

## Where the data comes from

The phone cannot read Trading 212 or calibrate cash against it, so the Mac publishes what
it knows into a **private gist** and the phone reads that:

```bash
./tools/publish-sync.py     # from the repo root, on the Mac
```

The payload carries the open positions, the platform-calibrated cash, deposits, targets and
the tracked symbols. Re-run it after trading, after changing targets, or whenever the cash
has been re-pinned.

**The gist id is a credential.** A secret gist is unlisted, not private: anyone holding the
id can read the account figures, so it is never committed. `publish-sync.py` prints it —
enter it in the app. If it ever leaks, delete the gist (`gh gist delete <id>`) and publish
again; the old id dies with it.

The app reads the gist through `api.github.com/gists/<id>` rather than a raw link. Raw gist
URLs are served by a CDN that has handed out stale 404s from other edges, and they also
carry a revision SHA that changes on every publish.

## Building

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd android && ./gradlew assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk
```

The wrapper pins Gradle 8.11.1: the Homebrew Gradle (9.x) is newer than the Android plugin
expects and fails to resolve it.

The release build is signed with the debug key — this is a personal build, not a store upload.

## Refresh rate

The app refreshes every 15 seconds while it is open. The home screen widget is driven by
WorkManager, whose floor for periodic work is 15 minutes; tapping the widget opens the app
for a live view.
