import '../domain/content_banners.dart';
import 'content_file_picker_stub.dart'
    if (dart.library.js_interop) 'content_file_picker_web.dart'
    as platform;

/// Story 6.2: the platform's [ContentFilePicker]. Staff web opens the
/// browser's file chooser (PNG, JPEG or WebP); other platforms cannot pick a
/// file here (content administration is a staff web surface). The bytes stay
/// in memory: nothing is stored.
ContentFilePicker platformContentFilePicker() => platform.picker();
