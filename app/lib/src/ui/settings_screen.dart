import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../platform/app_links.dart';

import '../app.dart' show kAppVersion;
import '../update/update_check.dart' show UpdateChecker;
import '../background/background.dart';
import '../brand.dart';
import '../call/call_controller.dart';
import '../chat/chat.dart';
import '../config.dart';
import '../notify/notify.dart';
import '../platform/device.dart';
import '../settings/settings.dart';
import '../speech/speech.dart';
import 'common/group_card.dart';
import 'common/profile_avatar.dart';
import 'settings/accessibility_about_sections.dart';
import 'settings/connection_section.dart';
import 'settings/data_controls_section.dart';
import 'settings/general_section.dart';
import 'settings/notifications_section.dart';
import 'settings/personalization_section.dart';
import 'settings/settings_index.dart';
import 'settings/settings_widgets.dart';
import 'settings/usage_limits_page.dart';
import 'settings/voice_section.dart';
import 'theme/tokens.dart';

export 'settings/data_controls_section.dart' show DataControls, SaveExport;
export 'settings/connection_section.dart' show OpenLink;
export 'settings/settings_index.dart';
export 'settings/settings_widgets.dart' show SettingAnchor, SettingsFocusScope;

/// Settings (spec §2.5): a searchable list of categories. Phones open each
/// category as its own page; wide screens show the categories beside the
/// selected one. Every control is the app's real setting; options the app
/// or server cannot honour are left out, not shown disabled.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.call,
    this.voices = kVoices,
    this.effortSupported = false,
    this.device,
    this.showShortcuts,
    this.notifyPrefs,
    this.notificationSink,
    this.push,
    this.instant,
    this.testEvents,
    this.speech,
    this.initialSection,
    this.capabilities,
    this.usageLimits,
    this.data = const DataControls(),
    this.desktopKeys,
    this.openLink = openExternal,
    this.links,
    this.onProfile,
  });

  /// Opens the Profile page (name and photo) from the row at the top
  /// (round 8: the avatar opens Settings, and Profile is its first row).
  final VoidCallback? onProfile;

  final SettingsController settings;
  final CallController call;

  /// The assistant-role row (Android); null hides it.
  final AppLinks? links;
  final List<String> voices;
  final bool effortSupported;
  final DeviceServices? device;

  /// Overrides where the desktop keyboard shortcuts are listed (tests).
  final bool? showShortcuts;

  /// Reply notifications; the category is hidden without them.
  final ReplyNotificationPrefs? notifyPrefs;
  final NotificationSink? notificationSink;
  final PushRegistrar? push;

  /// Android's instant notifications, and the events test (bridges with
  /// `events`).
  final InstantNotifications? instant;
  final Future<int> Function()? testEvents;

  /// Dictation, read aloud and their downloads; hidden without them.
  final SpeechServices? speech;

  /// The category a wide layout starts on (General by default).
  final SettingsSection? initialSection;

  /// What the server offers (connection status, version, voice service,
  /// usage). Null when not known yet.
  final Capabilities? capabilities;

  /// `GET /api/usage/limits`; null hides Usage and limits. Bridges without
  /// `usage_limits` still get the category, explaining it needs an update.
  final LoadUsageLimits? usageLimits;

  /// The loader when the bridge has the route, else null (old bridge).
  LoadUsageLimits? get _usageLoad =>
      capabilities?.usageLimits == true ? usageLimits : null;

  /// Chat history, export, delete-all and the local cache.
  final DataControls data;

  /// Whether "Send with Enter" applies (desktop and web by default).
  final bool? desktopKeys;
  final OpenLink openLink;

  static const shortcutsText = settingsShortcutsText;

  bool get _desktopKeys =>
      desktopKeys ??
      (kIsWeb ||
          switch (defaultTargetPlatform) {
            TargetPlatform.linux ||
            TargetPlatform.macOS ||
            TargetPlatform.windows => true,
            _ => false,
          });

  LiveBackendInfo? get _backend => capabilities == null
      ? null
      : LiveBackendInfo.fromCapabilities(capabilities!.raw);

  /// The categories with content for this app and server.
  List<SettingsSection> get sections => [
    SettingsSection.general,
    if (settings.sync.enabled) SettingsSection.personalization,
    SettingsSection.voice,
    if (notifyPrefs != null) SettingsSection.notifications,
    SettingsSection.data,
    if (usageLimits != null) SettingsSection.usage,
    SettingsSection.connection,
    SettingsSection.accessibility,
    SettingsSection.about,
  ];

  List<SettingsEntry> get index => settingsIndex(
    effort: effortSupported,
    speech: speech != null,
    notifications: notifyPrefs != null,
    personalization: settings.sync.enabled,
    history: data.history,
    sendWithEnter: _desktopKeys,
    liveBackend: _backend != null,
    usageLimits: usageLimits != null,
    assistant: links?.android ?? false,
    updates: UpdateChecker.supportedHere,
  );

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _query = TextEditingController();
  late SettingsSection _selected =
      widget.initialSection ?? SettingsSection.general;
  String? _target;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    // Pick up changes made on another device since the app started.
    unawaited(widget.settings.sync.refresh());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _wide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= Sz.wideLayout;

  /// Opens [section] (its page on phones, the pane on wide screens), showing
  /// [target] when a search result was chosen.
  void _open(SettingsSection section, {String? target}) {
    if (_wide(context)) {
      setState(() {
        _selected = section;
        _target = target;
        _token++;
      });
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (section == SettingsSection.usage) {
      // Its own page: pull to refresh needs the page's own list.
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => UsageLimitsPage(load: widget._usageLoad),
          ),
        ),
      );
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _SectionPage(
            screen: widget,
            section: section,
            target: target,
            token: ++_token,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The categories follow the sync state (Personalization).
    listenable: widget.settings.sync,
    builder: (context, _) => Scaffold(
      appBar: settingsBar(context, 'Settings'),
      body: _wide(context) ? _twoPane(context) : _hub(context),
    ),
  );

  Widget _searchField(HermesTokens t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: TextField(
      key: const ValueKey('settings-search'),
      controller: _query,
      textInputAction: TextInputAction.search,
      style: t.row.hermesWeight(400),
      decoration: InputDecoration(
        hintText: 'Search settings',
        isDense: true,
        filled: true,
        fillColor: t.surface,
        prefixIcon: Icon(Icons.search_rounded, size: 20, color: t.textMuted),
        suffixIcon: _query.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: _query.clear,
                icon: Icon(Icons.close_rounded, size: 20, color: t.text),
              ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );

  /// The results for the query, or the no-results note with a clear button.
  List<Widget> _results(HermesTokens t) {
    final hits = searchSettings(_query.text, widget.index);
    if (hits.isEmpty) {
      return [
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              'No settings match “${_query.text.trim()}”.',
              style: t.row.hermesWeight(400),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _query.clear,
              child: const Text('Clear search'),
            ),
          ),
        ),
      ];
    }
    return [
      Semantics(
        liveRegion: true,
        child: SectionHeader(
          '${hits.length} ${hits.length == 1 ? 'result' : 'results'}',
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        ),
      ),
      GroupCard(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final e in hits)
            GroupRow(
              key: ValueKey('settings-result-${e.id}'),
              label: e.label,
              icon: e.section.icon,
              subtitle: e.section.title,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _open(e.section, target: e.id),
            ),
        ],
      ),
    ];
  }

  /// The hub's categories, in the reference app's groups: preferences,
  /// then data and connection, then help.
  List<List<SettingsSection>> _groups() {
    final s = widget.sections;
    List<SettingsSection> pick(List<SettingsSection> want) => [
      for (final x in want)
        if (s.contains(x)) x,
    ];
    return [
      pick(const [
        SettingsSection.general,
        SettingsSection.personalization,
        SettingsSection.voice,
        SettingsSection.notifications,
      ]),
      pick(const [
        SettingsSection.data,
        SettingsSection.usage,
        SettingsSection.connection,
      ]),
      pick(const [SettingsSection.accessibility, SettingsSection.about]),
    ].where((g) => g.isNotEmpty).toList();
  }

  Widget _hub(BuildContext context) {
    final t = HermesTokens.of(context);
    final searching = _query.text.trim().isNotEmpty;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          key: const ValueKey('settings-hub'),
          padding: EdgeInsets.only(
            bottom: 32 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            _searchField(t),
            if (searching)
              ..._results(t)
            else ...[
              if (widget.onProfile != null) ...[
                const SizedBox(height: 12),
                GroupCard(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _ProfileRow(
                      settings: widget.settings,
                      onTap: widget.onProfile!,
                    ),
                  ],
                ),
              ],
              for (final group in _groups()) ...[
                const SizedBox(height: 12),
                GroupCard(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final s in group)
                      GroupRow(
                        key: ValueKey('settings-section-${s.name}'),
                        label: s.title,
                        icon: s.icon,
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _open(s),
                      ),
                  ],
                ),
              ],
              SyncStatusLine(sync: widget.settings.sync),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  '${Brand.appName} ${kAppVersion.split('+').first}',
                  style: t.label,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _twoPane(BuildContext context) {
    final t = HermesTokens.of(context);
    final searching = _query.text.trim().isNotEmpty;
    final sections = widget.sections;
    final selected = sections.contains(_selected)
        ? _selected
        : SettingsSection.general;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          child: FocusTraversalGroup(
            child: ListView(
              key: const ValueKey('settings-nav'),
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _searchField(t),
                if (searching)
                  ..._results(t)
                else ...[
                  if (widget.onProfile != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                      child: _ProfileRow(
                        settings: widget.settings,
                        onTap: widget.onProfile!,
                      ),
                    ),
                  for (final (i, group) in _groups().indexed) ...[
                    if (i > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 6,
                        ),
                        child: Divider(height: 1, color: t.hairline),
                      ),
                    for (final s in group)
                      _NavRow(
                        section: s,
                        selected: s == selected,
                        onTap: () => _open(s),
                      ),
                  ],
                  SyncStatusLine(sync: widget.settings.sync),
                ],
              ],
            ),
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: t.hairline),
        Expanded(
          child: FocusTraversalGroup(
            child: SettingsFocusScope(
              target: _target,
              token: _token,
              child: ListView(
                key: ValueKey('settings-pane-${selected.name}'),
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: 32 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                            child: Semantics(
                              header: true,
                              child: Text(selected.title, style: t.headline),
                            ),
                          ),
                          SettingsSectionBody(
                            screen: widget,
                            section: selected,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The first row of Settings: the avatar, the name and a chevron to the
/// Profile page.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.settings, required this.onTap});

  final SettingsController settings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final name = settings.displayName;
        return Semantics(
          button: true,
          label: name.isEmpty ? 'Profile' : '$name, profile',
          hint: 'Opens your name and photo',
          excludeSemantics: true,
          onTap: onTap,
          child: Material(
            key: const ValueKey('settings-profile'),
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(Rad.row),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      ProfileAvatar(
                        profile: settings.profile,
                        name: name,
                        size: 44,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              name.isEmpty ? 'Your profile' : name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.row.hermesWeight(600),
                            ),
                            Text('Profile', style: t.label),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: t.textMuted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A category in the wide layout's list.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Semantics(
        selected: selected,
        child: Material(
          key: ValueKey('settings-nav-${section.name}'),
          color: selected ? t.surfaceHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(Rad.row),
          child: InkWell(
            borderRadius: BorderRadius.circular(Rad.row),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(section.icon, size: 22, color: t.text),
                    const SizedBox(width: 14),
                    Expanded(child: Text(section.title, style: t.row)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A category as its own page (phones).
class _SectionPage extends StatelessWidget {
  const _SectionPage({
    required this.screen,
    required this.section,
    required this.token,
    this.target,
  });

  final SettingsScreen screen;
  final SettingsSection section;
  final String? target;
  final int token;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: settingsBar(context, section.title),
    body: SettingsFocusScope(
      target: target,
      token: token,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            key: ValueKey('settings-page-${section.name}'),
            padding: EdgeInsets.only(
              bottom: 32 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [SettingsSectionBody(screen: screen, section: section)],
          ),
        ),
      ),
    ),
  );
}

/// The controls of one category: the same widgets on a page or in a pane.
class SettingsSectionBody extends StatelessWidget {
  const SettingsSectionBody({
    super.key,
    required this.screen,
    required this.section,
  });

  final SettingsScreen screen;
  final SettingsSection section;

  SettingsController get settings => screen.settings;
  CallController get call => screen.call;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([settings, call, settings.sync]),
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: switch (section) {
        SettingsSection.general => generalSection(
          context,
          settings: settings,
          effortSupported: screen.effortSupported,
          sendWithEnter: screen._desktopKeys,
        ),
        SettingsSection.personalization => personalizationSection(
          context,
          settings: settings,
        ),
        SettingsSection.voice => voiceSection(
          context,
          settings: settings,
          call: call,
          voices: screen.voices,
          backend: screen._backend,
          speech: screen.speech,
          links: screen.links,
        ),
        SettingsSection.notifications => [
          const SizedBox(height: 8),
          SettingAnchor(
            id: 'replyNotifications',
            child: NotificationsSection(
              prefs: screen.notifyPrefs!,
              sink: screen.notificationSink,
              push: screen.push,
              instant: screen.instant,
              testEvents: screen.testEvents,
              web: kIsWeb,
              showHeader: false,
              anchor: (id, child) => SettingAnchor(id: id, child: child),
            ),
          ),
          const DeviceOnlyNote(),
        ],
        SettingsSection.data => dataControlsSection(context, data: screen.data),
        SettingsSection.usage => [
          SettingAnchor(
            id: 'usageLimits',
            child: UsageLimitsView(load: screen._usageLoad),
          ),
        ],
        SettingsSection.connection => connectionSection(
          context,
          settings: settings,
          call: call,
          capabilities: screen.capabilities,
          openLink: screen.openLink,
        ),
        SettingsSection.accessibility => accessibilitySection(
          context,
          settings: settings,
        ),
        SettingsSection.about => aboutSection(
          context,
          device: screen.device,
          showShortcuts: screen.showShortcuts,
        ),
      },
    ),
  );
}
