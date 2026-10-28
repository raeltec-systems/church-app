// Epic 6 entry 14: the finished Home (the guest Join card, the Pending card
// with two separate chips, Coming up poster cards that open the original
// poster) and the top-bar search (hymns on the device, the server's bounded
// search for sermons, events and announcements, honest failed and empty
// states). Fakes only; the server read is covered by
// supabase/tests/content_public_search_test.sql and
// tools/identity-e2e/content-search.mjs.
import 'dart:async';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _harvest = '71717171-7171-4171-8171-717171717171';
const _choir = '72727272-7272-4272-8272-727272727272';
const _series = '91919191-9191-4191-8191-919191919191';
const _sermon = '92929292-9292-4292-8292-929292929292';
const _notice = '73737373-7373-4373-8373-737373737373';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
}) async {
  tester.view.physicalSize = const Size(390, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness(account: account);
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: true,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: churchMobileTheme(Brightness.light),
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

/// Types [text] into the search field and waits past the pause.
Future<void> typeSearch(WidgetTester tester, String text) async {
  await tester.enterText(byKey('search-field'), text);
  await tester.pump(searchDebounce + const Duration(milliseconds: 10));
  await settle(tester);
}

/// The harvest event with a poster and the choir rehearsal without one.
AccessRead<PublicEvents> postersAndPlain() => AccessReadOk(
  PublicEvents.fromJson(
    publicEventsData([
      publicEventData(poster: publicEventPosterData()),
      publicEventData(
        eventId: _choir,
        title: 'SYNTHETIC Choir rehearsal',
        startsAt: '2099-11-05T15:30:00.000000Z',
        endsAt: '2099-11-05T17:00:00.000000Z',
        location: 'SYNTHETIC Church hall',
      ),
    ]),
  ),
);

/// A sermon in a series with a public poster.
AccessRead<PublicSermons> seriesWithPoster({bool poster = true}) {
  final series = publicSermonSeriesData(poster: poster);
  return AccessReadOk(
    PublicSermons.fromJson({
      'sermons': [publicSermonData(series: series)],
      'series': [series],
      'truncated': false,
    }),
  );
}

void main() {
  group('domain', () {
    test('searchQueryOf trims, folds spaces and needs two characters', () {
      expect(searchQueryOf('  harvest   week '), 'harvest week');
      expect(searchQueryOf(' a '), isNull);
      expect(searchQueryOf(''), isNull);
      expect(searchQueryOf('x' * 120)!.length, ContentSearchLimits.maxLength);
    });

    test('the search answer reads each kind through its public model', () {
      final r = PublicSearchResults.fromJson(
        publicSearchData(
          query: 'harvest',
          sermons: [publicSermonData()],
          events: [publicEventData()],
          announcements: [publicAnnouncementData()],
          truncated: true,
        ),
      );
      expect(r.query, 'harvest');
      expect(r.sermons.single.sermonId, _sermon);
      expect(r.events.single.eventId, _harvest);
      expect(r.announcements.single.announcementId, _notice);
      expect(r.truncated, isTrue);
      expect(r.isEmpty, isFalse);
    });

    test('an answer over the page size or of another shape is refused', () {
      expect(
        () => PublicSearchResults.fromJson(
          publicSearchData(
            announcements: [
              for (var i = 0; i < 11; i++) publicAnnouncementData(),
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => PublicSearchResults.fromJson({'query': 'x', 'sermons': []}),
        throwsFormatException,
      );
    });

    test('an older answer never replaces a newer query', () async {
      final h = ClientTestHarness(account: null);
      final slow = Completer<void>();
      h.search.hold = slow;
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);
      final sub = container.listen(contentSearchProvider, (_, _) {});
      addTearDown(sub.close);
      final ctl = container.read(contentSearchProvider.notifier);
      final first = ctl.search('harvest');
      h.search.hold = null;
      h.search.byQuery['choir'] = AccessReadOk(
        PublicSearchResults.fromJson(
          publicSearchData(query: 'choir', events: [publicEventData()]),
        ),
      );
      await ctl.search('choir');
      slow.complete();
      await first;
      final s = container.read(contentSearchProvider);
      expect(s.query, 'choir');
      expect(
        (s.result! as AccessReadOk<PublicSearchResults>).value.events,
        hasLength(1),
      );
      expect(h.search.asked, ['harvest', 'choir']);
    });
  });

  group('Home', () {
    testWidgets('a guest sees the Join card, which opens Sign in', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.home, account: null);
      expect(byKey('home-join-card'), findsOneWidget);
      expect(byKey('home-pending-card'), findsNothing);
      expect(byKey('home-greeting'), findsNothing);
      expect(find.text('Part of the church family?'), findsOneWidget);
      // The Join card comes before the announcements.
      expect(
        tester.getTopLeft(byKey('home-join-card')).dy,
        lessThan(tester.getTopLeft(byKey('home-announcements')).dy),
      );
      await tapKey(tester, 'home-join');
      expect(byKey('go-sign-in'), findsOneWidget);
      expect(byKey('go-create-account'), findsOneWidget);
    });

    testWidgets('a Pending applicant sees church approval and the cell as '
        'two chips, and the card opens the request', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) {
          h.grants.myAccess = const AccessReadDenied(AccessDenial.notLinked);
          h.membership.mine = myApplicationWith(applicationData());
        },
      );
      expect(byKey('home-join-card'), findsNothing);
      expect(byKey('home-pending-card'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('home-pending-church')).label,
        'Awaiting church approval',
      );
      expect(
        tester.widget<StatusLabel>(byKey('home-pending-cell')).label,
        'SYNTHETIC Riverside · Awaiting confirmation',
      );
      expect(byKey('home-duties-card'), findsNothing);
      await tapKey(tester, 'home-pending-card');
      expect(byKey('application-status'), findsOneWidget);
    });

    testWidgets('an applicant who is not sure of their cell gets a grey cell '
        'chip; details requested stay amber', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) {
          h.grants.myAccess = const AccessReadDenied(AccessDenial.notLinked);
          h.membership.mine = myApplicationWith(
            applicationData(
              churchStatus: 'details_requested',
              cellChoice: const {'choice': 'not_sure'},
            ),
          );
        },
      );
      final church = tester.widget<StatusLabel>(byKey('home-pending-church'));
      final cell = tester.widget<StatusLabel>(byKey('home-pending-cell'));
      expect(church.label, 'The church asked for more details');
      expect(church.tone, StatusTone.warning);
      expect(cell.label, 'Not sure · office will follow up');
      expect(cell.tone, StatusTone.neutral);
    });

    testWidgets('an account with no request sent keeps the plain line', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) =>
            h.grants.myAccess = const AccessReadDenied(AccessDenial.notLinked),
      );
      expect(byKey('home-pending-card'), findsNothing);
      expect(byKey('home-signed-in-line'), findsOneWidget);
    });

    testWidgets('a member keeps My duties, My follow-ups and My cell', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(syntheticGrants());
          h.memberAccess.next = MemberAccessGranted(syntheticMemberSummary());
          h.duties.mine = AccessReadOk(
            MyDuties.fromJson({
              'member_id': '22222222-2222-4222-8222-222222222222',
              'assignments': const <Object?>[],
            }),
          );
        },
      );
      expect(byKey('home-greeting'), findsOneWidget);
      expect(byKey('home-duties-card'), findsOneWidget);
      expect(byKey('home-join-card'), findsNothing);
      expect(byKey('home-pending-card'), findsNothing);
    });

    testWidgets('Coming up: a poster card opens the original poster, a card '
        'without one keeps its date badge', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.content.publicEvents = postersAndPlain(),
      );
      expect(byKey('coming-up-poster-$_harvest'), findsOneWidget);
      expect(byKey('coming-up-poster-$_choir'), findsNothing);
      expect(
        find.descendant(
          of: byKey('coming-up-card-$_choir'),
          matching: find.byType(DateBadge),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: byKey('coming-up-card-$_harvest'),
          matching: find.byType(DateBadge),
        ),
        findsNothing,
      );
      final size = tester.getSize(byKey('coming-up-poster-$_harvest'));
      expect(size.width / size.height, closeTo(16 / 9, 0.01));
      expect(
        find.bySemanticsLabel(RegExp('^Poster for SYNTHETIC Harvest')),
        findsOneWidget,
      );
      await tapKey(tester, 'coming-up-poster-$_harvest');
      expect(byKey('poster-viewer'), findsOneWidget);
      expect(textOf(tester, 'poster-title'), 'SYNTHETIC Harvest Thanksgiving');
      expect(
        tester.widget<Image>(byKey('poster-image')).semanticLabel,
        'SYNTHETIC harvest baskets on the altar',
      );
      await tapKey(tester, 'poster-see-event');
      expect(h.content.publicEventAsked, [_harvest]);
    });

    testWidgets('the card text opens the event', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.content.publicEvents = postersAndPlain(),
      );
      await tapKey(tester, 'event-row-$_choir');
      expect(h.content.publicEventAsked, [_choir]);
      expect(byKey('coming-up'), findsNothing);
    });

    testWidgets('the current sermon series shows as a poster card when its '
        'poster is public', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.sermons.catalog = seriesWithPoster(),
      );
      expect(byKey('coming-up-series-$_series'), findsOneWidget);
      expect(find.text('Sermon series · 1 sermon'), findsOneWidget);
      await tapKey(tester, 'coming-up-series-poster-$_series');
      expect(textOf(tester, 'poster-title'), 'SYNTHETIC Living hope');
      expect(byKey('poster-see-sermons'), findsOneWidget);
    });

    testWidgets('a series without a poster gets no card', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.sermons.catalog = seriesWithPoster(poster: false),
      );
      expect(byKey('coming-up-series-$_series'), findsNothing);
    });

    testWidgets('a poster that is no longer published says so', (tester) async {
      await pumpAt(tester, ClientPaths.eventPoster(_harvest), account: null);
      expect(byKey('poster-gone'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('finds a hymn on the device and the server\'s sermon, event '
        'and announcement', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.search,
        account: null,
        setUp: (h) => h.search.answer = AccessReadOk(
          PublicSearchResults.fromJson(
            publicSearchData(
              query: 'SYNTHETIC hymn 2',
              sermons: [publicSermonData()],
              events: [publicEventData()],
              announcements: [publicAnnouncementData()],
            ),
          ),
        ),
      );
      expect(byKey('search-intro'), findsOneWidget);
      await typeSearch(tester, 'SYNTHETIC hymn 2');
      expect(h.search.asked, ['SYNTHETIC hymn 2']);
      expect(byKey('hymn-row-hymn-2'), findsOneWidget);
      expect(byKey('search-sermon-$_sermon'), findsOneWidget);
      expect(byKey('event-row-$_harvest'), findsOneWidget);
      expect(byKey('announcement-row-$_notice'), findsOneWidget);
      // Hymns first, then sermons, events and announcements.
      double top(String k) => tester.getTopLeft(byKey(k)).dy;
      expect(
        top('search-hymns-header'),
        lessThan(top('search-sermons-header')),
      );
      expect(
        top('search-sermons-header'),
        lessThan(top('search-events-header')),
      );
      expect(
        top('search-events-header'),
        lessThan(top('search-announcements-header')),
      );
      await tapKey(tester, 'announcement-row-$_notice');
      expect(h.announcements.publicAnnouncementAsked, [_notice]);
    });

    testWidgets('a hymn opens from the results', (tester) async {
      await pumpAt(tester, ClientPaths.search, account: null);
      await typeSearch(tester, '3');
      expect(byKey('hymn-row-hymn-3'), findsOneWidget);
      await tapKey(tester, 'hymn-row-hymn-3');
      expect(find.text('SYNTHETIC hymn 3'), findsWidgets);
    });

    testWidgets('one character searches hymns only', (tester) async {
      final h = await pumpAt(tester, ClientPaths.search, account: null);
      await typeSearch(tester, '1');
      expect(byKey('hymn-row-hymn-1'), findsOneWidget);
      expect(byKey('search-too-short'), findsOneWidget);
      expect(h.search.asked, isEmpty);
    });

    testWidgets('offline: hymns are still found and the failed server read '
        'is said plainly, then retried', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.search,
        account: null,
        setUp: (h) =>
            h.search.answer = const AccessReadFailed(unreachable: true),
      );
      await typeSearch(tester, 'SYNTHETIC chorus');
      expect(byKey('hymn-row-chorus-1'), findsOneWidget);
      expect(byKey('search-server-failed'), findsOneWidget);
      expect(byKey('search-nothing'), findsNothing);
      expect(byKey('search-server-none'), findsNothing);
      h.search.answer = AccessReadOk(
        PublicSearchResults.fromJson(publicSearchData()),
      );
      await tapKey(tester, 'search-retry');
      expect(h.search.asked, ['SYNTHETIC chorus', 'SYNTHETIC chorus']);
      expect(byKey('search-server-failed'), findsNothing);
      expect(byKey('search-server-none'), findsOneWidget);
    });

    testWidgets('nothing anywhere says so once, in a frame', (tester) async {
      await pumpAt(tester, ClientPaths.search, account: null);
      await typeSearch(tester, 'zzzz');
      expect(byKey('search-nothing'), findsOneWidget);
      expect(byKey('search-hymns-none'), findsNothing);
    });

    testWidgets('a truncated answer says only the first ten are shown', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.search,
        account: null,
        setUp: (h) => h.search.answer = AccessReadOk(
          PublicSearchResults.fromJson(
            publicSearchData(
              announcements: [publicAnnouncementData()],
              truncated: true,
            ),
          ),
        ),
      );
      await typeSearch(tester, 'harvest');
      expect(byKey('search-truncated'), findsOneWidget);
    });

    testWidgets('the hymn book failing to open is not "no hymns"', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.search,
        account: null,
        setUp: (h) => h.hymnBook.error = const FormatException('broken'),
      );
      await typeSearch(tester, 'hymn');
      expect(byKey('search-hymns-failed'), findsOneWidget);
      expect(byKey('search-hymns-none'), findsNothing);
      expect(byKey('search-nothing'), findsNothing);
    });

    testWidgets('typing quickly asks the server once, for the last words', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.search, account: null);
      await tester.enterText(byKey('search-field'), 'ha');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(byKey('search-field'), 'harv');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(byKey('search-field'), 'harvest');
      await tester.pump(searchDebounce + const Duration(milliseconds: 10));
      await settle(tester);
      expect(h.search.asked, ['harvest']);
      await tapKey(tester, 'search-clear');
      expect(byKey('search-intro'), findsOneWidget);
    });

    // Review section 8: an answer shows only under the words it was asked
    // for; new words wait as a pending search.
    testWidgets('new words never show the previous answer or its "nothing"', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.search,
        account: null,
        setUp: (h) => h.search.answer = AccessReadOk(
          PublicSearchResults.fromJson(
            publicSearchData(
              announcements: [publicAnnouncementData()],
              truncated: true,
            ),
          ),
        ),
      );
      await typeSearch(tester, 'harvest');
      expect(byKey('search-truncated'), findsOneWidget);
      await tester.enterText(byKey('search-field'), 'harvest choir');
      await tester.pump(const Duration(milliseconds: 50));
      expect(byKey('search-truncated'), findsNothing);
      expect(byKey('search-server-loading'), findsOneWidget);
      await tester.pump(searchDebounce);
      await settle(tester);
      expect(h.search.asked, ['harvest', 'harvest choir']);
      expect(byKey('search-truncated'), findsOneWidget);

      h.search.answer = AccessReadOk(
        PublicSearchResults.fromJson(publicSearchData()),
      );
      await typeSearch(tester, 'zzzz');
      expect(byKey('search-nothing'), findsOneWidget);
      await tester.enterText(byKey('search-field'), 'zzzzq');
      await tester.pump(const Duration(milliseconds: 50));
      expect(byKey('search-nothing'), findsNothing);
      expect(byKey('search-server-loading'), findsOneWidget);
    });
  });
}
