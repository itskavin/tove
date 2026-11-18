/// An email artifact as an email card (round 8, the reference app's
/// layout): an "Email" header with Copy and a Send button, the recipients,
/// the subject and the whole body. Send opens a small menu: "Send with
/// Gmail" (Android, when Gmail is installed) and "Open in email app" (a
/// mailto: link with the recipients, subject and body). It takes the reply's
/// own type and colours (the blend rule); only the Send button is filled, with
/// the theme's one primary action fill.
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/popover.dart';
import '../feedback.dart';
import '../thread/message_actions.dart';
import 'artifact.dart';
import 'markdown_style.dart';

/// Hands a draft to a mail app. The shell provides the device's; tests and
/// other platforms use [MailtoComposer].
abstract class EmailComposer {
  /// Whether "Send with Gmail" can be offered.
  Future<bool> gmailAvailable();

  /// Opens a compose screen (Gmail's when [gmail]); false when nothing
  /// opened.
  Future<bool> compose({
    required bool gmail,
    required List<String> to,
    required String subject,
    required String body,
  });
}

/// The fallback: a `mailto:` link for the default email app.
class MailtoComposer implements EmailComposer {
  const MailtoComposer();

  @override
  Future<bool> gmailAvailable() async => false;

  @override
  Future<bool> compose({
    required bool gmail,
    required List<String> to,
    required String subject,
    required String body,
  }) async {
    try {
      return await launchUrl(
        mailtoUri(to: to, subject: subject, body: body),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }
}

final _address = RegExp(r'^[^\s@<>(),;:"]+@[^\s@<>(),;:"]+\.[^\s@<>(),;:"]+$');

/// The real addresses among [to] (`Ana <ana@x.org>` gives `ana@x.org`);
/// names alone are left for the user to fill in.
List<String> emailAddresses(List<String> to) => [
  for (final r in to)
    if (RegExp(r'<([^<>]+)>').firstMatch(r)?.group(1)?.trim() case final a?
        when _address.hasMatch(a))
      a
    else if (_address.hasMatch(r.trim()))
      r.trim(),
];

/// `mailto:a@x.org,b@y.org?subject=…&body=…`, percent-encoded (spaces as
/// %20, never "+", which mail apps would show literally).
Uri mailtoUri({
  required List<String> to,
  required String subject,
  required String body,
}) {
  final q = [
    if (subject.isNotEmpty) 'subject=${Uri.encodeComponent(subject)}',
    if (body.isNotEmpty) 'body=${Uri.encodeComponent(body)}',
  ].join('&');
  final addr = emailAddresses(to).map(Uri.encodeComponent).join(',');
  return Uri.parse('mailto:$addr${q.isEmpty ? '' : '?$q'}');
}

class EmailCard extends StatelessWidget {
  const EmailCard({super.key, required this.artifact, required this.style});

  final Artifact artifact;
  final MarkdownStyle style;

  Future<void> _copy(BuildContext context) async {
    final actions = MessageActions.of(context);
    await Clipboard.setData(ClipboardData(text: artifact.content.trim()));
    actions?.notify('Copied');
  }

  Future<void> _send(BuildContext anchor) async {
    final composer = MessageActions.of(anchor)?.email ?? const MailtoComposer();
    final actions = MessageActions.of(anchor);
    FeedbackScope.haptic(anchor, Haptic.light);
    final gmail = await composer.gmailAvailable();
    if (!anchor.mounted) return;
    final choice = await showPopover<String>(
      anchor: anchor,
      width: 248,
      align: PopoverAlign.end,
      above: false,
      label: 'Send email',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          if (gmail)
            PopoverItem(
              key: const ValueKey('email-gmail'),
              label: 'Send with Gmail',
              icon: Icons.mail_outline_rounded,
              height: 48,
              onTap: () => Navigator.pop(context, 'gmail'),
            ),
          PopoverItem(
            key: const ValueKey('email-app'),
            label: 'Open in email app',
            icon: Icons.open_in_new_rounded,
            height: 48,
            onTap: () => Navigator.pop(context, 'app'),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
    if (choice == null) return;
    final ok = await composer.compose(
      gmail: choice == 'gmail',
      to: artifact.to,
      subject: artifact.subject ?? '',
      body: artifact.content.trim(),
    );
    if (!ok) actions?.notify('No email app could open it');
  }

  @override
  Widget build(BuildContext context) {
    final s = style;
    final a = artifact;
    final muted = s.body.copyWith(color: s.textMuted);
    Widget divider() => Divider(height: 1, thickness: 1, color: s.hairline);
    final to = a.to.join(', ');
    return Semantics(
      container: true,
      label: 'Email${a.subject == null ? '' : ', ${a.subject}'}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(s.codeBlockRadius + 6),
          border: Border.all(color: s.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 6, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectionContainer.disabled(
                child: Row(
                  children: [
                    Icon(Icons.article_outlined, size: 18, color: s.textMuted),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Email', style: muted)),
                    IconButton(
                      key: const ValueKey('email-copy'),
                      tooltip: 'Copy',
                      onPressed: () => _copy(context),
                      icon: Icon(
                        Icons.copy_rounded,
                        size: 20,
                        color: s.textMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Builder(
                      builder: (anchor) => Semantics(
                        button: true,
                        label: 'Send',
                        hint: 'Opens Gmail or your email app',
                        excludeSemantics: true,
                        onTap: () => _send(anchor),
                        child: Tooltip(
                          message: 'Send',
                          child: Material(
                            key: const ValueKey('email-send'),
                            color: s.closeFill,
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => _send(anchor),
                              child: SizedBox.square(
                                dimension: 48,
                                child: Icon(
                                  Icons.send_rounded,
                                  size: 20,
                                  color: s.onClose,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: to.isEmpty
                          ? Text('Recipients', style: muted)
                          : Text(to, style: s.body),
                    ),
                    divider(),
                    if (a.subject != null && a.subject!.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(a.subject!, style: s.body),
                      ),
                      divider(),
                    ],
                    const SizedBox(height: 14),
                    Text(a.content.trim(), style: s.body),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
