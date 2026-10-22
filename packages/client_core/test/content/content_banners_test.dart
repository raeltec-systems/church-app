// Story 6.2: Home banners, rights records and validated image uploads. The
// wire parsing (public projection, the editors' banner and rights reads,
// upload and sync answers), Home's carousel for a signed-out phone (the
// theme card first, campaign images with text alternatives and an honest
// unavailable state, tap to open the original, a banner no longer shown,
// a failed read), and the staff Banners and Rights screens (editors only,
// sync on open and after publishing, upload refusals in words, the uploaded
// image saved with the draft, publish refusals for rights and Q5). Fakes
// only; the server is covered by supabase/tests/content_banners_test.sql
// and tools/identity-e2e/content-banners.mjs.
import 'dart:typed_data';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _theme = '81818181-8181-4181-8181-818181818181';
const _campaign = '83838383-8383-4383-8383-838383838383';
const _draft = '82828282-8282-4282-8282-828282828282';
const _rights = '91919191-9191-4191-8191-919191919191';
const _harvestEvent = '71717171-7171-4171-8171-717171717171';
const _uploaded = '61616161-6161-4161-8161-616161616161';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool staff = false,
  String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
}) async {
  tester.view.physicalSize = Size(staff ? 1200 : 390, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness(account: account);
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: !staff,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: staff ? churchStaffTheme() : churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
  return h;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String key) => find.byKey(Key(key));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await settle(tester);
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(byKey(key)).data!;

/// The theme and one campaign linked to the Harvest event, the campaign
/// listed first to show the theme still leads.
AccessRead<PublicBanners> twoBanners() => AccessReadOk(
  PublicBanners.fromJson(
    publicBannersData([
      publicBannerData(
        bannerId: _campaign,
        kind: 'campaign',
        title: 'SYNTHETIC Harvest appeal',
        subtitle: 'Bring a gift on Sunday',
        altText: 'SYNTHETIC baskets of maize and pumpkins',
        eventId: _harvestEvent,
        path: 'banner/$_campaign/r2/image.jpg',
      ),
      publicBannerData(),
    ]),
  ),
);

AccessRead<StaffBanners> staffBanners(
  List<Map<String, Object?>> banners, {
  int removalsPending = 0,
}) => AccessReadOk(
  StaffBanners.fromJson(
    staffBannersData(banners, removalsPending: removalsPending),
  ),
);

/// A verified rights record whose source is on the Q5 list.
AccessRead<StaffRights> verifiedRights({List<String>? q5}) => AccessReadOk(
  StaffRights.fromJson(
    staffRightsData([
      rightsRecordData(
        state: 'published',
        revision: 2,
        live: rightsRevisionData(),
        q5Uses: q5 ?? const ['display', 'offline', 'audio'],
        verifiedBy: 'SYNTHETIC Pastor Banda',
        verifiedAt: '2099-09-01T09:00:00.000000Z',
      ),
    ]),
  ),
);

PickedFile picked(String name, {String? type = 'image/png'}) =>
    PickedFile(name: name, declaredType: type, bytes: tinyPng);

void main() {
  group('wire parsing', () {
    test('the public banners, theme and campaign', () {
      final v = (twoBanners() as AccessReadOk<PublicBanners>).value;
      final theme = v.byId(_theme)!;
      expect(theme.kind, BannerKind.theme);
      expect(theme.themeYear, 2026);
      expect(theme.subtitle, 'Deuteronomy 7:9');
      expect(theme.image.width, 1920);
      final c = v.byId(_campaign)!;
      expect(c.kind, BannerKind.campaign);
      expect(c.themeYear, isNull);
      expect(c.eventId, _harvestEvent);
      expect(c.image.path, 'banner/$_campaign/r2/image.jpg');
      expect(
        bannerCardLabel(theme),
        'Theme for 2026. SYNTHETIC God\'s faithfulness in Self Sustenance. '
        'Deuteronomy 7:9. Opens the theme image.',
      );
      expect(
        bannerCardLabel(c),
        'SYNTHETIC baskets of maize and pumpkins. SYNTHETIC Harvest appeal.',
      );
      // A key a later entry adds is ignored.
      expect(
        PublicBanner.fromJson({...publicBannerData(), 'offline': true}).title,
        theme.title,
      );
    });

    test('a malformed public answer is refused, never guessed', () {
      final good = publicBannerData();
      for (final bad in <Object?>[
        null,
        {'banners': 'x'},
        publicBannersData([
          {...good, 'title': ' '},
        ]),
        publicBannersData([
          {...good, 'theme_year': null},
        ]),
        publicBannersData([
          {...good, 'banner_kind': 'poster'},
        ]),
        publicBannersData([
          {...publicBannerData(kind: 'campaign'), 'theme_year': 2026},
        ]),
        publicBannersData([
          {
            ...good,
            'image': {
              'path': '../drafts/x.png',
              'media_type': 'image/png',
              'width': 1,
              'height': 1,
            },
          },
        ]),
        publicBannersData([
          {
            ...good,
            'image': {
              'path': 'banner/x/r1/image.svg',
              'media_type': 'image/svg+xml',
              'width': 1,
              'height': 1,
            },
          },
        ]),
        publicBannersData([
          {...good, 'alt_text': null},
        ]),
      ]) {
        expect(
          () => PublicBanners.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('the editors\' banner read, its image state and removals', () {
      final v = StaffBanners.fromJson(
        staffBannersData([
          staffBannerData(
            state: 'published',
            revision: 4,
            publicImage: 'waiting',
            live: staffBannerRevisionData(
              imageAssetId: _uploaded,
              rights: bannerRightsData(),
            ),
            draft: staffBannerRevisionData(
              revisionNo: 2,
              title: 'SYNTHETIC Harvest appeal (new)',
              rights: bannerRightsData(display: 'source_not_cleared'),
            ),
            publishedBy: 'SYNTHETIC Media Phiri',
            publishedAt: '2099-09-01T08:00:00.000000Z',
          ),
        ], removalsPending: 2),
      );
      final b = v.banners.single;
      expect(v.removalsPending, 2);
      expect(b.publicImage, PublicImageState.waiting);
      expect(b.hasChanges, isTrue);
      expect(b.live!.image!.assetId, _uploaded);
      expect(b.current.rights!.display, 'source_not_cleared');
      expect(
        StaffBanners.fromJson(
          staffBannersData([
            staffBannerData(
              state: 'published',
              revision: 4,
              publicImage: 'event_not_public',
              live: staffBannerRevisionData(imageAssetId: _uploaded),
              publishedBy: 'SYNTHETIC Media Phiri',
              publishedAt: '2099-09-01T08:00:00.000000Z',
            ),
          ]),
        ).banners.single.publicImage,
        PublicImageState.eventNotPublic,
        reason: 'a campaign whose event is not public is not shown',
      );
      for (final bad in [
        staffBannersData([staffBannerData(publicImage: 'gone')]),
        staffBannersData([staffBannerData()]),
        {...staffBannersData([]), 'removals_pending': -1},
        staffBannersData([], capacity: 'member'),
      ]) {
        expect(() => StaffBanners.fromJson(bad), throwsFormatException);
      }
    });

    test('the editors\' rights read and its Q5 uses', () {
      final v = (verifiedRights() as AccessReadOk<StaffRights>).value;
      final r = v.rights.single;
      expect(r.inForce, isTrue);
      expect(r.clearsDisplayNow, isTrue);
      expect(r.live!.fields.basis, RightsBasis.churchOwned);
      expect(r.live!.fields.clearedLabels, ['Display']);
      final off = (verifiedRights(
        q5: const [],
      ) as AccessReadOk<StaffRights>).value.rights.single;
      expect(off.clearsDisplayNow, isFalse);
      for (final bad in [
        staffRightsData([
          rightsRecordData(draft: rightsRevisionData(), q5Uses: ['print']),
        ]),
        staffRightsData([
          rightsRecordData(draft: rightsRevisionData(basis: 'bought')),
        ]),
        staffRightsData([
          {...rightsRecordData(draft: rightsRevisionData()), 'q5_uses': null},
        ]),
      ]) {
        expect(() => StaffRights.fromJson(bad), throwsFormatException);
      }
    });

    test('payloads carry every field', () {
      const input = BannerInput(
        kind: BannerKind.theme,
        themeYear: 2026,
        title: ' SYNTHETIC Theme 2026 ',
        subtitle: ' ',
        altText: 'SYNTHETIC field at sunrise',
        eventId: _harvestEvent,
        imageAssetId: _uploaded,
        imageRightsId: _rights,
      );
      expect(input.toCreatePayload(), {
        'banner_kind': 'theme',
        'theme_year': 2026,
        'title': 'SYNTHETIC Theme 2026',
        'subtitle': null,
        'alt_text': 'SYNTHETIC field at sunrise',
        'event_id': null,
      });
      expect(input.toSavePayload(_draft), {
        'banner_id': _draft,
        'banner_kind': 'theme',
        'theme_year': 2026,
        'title': 'SYNTHETIC Theme 2026',
        'subtitle': null,
        'alt_text': 'SYNTHETIC field at sunrise',
        'event_id': null,
        'image_asset_id': _uploaded,
        'image_rights_id': _rights,
      });
      const rights = RightsInput(
        label: 'SYNTHETIC images',
        sourceKey: 'synthetic',
        holder: 'SYNTHETIC media team',
        basis: RightsBasis.churchOwned,
        clearsDisplay: true,
        clearsOffline: false,
        clearsAudio: false,
        evidence: 'SYNTHETIC made for staging',
      );
      expect(rights.toPayload(rightsId: _rights), {
        'rights_id': _rights,
        'label': 'SYNTHETIC images',
        'source_key': 'synthetic',
        'holder': 'SYNTHETIC media team',
        'basis': 'church_owned',
        'clears_display': true,
        'clears_offline': false,
        'clears_audio': false,
        'evidence': 'SYNTHETIC made for staging',
      });
    });

    test('upload and sync answers', () {
      final up = UploadedImage.fromJson({
        'outcome': 'uploaded',
        'asset_id': _uploaded,
        'media_type': 'image/jpeg',
        'byte_size': 10,
        'width': 1920,
        'height': 1080,
      });
      expect(up.mediaType, 'image/jpeg');
      expect(
        () => UploadedImage.fromJson({
          'outcome': 'uploaded',
          'asset_id': _uploaded,
          'media_type': 'text/html',
          'byte_size': 10,
          'width': 1,
          'height': 1,
        }),
        throwsFormatException,
      );
      final s = FileSyncDone.fromJson({
        'outcome': 'synced',
        'placed': 1,
        'removed': 2,
        'waiting': 0,
        'removals_pending': 0,
      });
      expect(s.complete, isTrue);
      expect(
        const ImageUploadRefused(
          code: 'validation_failed',
          fieldErrors: {'byte_size': 'too_large'},
        ).reason,
        'too_large',
      );
      expect(
        PickedFile(
          name: 'big.png',
          declaredType: 'image/png',
          bytes: Uint8List(0),
          size: 20 << 20,
        ).unreadable,
        isTrue,
      );
    });
  });

  group('Home carousel (signed out)', () {
    testWidgets('the theme card comes first, then campaigns', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.banners.publicBanners = twoBanners(),
      );
      expect(h.banners.publicCalls, 1);
      expect(byKey('home-banners'), findsOneWidget);
      final first = tester.getTopLeft(byKey('home-banner-$_theme'));
      final second = tester.getTopLeft(byKey('home-banner-$_campaign'));
      expect(first.dx, lessThan(second.dx));
      expect(textOf(tester, 'home-banner-eyebrow-$_theme'), 'THEME FOR 2026');
      expect(
        textOf(tester, 'home-banner-title-$_theme'),
        'SYNTHETIC God\'s faithfulness in Self Sustenance',
      );
      // The carousel opens Home, above the greeting.
      expect(
        tester.getTopLeft(byKey('home-banners')).dy,
        lessThan(tester.getTopLeft(byKey('home-greeting')).dy),
      );
      // 310 x 16:9 cards.
      final size = tester.getSize(byKey('home-banner-$_theme'));
      expect(size.width, 310);
      expect(size.height, closeTo(310 * 9 / 16, 0.01));
    });

    testWidgets('a withdrawn banner leaves Home when the app comes back', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.banners.publicBanners = twoBanners(),
      );
      expect(byKey('home-banner-$_campaign'), findsOneWidget);
      // Withdrawn on staff web meanwhile: the public read no longer has it.
      h.banners.publicBanners = AccessReadOk(
        PublicBanners.fromJson(publicBannersData([publicBannerData()])),
      );
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
      expect(h.banners.publicCalls, 2);
      expect(byKey('home-banner-$_campaign'), findsNothing);
      expect(byKey('home-banner-$_theme'), findsOneWidget);
    });

    testWidgets('cards are spoken with their text alternatives', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.banners.publicBanners = twoBanners(),
      );
      expect(
        find.bySemanticsLabel(
          'Theme for 2026. SYNTHETIC God\'s faithfulness in Self Sustenance. '
          'Deuteronomy 7:9. Opens the theme image.',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'SYNTHETIC baskets of maize and pumpkins. SYNTHETIC Harvest appeal.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a campaign image that cannot load says so', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.banners.publicBanners = twoBanners(),
      );
      // The test HTTP client answers every image request with an error.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await settle(tester);
      expect(byKey('home-banner-unavailable-$_campaign'), findsOneWidget);
      expect(
        textOf(tester, 'home-banner-title-$_campaign'),
        'SYNTHETIC Harvest appeal',
      );
    });

    testWidgets('a tap opens the theme\'s original image', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.banners.publicBanners = twoBanners(),
      );
      await tapKey(tester, 'home-banner-open-$_theme');
      expect(find.byType(BannerScreen), findsOneWidget);
      expect(find.text('Theme for 2026'), findsOneWidget);
      expect(
        textOf(tester, 'banner-title'),
        'SYNTHETIC God\'s faithfulness in Self Sustenance',
      );
      expect(textOf(tester, 'banner-subtitle'), 'Deuteronomy 7:9');
      final image = tester.widget<Image>(byKey('banner-image'));
      expect(
        image.semanticLabel,
        'SYNTHETIC theme artwork: an open field at sunrise',
      );
      expect(image.fit, BoxFit.contain);
      expect(
        (image.image as NetworkImage).url,
        'https://test.invalid/storage/v1/object/public/content-public/'
        'banner/$_theme/r1/image.png',
      );
      expect(byKey('banner-viewer'), findsOneWidget);
      expect(byKey('banner-see-event'), findsNothing);
    });

    testWidgets('a campaign linked to an event opens it', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.banners.publicBanners = twoBanners(),
      );
      await tester.drag(byKey('home-banners'), const Offset(-330, 0));
      await settle(tester);
      await tapKey(tester, 'home-banner-open-$_campaign');
      expect(textOf(tester, 'banner-title'), 'SYNTHETIC Harvest appeal');
      await tapKey(tester, 'banner-see-event');
      expect(find.byType(EventDetailScreen), findsOneWidget);
      expect(h.content.publicEventAsked, [_harvestEvent]);
    });

    testWidgets('a banner no longer public says so', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.banner('84848484-8484-4484-8484-848484848484'),
        account: null,
        setUp: (h) => h.banners.publicBanners = twoBanners(),
      );
      expect(byKey('banner-gone'), findsOneWidget);
      expect(find.text('This banner is no longer shown.'), findsOneWidget);
    });

    testWidgets('no banners: Home shows no carousel', (tester) async {
      await pumpAt(tester, ClientPaths.home, account: null);
      expect(byKey('home-banners'), findsNothing);
      expect(byKey('home-banners-failed'), findsNothing);
      expect(byKey('home-greeting'), findsOneWidget);
    });

    testWidgets('a failed read says so and can be retried', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) =>
            h.banners.publicBanners = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('home-banners-failed'), findsOneWidget);
      expect(find.text('Couldn\'t load church news.'), findsOneWidget);
      h.banners.publicBanners = twoBanners();
      await tapKey(tester, 'home-banners-retry');
      expect(h.banners.publicCalls, 2);
      expect(byKey('home-banners'), findsOneWidget);
    });
  });

  group('staff web Banners', () {
    testWidgets('a plain member is told who manages banners', (tester) async {
      await pumpAt(tester, ClientPaths.contentBanners, staff: true);
      expect(byKey('banners-denied-notGranted'), findsOneWidget);
      expect(byKey('banners-new'), findsNothing);
    });

    testWidgets('opening Banners syncs the public files, then lists', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentBanners,
        staff: true,
        setUp: (h) {
          h.banners.staffBanners = staffBanners([
            staffBannerData(
              bannerId: _theme,
              state: 'published',
              revision: 3,
              publicImage: 'shown',
              live: staffBannerRevisionData(
                kind: 'theme',
                themeYear: 2026,
                title: 'SYNTHETIC Theme 2026',
                subtitle: 'Deuteronomy 7:9',
                imageAssetId: _uploaded,
                rights: bannerRightsData(),
              ),
              publishedBy: 'SYNTHETIC Media Phiri',
              publishedAt: '2099-09-01T08:00:00.000000Z',
            ),
            staffBannerData(draft: staffBannerRevisionData()),
          ], removalsPending: 1);
          h.banners.previews[_uploaded] = tinyPng;
        },
      );
      expect(h.banners.syncCalls, 1);
      expect(
        textOf(tester, 'page-subtitle'),
        '1 waiting to publish · 1 on Home · 1 public file to remove',
      );
      expect(byKey('banners-on-home'), findsOneWidget);
      expect(byKey('banners-waiting'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('banner-mark-$_theme')).label,
        'On Home',
      );
      expect(byKey('banner-thumb-$_uploaded'), findsOneWidget);
      expect(byKey('banners-removals'), findsOneWidget);
      await tapKey(tester, 'banners-sync');
      expect(h.banners.syncCalls, 2);
    });

    testWidgets('a published image not yet placed is flagged', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.contentBanners,
        staff: true,
        setUp: (h) {
          h.banners.staffBanners = staffBanners([
            staffBannerData(
              state: 'published',
              revision: 3,
              publicImage: 'blocked',
              live: staffBannerRevisionData(
                imageAssetId: _uploaded,
                rights: bannerRightsData(display: 'not_in_force'),
              ),
              publishedBy: 'SYNTHETIC Media Phiri',
              publishedAt: '2099-09-01T08:00:00.000000Z',
            ),
          ]);
          h.banners.sync = const FileSyncDone(
            placed: 0,
            removed: 0,
            waiting: 1,
            removalsPending: 0,
          );
        },
      );
      expect(
        textOf(tester, 'banner-note-$_draft'),
        'Rights no longer clear: not shown',
      );
      expect(
        tester.widget<StatusLabel>(byKey('banner-mark-$_draft')).label,
        'Published, not shown',
      );
      expect(byKey('banners-sync-waiting'), findsOneWidget);
    });

    testWidgets('a new campaign is saved as a draft without an image', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentBanners,
        staff: true,
        setUp: (h) => h.banners.staffBanners = staffBanners([]),
      );
      await tapKey(tester, 'banners-new');
      expect(byKey('banner-image-after-save'), findsOneWidget);
      await tester.enterText(
        byKey('banner-title-new'),
        'SYNTHETIC Harvest appeal',
      );
      await tester.enterText(
        byKey('banner-alt-new'),
        'SYNTHETIC baskets of maize',
      );
      await settle(tester);
      await tapKey(tester, 'banner-save-new');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'content_command');
      expect(sent.wire['command'], 'content.create_banner');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'banner_kind': 'campaign',
        'theme_year': null,
        'title': 'SYNTHETIC Harvest appeal',
        'subtitle': null,
        'alt_text': 'SYNTHETIC baskets of maize',
        'event_id': null,
      });
      h.banners.staffBanners = staffBanners([
        staffBannerData(draft: staffBannerRevisionData()),
      ]);
      sent.confirm({'banner_id': _draft, 'revision': 1}, 1);
      await settle(tester);
      expect(byKey('banners-notice-created'), findsOneWidget);
      expect(byKey('banner-form-new'), findsNothing);
    });

    testWidgets('an image refused by the server says why; nothing is kept', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentBanners,
        staff: true,
        setUp: (h) {
          h.banners.staffBanners = staffBanners([
            staffBannerData(draft: staffBannerRevisionData()),
          ]);
          h.banners.staffRights = verifiedRights();
        },
      );
      await tapKey(tester, 'banner-open-$_draft');
      await tapKey(tester, 'banner-edit-$_draft');
      for (final (field, code, copy) in [
        ('byte_size', 'too_large', 'This image is larger than 5 MB.'),
        (
          'file',
          'unsupported_type',
          'Only PNG, JPEG or WebP images can be used.',
        ),
        (
          'file',
          'type_mismatch',
          'This file is not the image type it claims to be.',
        ),
        ('width', 'too_small', 'This image is smaller than 960 x 540.'),
        ('width', 'bad_ratio', 'Use a landscape image close to 16:9.'),
      ]) {
        h.filePicker.next = picked('poster.png');
        h.banners.upload = ImageUploadRefused(
          code: 'validation_failed',
          fieldErrors: {field: code},
        );
        await tapKey(tester, 'banner-choose-image-$_draft');
        expect(
          textOf(tester, 'banner-upload-status-$_draft'),
          'Not uploaded. $copy',
        );
      }
      expect(h.banners.uploads.length, 5);
      expect(h.banners.uploads.first.$1, _draft);
      expect(h.banners.uploads.first.$2, 'banner_image');
      // A file too large to read is refused here: nothing is sent.
      h.filePicker.next = PickedFile(
        name: 'huge.png',
        declaredType: 'image/png',
        bytes: Uint8List(0),
        size: 40 << 20,
      );
      await tapKey(tester, 'banner-choose-image-$_draft');
      expect(
        textOf(tester, 'banner-upload-status-$_draft'),
        'Not uploaded. This image is larger than 5 MB.',
      );
      expect(h.banners.uploads.length, 5);
    });

    testWidgets('an uploaded image is saved with the draft and its rights', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentBanners,
        staff: true,
        setUp: (h) {
          h.banners.staffBanners = staffBanners([
            staffBannerData(revision: 2, draft: staffBannerRevisionData()),
          ]);
          h.banners.staffRights = verifiedRights();
        },
      );
      await tapKey(tester, 'banner-open-$_draft');
      await tapKey(tester, 'banner-edit-$_draft');
      h.filePicker.next = picked('appeal.png');
      await tapKey(tester, 'banner-choose-image-$_draft');
      expect(
        textOf(tester, 'banner-upload-status-$_draft'),
        'Uploaded (1920 x 1080). Save the draft to use this image.',
      );
      expect(byKey('banner-upload-preview-$_draft'), findsOneWidget);
      await tapKey(tester, 'banner-rights-$_draft');
      await tester.tap(
        find
            .textContaining(
              'SYNTHETIC images made for the church · On the Q5 list',
            )
            .last,
      );
      await settle(tester);
      await tapKey(tester, 'banner-save-$_draft');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'content.save_banner');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'banner_id': _draft,
        'banner_kind': 'campaign',
        'theme_year': null,
        'title': 'SYNTHETIC Harvest appeal',
        'subtitle': 'Bring a gift on Sunday',
        'alt_text': 'SYNTHETIC baskets of maize and pumpkins',
        'event_id': null,
        'image_asset_id': _uploaded,
        'image_rights_id': _rights,
      });
    });

    testWidgets('publish sends the command, then syncs the public files', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentBanners,
        staff: true,
        setUp: (h) => h.banners.staffBanners = staffBanners([
          staffBannerData(
            revision: 3,
            draft: staffBannerRevisionData(
              imageAssetId: _uploaded,
              rights: bannerRightsData(),
            ),
          ),
        ]),
      );
      expect(h.banners.syncCalls, 1);
      await tapKey(tester, 'banner-open-$_draft');
      await tapKey(tester, 'banner-publish-$_draft');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'content.publish_banner');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {'banner_id': _draft});
      sent.confirm({'banner_id': _draft, 'revision': 4}, 4);
      await settle(tester);
      expect(byKey('banners-notice-published'), findsOneWidget);
      expect(h.banners.syncCalls, 2);
    });

    testWidgets('publishing with an uncleared source is refused in words', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentBanners,
        staff: true,
        setUp: (h) => h.banners.staffBanners = staffBanners([
          staffBannerData(
            revision: 3,
            draft: staffBannerRevisionData(
              imageAssetId: _uploaded,
              rights: bannerRightsData(display: 'source_not_cleared'),
            ),
          ),
        ]),
      );
      await tapKey(tester, 'banner-open-$_draft');
      await tapKey(tester, 'banner-publish-$_draft');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'image_rights_id': 'source_not_cleared'},
      );
      await settle(tester);
      expect(byKey('banners-notice-blocked'), findsOneWidget);
      expect(
        find.textContaining(
          'This rights record\'s source is not cleared by the owner (Q5).',
        ),
        findsWidgets,
      );
      // Nothing was published, so nothing to sync.
      expect(h.banners.syncCalls, 1);
    });
  });

  group('staff web Rights', () {
    testWidgets('a new rights record is saved as a draft', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentRights,
        staff: true,
        setUp: (h) => h.banners.staffRights = AccessReadOk(
          StaffRights.fromJson(staffRightsData([])),
        ),
      );
      expect(textOf(tester, 'page-subtitle'), startsWith('No rights records'));
      await tapKey(tester, 'rights-new');
      for (final (key, value) in [
        ('rights-label-new', 'SYNTHETIC Theme 2026 artwork'),
        ('rights-source-new', 'synthetic'),
        ('rights-holder-new', 'SYNTHETIC BICC Kafue media team'),
        ('rights-evidence-new', 'SYNTHETIC drawn by the media team'),
      ]) {
        await tester.enterText(byKey(key), value);
      }
      await settle(tester);
      await tapKey(tester, 'rights-save-new');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'content.create_rights_record');
      expect(sent.wire['payload'], {
        'label': 'SYNTHETIC Theme 2026 artwork',
        'source_key': 'synthetic',
        'holder': 'SYNTHETIC BICC Kafue media team',
        'basis': 'church_owned',
        'clears_display': true,
        'clears_offline': false,
        'clears_audio': false,
        'evidence': 'SYNTHETIC drawn by the media team',
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'source_key': 'invalid'},
      );
      await settle(tester);
      expect(byKey('rights-notice-invalid'), findsOneWidget);
      expect(
        find.text('Lower case letters, digits and dashes (for example kjv)'),
        findsOneWidget,
      );
    });

    testWidgets('verify puts a record in force, then syncs', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentRights,
        staff: true,
        setUp: (h) => h.banners.staffRights = AccessReadOk(
          StaffRights.fromJson(
            staffRightsData([
              rightsRecordData(draft: rightsRevisionData(), q5Uses: const []),
            ]),
          ),
        ),
      );
      expect(textOf(tester, 'rights-q5-$_rights'), 'Not on the Q5 list');
      expect(
        tester.widget<StatusLabel>(byKey('rights-mark-$_rights')).label,
        'Draft',
      );
      await tapKey(tester, 'rights-open-$_rights');
      await tapKey(tester, 'rights-verify-$_rights');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'content.verify_rights_record');
      expect(sent.wire['payload'], {'rights_id': _rights});
      expect(h.banners.syncCalls, 0);
      sent.confirm({'rights_id': _rights, 'revision': 2}, 2);
      await settle(tester);
      expect(byKey('rights-notice-verified'), findsOneWidget);
      expect(h.banners.syncCalls, 1);
    });
  });
}
