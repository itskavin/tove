# Native call integration (Android and iOS)

Tove keeps a voice session running with the screen off and puts Mute and End controls in the notification shade and on the lock screen. Dart owns WebRTC through `flutter_webrtc` ^1.6.3. The native code keeps the process and Flutter engine alive, shows the system controls, and forwards those controls to Dart. If Dart cannot be reached, the native code shuts the microphone off itself.

Status: Android compiles (see Validation). iOS has not been compiled, because Xcode only runs on macOS. Neither platform has been tested on a device yet.

## Channel contract

The channel is `io.github.tovechat.tove/call`, a standard `MethodChannel`.

| Direction | Method | Arguments | Result |
|---|---|---|---|
| Flutter → native | `startCall` | `{muted: bool}` | Android: `{notificationsVisible: bool, warning: String?}`. iOS: `{callKit: true, notificationsVisible: true}`. Fails with a `PlatformException` (codes below). |
| Flutter → native | `updateCall` | `{muted: bool}` | `{active: bool}`. Does nothing when no call is live. |
| Flutter → native | `endCall` | `{}` | `null`. Safe to call more than once. If a `startCall` is still pending, it fails with `cancelled`. |
| Native → Flutter | `onMute` | `{muted: bool}` | Dart answers `null` or `true` once it has applied the change. `false` means "not applied". |
| Native → Flutter | `onEnd` | `{}` | Dart answers right away and runs teardown asynchronously. It still calls `endCall`. |

Every Flutter call gets exactly one answer. That holds when a permission dialog is dismissed, when the activity goes away mid-request, when CallKit refuses, when the service never reports back (6-second timeout), and when the engine is destroyed.

Order expected from Dart:

1. `getUserMedia` (this opens the microphone and, on Android, the plugin requests `RECORD_AUDIO`).
2. `startCall`.
3. Create the peer connection and do SDP.
4. `endCall`.

Error codes from `startCall`:

| Code | Platforms | Meaning |
|---|---|---|
| `not_visible` | Android, iOS | The app is not on screen. A microphone call can only start from the visible app. |
| `microphone_denied` | Android, iOS | Microphone permission was declined, or is off in Settings. |
| `busy` | Android, iOS | Another `startCall` is already in progress. |
| `cancelled` | Android, iOS | `endCall` arrived before setup finished. |
| `service_start_failed` | Android | `startForegroundService` threw. |
| `foreground_denied` | Android | `startForeground` threw (Android refused a microphone FGS). |
| `service_timeout` | Android | The service did not report back in time. |
| `engine_destroyed` | Android | The Flutter engine was destroyed during setup. |
| `callkit_failed` | iOS | The CallKit transaction failed. Audio is handed back to flutter_webrtc, so Dart can keep the session going without lock-screen controls. |
| `bad_arguments` | Android, iOS | `muted` is missing or is not a bool. |

On both platforms, `startCall` while a call is already live is a no-op apart from syncing the mute state.

Dart side: `MethodChannelCallPlatform.startCall` reads the result map. When `notificationsVisible` is `false` it returns the native `warning` (or a default text if that is missing), and `CallController` shows it as a dismissible notice while the call keeps running.

## Android

Files are under `android/app/src/main/`:

- `kotlin/io/github/tovechat/tove/MainActivity.kt` attaches to the shared engine and forwards activity visibility and permission results.
- `kotlin/.../HermesEngine.kt` holds the one process-wide `FlutterEngine` (in `FlutterEngineCache`), keeps it while a call is live, and has the defensive teardown.
- `kotlin/.../CallBridge.kt` is the MethodChannel, the permission flow, the start handshake, and native→Dart acknowledgements with timeouts.
- `kotlin/.../HermesCallService.kt` is the microphone-type foreground service.
- `kotlin/.../CallNotification.kt` builds the channel, the notification and the PendingIntents.
- `res/drawable/ic_stat_hermes.xml` (winged-H glyph), `ic_call_mic.xml`, `ic_call_mic_off.xml` and `ic_call_end.xml` are vector icons. The last three are Material icons, Apache 2.0.
- `res/values/strings.xml` and `colors.xml` hold the strings and the Hermes accent `#6AA8FF`.
- `AndroidManifest.xml` declares the permissions and the service. Release builds have no cleartext setting, so they keep the platform default of HTTPS only.

Debug only, under `android/app/src/debug/`: `res/xml/network_security_config.xml` and `AndroidManifest.xml` allow plain HTTP to `127.0.0.1` and `localhost` only. This exists for `adb reverse tcp:8787 tcp:8787` testing against a bridge on the build machine (`http://127.0.0.1:8787`). Release and profile builds do not include it.

Build settings: `minSdk = max(23, flutter.minSdkVersion)` (24 with Flutter 3.50), `compileSdk` and `targetSdk` from Flutter (36), Java and Kotlin target 17. No dependencies were added; the native code uses platform APIs only.

### Release signing

Release builds are signed with a stable key that is kept outside the repo. They never fall back to the debug key. Debug builds still use the standard debug key and the loopback cleartext config.

- Keystore: any PKCS12 or JKS keystore of yours, for example made with
  `keytool -genkeypair -storetype PKCS12 -keyalg RSA -keysize 4096 -validity 18250 -alias tove -keystore tove-release.p12`.
  Keep it outside the repo, mode 600.
- Config: a `key.properties` file (mode 600) with `storeFile`, `storeType`, `keyAlias`, `storePassword` and `keyPassword`. Never commit it or print it.

`android/app/build.gradle.kts` uses the first config it finds, in this order:

1. `$TOVE_KEY_PROPERTIES`, the path of your `key.properties` (then the legacy `$HERMES_LIVE_KEY_PROPERTIES`)
2. `android/key.properties` (gitignored)
3. a per-user fallback path outside the repo, kept for existing setups (see `releaseKeyProperties` in the Gradle file)

A relative `storeFile` path resolves against the folder of the properties file. If none of these exists, any `package*Release` task fails with an explanation, so no unsigned or debug-signed release is ever produced.

**Back up both files together** (for example in a password manager, or on offline storage). Android only installs an update over an existing install when it is signed with the same key. If the keystore or its password is lost, every phone has to uninstall the app, losing its stored access key, before a newly signed build can be installed.

### Permissions and start flow

Declared permissions:

- `RECORD_AUDIO`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_MICROPHONE`
- `POST_NOTIFICATIONS`
- `MODIFY_AUDIO_SETTINGS`
- `INTERNET`
- network state
- legacy `BLUETOOTH` (up to API 30)

There is no telecom or phone-call permission, no boot receiver, and no `SYSTEM_ALERT_WINDOW`.

What `startCall` does:

1. It refuses (`not_visible`) unless `MainActivity` is started. This prevents starting a microphone FGS from the background.
2. If `RECORD_AUDIO` is missing, it asks once from the activity. If declined, it fails with `microphone_denied`.
3. On Android 13+, if `POST_NOTIFICATIONS` is missing, it asks once. If declined, the call still starts and the result has `notificationsVisible: false` plus an honest warning, instead of claiming that lock-screen controls exist.
4. It calls `startForegroundService`. The service calls `startForeground(..., FOREGROUND_SERVICE_TYPE_MICROPHONE)` and reports success or failure back through `CallBridge`. Only then does the Dart future complete. A 6-second timeout covers the case where the service never reports.

### Notification

- The channel is `hermes_live_call` with `IMPORTANCE_LOW`: no sound, no vibration, no heads-up. Updates use `setOnlyAlertOnce`, so they never buzz.
- It is ongoing, with `CATEGORY_CALL`, `VISIBILITY_PUBLIC`, and a chronometer that starts at the call start time.
- The text is only "Voice session in progress", "Muted · …" or "Ending…". It never contains transcript or task content, so it is safe on the lock screen.
- On Android 12+ it uses `Notification.CallStyle.forOngoingCall`: the system draws the Hang up button, shows the status-bar call chip, and makes the notification non-dismissible on Android 14+. Mute/Unmute is an added action. If CallStyle is rejected, it falls back to a plain notification with Mute and End actions.
- Tapping the notification opens `MainActivity`.
- If the plain notification is swiped away, its delete intent posts it again.
- All PendingIntents are explicit and `FLAG_IMMUTABLE`, and they target the non-exported `HermesCallService`.

### Engine retention

`MainActivity.provideFlutterEngine` returns the cached engine. `shouldDestroyEngineWithHost()` is false while a call is live. When the screen turns off, the activity stops, or the activity is destroyed, Dart (and so WebRTC and the `onMute`/`onEnd` handlers) keeps running. The foreground service keeps the process alive. Tapping the notification reattaches the UI to the same engine.

Without a live call, the engine is destroyed with the activity, like a stock `FlutterActivity`. After a call ends with no activity attached, the engine is released after 15 seconds.

For the Dart side: `AppLifecycleState.detached` or `paused` during a call does not mean the call ended.

### Mute, End and teardown

When the user taps Mute or Unmute, the service calls `onMute`. It updates the notification only after Dart acknowledges.

When the user taps End, the notification switches to "Ending…" and the service calls `onEnd`. It then waits up to 10 seconds for Dart's `endCall`.

`endCall` from Dart runs `stopForeground(STOP_FOREGROUND_REMOVE)` and `stopSelf`. The service uses `START_NOT_STICKY`, so Android never restarts it.

If the task is removed (swiped from recents), the service sends `onEnd` and gives Dart 4 seconds before force teardown.

If the service is destroyed while live, it removes the foreground state, sends `onEnd` as a best effort, and forces teardown if that fails.

Defensive path: when Dart is unreachable it is a privacy problem, so the call is torn down. "Unreachable" means no channel, an error, `notImplemented`, `false`, a missing acknowledgement (4 s for mute, 8 s for end), or an `onEnd` acknowledgement with no `endCall` within 10 s. In that case `HermesEngine.forceTeardown` runs:

- If an activity is attached, it finishes the activity. The call is no longer live, so the activity's `onDestroy` destroys the engine. Destroying an engine under a live activity would crash the activity.
- Otherwise, it destroys the headless engine.

Destroying the engine detaches `flutter_webrtc`. Its `onDetachedFromEngine` disposes all peer connections and local tracks, which releases the microphone, and calls `AudioSwitchManager.stop()`, which abandons audio focus and restores the audio mode. As a last check after 1.5 seconds, `MODE_IN_COMMUNICATION` is reset to `MODE_NORMAL` if no call is live.

A Mute that cannot be confirmed also ends the call. Without Dart, nothing can disable the WebRTC track, and Android has no per-app microphone mute that is safe to use.

### Audio focus

The service does not request audio focus. `flutter_webrtc`'s `AudioSwitchManager` already requests `AUDIOFOCUS_GAIN` with `USAGE_VOICE_COMMUNICATION`, sets `MODE_IN_COMMUNICATION` when the peer connection starts, and releases both when the peer connection is disposed or the plugin detaches. A second focus request from the same app would make AudioSwitch see a focus loss. The Dart call to `Helper.setAndroidAudioConfiguration(communication)` fits with this.

## iOS

Files:

- `ios/Runner/HermesCallKit.swift` is the CallKit bridge. It is registered in `AppDelegate.didInitializeImplicitFlutterEngine` and added to the Runner target in `project.pbxproj`.
- `ios/Runner/Info.plist` has `NSMicrophoneUsageDescription` and `UIBackgroundModes = [audio]`.
- `ios/Runner/Assets.xcassets/CallKitIcon.imageset` holds the winged-H SVG, used as the CallKit template icon.

The deployment target is iOS 15.0 in the project. That is at least the iOS 13.0 that flutter_webrtc's podspec and `Package.swift` require. No Podfile is checked in: Flutter generates it, and its `post_install` applies the project deployment target.

No entitlements file is added, because none is needed. CallKit and the microphone need no entitlement, and there is no PushKit and no `voip` background mode.

### Call flow

- `startCall` refuses if the app is in the background. It checks microphone permission (`AVAudioApplication` on iOS 17+, `AVAudioSession` before that), asks if undetermined, and fails with `microphone_denied` if denied.
- It then requests a `CXStartCallAction` with a generic handle "Hermes". The provider reports connecting and connected, and the future resolves.
- Provider settings: `includesCallsInRecents = false`, one call, no video, no hold.
- `updateCall` requests a `CXSetMutedCallAction` so the CallKit UI matches. That action is not echoed back to Dart.
- A `CXSetMutedCallAction` from the CallKit or lock-screen UI applies the mute natively first (`RTCAudioDeviceModule.setMicrophoneMuted`), then sends `onMute`.
- A `CXEndCallAction` from the CallKit UI silences WebRTC natively right away, then sends `onEnd`. When the end comes from Dart's `endCall`, the Dart result resolves after CallKit has ended the call. If the end transaction fails, the call is closed locally with `reportCall(endedAt:)`.
- `providerDidReset` ends everything and sends `onEnd`.

### Audio session (checked against flutter_webrtc 1.6.3 and WebRTC-SDK 150.7871.04 headers)

flutter_webrtc 1.6.3 builds its factory with the AVAudioEngine ADM (`RTCAudioDeviceModuleTypeAudioEngine`) on devices and the platform ADM on the Simulator. Its own session management (`ensureAudioSession`, `deactiveRtcAudioSession`, speaker routing) only sets the category and mode and changes routes. That management is left enabled, so `Helper.setSpeakerphoneOn*` from Dart keeps working.

What the bridge does:

1. **Before the CallKit request:**
   - `RTCAudioSession.useManualAudio = true` and `isAudioEnabled = false`.
   - Set the category to `playAndRecord`, mode `voiceChat`, option `allowBluetooth`, under `lockForConfiguration`, without activating the session.
   - `RTCAudioDeviceModule.setEngineAvailability({input: NO, output: NO})`, so no engine I/O starts before CallKit activates the session.
2. **`provider(_:didActivate:)`:** `audioSessionDidActivate`, `isAudioEnabled = true`, engine availability set back to available, and the mute state reapplied.
3. **`didDeactivate`:** `audioSessionDidDeactivate`, `isAudioEnabled = false`, engine unavailable.
4. **When a call ends:** the ADM microphone is muted and the engine made unavailable, so the microphone stops even if Dart has not disposed its tracks yet. This state stays until the next `startCall`.
5. **If CallKit fails:** manual audio is turned off and the engine made available again, which hands control back to flutter_webrtc.

The ADM is reached through `FlutterWebRTCPlugin.sharedSingleton().peerConnectionFactory.audioDeviceModule`, which is public in the plugin header. It exists after Dart's first WebRTC call (`getUserMedia`). The imports are guarded by `#if canImport(WebRTC)` and `#if canImport(flutter_webrtc)`. If a build setup (for example Swift Package Manager) hides either module from Runner, the bridge still compiles but logs that the audio hand-off is disabled. Check the Xcode build log for that message.

### Things that need a Mac and a real iPhone

- Compiling the bridge at all. Swift names were derived from the Objective-C headers, including `RTCAudioEngineAvailability(isInputAvailable: ObjCBool, …)`, `setCategory(_:mode:options:)` and `FlutterWebRTCPlugin.sharedSingleton()`. These are the most likely places for a compile fix.
- Whether `import flutter_webrtc` and `import WebRTC` both resolve from Runner. This is expected with CocoaPods `use_frameworks!`. Check it again if Flutter's Swift Package Manager integration is enabled.
- Whether the AVAudioEngine ADM honours `setEngineAvailability` and the timing of CallKit `didActivate`, so audio starts after activation and does not get stuck silent.
- Lock-screen behaviour: iOS shows the call banner and the CallKit UI with Mute and End. It is not a custom notification.
- `.allowBluetooth` triggers a deprecation warning on the iOS 26 SDK (renamed to `allowBluetoothHFP`). It is kept for older Xcode versions.
- The Simulator uses the platform ADM and cannot exercise CallKit audio properly.
- App Store review of the `audio` background mode for an AI voice app is up to Apple. Free Personal Team builds expire after 7 days.

## Remaining risks and device QA

Android, on the Android 16 phone:

1. Lock the screen for more than 10 minutes during a call and confirm audio continues both ways.
2. Tap Mute, Unmute and End from the shade and from the lock screen.
3. Swipe the app from recents during a call. The call should end and the microphone indicator should go away.
4. Decline notifications. The call should still run and the warning should be returned.
5. Decline the microphone. The result should be `microphone_denied`.
6. Press back or rotate during a call. The engine should be retained.
7. Check whether the CallStyle Mute action appears on this OEM's build.

Further risks:

- Bluetooth headset routing on Android 12+ needs `BLUETOOTH_CONNECT`, which is neither declared nor requested. Wired headsets and the speaker are unaffected.
- The timeouts (6 s start, 4 s mute acknowledgement, 8 s end acknowledgement, 10 s end deadline, 4 s after task removal) are judgement calls. Dart handlers must acknowledge quickly. The current `call_platform.dart` returns at once, so it meets this.

## Validation done (2026-11-14, Linux build host)

Run with JDK 17, the local Android SDK, and `GRADLE_USER_HOME=~/.local/share/hermes-build-tools/gradle`:

- `./gradlew :app:processDebugResources :app:compileDebugKotlin :app:compileReleaseKotlin :app:processDebugMainManifest :app:processReleaseMainManifest :app:validateSigningRelease` passed. The release keystore and config were found and validated.
- Merged release manifest: microphone FGS `HermesCallService` with `exported=false`, the expected permissions, no `networkSecurityConfig` and no `usesCleartextTraffic`.
- Merged debug manifest: `networkSecurityConfig` for loopback cleartext only.
- `:app:lintDebug` on the app module: 0 errors. The one real warning (the microphone FGS type constant on API 29) is fixed. The remaining warnings are `ObsoleteSdkInt` for defensive version checks.
- Running lint on the plugin modules crashes inside lint itself: it calls the JDK 21 API `List.removeLast` while running on JDK 17. That run was skipped with `-x :<plugin>:lintAnalyzeDebug`. `tool/build_release.py` now runs APK builds on JDK 21 (see the README), and with JDK 21 the release lint passes.
- Not done here: building the APK, installing it, and testing on a device. iOS was not compiled (no macOS or Xcode). Only the Info.plist, the asset JSON and SVG, and the pbxproj edits were checked for syntax.
