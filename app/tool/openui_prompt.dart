// Prints the OpenUI section of the bridge prompt for "ui": 2 clients,
// generated from the Tove component registry (OpenUI's chat library plus
// Tove's components). Install it as server/openui-chat-prompt.md:
//   dart run tool/openui_prompt.dart > ../server/openui-chat-prompt.md
// server/openui-prompt.md is the frozen round-9 section for "ui": 1 apps.
// (pure Dart: the registry and language core import no Flutter.)
import 'dart:io';

import 'package:tove_chat/src/ui/openui/library.dart';

void main() => stdout.write(toveOpenUiPrompt());
