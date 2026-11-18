import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../brand.dart';
import '../../platform/app_links.dart';
import '../common/group_card.dart';

/// Settings › Voice › "Default assistant app" (Android): whether Tove is
/// the device's digital assistant, and a way to change it. Apps cannot
/// request that role, so the row opens the system's assistant settings and
/// reads the state again when the user comes back.
class DefaultAssistantRow extends StatefulWidget {
  const DefaultAssistantRow({super.key, required this.links});
  final AppLinks links;

  @override
  State<DefaultAssistantRow> createState() => _DefaultAssistantRowState();
}

class _DefaultAssistantRowState extends State<DefaultAssistantRow>
    with WidgetsBindingObserver {
  AssistantStatus? _status;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_read());
  }

  Future<void> _read() async {
    final s = await widget.links.assistantStatus();
    if (!mounted) return;
    setState(() {
      _status = s;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    if (_loaded && (s == null || !s.supported)) return const SizedBox.shrink();
    final value = switch (s?.held) {
      true => Brand.appName,
      false => 'Another app',
      null => null,
    };
    return GroupRow(
      key: const ValueKey('settings-default-assistant'),
      label: 'Default assistant app',
      icon: Icons.assistant_outlined,
      value: value,
      subtitle: s?.held == true
          ? 'Hold Home or the power button to open live voice.'
          : 'Set ${Brand.appName} to open live voice when you hold Home '
                'or the power button.',
      trailing: const Icon(Icons.open_in_new_rounded),
      semanticsHint: 'Opens the system setting',
      onTap: () => unawaited(widget.links.openAssistantSettings()),
    );
  }
}
