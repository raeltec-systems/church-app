// Staff web: the browser's file chooser for content images (story 6.2). The
// picked file is read into memory once and handed to the upload; nothing is
// written to browser storage.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../domain/content_banners.dart';

ContentFilePicker picker() => const _BrowserFilePicker();

class _BrowserFilePicker implements ContentFilePicker {
  const _BrowserFilePicker();

  @override
  bool get supported => true;

  @override
  Future<PickedFile?> pickImage() {
    final done = Completer<PickedFile?>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = contentImageTypes.join(',');
    void finish(PickedFile? file) {
      if (!done.isCompleted) done.complete(file);
    }

    input.onchange = ((web.Event _) {
      unawaited(_read(input).then(finish, onError: (_) => finish(null)));
    }).toJS;
    input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
    input.click();
    return done.future;
  }

  static Future<PickedFile?> _read(web.HTMLInputElement input) async {
    final files = input.files;
    if (files == null || files.length == 0) return null;
    final file = files.item(0);
    if (file == null) return null;
    final declared = file.type.isEmpty ? null : file.type;
    final size = file.size;
    if (size > ContentFilePicker.maxReadBytes) {
      return PickedFile(
        name: file.name,
        declaredType: declared,
        bytes: Uint8List(0),
        size: size,
      );
    }
    final buffer = await file.arrayBuffer().toDart;
    return PickedFile(
      name: file.name,
      declaredType: declared,
      bytes: buffer.toDart.asUint8List(),
    );
  }
}
