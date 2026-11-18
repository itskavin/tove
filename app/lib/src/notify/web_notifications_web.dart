import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Browser notifications (web app only, while its tab is open): the page has
/// no service worker, so nothing arrives once the tab is closed.
bool get available {
  try {
    web.Notification.permission;
    return true;
  } catch (_) {
    return false; // No Notification API (older browsers, some webviews).
  }
}

bool get granted {
  try {
    return web.Notification.permission == 'granted';
  } catch (_) {
    return false;
  }
}

/// True when the tab is in the background (another tab or window in front).
bool get hidden {
  try {
    return web.document.hidden;
  } catch (_) {
    return false;
  }
}

Future<bool> requestPermission() async {
  if (!available) return false;
  try {
    final r = await web.Notification.requestPermission().toDart;
    return r.toDart == 'granted';
  } catch (_) {
    return false;
  }
}

void show(String title, String body, String tag, void Function() onTap) {
  if (!granted) return;
  try {
    final n = web.Notification(
      title,
      web.NotificationOptions(body: body, tag: tag),
    );
    n.onclick = ((web.Event _) {
      try {
        web.window.focus();
      } catch (_) {}
      n.close();
      onTap();
    }).toJS;
  } catch (_) {}
}

void close(String tag) {}
