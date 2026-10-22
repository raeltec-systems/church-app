// Story 6.13: pinned announcements with an optional generic notice. The wire
// parsing (public projection, the editors' read with the notice record and
// the audience), the public list (pinned first) and one announcement (a
// withdrawn one says so), Home's Announcements section for a guest, the inbox
// deep link, and the staff Announcements editor's commands (create, save,
// publish with or without a notice, withdraw) with honest request states and
// the notice refusals. Fakes only; the server behaviour is covered by
// supabase/tests/content_announcements_test.sql and
// tools/identity-e2e/content-announcements.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _offering = '73737373-7373-4373-8373-737373737373';
const _choir = '74747474-7474-4474-8474-747474747474';
const _parking = '75757575-7575-4575-8575-757575757575';

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

/// A pinned offering notice, an unpinned choir notice and an unpinned
/// parking notice, in the server's order (pinned first, then newest).
AccessRead<PublicAnnouncements> threeAnnouncements() => AccessReadOk(
  PublicAnnouncements.fromJson(
    publicAnnouncementsData([
      publicAnnouncementData(),
      publicAnnouncementData(
        announcementId: _choir,
        title: 'SYNTHETIC Choir practice moves to Thursday',
        body: 'SYNTHETIC Practice is on Thursday this week.\nSame time.',
        pinned: false,
        publishedAt: '2099-09-03T08:00:00.000000Z',
      ),
      publicAnnouncementData(
        announcementId: _parking,
        title: 'SYNTHETIC Parking at the hall',
        body: 'SYNTHETIC Use the back gate.',
        pinned: false,
        publishedAt: '2099-09-02T08:00:00.000000Z',
      ),
    ]),
  ),
);

AccessRead<StaffAnnouncements> staffAnnouncements(
  List<Map<String, Object?>> items, {
  int audienceMembers = 12,
  int audienceLimit = 1000,
}) => AccessReadOk(
  StaffAnnouncements.fromJson(
    staffAnnouncementsData(
      items,
      audienceMembers: audienceMembers,
      audienceLimit: audienceLimit,
    ),
  ),
);

Map<String, Object?> publishedOffering({
  Map<String, Object?>? live,
  Map<String, Object?>? draft,
}) => staffAnnouncementData(
  revision: 3,
  state: 'published',
  live: live ?? staffAnnouncementRevisionData(),
  draft: draft,
  publishedBy: 'SYNTHETIC Media Phiri',
  publishedAt: '2099-09-01T08:00:00.000000Z',
);

Map<String, Object?> notifiedRevision({int revisionNo = 1}) =>
    staffAnnouncementRevisionData(
      revisionNo: revisionNo,
      notifiedAt: '2099-09-01T08:00:00.000000Z',
      notifiedBy: 'SYNTHETIC Media Phiri',
      notifiedCount: 12,
    );

void main() {
  group('wire parsing', () {
    test('the public projection, pinned first', () {
      final list =
          (threeAnnouncements() as AccessReadOk<PublicAnnouncements>).value;
      expect(list.announcements, hasLength(3));
      expect(list.pinned.single.announcementId, _offering);
      expect(list.others.map((a) => a.announcementId), [_choir, _parking]);
      final a = list.announcements.first;
      expect(a.title, 'SYNTHETIC Harvest offering on Sunday');
      expect(a.pinned, isTrue);
      expect(a.publicationRevision, 1);
      expect(churchLongWhen(a.publishedAt), 'Tuesday 1 September 2099, 10:00');
      // A key a later entry adds is ignored (an older app keeps reading).
      expect(
        PublicAnnouncement.fromJson({
          ...publicAnnouncementData(),
          'poster': null,
        }).announcementId,
        _offering,
      );
      expect(
        announcementExcerpt('SYNTHETIC one\n\n  two\tthree '),
        'SYNTHETIC one two three',
      );
    });

    test('a malformed public answer is refused, never guessed', () {
      for (final bad in <Object?>[
        null,
        {'announcements': 'x', 'truncated': false},
        {'announcements': const <Object?>[]},
        publicAnnouncementsData([
          {...publicAnnouncementData(), 'title': '  '},
        ]),
        publicAnnouncementsData([
          {...publicAnnouncementData(), 'body': ''},
        ]),
        publicAnnouncementsData([
          {...publicAnnouncementData(), 'pinned': 'yes'},
        ]),
        publicAnnouncementsData([
          {...publicAnnouncementData(), 'publication_revision': 0},
        ]),
        publicAnnouncementsData([
          publicAnnouncementData(publishedAt: '2099-09-01T10:00:00'),
        ]),
      ]) {
        expect(
          () => PublicAnnouncements.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
      expect(
        PublicAnnouncementRead.fromJson({'announcement': null}).announcement,
        isNull,
      );
      expect(() => PublicAnnouncementRead.fromJson({}), throwsFormatException);
    });

    test('the editors\' read: states, notices, audience', () {
      final staff = StaffAnnouncements.fromJson(
        staffAnnouncementsData(
          [
            staffAnnouncementData(draft: staffAnnouncementRevisionData()),
            publishedOffering(
              live: notifiedRevision(),
              draft: staffAnnouncementRevisionData(
                revisionNo: 2,
                pinned: false,
              ),
            ),
            staffAnnouncementData(
              announcementId: _choir,
              revision: 5,
              state: 'withdrawn',
              live: notifiedRevision(),
              withdrawnAt: '2099-09-02T08:00:00.000000Z',
            ),
          ],
          capacity: 'pastor',
          audienceMembers: 1200,
        ),
      );
      expect(staff.capacity, 'pastor');
      expect(staff.audienceMembers, 1200);
      expect(staff.audienceLimit, 1000);
      expect(staff.audienceTooLarge, isTrue);
      final [draft, changed, withdrawn] = staff.announcements;
      expect(draft.state, ContentState.draft);
      expect(draft.canPublish, isTrue);
      expect(draft.canWithdraw, isFalse);
      expect(draft.publishTarget?.revisionNo, 1);
      expect(draft.notifyDone, isFalse);
      expect(changed.hasChanges, isTrue);
      expect(changed.pinnedLive, isTrue);
      expect(changed.current.pinned, isFalse);
      expect(changed.live!.notified, isTrue);
      expect(changed.live!.notifiedCount, 12);
      // The draft (revision 2) was never notified: a notice is possible.
      expect(changed.publishTarget?.revisionNo, 2);
      expect(changed.notifyDone, isFalse);
      // Publishing a withdrawn announcement again brings back its notified
      // live revision: no second notice.
      expect(withdrawn.publishTarget?.revisionNo, 1);
      expect(withdrawn.notifyDone, isTrue);
      for (final bad in <Map<String, Object?>>[
        staffAnnouncementData(),
        staffAnnouncementData(
          state: 'published',
          draft: staffAnnouncementRevisionData(),
        ),
        staffAnnouncementData(
          state: 'hidden',
          draft: staffAnnouncementRevisionData(),
        ),
        // A notice record without its count.
        staffAnnouncementData(
          draft: {
            ...staffAnnouncementRevisionData(),
            'notified_at': '2099-09-01T08:00:00.000000Z',
            'notified_by': 'SYNTHETIC Media Phiri',
          },
        ),
      ]) {
        expect(
          () => StaffAnnouncements.fromJson(staffAnnouncementsData([bad])),
          throwsFormatException,
          reason: '$bad',
        );
      }
      expect(
        () => StaffAnnouncements.fromJson(
          staffAnnouncementsData([], capacity: 'member'),
        ),
        throwsFormatException,
      );
      expect(
        () => StaffAnnouncements.fromJson({
          ...staffAnnouncementsData([]),
          'audience': null,
        }),
        throwsFormatException,
      );
    });

    test('an input sends every field, trimmed', () {
      const input = AnnouncementInput(
        title: ' SYNTHETIC Harvest offering on Sunday ',
        body: 'SYNTHETIC Bring it.\n',
        pinned: true,
      );
      expect(input.toPayload(announcementId: _offering), {
        'announcement_id': _offering,
        'title': 'SYNTHETIC Harvest offering on Sunday',
        'body': 'SYNTHETIC Bring it.',
        'pinned': true,
      });
      expect(input.toPayload().containsKey('announcement_id'), isFalse);
    });

    test('the inbox notice opens the announcement (a known deep link)', () {
      expect(ClientPaths.isKnownDeepLink('/announcements/$_offering'), isTrue);
      expect(ClientPaths.isKnownDeepLink('/announcements'), isFalse);
      expect(ClientPaths.isKnownDeepLink('/announcements/x'), isFalse);
      expect(ClientPaths.announcement(_offering), '/announcements/$_offering');
    });
  });

  group('the public announcements (signed out)', () {
    testWidgets('pinned first, then the latest, each with when and text', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.announcements,
        account: null,
        setUp: (h) =>
            h.announcements.publicAnnouncements = threeAnnouncements(),
      );
      expect(h.announcements.publicAnnouncementsCalls, 1);
      expect(find.text('Announcements'), findsOneWidget);
      expect(byKey('announcements-pinned-header'), findsOneWidget);
      expect(byKey('announcements-latest-header'), findsOneWidget);
      final pinnedY = tester
          .getTopLeft(byKey('announcement-row-$_offering'))
          .dy;
      final choirY = tester.getTopLeft(byKey('announcement-row-$_choir')).dy;
      final parkingY = tester
          .getTopLeft(byKey('announcement-row-$_parking'))
          .dy;
      expect(pinnedY < choirY && choirY < parkingY, isTrue);
      expect(
        find.descendant(
          of: byKey('announcements-pinned'),
          matching: byKey('announcement-row-$_offering'),
        ),
        findsOneWidget,
      );
      expect(
        textOf(tester, 'announcement-line-$_choir'),
        'Thu 3 Sep 10:00 · SYNTHETIC Practice is on Thursday this week. '
        'Same time.',
      );
      // No editor or private field reaches the public screens.
      expect(find.textContaining('Phiri'), findsNothing);
    });

    testWidgets('a row opens the announcement with its text', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.announcements,
        account: null,
        setUp: (h) {
          h.announcements.publicAnnouncements = threeAnnouncements();
          h.announcements.publicAnnouncement[_offering] = AccessReadOk(
            PublicAnnouncementRead.fromJson({
              'announcement': publicAnnouncementData(),
            }),
          );
        },
      );
      await tapKey(tester, 'announcement-row-$_offering');
      expect(h.announcements.publicAnnouncementAsked, [_offering]);
      expect(
        textOf(tester, 'announcement-title'),
        'SYNTHETIC Harvest offering on Sunday',
      );
      expect(
        textOf(tester, 'announcement-posted'),
        'Posted Tuesday 1 September 2099, 10:00',
      );
      expect(
        textOf(tester, 'announcement-body'),
        'SYNTHETIC Bring your harvest offering to the 09:00 service.',
      );
      expect(find.byType(BackButton), findsOneWidget);
    });

    testWidgets('a withdrawn announcement says so instead of an old copy', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.announcement(_offering),
        account: null,
        setUp: (h) =>
            h.announcements.publicAnnouncement[_offering] = AccessReadOk(
              PublicAnnouncementRead.fromJson({
                'announcement': publicAnnouncementData(),
              }),
            ),
      );
      expect(byKey('announcement-title'), findsOneWidget);
      h.announcements.publicAnnouncement.remove(_offering);
      await tapKey(tester, 'announcement-reload');
      expect(byKey('announcement-gone'), findsOneWidget);
      expect(
        find.text('This announcement is no longer published.'),
        findsOneWidget,
      );
      expect(byKey('announcement-title'), findsNothing);
      await tapKey(tester, 'announcement-gone-list');
      expect(byKey('announcements-empty'), findsOneWidget);
    });

    testWidgets('empty and failed reads differ', (tester) async {
      await pumpAt(tester, ClientPaths.announcements, account: null);
      expect(byKey('announcements-empty'), findsOneWidget);
      expect(byKey('announcements-failed'), findsNothing);
    });

    testWidgets('no connection is not "no announcements"', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.announcements,
        account: null,
        setUp: (h) => h.announcements.publicAnnouncements =
            const AccessReadFailed(unreachable: true),
      );
      expect(byKey('announcements-failed'), findsOneWidget);
      expect(byKey('announcements-empty'), findsNothing);
    });

    testWidgets('a failed refresh keeps the list and says from when', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.announcements,
        account: null,
        setUp: (h) =>
            h.announcements.publicAnnouncements = threeAnnouncements(),
      );
      h.announcements.publicAnnouncements = const AccessReadFailed(
        unreachable: true,
      );
      await tapKey(tester, 'announcements-reload');
      expect(byKey('announcements-stale'), findsOneWidget);
      expect(byKey('announcement-row-$_offering'), findsOneWidget);
      expect(h.announcements.publicAnnouncementsCalls, 2);
    });

    testWidgets('a row is spoken with its title, pin and date', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAt(
        tester,
        ClientPaths.announcements,
        account: null,
        setUp: (h) =>
            h.announcements.publicAnnouncements = threeAnnouncements(),
      );
      expect(
        find.bySemanticsLabel(
          'SYNTHETIC Harvest offering on Sunday, pinned, posted '
          'Tue 1 Sep 10:00',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('Home', () {
    testWidgets('a guest sees the pinned announcements and See all', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) =>
            h.announcements.publicAnnouncements = threeAnnouncements(),
      );
      expect(byKey('home-announcements-list'), findsOneWidget);
      expect(byKey('announcement-row-$_offering'), findsOneWidget);
      // Only the pinned ones are on Home.
      expect(byKey('announcement-row-$_choir'), findsNothing);
      // Announcements come before Coming up.
      expect(
        tester.getTopLeft(byKey('home-announcements')).dy <
            tester.getTopLeft(byKey('coming-up')).dy,
        isTrue,
      );
      await tapKey(tester, 'home-announcements-all');
      expect(byKey('announcement-row-$_choir'), findsOneWidget);
    });

    testWidgets('at most three pinned on Home', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.announcements.publicAnnouncements = AccessReadOk(
          PublicAnnouncements.fromJson(
            publicAnnouncementsData([
              for (var i = 0; i < 5; i++)
                publicAnnouncementData(
                  announcementId: '7676767$i-7676-4676-8676-767676767676',
                  title: 'SYNTHETIC Pinned $i',
                ),
            ]),
          ),
        ),
      );
      expect(
        find.descendant(
          of: byKey('home-announcements-list'),
          matching: find.byType(AnnouncementRow),
        ),
        findsNWidgets(3),
      );
    });

    testWidgets('none pinned, none at all and a failure are told apart', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.announcements.publicAnnouncements = AccessReadOk(
          PublicAnnouncements.fromJson(
            publicAnnouncementsData([publicAnnouncementData(pinned: false)]),
          ),
        ),
      );
      expect(byKey('home-announcements-no-pinned'), findsOneWidget);
      h.announcements.publicAnnouncements = AccessReadOk(
        PublicAnnouncements.fromJson(publicAnnouncementsData(const [])),
      );
      await tapKey(tester, 'home-announcements-all');
      await tester.pageBack();
      await settle(tester);
      expect(byKey('home-announcements-none'), findsOneWidget);
    });

    testWidgets('a failed read on Home is not "no announcements"', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.announcements.publicAnnouncements =
            const AccessReadFailed(unreachable: true),
      );
      expect(byKey('home-announcements-failed'), findsOneWidget);
      expect(byKey('home-announcements-none'), findsNothing);
    });
  });

  group('staff web Announcements', () {
    testWidgets('a plain member is told who manages announcements', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.contentAnnouncements, staff: true);
      expect(byKey('announcements-denied-notGranted'), findsOneWidget);
      expect(
        find.textContaining(
          'Announcements are managed by Media, Pastors and Admins.',
        ),
        findsOneWidget,
      );
      expect(byKey('announcements-new'), findsNothing);
    });

    testWidgets('a new pinned announcement is saved as a draft', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) =>
            h.announcements.staffAnnouncements = staffAnnouncements([]),
      );
      expect(
        textOf(tester, 'page-subtitle'),
        startsWith('No announcements yet.'),
      );
      await tapKey(tester, 'announcements-new');
      await tester.enterText(
        byKey('announcement-title-new'),
        'SYNTHETIC Harvest offering on Sunday',
      );
      await tester.enterText(
        byKey('announcement-body-new'),
        'SYNTHETIC Bring your harvest offering.',
      );
      await settle(tester);
      await tapKey(tester, 'announcement-pinned-new');
      await tapKey(tester, 'announcement-save-new');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'content_command');
      expect(sent.wire['command'], 'content.create_announcement');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'title': 'SYNTHETIC Harvest offering on Sunday',
        'body': 'SYNTHETIC Bring your harvest offering.',
        'pinned': true,
      });
      expect(byKey('announcements-pending'), findsOneWidget);
      h.announcements.staffAnnouncements = staffAnnouncements([
        staffAnnouncementData(draft: staffAnnouncementRevisionData()),
      ]);
      sent.confirm({
        'announcement_id': _offering,
        'revision': 1,
        'state': 'draft',
        'live_revision_no': null,
        'draft_revision_no': 1,
      }, 1);
      await settle(tester);
      expect(byKey('announcements-notice-created'), findsOneWidget);
      expect(byKey('announcement-form-new'), findsNothing);
      expect(textOf(tester, 'page-subtitle'), contains('1 waiting to publish'));
      expect(
        tester.widget<StatusLabel>(byKey('announcement-mark-$_offering')).label,
        'Draft',
      );
    });

    testWidgets('field errors are shown on the form; nothing was saved', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) =>
            h.announcements.staffAnnouncements = staffAnnouncements([]),
      );
      await tapKey(tester, 'announcements-new');
      await tester.enterText(byKey('announcement-title-new'), 'SYNTHETIC x');
      await tester.enterText(byKey('announcement-body-new'), 'SYNTHETIC y');
      await settle(tester);
      await tapKey(tester, 'announcement-save-new');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'body': 'too_long'},
      );
      await settle(tester);
      expect(byKey('announcements-notice-invalid'), findsOneWidget);
      expect(find.text('Too long'), findsOneWidget);
      expect(byKey('announcement-form-new'), findsOneWidget);
      expect(h.announcements.staffAnnouncementsCalls, 1);
    });

    testWidgets('editing a published one saves a draft at its revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          publishedOffering(),
        ]),
      );
      expect(
        tester.widget<StatusLabel>(byKey('announcement-mark-$_offering')).label,
        'Pinned',
      );
      expect(byKey('announcements-pinned'), findsOneWidget);
      await tapKey(tester, 'announcement-open-$_offering');
      expect(
        find.textContaining('Published by SYNTHETIC Media Phiri'),
        findsOne,
      );
      await tapKey(tester, 'announcement-edit-$_offering');
      // Unpin it.
      await tapKey(tester, 'announcement-pinned-$_offering');
      await tapKey(tester, 'announcement-save-$_offering');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'content.save_announcement');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {
        'announcement_id': _offering,
        'title': 'SYNTHETIC Harvest offering on Sunday',
        'body': 'SYNTHETIC Bring your harvest offering to the 09:00 service.',
        'pinned': false,
      });
      h.announcements.staffAnnouncements = staffAnnouncements([
        publishedOffering(
          draft: staffAnnouncementRevisionData(revisionNo: 2, pinned: false),
        ),
      ]);
      sent.confirm({'announcement_id': _offering, 'revision': 4}, 4);
      await settle(tester);
      expect(byKey('announcements-notice-saved'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('announcement-mark-$_offering')).label,
        'Changes not published',
      );
      expect(find.text('Publish changes'), findsOneWidget);
    });

    testWidgets('publish with a notice: the dialog previews the generic '
        'text, the command says notify, the notice says how many', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          staffAnnouncementData(draft: staffAnnouncementRevisionData()),
        ]),
      );
      await tapKey(tester, 'announcement-open-$_offering');
      await tapKey(tester, 'announcement-publish-$_offering');
      expect(
        find.text('Publish SYNTHETIC Harvest offering on Sunday?'),
        findsOneWidget,
      );
      final preview = byKey('announcement-notice-preview');
      expect(
        find.descendant(
          of: preview,
          matching: find.text('Church announcement'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: preview,
          matching: find.text(
            'The church has posted an announcement. Open the app to read it.',
          ),
        ),
        findsOneWidget,
      );
      // The announcement's own text is never in the preview.
      expect(
        find.descendant(of: preview, matching: find.textContaining('harvest')),
        findsNothing,
      );
      expect(
        textOf(tester, 'announcement-notify-reason'),
        'About 12 members can get it now.',
      );
      await tapKey(tester, 'announcement-notify');
      expect(find.text('Publish and notify'), findsOneWidget);
      await tapKey(tester, 'announcement-publish-confirm');
      final publish = h.gateway.sent.single;
      expect(publish.wire['command'], 'content.publish_announcement');
      expect(publish.wire['expected_revision'], 1);
      expect(publish.wire['payload'], {
        'announcement_id': _offering,
        'notify': true,
      });
      h.announcements.staffAnnouncements = staffAnnouncements([
        publishedOffering(live: notifiedRevision()),
      ]);
      publish.confirm({
        'announcement_id': _offering,
        'revision': 3,
        'state': 'published',
        'live_revision_no': 1,
        'draft_revision_no': null,
        'notified': 12,
      }, 3);
      await settle(tester);
      expect(byKey('announcements-notice-publishedAndNotified'), findsOne);
      expect(find.textContaining('on its way to 12 members'), findsOneWidget);
      // The opened row now shows who was notified, and how many.
      expect(
        find.textContaining('Members notified Tue 1 Sep 10:00 · 12 members'),
        findsOneWidget,
      );
    });

    testWidgets('publish without a notice sends notify false', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          staffAnnouncementData(draft: staffAnnouncementRevisionData()),
        ]),
      );
      await tapKey(tester, 'announcement-open-$_offering');
      await tapKey(tester, 'announcement-publish-$_offering');
      await tapKey(tester, 'announcement-publish-confirm');
      final publish = h.gateway.sent.single;
      expect(publish.wire['payload'], {
        'announcement_id': _offering,
        'notify': false,
      });
      h.announcements.staffAnnouncements = staffAnnouncements([
        publishedOffering(),
      ]);
      publish.confirm({'announcement_id': _offering, 'notified': 0}, 3);
      await settle(tester);
      expect(byKey('announcements-notice-published'), findsOneWidget);
      expect(find.textContaining('No notice was sent'), findsOneWidget);
    });

    testWidgets('a cancelled publish sends nothing', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          staffAnnouncementData(draft: staffAnnouncementRevisionData()),
        ]),
      );
      await tapKey(tester, 'announcement-open-$_offering');
      await tapKey(tester, 'announcement-publish-$_offering');
      await tapKey(tester, 'announcement-publish-cancel');
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets('a notified version cannot be notified again', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          staffAnnouncementData(
            revision: 5,
            state: 'withdrawn',
            live: notifiedRevision(),
            publishedBy: 'SYNTHETIC Media Phiri',
            publishedAt: '2099-09-01T08:00:00.000000Z',
            withdrawnAt: '2099-09-02T08:00:00.000000Z',
          ),
        ]),
      );
      await tapKey(tester, 'announcement-open-$_offering');
      expect(find.text('Publish again'), findsOneWidget);
      await tapKey(tester, 'announcement-publish-$_offering');
      expect(
        tester.widget<CheckboxListTile>(byKey('announcement-notify')).onChanged,
        isNull,
      );
      expect(
        textOf(tester, 'announcement-notify-reason'),
        'Members already had a notice about this version.',
      );
      await tapKey(tester, 'announcement-publish-confirm');
      expect(h.gateway.sent.single.wire['payload'], {
        'announcement_id': _offering,
        'notify': false,
      });
    });

    testWidgets('too many members: no notice offered', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          staffAnnouncementData(draft: staffAnnouncementRevisionData()),
        ], audienceMembers: 1001),
      );
      await tapKey(tester, 'announcement-open-$_offering');
      await tapKey(tester, 'announcement-publish-$_offering');
      expect(
        tester.widget<CheckboxListTile>(byKey('announcement-notify')).onChanged,
        isNull,
      );
      expect(
        textOf(tester, 'announcement-notify-reason'),
        startsWith('More than 1000 members can be reached'),
      );
    });

    for (final (name, code, fields, notice) in [
      (
        'already notified',
        ErrorCode.validationFailed,
        const {'notify': 'already_notified'},
        'alreadyNotified',
      ),
      (
        'too many recipients',
        ErrorCode.validationFailed,
        const {'notify': 'too_many_recipients'},
        'tooManyRecipients',
      ),
      (
        'notices unavailable (Q2 closed)',
        ErrorCode.unavailable,
        const <String, String>{},
        'notifyUnavailable',
      ),
      (
        'nothing to publish',
        ErrorCode.validationFailed,
        const {'announcement_id': 'nothing_to_publish'},
        'nothingToPublish',
      ),
    ]) {
      testWidgets('a refused publish with a notice: $name', (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.contentAnnouncements,
          staff: true,
          setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements(
            [staffAnnouncementData(draft: staffAnnouncementRevisionData())],
          ),
        );
        await tapKey(tester, 'announcement-open-$_offering');
        await tapKey(tester, 'announcement-publish-$_offering');
        await tapKey(tester, 'announcement-notify');
        await tapKey(tester, 'announcement-publish-confirm');
        h.gateway.sent.single.refuse(code, fieldErrors: fields);
        await settle(tester);
        expect(byKey('announcements-notice-$notice'), findsOneWidget);
        if (notice != 'nothingToPublish') {
          expect(find.textContaining('Nothing was published'), findsOneWidget);
        }
        // The list is read again (nothing changed on the server).
        expect(h.announcements.staffAnnouncementsCalls, 2);
      });
    }

    testWidgets('an unavailable publish without a notice is the generic '
        'notice', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          staffAnnouncementData(draft: staffAnnouncementRevisionData()),
        ]),
      );
      await tapKey(tester, 'announcement-open-$_offering');
      await tapKey(tester, 'announcement-publish-$_offering');
      await tapKey(tester, 'announcement-publish-confirm');
      h.gateway.sent.single.refuse(ErrorCode.unavailable);
      await settle(tester);
      expect(byKey('announcements-notice-notAvailable'), findsOneWidget);
    });

    testWidgets('withdraw asks first and sends at the revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          publishedOffering(),
        ]),
      );
      await tapKey(tester, 'announcement-open-$_offering');
      await tapKey(tester, 'announcement-withdraw-$_offering');
      expect(
        find.text('Withdraw SYNTHETIC Harvest offering on Sunday?'),
        findsOneWidget,
      );
      await tapKey(tester, 'announcement-confirm-yes');
      final withdraw = h.gateway.sent.single;
      expect(withdraw.wire['command'], 'content.withdraw_announcement');
      expect(withdraw.wire['expected_revision'], 3);
      expect(withdraw.wire['payload'], {'announcement_id': _offering});
      h.announcements.staffAnnouncements = staffAnnouncements([
        staffAnnouncementData(
          revision: 4,
          state: 'withdrawn',
          live: staffAnnouncementRevisionData(),
          withdrawnAt: '2099-09-02T08:00:00.000000Z',
        ),
      ]);
      withdraw.confirm({'announcement_id': _offering, 'revision': 4}, 4);
      await settle(tester);
      expect(byKey('announcements-notice-withdrawn'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('announcement-mark-$_offering')).label,
        'Withdrawn',
      );
    });

    testWidgets('an unknown outcome resends the same request', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentAnnouncements,
        staff: true,
        setUp: (h) => h.announcements.staffAnnouncements = staffAnnouncements([
          publishedOffering(),
        ]),
      );
      await tapKey(tester, 'announcement-open-$_offering');
      await tapKey(tester, 'announcement-archive-$_offering');
      await tapKey(tester, 'announcement-confirm-yes');
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(byKey('announcements-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'announcements-check-again');
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
      expect(byKey('announcements-notice-changedElsewhere'), findsOneWidget);
    });
  });
}
