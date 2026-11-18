# Tove app (Flutter): developer notes

What Tove is, how to run the bridge and how to connect are in the [root README](../README.md). This file is for
working on the app.

Dart package `tove_chat`; Android application id and iOS/macOS bundle id `io.github.tovechat.tove`. The display
names ("Tove" for the app, "Hermes" for the assistant) live in `lib/src/brand.dart`.

In live mode you start a call and talk. Audio goes **directly** between this device and GPT-Live over WebRTC. The
bridge (`server/gpt-live-bridge.py`) only exchanges the SDP and runs delegated Hermes tasks. This is the same
protocol as `server/hermes-live.html`, the bridge's minimal browser page.

Targets: Android, iOS, Linux, macOS, Windows and the web.

## Protocol

| Step | Request |
| --- | --- |
| Offer | `POST /api/session {offer, voice}` → `{session, answer}` (Bearer key) |
| Events | data channel `oai-events`: `session.started`, `turn.created`, `input_transcript.added`, `output_transcript.added`, `turn.done`, `delegation.created`, `error` |
| Task | `delegation.created` → `POST /api/delegate {session, text}` → poll `GET /api/job/{sid}/{jid}` every 1.2 s → send `delegation.context.append` |
| Hang up | `POST /api/stop {session}` |
| Key check | `GET /api/job/check/check`: 404 means the key is valid, 401 means it is wrong. This check has no side effects. |

Rules that match the server:

- One live session at a time. Starting a call here ends a call on another device.
- At most two tasks run at once. A 429 response is shown as "Not started: busy", and the voice model is told so.
- Small-talk delegations are answered without creating a task.
- Each delegation item id is handled once.
- If the call ends while a task is running, the task is shown as "Stopped", because the bridge cancels the jobs of a closed session.

## Call lifecycle

`CallController` (`lib/src/call/call_controller.dart`) owns the call.

1. It opens the microphone. The OS permission prompt appears at this step.
2. It calls `startCall` on the native channel. On Android the microphone foreground service may only start after the permission is granted and while the app is visible. On iOS, CallKit may take a moment to confirm.
3. It creates the peer connection and the offer, then waits up to 2.5 s for ICE gathering.
4. It sends `POST /api/session` and applies the answer.
5. The call is live when `session.started` arrives. If that event has not arrived 20 s after the answer, the call fails with a clear message.

Every step can be cancelled. Hanging up switches the UI to idle immediately, then releases the tracks, the peer connection, the data channel, the stats timer, task polling and the native call. A session that the server creates after the hang-up is stopped as soon as its id arrives. Errors never leave the app in a "connecting" state.

When the peer connection fails or closes, the call ends with "Connection lost". If it reports `disconnected`, the app waits 6 s for it to reconnect before ending the call.

## Native call channel

Channel: `io.github.tovechat.tove/call`. The contract is documented in `lib/src/platform/call_platform.dart`.

| Direction | Method | Arguments |
| --- | --- | --- |
| Flutter → native | `startCall` | `{muted: bool}` → `{notificationsVisible, warning?}` |
| Flutter → native | `updateCall` | `{muted: bool}` |
| Flutter → native | `endCall` | `{}` |
| native → Flutter | `onMute` | `{muted: bool}` → `true` when applied, `false` when there is no call |
| native → Flutter | `onEnd` | `{}` → `null` |

The channel is used only on Android and iOS. On the web and on desktop it is a no-op.

If `startCall` reports `notificationsVisible: false` (Android with notifications off), the app shows the native warning: the call keeps running in the background, but it has no controls in the shade or on the lock screen.

A mute toggled while `startCall` is still pending is sent with `updateCall` once the native call is live. `onMute` with no call in Dart answers `false`, so Android ends its stale service instead of showing a mute that nothing applied. `onEnd` with no call still calls `endCall`.

If the native side is missing or reports an error, the app shows a notice and the call continues in the foreground. The background status then reads "limited", so the call is never wrongly presented as backgrounded. `endCall` can arrive while `startCall` is still pending, and it must be idempotent.

## Audio

- Remote audio plays natively. On the web it plays through a hidden audio element created by `RTCVideoRenderer`.
- Android uses flutter_webrtc's `communication` audio configuration.
- On phones the speaker toggle uses `setSpeakerphoneOnButPreferBluetooth` for the speaker and `setSpeakerphoneOn(false)` for the earpiece.
- Mute disables the outgoing track. The mute state is mirrored to the native call in both directions.
- The orb reacts to measured levels: `media-source` and `inbound-rtp` `audioLevel` from WebRTC stats, or RMS computed from the energy counters. Where a platform reports no levels, the orb follows only the transcript events and a slow idle breathing.
- Reduce motion is available as an in-app switch, and the app also follows the system setting.

## Settings and secrets

The access key is the bridge's `LIVE_PAGE_KEY`. It is stored with `flutter_secure_storage` and is never logged or written to preferences:

- iOS: Keychain, readable after first unlock, so task polling keeps working on a locked phone.
- Android: encrypted storage.
- Linux: libsecret.
- Windows: Credential Manager.
- Web: WebCrypto-encrypted IndexedDB/localStorage. This is obfuscation, not a hardware keystore.

The server address, voice, theme and reduce-motion setting are stored in `shared_preferences`.

There is no default server: the connect screen starts empty. On the web it proposes the page's own origin, because the bridge sends no CORS headers, so the web app only works when the bridge serves it (`/app/`).

## Keyboard

- `M`: mute or unmute.
- `Esc`: end the call.
- `T`: open the transcript and tasks on narrow layouts.

All controls can be reached with Tab and have semantic labels.

## Web fonts

The web build bundles Roboto. For glyphs Roboto lacks (emoji, CJK, Arabic, Indic scripts, symbols), the CanvasKit engine
loads Noto fallback fonts on demand. `web/flutter_bootstrap.js` sets `fontFallbackBaseUrl` to the app's own
`fonts/fallback/`. `tool/web_fallback_fonts.py` copies there exactly the files the compiled `main.dart.js` can request
(728 files, 36 MB for Flutter 3.50, SIL OFL 1.1). A browser downloads only the few files the text on screen needs. The
bridge CSP stays same-origin, and no third-party font CDN is contacted at runtime. The fonts are cached in
`~/.cache/hermes-live/web-fallback-fonts/`. They are fetched from the CDN once, at build time, with only the public font path.
`deploy-app.py` refuses a web build whose fallback set is missing or incomplete.

## Develop

```sh
flutter pub get
dart format lib test
flutter analyze
flutter test -j 1
flutter build web --release --base-href /app/ --no-web-resources-cdn --no-wasm-dry-run
python3 -I tool/web_fallback_fonts.py --web-dir build/web --fetch
```

Release builds with evidence (toolchain, git state, SHA-256, APK badging, debuggable flag, signer certificate digest
and a secret scan that reports only variable names). Reports go to `~/.local/state/hermes-live-qa/builds/`:

```sh
python3 -I tool/build_release.py web --checks         # then: deploy-app.py --web-dir build/web
python3 -I tool/build_release.py apk-debug            # device QA over adb reverse only; never published
python3 -I tool/build_release.py apk-release          # signed, non-debuggable; refused otherwise
```

To serve a web build from your own bridge, copy it with `python3 -I ../server/deploy-app.py --web-dir build/web`.

`server/deploy-app.py` copies a web build and/or an APK into the bridge's data directory (`--destination`, default
`$BRIDGE_DATA_DIR` or `~/.local/share/gpt-live-bridge`), where the bridge serves them at `/app/` and
`/downloads/hermes-live.apk`. Run it as the bridge's user. It refuses a build that contains a secret from that
directory's `bridge.env`, and a debuggable APK unless `--allow-debug` is given. That is only for serving your own
builds; official releases are published on GitHub (below).

Builds use the shared toolchain and Gradle home (`~/.local/share/hermes-build-tools`, override with
`TOVE_BUILD_TOOLS`), whose `gradle.properties` caps Gradle at 1536 MB and two workers. APK builds need JDK 21 or
newer, because AGP 9's release lint (`lintVitalAnalyzeRelease`) crashes on JDK 17. The script uses `$TOVE_JDK`, or else
the newest JDK 21+ under the toolchain's `sysroot*/usr/lib/jvm/` (for example
`sysroot-jdk21/usr/lib/jvm/java-21-openjdk-amd64`, beside a JDK 17 `sysroot`). The app's bytecode target
stays Java 17. A global `flutter config --jdk-dir` outranks `JAVA_HOME`, so the script gives Flutter a private copy of
your settings with `jdk-dir` set to that JDK under `~/.local/state/hermes-live-qa/flutter-config/`. Your own settings
are not changed. Before Gradle starts, the script refuses to build if Flutter would resolve a different JDK or an
`org.gradle.java.home` pins one. Release signing comes from
`$TOVE_KEY_PROPERTIES` (the path of a `key.properties` file), then `android/key.properties` (gitignored), then a
per-user fallback outside the repo; Gradle reads it (`docs/native-call-integration.md`, "Release signing"). Other overrides: `TOVE_FLUTTER`, `TOVE_BRIDGE_ENV` (the
`bridge.env` whose secrets the build scans for, default `~/.local/share/gpt-live-bridge/bridge.env`), `TOVE_QA_STATE`,
`TOVE_PACKAGE`, and for `tool/device_qa.py` `TOVE_QA_SERIAL` (needed only with several adb devices) and
`TOVE_BRIDGE_PORT` (default 8787) (the old `HERMES_*` names still work).

The tests use fakes for the transport, bridge and native channel. They never open a microphone.

## Releasing

Tove is released only on GitHub: a signed APK attached to a GitHub release of `itskavin/tove`. The app's update check
(`lib/src/update/`) reads `GET https://api.github.com/repos/itskavin/tove/releases/latest`, so what that endpoint
returns is what every install is offered.

**Tag convention:** `vX.Y.Z+N`, exactly the pubspec version with a `v` (`v1.2.0+5`). `X.Y.Z` is the versionName people
see; `N` is the Android versionCode and must grow with every release, because Android refuses to install a lower one
over a higher one. The app compares `X.Y.Z` first and `N` only when both sides have one; a tag it cannot read falls
back to the version in the APK's name. The APK asset is `tove-X.Y.Z.apk` (the check prefers that name; any `.apk`
works). Drafts and pre-releases are never offered.

1. Bump the version in **both** `pubspec.yaml` (`version: 1.2.0+5`) and `kAppVersion` in `lib/src/app.dart`. A test
   and the build script both refuse a mismatch. Commit and push to `main`.
2. Build with the release key (`TOVE_KEY_PROPERTIES`; always the same key, or existing installs cannot update):

   ```sh
   TOVE_BRIDGE_ENV=/path/to/bridge.env python3 -I tool/build_release.py apk-release --checks
   ```

   Besides the evidence report it writes `build/release/tove-1.2.0.apk`, a notes stub
   `build/release/notes-v1.2.0+5.md` (kept on rebuilds) and prints the next commands. It never publishes anything.
3. Edit the notes. They are shown in the app's update dialog as plain text, so keep them short Markdown.
4. Tag the release commit and publish (the script prints these with your paths):

   ```sh
   git tag -a v1.2.0+5 -m 'Tove 1.2.0' && git push origin v1.2.0+5
   gh release create v1.2.0+5 build/release/tove-1.2.0.apk --repo itskavin/tove --verify-tag \
     --title 'Tove 1.2.0' --notes-file build/release/notes-v1.2.0+5.md
   ```

Installs see it within a day (or at once from Settings › About › Check for updates). Unauthenticated GitHub API calls
are limited to 60 an hour per address; the app checks at most once a day and stays quiet when limited or offline.

## Known limits

- Voice signalling (`POST /api/session`) goes over the bridge's public HTTPS address. The bridge passes the SDP through unchanged, and the audio and data channel then connect directly to the voice provider's public media candidates, not to the home network, so no TURN server is needed for that path. Calls over mobile data or restrictive networks (TLS-only or proxy-only Wi-Fi, IPv6-only) are still unverified.
- Android cannot start a microphone call from the lock screen or a notification. Calls start in the app.
- iOS builds need macOS with Xcode. CallKit behaviour on the lock screen must be tested on a real device.
- Browsers may pause the microphone when the tab is in the background. The web app says so during a call.
- The Linux build needs `libsecret-1-dev` and the GTK development packages, and at runtime a keyring for the key.
