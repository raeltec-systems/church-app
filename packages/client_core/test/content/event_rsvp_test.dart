// Story 6.11: event posters, Add to calendar and RSVP within capacity. The
// wire parsing (poster, counts, the member's own RSVP, the organisers' names
// read), the iCalendar export (both endpoints of a multi-day event, the
// duty export unchanged), the mobile Calendar row and event detail (poster,
// places, every RSVP state, Add to calendar) and the staff Events editor
// (RSVP and poster fields, counts for every editor, names only for
// organisers and Admins, organisers, the file sync). Fakes only; the server
// behaviour is covered by supabase/tests/content_event_rsvp_test.sql and
// tools/identity-e2e/content-event-rsvp.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/src/domain/icalendar_text.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _camp = '73737373-7373-4373-8373-737373737373';
const _organiser = '81818181-8181-4181-8181-818181818181';
const _otherEditor = '82828282-8282-4282-8282-828282828282';

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
      overrides: [
        ...h.overrides(),
        dutyCalendarExportProvider.overrideWithValue(_calendar),
      ],
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

/// Records what Add to calendar handed to the phone.
class _FakeCalendar implements DutyCalendarExport {
  CalendarHandoff answer = CalendarHandoff.handedOver;
  final exported = <(String, String)>[];

  @override
  Future<CalendarHandoff> export({
    required String fileName,
    required String ics,
    ShareOrigin? origin,
  }) async {
    exported.add((fileName, ics));
    return answer;
  }
}

late _FakeCalendar _calendar;

/// A three-day SYNTHETIC youth camp (Fri 9 to Sun 11 Oct 2099, church time)
/// with a poster and two places.
Map<String, Object?> campData({
  Map<String, Object?>? rsvp,
  bool poster = true,
}) => publicEventData(
  eventId: _camp,
  title: 'SYNTHETIC Youth Camp',
  description: 'SYNTHETIC three days by the lake, with meals.',
  startsAt: '2099-10-09T07:00:00.000000Z',
  endsAt: '2099-10-11T15:00:00.000000Z',
  location: 'SYNTHETIC Camp grounds',
  publicationRevision: 3,
  poster: poster ? publicEventPosterData(eventId: _camp) : null,
  rsvp: rsvp ?? publicEventRsvpData(),
);

void seedCamp(ClientTestHarness h, {Map<String, Object?>? rsvp}) {
  final camp = campData(rsvp: rsvp);
  h.content.publicEvents = AccessReadOk(
    PublicEvents.fromJson(publicEventsData([camp])),
  );
  h.content.publicEvent[_camp] = AccessReadOk(
    PublicEventRead.fromJson({'event': camp}),
  );
}

Map<String, Object?> staffCamp({
  bool seesNames = false,
  int going = 1,
  bool poster = true,
  String? publicPoster = 'shown',
}) => staffEventData(
  eventId: _camp,
  revision: 4,
  state: 'published',
  live: staffEventRevisionData(
    title: 'SYNTHETIC Youth Camp',
    startsAt: '2099-10-09T07:00:00.000000Z',
    endsAt: '2099-10-11T15:00:00.000000Z',
    rsvpEnabled: true,
    rsvpCapacity: 2,
    poster: poster
        ? const {
            'asset_id': '61616161-6161-4161-8161-616161616161',
            'media_type': 'image/png',
            'byte_size': 204800,
            'width': 1920,
            'height': 1080,
          }
        : null,
    posterRights: poster
        ? const {
            'rights_id': '91919191-9191-4191-8191-919191919191',
            'label': 'SYNTHETIC images made for the church',
            'state': 'published',
            'live_revision_no': 1,
            'display': null,
          }
        : null,
    posterAltText: poster ? 'SYNTHETIC tents by a lake' : null,
  ),
  publishedBy: 'SYNTHETIC Media Phiri',
  publishedAt: '2099-09-01T08:00:00.000000Z',
  publicPoster: poster ? publicPoster : null,
  rsvpGoing: going,
  organisers: [eventOrganiserData(_organiser, 'SYNTHETIC Media Phiri')],
  seesNames: seesNames,
);

AccessRead<StaffEvents> staffList(List<Map<String, Object?>> events) =>
    AccessReadOk(
      StaffEvents.fromJson(
        staffEventsData(
          events,
          organiserOptions: [
            eventOrganiserData(_organiser, 'SYNTHETIC Media Phiri'),
            eventOrganiserData(_otherEditor, 'SYNTHETIC Pastor Banda'),
          ],
        ),
      ),
    );

void main() {
  setUp(() => _calendar = _FakeCalendar());

  group('wire parsing', () {
    test('a public event with its poster and RSVP counts', () {
      final e = PublicEvent.fromJson(campData());
      expect(e.poster!.image.path, 'event/$_camp/r1/poster.png');
      expect(e.poster!.altText, 'SYNTHETIC harvest baskets on the altar');
      expect(e.poster!.offlineAllowed, isFalse);
      expect(e.rsvp!.capacity, 2);
      expect(e.rsvp!.placesText, '2 of 2 places left');
      expect(
        PublicEventRsvp.fromJson(publicEventRsvpData(going: 2)).placesText,
        'Full (2 places)',
      );
      expect(
        PublicEventRsvp.fromJson(publicEventRsvpData(capacity: null, going: 12))
            .placesText,
        '12 going',
      );
      // An older server (and the offline snapshot) sends neither key.
      final plain = PublicEvent.fromJson(publicEventData());
      expect(plain.poster, isNull);
      expect(plain.rsvp, isNull);
    });

    test('a malformed poster or count is refused, never guessed', () {
      for (final bad in <Map<String, Object?>>[
        campData()
          ..['poster'] = {
            ...publicEventPosterData(),
            'path': '../drafts/x.png',
          },
        campData()..['poster'] = {...publicEventPosterData(), 'alt_text': ' '},
        campData()
          ..['rsvp'] = {...publicEventRsvpData(capacity: null), 'full': true},
        campData()
          ..['rsvp'] = {
            ...publicEventRsvpData(capacity: null),
            'spaces_left': 3,
          },
        campData()..['rsvp'] = {...publicEventRsvpData(), 'going': -1},
      ]) {
        expect(() => PublicEvent.fromJson(bad), throwsFormatException);
      }
    });

    test(
      'the editors read the poster, RSVP, organisers and who sees names',
      () {
        final v = StaffEvents.fromJson(
          staffEventsData(
            [staffCamp(seesNames: true)],
            organiserOptions: [eventOrganiserData(_otherEditor, 'SYNTHETIC P')],
          ),
        );
        final e = v.events.single;
        expect(e.publicPoster, EventPosterState.shown);
        expect(e.rsvpGoing, 1);
        expect(e.organisers.single.name, 'SYNTHETIC Media Phiri');
        expect(e.seesNames, isTrue);
        expect(e.live!.rsvpEnabled, isTrue);
        expect(e.live!.rsvpCapacity, 2);
        expect(e.live!.poster!.width, 1920);
        expect(e.live!.posterRights!.display, isNull);
        expect(v.organiserOptions.single.memberId, _otherEditor);
        // An older server's answer still reads (no poster, RSVP off).
        final old = StaffEvents.fromJson(
          staffEventsData([staffEventData(draft: staffEventRevisionData())]),
        ).events.single;
        expect(old.seesNames, isFalse);
        expect(old.organisers, isEmpty);
        expect(old.draft!.rsvpEnabled, isFalse);
        expect(
          () => StaffEvent.fromJson({...staffCamp(), 'public_poster': 'lost'}),
          throwsFormatException,
        );
        expect(
          () => StaffEventRevision.fromJson(
            staffEventRevisionData(rsvpCapacity: 3),
          ),
          throwsFormatException,
          reason: 'places without RSVP on',
        );
      },
    );

    test('the member\'s own RSVP and the organisers\' names read', () {
      expect(
        MyEventRsvp.fromJson(myEventRsvpData(eventId: _camp)).state,
        isNull,
      );
      expect(
        MyEventRsvp.fromJson(myEventRsvpData(eventId: _camp, state: 'going'))
            .going,
        isTrue,
      );
      expect(
        () => MyEventRsvp.fromJson({
          'event_id': _camp,
          'rsvp_state': 'going',
          'updated_at': null,
        }),
        throwsFormatException,
      );
      final names = StaffEventRsvpsRead.fromJson(
        staffEventRsvpsData(['SYNTHETIC Member A', 'SYNTHETIC Member B']),
      ).rsvps!;
      expect(names.going, 2);
      expect(names.attendees.first.name, 'SYNTHETIC Member A');
      expect(StaffEventRsvpsRead.fromJson({'rsvps': null}).rsvps, isNull);
      expect(
        () => StaffEventRsvpsRead.fromJson({
          'rsvps': {
            ...(staffEventRsvpsData(['A'])['rsvps'] as Map),
            'going': 0,
          },
        }),
        throwsFormatException,
      );
    });

    test('a save sends RSVP and the poster; a create never sends a poster', () {
      final input = EventInput(
        title: ' SYNTHETIC Youth Camp ',
        description: 'SYNTHETIC lake.',
        startsAt: DateTime.utc(2099, 10, 9, 7),
        endsAt: DateTime.utc(2099, 10, 11, 15),
        location: 'SYNTHETIC Camp',
        rsvpEnabled: true,
        rsvpCapacity: 40,
        posterAssetId: 'asset-1',
        posterRightsId: 'rights-1',
        posterAltText: ' SYNTHETIC tents ',
      );
      expect(input.toPayload(eventId: _camp), {
        'event_id': _camp,
        'title': 'SYNTHETIC Youth Camp',
        'description': 'SYNTHETIC lake.',
        'starts_at': '2099-10-09T07:00:00.000Z',
        'ends_at': '2099-10-11T15:00:00.000Z',
        'location': 'SYNTHETIC Camp',
        'rsvp_enabled': true,
        'rsvp_capacity': 40,
        'poster_asset_id': 'asset-1',
        'poster_rights_id': 'rights-1',
        'poster_alt_text': 'SYNTHETIC tents',
      });
      expect(input.toPayload().containsKey('poster_asset_id'), isFalse);
      // RSVP off and no poster: absent keys, which the server reads as off
      // and none.
      final plain = EventInput(
        title: 'SYNTHETIC Choir',
        description: 'SYNTHETIC.',
        startsAt: DateTime.utc(2099, 10, 9, 7),
        endsAt: DateTime.utc(2099, 10, 9, 9),
        location: 'SYNTHETIC Hall',
      );
      expect(plain.toPayload(eventId: _camp).keys, {
        'event_id',
        'title',
        'description',
        'starts_at',
        'ends_at',
        'location',
      });
    });
  });

  group('Add to calendar (iCalendar)', () {
    test('a three-day event keeps both endpoints, with the copy caveat', () {
      final e = PublicEvent.fromJson(campData());
      final ics = EventCalendar.ics(e, now: DateTime.utc(2099, 9, 2, 6));
      expect(ics, startsWith('BEGIN:VCALENDAR\r\nVERSION:2.0\r\n'));
      expect(ics, endsWith('END:VEVENT\r\nEND:VCALENDAR\r\n'));
      expect(ics, contains('PRODID:-//BICC Kafue//Events//EN\r\n'));
      expect(ics, contains('UID:event-$_camp@bickafue.app\r\n'));
      expect(ics, contains('SEQUENCE:3\r\n'));
      expect(ics, contains('DTSTAMP:20990902T060000Z\r\n'));
      expect(ics, contains('DTSTART:20991009T070000Z\r\n'));
      expect(ics, contains('DTEND:20991011T150000Z\r\n'));
      expect(ics, contains('SUMMARY:SYNTHETIC Youth Camp\r\n'));
      expect(ics, contains('LOCATION:SYNTHETIC Camp grounds\r\n'));
      final unfolded = ics.replaceAll('\r\n ', '');
      expect(unfolded, contains(r'with meals.\n\nThis entry is a copy'));
      expect(unfolded, contains('Open BICC Kafue\\, Calendar\\, for the'));
      for (final line in ics.split('\r\n')) {
        expect(line.length, lessThanOrEqualTo(75));
      }
      expect(EventCalendar.fileName(e), 'event-2099-10-09.ics');
    });

    test('the file name is the church date of the start', () {
      final late = PublicEvent.fromJson(
        publicEventData(
          startsAt: '2099-10-09T22:30:00.000000Z',
          endsAt: '2099-10-10T01:00:00.000000Z',
        ),
      );
      expect(EventCalendar.fileName(late), 'event-2099-10-10.ics');
    });

    test('text escaping and folding follow the 4.5 rules', () {
      expect(ICalendarText.text('a,b;c\\d\ne'), r'a\,b\;c\\d\ne');
      final folded = ICalendarText.fold('X' * 80);
      expect(folded.split('\r\n ').first.length, 75);
      expect(ICalendarText.document(['A', 'B']), 'A\r\nB\r\n');
    });
  });

  group('mobile Calendar and event detail', () {
    testWidgets('a poster is a 16:9 thumbnail in the list', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.calendar,
        account: null,
        setUp: (h) => h.content.publicEvents = AccessReadOk(
          PublicEvents.fromJson(
            publicEventsData([campData(), publicEventData()]),
          ),
        ),
      );
      final thumb = tester.getSize(byKey('event-thumb-$_camp'));
      expect(thumb.width / thumb.height, closeTo(16 / 9, 0.01));
      // An event without a poster keeps its chevron.
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets(
      'a guest reads the poster, the places and is asked to sign in',
      (tester) async {
        final h = await pumpAt(
          tester,
          CalendarPaths.event(_camp),
          account: null,
          setUp: (h) => seedCamp(h, rsvp: publicEventRsvpData(going: 1)),
        );
        final poster = tester.widget<Image>(byKey('event-poster'));
        expect(poster.semanticLabel, 'SYNTHETIC harvest baskets on the altar');
        expect(find.text('1 of 2 places left'), findsOneWidget);
        expect(byKey('event-rsvp-going-button'), findsNothing);
        expect(h.content.myRsvpAsked, isEmpty, reason: 'a guest has none');
        await tapKey(tester, 'event-rsvp-sign-in');
        expect(find.byType(SignInScreen), findsOneWidget);
      },
    );

    testWidgets('a signed-in account without member access is told plainly', (
      tester,
    ) async {
      await pumpAt(
        tester,
        CalendarPaths.event(_camp),
        setUp: (h) {
          seedCamp(h);
          h.grants.myAccess = const AccessReadDenied(AccessDenial.notLinked);
        },
      );
      expect(byKey('event-rsvp-members-only'), findsOneWidget);
      expect(byKey('event-rsvp-sign-in'), findsNothing);
      expect(byKey('event-rsvp-going-button'), findsNothing);
    });

    testWidgets(
      'a member says they are going, then the counts are read again',
      (tester) async {
        final h = await pumpAt(
          tester,
          CalendarPaths.event(_camp),
          setUp: (h) {
            seedCamp(h);
            h.grants.myAccess = AccessReadOk(syntheticGrants());
          },
        );
        final eventReads = h.content.publicEventAsked.length;
        await tapKey(tester, 'event-rsvp-going-button');
        final sent = h.gateway.sent.single;
        expect(sent.request.command, ContentCommands.rsvpEvent);
        expect(sent.wire['expected_revision'], isNull);
        expect(sent.wire['payload'], {'event_id': _camp});
        h.content.myRsvp[_camp] = AccessReadOk(
          MyEventRsvp.fromJson(myEventRsvpData(eventId: _camp, state: 'going')),
        );
        sent.confirm({'rsvp_state': 'going'}, 1);
        await settle(tester);
        expect(byKey('event-rsvp-notice-going'), findsOneWidget);
        expect(byKey('event-rsvp-going'), findsOneWidget);
        expect(h.content.publicEventAsked.length, greaterThan(eventReads));
      },
    );

    testWidgets('a going member cancels after confirming', (tester) async {
      final h = await pumpAt(
        tester,
        CalendarPaths.event(_camp),
        setUp: (h) {
          seedCamp(h, rsvp: publicEventRsvpData(going: 2));
          h.grants.myAccess = AccessReadOk(syntheticGrants());
          h.content.myRsvp[_camp] = AccessReadOk(
            MyEventRsvp.fromJson(
              myEventRsvpData(eventId: _camp, state: 'going'),
            ),
          );
        },
      );
      expect(
        tester.widget<StatusLabel>(byKey('event-rsvp-going')).label,
        'You\'re going',
      );
      await tapKey(tester, 'event-rsvp-cancel');
      await tapKey(tester, 'event-rsvp-keep');
      expect(h.gateway.sent, isEmpty, reason: 'kept the place');
      await tapKey(tester, 'event-rsvp-cancel');
      await tapKey(tester, 'event-rsvp-cancel-confirm');
      expect(h.gateway.sent.single.request.command, ContentCommands.cancelRsvp);
      h.content.myRsvp[_camp] = AccessReadOk(
        MyEventRsvp.fromJson(
          myEventRsvpData(eventId: _camp, state: 'cancelled'),
        ),
      );
      h.gateway.sent.single.confirm({'rsvp_state': 'cancelled'}, 2);
      await settle(tester);
      expect(byKey('event-rsvp-notice-cancelled'), findsOneWidget);
    });

    testWidgets('full and closed events offer no answer', (tester) async {
      await pumpAt(
        tester,
        CalendarPaths.event(_camp),
        setUp: (h) {
          seedCamp(h, rsvp: publicEventRsvpData(going: 2));
          h.grants.myAccess = AccessReadOk(syntheticGrants());
        },
      );
      expect(byKey('event-rsvp-full'), findsOneWidget);
      expect(find.text('Full (2 places)'), findsOneWidget);
      expect(byKey('event-rsvp-going-button'), findsNothing);
    });

    testWidgets('an event that has started says RSVP is closed', (
      tester,
    ) async {
      await pumpAt(
        tester,
        CalendarPaths.event(_camp),
        setUp: (h) {
          seedCamp(h, rsvp: publicEventRsvpData(open: false));
          h.grants.myAccess = AccessReadOk(syntheticGrants());
        },
      );
      expect(byKey('event-rsvp-closed'), findsOneWidget);
      expect(byKey('event-rsvp-going-button'), findsNothing);
    });

    testWidgets('a refusal says why; an unknown outcome is checked again', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        CalendarPaths.event(_camp),
        setUp: (h) {
          seedCamp(h);
          h.grants.myAccess = AccessReadOk(syntheticGrants());
        },
      );
      await tapKey(tester, 'event-rsvp-going-button');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'event_id': 'full'},
      );
      await settle(tester);
      expect(byKey('event-rsvp-notice-full'), findsOneWidget);
      await tapKey(tester, 'event-rsvp-going-button');
      h.gateway.sent.last.unknown();
      await settle(tester);
      expect(byKey('event-rsvp-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'event-rsvp-check-again');
      expect(h.gateway.sent, hasLength(3));
      expect(
        h.gateway.sent.last.wire['request_id'],
        h.gateway.sent[1].wire['request_id'],
        reason: 'the same answer is sent again',
      );
    });

    testWidgets('Add to calendar hands over the event with the caveat', (
      tester,
    ) async {
      await pumpAt(
        tester,
        CalendarPaths.event(_camp),
        account: null,
        setUp: (h) => seedCamp(h),
      );
      expect(find.text(EventCalendar.staleCaveat), findsOneWidget);
      await tapKey(tester, 'event-calendar');
      final (name, ics) = _calendar.exported.single;
      expect(name, 'event-2099-10-09.ics');
      expect(ics, contains('DTEND:20991011T150000Z'));
      expect(
        textOf(tester, 'event-calendar-result'),
        startsWith('Calendar file handed to your phone.'),
      );
    });
  });

  group('staff web Events', () {
    testWidgets('every editor reads the counts; names stay with organisers', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffList([staffCamp()]),
      );
      await tapKey(tester, 'event-open-$_camp');
      expect(
        textOf(tester, 'event-going-$_camp'),
        '1 going · 1 of 2 places left',
      );
      expect(
        textOf(tester, 'event-organisers-$_camp'),
        'Organisers: SYNTHETIC Media Phiri',
      );
      expect(byKey('event-names-hidden-$_camp'), findsOneWidget);
      expect(byKey('event-who-$_camp'), findsNothing);
      expect(byKey('event-organisers-change-$_camp'), findsNothing);
      expect(h.content.staffRsvpsAsked, isEmpty);
      expect(find.text('On · 2 places'), findsOneWidget);
      expect(find.text('Added · SYNTHETIC tents by a lake'), findsOneWidget);
    });

    testWidgets('an organiser reads who is coming', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) {
          h.content.staffEvents = staffList([staffCamp(seesNames: true)]);
          h.content.staffRsvps[_camp] = AccessReadOk(
            StaffEventRsvpsRead.fromJson(
              staffEventRsvpsData(['SYNTHETIC Member A'], eventId: _camp),
            ),
          );
        },
      );
      await tapKey(tester, 'event-open-$_camp');
      await tapKey(tester, 'event-who-$_camp');
      expect(h.content.staffRsvpsAsked, [_camp]);
      expect(byKey('event-names-$_camp'), findsOneWidget);
      expect(find.text('SYNTHETIC Member A'), findsOneWidget);
    });

    testWidgets('an organiser changes the organisers', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) =>
            h.content.staffEvents = staffList([staffCamp(seesNames: true)]),
      );
      await tapKey(tester, 'event-open-$_camp');
      await tapKey(tester, 'event-organisers-change-$_camp');
      await tapKey(tester, 'organiser-option-$_otherEditor');
      await tapKey(tester, 'organisers-save');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, ContentCommands.setEventOrganisers);
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'event_id': _camp,
        'organiser_ids': [_organiser, _otherEditor],
      });
      sent.confirm({'event_id': _camp}, 5);
      await settle(tester);
      expect(byKey('events-notice-organisersSet'), findsOneWidget);
    });

    testWidgets('an organiser who no longer edits events is never sent again', (
      tester,
    ) async {
      const stale = '83838383-8383-4383-8383-838383838383';
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffList([
          {
            ...staffCamp(seesNames: true),
            'organisers': [
              eventOrganiserData(_organiser, 'SYNTHETIC Media Phiri'),
              eventOrganiserData(stale, 'SYNTHETIC Former Media'),
            ],
          },
        ]),
      );
      await tapKey(tester, 'event-open-$_camp');
      await tapKey(tester, 'event-organisers-change-$_camp');
      final row = tester.widget<CheckboxListTile>(
        byKey('organiser-stale-$stale'),
      );
      expect(row.value, isFalse);
      expect(row.onChanged, isNull);
      await tapKey(tester, 'organisers-save');
      final sent = h.gateway.sent.single;
      expect(sent.wire['payload'], {
        'event_id': _camp,
        'organiser_ids': [_organiser],
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'organiser_ids': 'not_editor'},
      );
      await settle(tester);
      expect(byKey('events-notice-organisersInvalid'), findsOneWidget);
    });

    testWidgets('a poster waiting for the sync says so; opening Events syncs', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffList([
          staffCamp(publicPoster: 'waiting'),
        ]),
      );
      expect(h.banners.syncCalls, 1);
      await tapKey(tester, 'event-open-$_camp');
      expect(byKey('event-poster-note-$_camp'), findsOneWidget);
    });

    testWidgets('publishing places the poster through the file sync', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffList([
          staffEventData(
            eventId: _camp,
            revision: 2,
            draft: staffEventRevisionData(title: 'SYNTHETIC Youth Camp'),
          ),
        ]),
      );
      final before = h.banners.syncCalls;
      await tapKey(tester, 'event-open-$_camp');
      await tapKey(tester, 'event-publish-$_camp');
      h.gateway.sent.single.confirm({'event_id': _camp}, 3);
      await settle(tester);
      expect(h.banners.syncCalls, before + 1);
    });

    testWidgets('the form saves RSVP, places and an uploaded poster', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) {
          h.content.staffEvents = staffList([
            staffEventData(
              eventId: _camp,
              revision: 2,
              draft: staffEventRevisionData(title: 'SYNTHETIC Youth Camp'),
            ),
          ]);
          h.banners.staffRights = AccessReadOk(
            StaffRights.fromJson(
              staffRightsData([
                rightsRecordData(
                  state: 'published',
                  revision: 2,
                  live: rightsRevisionData(),
                  verifiedBy: 'SYNTHETIC Pastor Banda',
                  verifiedAt: '2099-09-01T09:00:00.000000Z',
                ),
              ]),
            ),
          );
          h.filePicker.next = PickedFile(
            name: 'camp.png',
            declaredType: 'image/png',
            bytes: tinyPng,
          );
        },
      );
      await tapKey(tester, 'event-open-$_camp');
      await tapKey(tester, 'event-edit-$_camp');
      await tapKey(tester, 'event-rsvp-$_camp');
      await tester.enterText(byKey('event-places-$_camp'), '40');
      await settle(tester);
      await tapKey(tester, 'event-choose-poster-$_camp');
      expect(h.banners.uploads.single.$1, _camp);
      expect(h.banners.uploads.single.$2, ContentPurposes.eventPoster);
      await tester.tap(byKey('event-poster-rights-$_camp'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Q5 approval is not required').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        byKey('event-poster-alt-$_camp'),
        'SYNTHETIC tents by a lake',
      );
      await settle(tester);
      await tapKey(tester, 'event-save-$_camp');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload['rsvp_enabled'], true);
      expect(payload['rsvp_capacity'], 40);
      expect(
        payload['poster_asset_id'],
        '61616161-6161-4161-8161-616161616161',
      );
      expect(
        payload['poster_rights_id'],
        '91919191-9191-4191-8191-919191919191',
      );
      expect(payload['poster_alt_text'], 'SYNTHETIC tents by a lake');
    });

    testWidgets('removing the poster saves the draft without it', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) =>
            h.content.staffEvents = staffList([staffCamp(seesNames: true)]),
      );
      await tapKey(tester, 'event-open-$_camp');
      await tapKey(tester, 'event-edit-$_camp');
      expect(byKey('event-poster-rights-$_camp'), findsOneWidget);
      await tapKey(tester, 'event-remove-poster-$_camp');
      expect(byKey('event-poster-rights-$_camp'), findsNothing);
      await tapKey(tester, 'event-save-$_camp');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload.containsKey('poster_asset_id'), isFalse);
      expect(payload['rsvp_enabled'], true);
      expect(payload['rsvp_capacity'], 2);
    });

    testWidgets('a refused poster field is shown on the form', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        staff: true,
        setUp: (h) => h.content.staffEvents = staffList([staffCamp()]),
      );
      await tapKey(tester, 'event-open-$_camp');
      await tapKey(tester, 'event-edit-$_camp');
      await tapKey(tester, 'event-save-$_camp');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'poster_rights_id': 'not_in_force'},
      );
      await settle(tester);
      expect(find.text('Verify this rights record first'), findsOneWidget);
      expect(byKey('events-notice-invalid'), findsOneWidget);
    });
  });
}
