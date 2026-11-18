import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/floating_sheet.dart';
import '../tokens.dart';

/// Links open in the external browser after a confirm sheet that shows the
/// host (spec §5.2). Only http, https and mailto links are opened.
typedef LinkOpener = Future<bool> Function(Uri uri);

Future<bool> _launch(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Replaced in tests.
LinkOpener linkOpener = _launch;

Uri? safeLink(String href) {
  final u = Uri.tryParse(href.trim());
  if (u == null) return null;
  if (u.scheme == 'http' || u.scheme == 'https') {
    return u.host.isEmpty ? null : u;
  }
  if (u.scheme == 'mailto') return u;
  return null;
}

String linkHost(Uri u) {
  if (u.scheme == 'mailto') return u.path;
  final h = u.host;
  return h.startsWith('www.') ? h.substring(4) : h;
}

Future<void> confirmAndOpen(BuildContext context, String href) async {
  final uri = safeLink(href);
  if (uri == null) return;
  final ok = await showFloatingSheet<bool>(
    context,
    page: SheetPage(
      title: 'Open link?',
      builder: (context) {
        final t = HermesTokens.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(linkHost(uri), textAlign: TextAlign.center, style: t.title),
              const SizedBox(height: 6),
              Text(
                uri.toString(),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: t.label.copyWith(fontWeight: FontWeight.w400),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Open in browser'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(foregroundColor: t.text),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    ),
  );
  if (ok == true) {
    try {
      await linkOpener(uri);
    } catch (_) {
      // Nothing to open it with; the sheet already showed the address.
    }
  }
}
