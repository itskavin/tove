import 'dart:async';
import 'dart:convert';

/// One server-sent event. [event] defaults to `message`.
class SseEvent {
  const SseEvent(this.event, this.data, {this.id});
  final String event;
  final String data;
  final String? id;

  @override
  String toString() => 'SseEvent($event, $data)';
}

/// Decodes a `text/event-stream` byte stream (WHATWG rules): UTF-8 split
/// across chunks, `\n` / `\r\n` / `\r` line ends, `:` comments (keep-alives)
/// ignored, multi-line `data`, and an unterminated last event dropped.
class SseDecoder extends StreamTransformerBase<List<int>, SseEvent> {
  const SseDecoder();

  @override
  Stream<SseEvent> bind(Stream<List<int>> stream) {
    String? event;
    String? id;
    final data = <String>[];

    return stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .transform(
          StreamTransformer<String, SseEvent>.fromHandlers(
            handleData: (line, sink) {
              if (line.isEmpty) {
                if (data.isNotEmpty) {
                  sink.add(
                    SseEvent(event ?? 'message', data.join('\n'), id: id),
                  );
                }
                event = null;
                data.clear();
                return;
              }
              if (line.startsWith(':')) return;
              final colon = line.indexOf(':');
              final field = colon < 0 ? line : line.substring(0, colon);
              var value = colon < 0 ? '' : line.substring(colon + 1);
              if (value.startsWith(' ')) value = value.substring(1);
              switch (field) {
                case 'event':
                  event = value;
                case 'data':
                  data.add(value);
                case 'id':
                  id = value;
              }
            },
          ),
        );
  }
}
