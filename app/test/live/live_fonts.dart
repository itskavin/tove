import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tove_chat/src/ui/theme/tokens.dart';

/// Loads the app fonts from the files on disk, skipping any that are not
/// there (the font set is being changed in parallel), plus Material Icons.
/// The text family is registered under [HermesTokens.fontFamily], from the
/// first file found.
Future<void> loadLiveTestFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    var any = false;
    for (final f in files) {
      final file = File('assets/fonts/$f');
      if (!file.existsSync()) continue;
      loader.addFont(
        Future.value(ByteData.sublistView(file.readAsBytesSync())),
      );
      any = true;
    }
    if (any) await loader.load();
  }

  final sans = [
    'RobotoFlex-Hermes.ttf',
    'Inter-Regular.ttf',
    'Inter-Medium.ttf',
    'Inter-SemiBold.ttf',
    'Inter-Bold.ttf',
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ];
  final first = sans.where((f) => File('assets/fonts/$f').existsSync());
  final family = first.isEmpty
      ? const <String>[]
      : first.first.startsWith('RobotoFlex')
      ? [first.first]
      : first.where((f) => f.startsWith(first.first.split('-').first)).toList();
  await load(HermesTokens.fontFamily, family);
  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf']);
  await load(HermesTokens.monoFamily, [
    'JetBrainsMono-Regular.ttf',
    'JetBrainsMono-SemiBold.ttf',
  ]);

  final root = Platform.environment['FLUTTER_ROOT'];
  for (final p in [
    if (root != null)
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    '${Platform.environment['HOME']}/.local/share/hermes-build-tools/flutter/'
        'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]) {
    final f = File(p);
    if (f.existsSync()) {
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync()))))
          .load();
      return;
    }
  }
}
