/// The one place for the app's user-visible names.
///
/// A rename is one edit here. Every user-facing string that names the app,
/// the assistant or its server reads these constants (all `const`, so they can
/// sit inside `const` widgets and error messages).
///
/// Not covered here, on purpose: the technical identifiers (Dart package
/// `tove_chat`, Android application id, Kotlin package and iOS/macOS bundle
/// id `io.github.tovechat.tove`, platform channel names under that id), the
/// legacy storage keys `hermes_live_access_key` and `HermesLive` (kept so
/// stored access keys survive), the `HermesSans` font family and the
/// `hermes-ui` block info string. A display rename also has to update,
/// outside Dart:
///
/// - `android/app/src/main/res/values/strings.xml` (`app_name`, `call_title`),
/// - `ios/Runner/Info.plist` `CFBundleDisplayName`,
/// - `web/manifest.json` and `web/index.html` `<title>`,
/// - the Linux and Windows window titles and `windows/runner/Runner.rc`,
/// - the release APK name in `tool/build_release.py`.
///
/// "Hermes Agent" (the upstream agent the server talks to) is a product name,
/// not ours, and stays literal where it appears.
abstract final class Brand {
  /// The app's display name (window title, About, drawer header).
  static const appName = 'Tove';

  /// The agent's name in conversation strings ("Ask Hermes", "Hermes
  /// replied"). Users connect to their own Hermes Agent, so this stays
  /// "Hermes" whatever the app is called.
  static const assistantName = 'Hermes';

  /// How the app names the server it connects to.
  static const serverName = '$assistantName server';
}
