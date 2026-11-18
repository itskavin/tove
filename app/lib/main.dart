import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'src/app.dart';
import 'src/background/background.dart';
import 'src/bridge/bridge_api.dart';
import 'src/call/call_controller.dart';
import 'src/config.dart';
import 'src/notify/notify.dart';
import 'src/platform/app_links.dart';
import 'src/platform/call_platform.dart';
import 'src/rtc/webrtc_transport.dart';
import 'src/settings/settings.dart';
import 'src/speech/speech.dart';
import 'src/sync/speech_sync.dart';
import 'src/third_party_licences.dart';
import 'src/update/update_check.dart';
import 'src/ui/orb/orb.dart';
import 'src/ui/theme/fonts.dart';

Future<void> main(List<String> args) async {
  // FIRST: UnifiedPush starts the default entrypoint with --unifiedpush-bg
  // for a push while the app is closed; that run shows a notification and
  // never builds the UI.
  if (await handlePushInBackground(args)) return;
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicences();
  registerCodeLicences();
  // Compile the orb shader before the first live frame needs it.
  unawaited(OrbShader.precache());

  // Replies outlive the chat on screen and the app's foreground.
  final replies = BackgroundReplies.instance..bindLifecycle();
  final notifyPrefs = ReplyNotificationPrefs();
  unawaited(notifyPrefs.load());
  final sink = LocalNotificationSink.platformDefault();
  unawaited(sink.init());
  // Android: Tove's own notification connection (no distributor app).
  final instant = InstantNotifications.supportedHere
      ? InstantNotifications()
      : null;
  if (instant != null) unawaited(instant.load());
  ReplyKeepAlive(replies: replies).start(); // Android WorkManager fallback.
  // Android: the daily GitHub Releases check (Settings › About › Updates).
  final updates = UpdateChecker.supportedHere ? UpdateChecker() : null;
  if (updates != null) unawaited(updates.load());

  final settings = SettingsController(
    keys: SecureKeyStore(),
    prefs: SharedPrefsStore(),
    // Synced settings (bridges with `settings_sync`; local only otherwise).
    syncApi: httpSettingsApi,
  );
  final liveLink = LiveLink();
  final call = CallController(
    apiFactory: () => BridgeApi(
      baseUrl: BridgeApi.parseUrl(settings.url) ?? Uri.parse(kDefaultBridgeUrl),
      accessKey: settings.accessKey,
    ),
    transportFactory: WebRtcTransport.new,
    platform: MethodChannelCallPlatform(),
    voice: () => settings.voice,
    conversationId: () => liveLink.conversationId,
  );

  // Speech (dictation, read aloud) is optional: without it the mic falls
  // back to the keyboard's voice key and Read aloud is hidden.
  SpeechServices? speech;
  try {
    speech = await SpeechServices.create(
      prefs: SharedPrefsStore(),
      // Dictation on the Tove server (most accurate; falls back on-phone).
      transcriber: BridgeTranscriber(
        baseUrl: () => BridgeApi.parseUrl(settings.url),
        accessKey: () => settings.accessKey,
      ),
    );
  } catch (e) {
    debugPrint('Speech unavailable: $e');
  }
  // Read-aloud speed, auto read and dictation language sync too.
  if (speech != null) SpeechSyncSlice.attach(speech.settings, settings.sync);

  runApp(
    HermesApp(
      settings: settings,
      call: call,
      liveLink: liveLink,
      services: AppServices(
        replies: replies,
        notifyPrefs: notifyPrefs,
        notificationSink: sink,
        instant: instant,
        links: AppLinks(),
        speech: speech,
        updates: updates,
      ),
    ),
  );
  await settings.load();
}
