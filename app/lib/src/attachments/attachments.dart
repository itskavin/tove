/// Composer attachments: pick, prepare (downscale, strip metadata), upload
/// to the bridge, and stage for a message. See
/// `docs/design/bridge-requests.md` for the server contract.
library;

export 'attachment.dart';
export 'attachment_controller.dart';
export 'attachment_limits.dart';
export 'image_prep.dart';
export 'picker.dart';
export 'upload_client.dart';
