// Story 6.10: the Facebook player's web view stays on the embedded player page.
import 'package:bic_kafue_mobile/sermons/facebook_sermon_player.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the embedded player page may load at the top level', () {
    final embed = facebookSermonEmbedUri(
      'https://www.facebook.com/SyntheticChurch/videos/1061000000000001/',
    );
    expect(isFacebookPlayerPage(embed), isTrue);
    for (final url in [
      'https://www.facebook.com/login.php?next=x',
      'https://www.facebook.com/SyntheticChurch/videos/1061000000000001/',
      'https://m.facebook.com/plugins/video.php?href=x',
      'http://www.facebook.com/plugins/video.php?href=x',
      'https://www.facebook.com:8443/plugins/video.php?href=x',
      'https://user@www.facebook.com/plugins/video.php?href=x',
      'https://evil.test/plugins/video.php?href=x',
    ]) {
      expect(isFacebookPlayerPage(Uri.parse(url)), isFalse, reason: url);
    }
  });

  testWidgets('without a web view the player shows the unavailable state', (
    tester,
  ) async {
    // Widget tests have no web view platform, as a phone without one.
    await tester.pumpWidget(
      MaterialApp(
        theme: churchMobileTheme(Brightness.light),
        home: const Scaffold(
          body: FacebookSermonPlayer(
            videoUrl: 'https://www.facebook.com/SyntheticChurch/videos/1061000000000001/',
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('sermon-video-unavailable')), findsOneWidget);
  });
}
