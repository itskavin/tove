/// Not on the web: nothing to show (see web_notifications_web.dart).
bool get available => false;
bool get granted => false;
bool get hidden => false;
Future<bool> requestPermission() async => false;
void show(String title, String body, String tag, void Function() onTap) {}
void close(String tag) {}
