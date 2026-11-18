import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../brand.dart';
import '../ui/common/group_card.dart';
import '../ui/settings/settings_widgets.dart';
import '../ui/theme/tokens.dart';
import 'update_check.dart';

/// Opens a URL in the browser; replaceable in tests.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> openInBrowser(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Release notes longer than this are cut (the full text is on GitHub).
const _maxNotes = 4000;

/// "Tove 1.2.3 is available": the release notes, "Later" and "Download".
/// Dismissible; "Download" opens the APK in the browser, which hands it to
/// Android's installer once downloaded.
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateChecker checker,
  ReleaseInfo release, {
  UrlOpener open = openInBrowser,
}) {
  final notes = release.notes.length > _maxNotes
      ? '${release.notes.substring(0, _maxNotes).trimRight()}…'
      : release.notes;
  return showDialog<void>(
    context: context,
    builder: (context) {
      final t = HermesTokens.of(context);
      return AlertDialog(
        key: const ValueKey('update-dialog'),
        title: Text('${Brand.appName} ${release.version.name} is available'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'You have ${checker.installed.name}. Download the new APK '
                  'and open it to update; your chats and settings stay.',
                  style: t.row.copyWith(color: t.textMuted, height: 1.4),
                ),
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(notes, style: t.row.copyWith(height: 1.4)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              unawaited(checker.dismiss(release));
              Navigator.of(context).pop();
            },
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(open(release.downloadUrl));
            },
            child: const Text('Download'),
          ),
        ],
      );
    },
  );
}

/// Settings › About › Updates: "Check for updates" and the daily check's
/// switch. Empty without an [UpdateScope] or off Android.
List<Widget> updateRows(BuildContext context, {UrlOpener? open}) {
  final checker = UpdateScope.maybeOf(context);
  if (checker == null || !checker.supported) return const [];
  return [
    const SectionHeader('Updates'),
    SettingAnchor(
      id: 'updates',
      child: GroupCard(
        margin: settingsCard,
        children: [
          GroupRow(
            key: const ValueKey('about-check-updates'),
            label: 'Check for updates',
            icon: Icons.system_update_outlined,
            subtitle: _statusText(checker),
            trailing: checker.status == UpdateStatus.checking
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: () => unawaited(_checkFromAbout(context, checker, open)),
          ),
          SwitchRow(
            key: const ValueKey('about-auto-update-check'),
            label: 'Check automatically',
            icon: Icons.update_rounded,
            subtitle:
                'Once a day, asks GitHub for the latest release. Nothing is '
                'downloaded without you.',
            value: checker.enabled,
            onChanged: (on) => unawaited(checker.setEnabled(on)),
          ),
        ],
      ),
    ),
  ];
}

String _statusText(UpdateChecker c) => switch (c.status) {
  UpdateStatus.checking => 'Checking…',
  UpdateStatus.available =>
    'Version ${c.available?.version.name} is available. Tap to see what’s new.',
  UpdateStatus.upToDate => 'You have the latest version (${c.installed.name}).',
  UpdateStatus.offline => 'Couldn’t reach GitHub. Check your connection.',
  UpdateStatus.rateLimited =>
    'GitHub is limiting requests right now. Try again in an hour.',
  UpdateStatus.failed => 'The check didn’t work. Try again later.',
  UpdateStatus.unknown => 'Installed: ${c.installed.name}',
};

Future<void> _checkFromAbout(
  BuildContext context,
  UpdateChecker checker,
  UrlOpener? open,
) async {
  // A release already found opens straight away.
  var release = checker.available;
  if (release == null) {
    await checker.checkNow();
    release = checker.available;
  }
  if (release == null || !context.mounted) return;
  await showUpdateDialog(
    context,
    checker,
    release,
    open: open ?? openInBrowser,
  );
}

/// The start-up check: after the first frame, at most once a day; shows the
/// dialog only for a newer release not dismissed with "Later".
Future<void> runStartupUpdateCheck(
  UpdateChecker checker,
  BuildContext? Function() context, {
  UrlOpener open = openInBrowser,
}) async {
  final release = await checker.checkIfDue();
  final c = context();
  if (release == null || c == null || !c.mounted) return;
  await showUpdateDialog(c, checker, release, open: open);
}
