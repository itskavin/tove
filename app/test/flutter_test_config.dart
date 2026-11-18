import 'dart:async';

import 'package:tove_chat/src/ui/thread/starter_prompts.dart';

/// Runs before every test file: the empty chat's suggestions come from a
/// seeded generator and a fixed morning clock, so goldens and finders see
/// the same set every run.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  StarterPrompts.debugSeed = 7;
  StarterPrompts.debugClock = () => DateTime(2026, 11, 16, 10);
  await testMain();
}
