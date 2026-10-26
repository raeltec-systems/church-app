import 'package:flutter/services.dart';

import '../domain/content_bible.dart';

/// Reads the reviewed eBible.org package bundled with the staff app.
class BundledBibleTranslationPackageSource
    implements BibleTranslationPackageSource {
  const BundledBibleTranslationPackageSource({this.bundle});

  final AssetBundle? bundle;

  @override
  Future<String> loadWorldEnglishBibleVpl() async {
    return (bundle ?? rootBundle).loadString(
      'assets/bible/engwebp_vpl.txt',
      cache: false,
    );
  }
}
