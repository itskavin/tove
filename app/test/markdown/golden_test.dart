import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';

import 'golden_harness.dart';

/// Typical replies (chat-rendering-v2 §1), dark and light, 100 % and 200 %
/// text. Regenerate with `flutter test --update-goldens test/markdown`.
const prose = '''Since you want a natural voice assistant, I'd **prototype with the realtime model first**, then compare it against the cheaper mini model on the same prompts.

Test these four things:

- **Latency:** how quickly it starts speaking after you stop.
- **Interruptions:** whether it stops cleanly when you talk over it.
- **Tool calls:** check the `disk_usage` tool on NAS-01 and the backups.
  - nested detail with a ring bullet
    - third level square
- **Cost:** compare a typical 60-minute day.

1. Install the bridge.
2. Run `homelab-sync` once.
3. Open the [setup guide](https://example.com/docs/setup).

- [x] Ethernet preferred on Workbench
- [ ] Wi-Fi fallback tested

> Quotes stay quiet: muted text beside a thin bar, with no background.

Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to stop. <small>Prices checked on 15 November 2026.</small>

---

A bare link: https://www.example.com/a/very/long/path/that/keeps/going/and/going/index.html''';

const headings = '''# Homelab status

The core is healthy and every service answered within a second.

## Storage on NAS-01

Usage is at **71 %** after the nightly job, up from 68 % last week.

### Backups

Nightly dumps finished at 03:12.

#### Retention

Thirty daily and twelve monthly copies are kept.''';

const table = '''Here is how the two options compare:

| Area | Realtime | Mini |
|---|---|---|
| Voice quality | Needs testing | Needs testing |
| Latency | Needs benchmarking | Needs benchmarking |
| Tool integration | Backend charges listed | Realtime API support, tool calling |
| Best starting use | Voice-first companion | Customizable realtime assistant |

| Machine | Disk used | Cost |
|---|---:|---:|
| Pathfinder | 41 % | \$3.00 |
| NAS-01 | 71 % | \$12.50 |

<small>Based on the published pricing; the documentation does not say which model sounds better.</small>''';

const code = '''Run this on Workbench:

```bash
sudo systemctl restart homelab-stats-exporter.service && journalctl -u homelab-stats-exporter -n 20 --no-pager
```

```dart
final total = minutes * 0.05;
```''';

const citations = '''Published audio prices are \$32 per million input tokens and \$64 per million output tokens.[^1][^2] The mini model is cheaper at \$10 and \$20 respectively.[^3]

<small>Based on the published pricing.[^1]</small>

[^1]: [Pricing](https://www.example.com/pricing) — Example Docs
[^2]: [Realtime guide](https://platform.example.org/docs/realtime) — Example Platform
[^3]: https://news.example.net/mini-launch Launch notes''';

void main() {
  goldenMatrix('reply_prose', () => const HermesMarkdown(text: prose));
  goldenMatrix('reply_headings', () => const HermesMarkdown(text: headings));
  goldenMatrix('reply_table', () => const HermesMarkdown(text: table));
  goldenMatrix('reply_code', () => const HermesMarkdown(text: code));
  goldenMatrix('reply_citations', () => const HermesMarkdown(text: citations));
}
