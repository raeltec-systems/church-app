// Disposable Flutter Web trial (Q10). Do not build on this.
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Saves [content] as a file through a temporary object URL. The bytes stay in
/// the browser; nothing is uploaded or emailed.
bool downloadTextFile(String filename, String content, String mimeType) {
  try {
    final bytes = utf8.encode(content);
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
    Future<void>.delayed(
      const Duration(seconds: 30),
      () => web.URL.revokeObjectURL(url),
    );
    return true;
  } catch (_) {
    return false;
  }
}
