// Story 6.1: church events through Content's publication lifecycle. The
// wire parsing (public projection and the editors' read), the public
// Calendar and an event's detail (both endpoints of a multi-day event, a
// withdrawn event, honest failed and empty states), Home's Coming up for a
// guest (no member card) and a member, and the staff Events editor's
// commands (create, save, publish, withdraw) with honest request states.
// Fakes only; the server behaviour is covered by
// supabase/tests/content_events_test.sql and
// tools/identity-e2e/content-events.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _harvest = '71717171-7171-4171-8171-717171717171';
const _choir = '72727272-7272-4272-8272-727272727272';

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

/// A two-day Harvest Thanksgiving and a one-evening choir rehearsal in
/// November (2099, so they stay ahead).
AccessRead<PublicEvents> twoEvents() => AccessReadOk(
  PublicEvents.fromJson(
    publicEventsData([
      publicEventData(),
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

AccessRead<StaffEvents> staffEvents(List<Map<String, Object?>> events) =>
    AccessReadOk(StaffEvents.fromJson(staffEventsData(events)));

Map<String, Object?> publishedHarvest({Map<String, Object?>? draft}) =>
    staffEventData(
      revision: 3,
      state: 'published',
      live: staffEventRevisionData(revisionNo: 1),
      draft: draft,
      publishedBy: 'SYNTHETIC Media Phiri',
      publishedAt: '2099-09-01T08:00:00.000000Z',
    );

void main() {
  group('wire parsing', () {
    test('the public projection and its multi-day events', () {
      final events = PublicEvents.fromJson(
        publicEventsData([publicEventData()], truncated: true),
      );
      final e = events.events.single;
      expect(events.truncated, isTrue);
      expect(e.title, 'SYNTHETIC Harvest Thanksgiving');
      expect(e.multiDay, isTrue);
      expect(e.publicationRevision, 1);
      expect(
        eventSpanText(e.startsAt, e.endsAt),
        'Sat 10 Oct 09:00 – Sun 11 Oct 12:00',
      );
      final evening = PublicEvent.fromJson(
        publicEventData(
          startsAt: '2099-11-05T15:30:00.000000Z',
          endsAt: '2099-11-05T17:00:00.000000Z',
        ),
      );
      expect(evening.multiDay, isFalse);
      expect(eventSpanText(evening.startsAt, evening.endsAt), '17:30–19:00');
      expect(churchLongWhen(e.startsAt), 'Saturday 10 October 2099, 09:00');
      // A key a later entry adds is ignored (an older app keeps reading).
      expect(
        PublicEvent.fromJson({...publicEventData(), 'poster': null}).eventId,
        _harvest,
      );
    });

    test('a malformed public answer is refused, never guessed', () {
      for (final bad in <Object?>[
        null,
        {'events': 'x', 'truncated': false},
        publicEventsData([
          {...publicEventData(), 'title': ''},
        ]),
        publicEventsData([
          publicEventData(endsAt: '2099-10-10T06:00:00.000000Z'),
        ]),
        publicEventsData([
          publicEventData(startsAt: '2099-10-10T09:00:00+02:00x'),
        ]),
        publicEventsData([
          {...publicEventData(), 'publication_revision': 0},
        ]),
      ]) {
        expect(
          () => PublicEvents.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
      expect(PublicEventRead.fromJson({'event': null}).event, isNull);
      expect(() => PublicEventRead.fromJson({}), throwsFormatException);
    });

    test('the editors\' read: states, revisions and attribution', () {
      final staff = StaffEvents.fromJson(
        staffEventsData([
          staffEventData(draft: staffEventRevisionData()),
          publishedHarvest(draft: staffEventRevisionData(revisionNo: 2)),
        ], capacity: 'pastor'),
      );
      expect(staff.capacity, 'pastor');
      final draft = staff.events.first;
      expect(draft.state, ContentState.draft);
      expect(draft.canPublish, isTrue);
      expect(draft.canWithdraw, isFalse);
      final changed = staff.events.last;
      expect(changed.hasChanges, isTrue);
      expect(changed.current.title, 'SYNTHETIC Harvest Thanksgiving');
      expect(changed.publishedBy, 'SYNTHETIC Media Phiri');
      for (final bad in <Map<String, Object?>>[
        // A never-published event without its draft.
        staffEventData(),
        // A published event without its live revision.
        staffEventData(state: 'published', draft: staffEventRevisionData()),
        staffEventData(state: 'hidden', draft: staffEventRevisionData()),
      ]) {
        expect(
          () => StaffEvents.fromJson(staffEventsData([bad])),
          throwsFormatException,
        );
      }
      expect(
        () => StaffEvents.fromJson(staffEventsData([], capacity: 'member')),
        throwsFormatException,
      );
    });

    test('an input sends every field as UTC instants ending in Z', () {
      final input = EventInput(
        title: ' SYNTHETIC Harvest Thanksgiving ',
        description: 'SYNTHETIC two days.',
        startsAt: ChurchTime.parse('2099-10-10', '09:00')!,
        endsAt: ChurchTime.parse('2099-10-11', '12:00')!,
        location: 'SYNTHETIC Main sanctuary',
      );
      expect(input.toPayload(eventId: _harvest), {
        'event_id': _harvest,
        'title': 'SYNTHETIC Harvest Thanksgiving',
        'description': 'SYNTHETIC two days.',
        'starts_at': '2099-10-10T07:00:00.000Z',
        'ends_at': '2099-10-11T10:00:00.000Z',
        'location': 'SYNTHETIC Main sanctuary',
      });
      expect(input.toPayload().containsKey('event_id'), isFalse);
    });

    test('only Media, Pastor and Admin edit content (navigation only)', () {
      expect(editsContent(null), isFalse);
      expect(editsContent(syntheticGrants()), isFalse);
      for (final role in ['media', 'pastor', 'admin']) {
        expect(editsContent(syntheticGrants(roles: [role])), isTrue);
      }
      expect(editsContent(syntheticGrants(roles: ['lead_pastor'])), isFalse);
    });
  });

  group('the public Calendar (signed out)', () {
    testWidgets('events by church month, both endpoints of a two-day event', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.calendar,
        account: null,
        setUp: (h) => h.content.publicEvents = twoEvents(),
      );
      expect(h.content.publicEventsCalls, 1);
      expect(find.text('Calendar'), findsOneWidget);
      expect(find.text('October 2099'), findsOneWidget);
      expect(find.text('November 2099'), findsOneWidget);
      expect(
        textOf(tester, 'event-when-$_harvest'),
        'Sat 10 Oct 09:00 – Sun 11 Oct 12:00 · SYNTHETIC Main sanctuary',
      );
      expect(
        textOf(tester, 'event-when-$_choir'),
        '17:30–19:00 · SYNTHETIC Church hall',
      );
      // No draft, editor or private field reaches the public screens.
      expect(find.textContaining('Phiri'), findsNothing);
    });

    testWidgets('a row opens the event with its start, end and place', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.calendar,
        account: null,
        setUp: (h) {
          h.content.publicEvents = twoEvents();
          h.content.publicEvent[_harvest] = AccessReadOk(
            PublicEventRead.fromJson({'event': publicEventData()}),
          );
        },
      );
      await tapKey(tester, 'event-row-$_harvest');
      expect(h.content.publicEventAsked, [_harvest]);
      expect(textOf(tester, 'event-title'), 'SYNTHETIC Harvest Thanksgiving');
      expect(find.text('Saturday 10 October 2099, 09:00'), findsOneWidget);
      expect(find.text('Sunday 11 October 2099, 12:00'), findsOneWidget);
      expect(find.text('SYNTHETIC Main sanctuary'), findsOneWidget);
      expect(
        textOf(tester, 'event-description'),
        'SYNTHETIC two days of thanksgiving services.',
      );
      expect(find.byType(BackButton), findsOneWidget);
    });

    testWidgets('a withdrawn event says so instead of an old copy', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.calendarEvent(_harvest),
        account: null,
        setUp: (h) => h.content.publicEvent[_harvest] = AccessReadOk(
          PublicEventRead.fromJson({'event': publicEventData()}),
        ),
      );
      expect(textOf(tester, 'event-title'), 'SYNTHETIC Harvest Thanksgiving');
      // Withdrawn on staff web: the next read answers null.
      h.content.publicEvent.remove(_harvest);
      await tapKey(tester, 'event-reload');
      await settle(tester);
      expect(byKey('event-gone'), findsOneWidget);
      expect(find.text('This event is no longer on the calendar.'), findsOne);
      expect(byKey('event-title'), findsNothing);
    });

    testWidgets('empty and failed reads differ', (tester) async {
      await pumpAt(tester, ClientPaths.calendar, account: null);
      expect(byKey('calendar-empty'), findsOneWidget);
      expect(byKey('calendar-failed'), findsNothing);
    });

    testWidgets('no connection is not an empty calendar', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.calendar,
        account: null,
        setUp: (h) =>
            h.content.publicEvents = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('calendar-failed'), findsOneWidget);
      expect(byKey('calendar-empty'), findsNothing);
      expect(find.textContaining('not an empty calendar'), findsOneWidget);
    });

    testWidgets('reload asks the server again', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.calendar,
        account: null,
        setUp: (h) => h.content.publicEvents = twoEvents(),
      );
      await tapKey(tester, 'calendar-reload');
      expect(h.content.publicEventsCalls, 2);
    });

    testWidgets('a failed refresh keeps the events shown and says from when', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.calendar,
        account: null,
        setUp: (h) => h.content.publicEvents = twoEvents(),
      );
      expect(byKey('event-row-$_harvest'), findsOneWidget);
      h.content.publicEvents = const AccessReadFailed(unreachable: true);
      await tapKey(tester, 'calendar-reload');
      expect(byKey('calendar-stale'), findsOneWidget);
      expect(find.textContaining('as it was at'), findsOneWidget);
      expect(byKey('event-row-$_harvest'), findsOneWidget);
      expect(byKey('calendar-failed'), findsNothing);
      // The next good answer clears the notice.
      h.content.publicEvents = twoEvents();
      await tapKey(tester, 'calendar-reload');
      expect(byKey('calendar-stale'), findsNothing);
    });

    testWidgets('a one-day row is spoken with its date', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAt(
        tester,
        ClientPaths.calendar,
        account: null,
        setUp: (h) => h.content.publicEvents = twoEvents(),
      );
      expect(
        find.bySemanticsLabel(
          'SYNTHETIC Choir rehearsal, Thu 5 Nov 17:30 to 19:00, '
          'SYNTHETIC Church hall',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('Home', () {
    testWidgets('a guest sees Welcome and Coming up, no member card', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.content.publicEvents = twoEvents(),
      );
      expect(textOf(tester, 'home-greeting'), 'Welcome');
      expect(byKey('home-guest-line'), findsOneWidget);
      for (final card in [
        'home-duties-card',
        'home-followups-card',
        'home-followups-link',
        'home-my-cell',
      ]) {
        expect(byKey(card), findsNothing, reason: card);
      }
      expect(byKey('event-row-$_harvest'), findsOneWidget);
      expect(byKey('event-row-$_choir'), findsOneWidget);
      await tapKey(tester, 'coming-up-calendar');
      expect(find.text('Calendar'), findsOneWidget);
    });

    testWidgets('a Pending applicant (no member access) sees the same', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) =>
            h.grants.myAccess = const AccessReadDenied(AccessDenial.notLinked),
      );
      expect(textOf(tester, 'home-greeting'), 'Welcome');
      expect(byKey('home-duties-card'), findsNothing);
      expect(byKey('coming-up-empty'), findsOneWidget);
      // Already signed in: not told to sign in.
      expect(byKey('home-guest-line'), findsNothing);
      expect(byKey('home-signed-in-line'), findsOneWidget);
    });

    testWidgets('a member whose access read failed is not shown a guest Home', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) {
          h.grants.myAccess = const AccessReadFailed(unreachable: true);
          h.duties.mine = const AccessReadFailed(unreachable: true);
        },
      );
      expect(byKey('home-guest-line'), findsNothing);
      expect(byKey('home-signed-in-line'), findsNothing);
      expect(textOf(tester, 'home-greeting'), isNot('Welcome'));
      expect(byKey('home-duties-card'), findsOneWidget);
      expect(byKey('home-duties-failed'), findsOneWidget);
    });

    testWidgets('a member keeps the cards, then Coming up', (tester) async {
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
          h.content.publicEvents = twoEvents();
        },
      );
      expect(textOf(tester, 'home-greeting'), contains('Member'));
      expect(byKey('home-guest-line'), findsNothing);
      expect(byKey('home-duties-card'), findsOneWidget);
      expect(byKey('coming-up-list'), findsOneWidget);
    });

    testWidgets('a failed calendar read on Home is not an empty calendar', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) =>
            h.content.publicEvents = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('coming-up-failed'), findsOneWidget);
      expect(byKey('coming-up-empty'), findsNothing);
    });
  });

  group('staff web Events', () {
    testWidgets('a plain member is told who manages events', (tester) async {
      await pumpAt(tester, ClientPaths.contentEvents, staff: true);
      expect(byKey('events-denied-notGranted'), findsOneWidget);
      expect(
        find.textContaining('Events are managed by Media, Pastors and Admins.'),
        findsOneWidget,
      );
      expect(byKey('events-new'), findsNothing);
    });

    testWidgets('a new event is saved as a draft, then the list reloads', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffEvents([]),
      );
      expect(textOf(tester, 'page-subtitle'), startsWith('No events yet.'));
      await tapKey(tester, 'events-new');
      for (final (key, value) in [
        ('event-title-new', 'SYNTHETIC Harvest Thanksgiving'),
        ('event-description-new', 'SYNTHETIC two days.'),
        ('event-start-date-new', '2099-10-10'),
        ('event-start-time-new', '09:00'),
        ('event-end-date-new', '2099-10-11'),
        ('event-end-time-new', '12:00'),
        ('event-location-new', 'SYNTHETIC Main sanctuary'),
      ]) {
        await tester.enterText(byKey(key), value);
      }
      await settle(tester);
      await tapKey(tester, 'event-save-new');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'content_command');
      expect(sent.wire['command'], 'content.create_event');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'title': 'SYNTHETIC Harvest Thanksgiving',
        'description': 'SYNTHETIC two days.',
        'starts_at': '2099-10-10T07:00:00.000Z',
        'ends_at': '2099-10-11T10:00:00.000Z',
        'location': 'SYNTHETIC Main sanctuary',
      });
      expect(byKey('events-pending'), findsOneWidget);
      h.content.staffEvents = staffEvents([
        staffEventData(draft: staffEventRevisionData()),
      ]);
      sent.confirm({
        'event_id': _harvest,
        'revision': 1,
        'state': 'draft',
        'live_revision_no': null,
        'draft_revision_no': 1,
      }, 1);
      await settle(tester);
      expect(byKey('events-notice-created'), findsOneWidget);
      expect(byKey('event-form-new'), findsNothing);
      expect(textOf(tester, 'page-subtitle'), contains('1 waiting to publish'));
      expect(
        tester.widget<StatusLabel>(byKey('event-mark-$_harvest')).label,
        'Draft',
      );
    });

    testWidgets('field errors are shown on the form; nothing was saved', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffEvents([]),
      );
      await tapKey(tester, 'events-new');
      for (final (key, value) in [
        ('event-title-new', 'SYNTHETIC Long retreat'),
        ('event-description-new', 'SYNTHETIC too long.'),
        ('event-start-date-new', '2099-10-01'),
        ('event-start-time-new', '09:00'),
        ('event-end-date-new', '2099-12-01'),
        ('event-end-time-new', '12:00'),
        ('event-location-new', 'SYNTHETIC Camp'),
      ]) {
        await tester.enterText(byKey(key), value);
      }
      await settle(tester);
      await tapKey(tester, 'event-save-new');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'ends_at': 'too_long'},
      );
      await settle(tester);
      expect(byKey('events-notice-invalid'), findsOneWidget);
      expect(find.text('An event can last at most 31 days'), findsOneWidget);
      expect(byKey('event-form-new'), findsOneWidget);
      expect(h.content.staffEventsCalls, 1, reason: 'the form stays as typed');
    });

    testWidgets('editing a published event saves a draft at its revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffEvents([publishedHarvest()]),
      );
      expect(
        tester.widget<StatusLabel>(byKey('event-mark-$_harvest')).label,
        'Published',
      );
      await tapKey(tester, 'event-open-$_harvest');
      expect(
        find.textContaining('Published by SYNTHETIC Media Phiri'),
        findsOne,
      );
      await tapKey(tester, 'event-edit-$_harvest');
      await tester.enterText(
        byKey('event-location-$_harvest'),
        'SYNTHETIC Church grounds',
      );
      await settle(tester);
      await tapKey(tester, 'event-save-$_harvest');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'content.save_event');
      expect(sent.wire['expected_revision'], 3);
      expect((sent.wire['payload'] as Map)['event_id'], _harvest);
      expect(
        (sent.wire['payload'] as Map)['location'],
        'SYNTHETIC Church grounds',
      );
      h.content.staffEvents = staffEvents([
        publishedHarvest(
          draft: staffEventRevisionData(
            revisionNo: 2,
            location: 'SYNTHETIC Church grounds',
          ),
        ),
      ]);
      sent.confirm({'event_id': _harvest, 'revision': 4}, 4);
      await settle(tester);
      expect(byKey('events-notice-saved'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('event-mark-$_harvest')).label,
        'Changes not published',
      );
      // The published version stays on the calendar until republished.
      expect(find.text('On the public calendar'), findsOneWidget);
      expect(find.text('SYNTHETIC Main sanctuary'), findsWidgets);
      expect(byKey('event-publish-$_harvest'), findsOneWidget);
      expect(find.text('Publish changes'), findsOneWidget);
    });

    testWidgets('publish and withdraw send their commands at the revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffEvents([
          staffEventData(draft: staffEventRevisionData()),
        ]),
      );
      await tapKey(tester, 'event-open-$_harvest');
      await tapKey(tester, 'event-publish-$_harvest');
      final publish = h.gateway.sent.single;
      expect(publish.wire['command'], 'content.publish_event');
      expect(publish.wire['expected_revision'], 1);
      expect(publish.wire['payload'], {'event_id': _harvest});
      h.content.staffEvents = staffEvents([publishedHarvest()]);
      publish.confirm({'event_id': _harvest, 'revision': 3}, 3);
      await settle(tester);
      expect(byKey('events-notice-published'), findsOneWidget);
      await tapKey(tester, 'event-withdraw-$_harvest');
      expect(find.text('Withdraw SYNTHETIC Harvest Thanksgiving?'), findsOne);
      await tapKey(tester, 'event-confirm-yes');
      final withdraw = h.gateway.sent.last;
      expect(withdraw.wire['command'], 'content.withdraw_event');
      expect(withdraw.wire['expected_revision'], 3);
      h.content.staffEvents = staffEvents([
        staffEventData(
          revision: 4,
          state: 'withdrawn',
          live: staffEventRevisionData(),
          withdrawnAt: '2099-09-02T08:00:00.000000Z',
        ),
      ]);
      withdraw.confirm({'event_id': _harvest, 'revision': 4}, 4);
      await settle(tester);
      expect(byKey('events-notice-withdrawn'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('event-mark-$_harvest')).label,
        'Withdrawn',
      );
      expect(find.text('Publish again'), findsOneWidget);
    });

    testWidgets('a stale tab reloads; an unknown outcome resends the same '
        'request', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffEvents([publishedHarvest()]),
      );
      await tapKey(tester, 'event-open-$_harvest');
      await tapKey(tester, 'event-archive-$_harvest');
      await tapKey(tester, 'event-confirm-yes');
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(byKey('events-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'events-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(
        h.gateway.sent.last.wire['request_id'],
        h.gateway.sent.first.wire['request_id'],
      );
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        currentRevision: const Optional.of(4),
      );
      await settle(tester);
      expect(byKey('events-notice-changedElsewhere'), findsOneWidget);
      expect(h.content.staffEventsCalls, 2);
    });
  });
}
