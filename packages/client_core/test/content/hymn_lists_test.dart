// Story 6.8: favourite hymns and Hymns for this Sunday. The wire parsing
// (favourites, this Sunday's public list, the editors' read), the church-time
// Sunday window (Home from Saturday 00:00 to Sunday 23:59, Africa/Lusaka,
// under a test clock), the Sunday chip in the hymn book, the Save pill (a
// member saves and removes; a guest is asked to sign in; a Pending account is
// told saving is for members; an unknown outcome is checked again with the
// same request), the Saved group and Saved hymns, and the staff Sunday hymns
// editor (set and clear a list, Admin's worship leaders). Fakes only; the
// server is covered by supabase/tests/content_hymn_lists_test.sql and
// tools/identity-e2e/content-hymn-lists.mjs. Every name is SYNTHETIC.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Church-time instants around the Sunday 2099-01-04 (Lusaka is UTC+2).
final fridayLate = DateTime.utc(2099, 1, 2, 21, 59); // Fri 23:59 Lusaka
final saturdayStart = DateTime.utc(2099, 1, 2, 22); // Sat 00:00 Lusaka
final sundayLate = DateTime.utc(2099, 1, 4, 21, 59); // Sun 23:59 Lusaka
final mondayStart = DateTime.utc(2099, 1, 4, 22); // Mon 00:00 Lusaka
const sunday = '2099-01-04';

const _listId = '68686868-6868-4868-8868-686868686868';
const _member = '61616161-6161-4161-8161-616161616161';
const _leader = '62626262-6262-4262-8262-626262626262';

MemberGrants grantsOf({
  List<String> roles = const [],
  List<ScopeGrant> scopes = const [],
}) =>
    MemberGrants(memberId: _member, revision: 1, roles: roles, scopes: scopes);

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool staff = false,
  String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  DateTime? clock,
}) async {
  tester.view.physicalSize = Size(staff ? 1200 : 390, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness(account: account);
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: !staff,
    shell: (_, _, child) => Scaffold(body: AccessRefresher(child: child)),
  );
  addTearDown(router.dispose);
  final at = clock ?? saturdayStart;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...h.overrides(),
        hymnClockProvider.overrideWithValue(() => at),
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

Map<String, Object?> staffJson({
  String capacity = 'media',
  int revision = 3,
  List<Map<String, Object?>> sundays = const [],
  bool admin = false,
}) => {
  'capacity': capacity,
  'list_id': _listId,
  'revision': revision,
  'this_sunday': sunday,
  'editions': [
    {'edition': 'test-1', 'hymns': 3, 'choruses': 2},
  ],
  'sundays': sundays,
  'worship_leaders': admin
      ? [
          {
            'member_id': _leader,
            'display_name': 'SYNTHETIC Worship Leader',
            'grants_revision': 4,
          },
        ]
      : null,
  'members': admin
      ? [
          {
            'member_id': _leader,
            'display_name': 'SYNTHETIC Worship Leader',
            'account': 'app_account',
            'grants_revision': 4,
          },
          {
            'member_id': _member,
            'display_name': 'SYNTHETIC Choir Member',
            'account': 'app_account',
            'grants_revision': 2,
          },
        ]
      : null,
  'members_truncated': admin ? false : null,
};

Map<String, Object?> sundayJson(String day, List<String> items) => {
  'sunday': day,
  'revision_no': 2,
  'edition': items.isEmpty ? null : 'test-1',
  'items': items,
  'saved_at': '2098-12-30T10:00:00Z',
  'saved_by': 'SYNTHETIC Worship Leader',
  'saved_capacity': 'worship_leader',
};

void main() {
  group('wire', () {
    test('favourites are the member\'s own item ids, strictly read', () {
      final f = MyHymnFavourites.fromJson({
        'favourites': [
          {
            'edition': 'bicc-tonga-2012',
            'item': 'hymn-12',
            'saved_at': '2099-01-01T10:00:00Z',
          },
          {
            'edition': 'bicc-tonga-2012',
            'item': 'chorus-3',
            'saved_at': '2098-12-01T10:00:00Z',
          },
        ],
        'truncated': false,
      });
      expect(f.itemIds, {'hymn-12', 'chorus-3'});
      expect(f.contains('chorus-3'), isTrue);
      final removed = f.withItem(
        'hymn-12',
        saved: false,
        edition: 'x',
        at: DateTime.utc(2099),
      );
      expect(removed.itemIds, {'chorus-3'});
      final added = f.withItem(
        'hymn-1',
        saved: true,
        edition: 'bicc-tonga-2012',
        at: DateTime.utc(2099),
      );
      expect(added.favourites.first.itemId, 'hymn-1');
      for (final bad in ['hymn-012', 'Hymn-1', 'hymn-0', '12', 'psalm-1']) {
        expect(
          () => MyHymnFavourites.fromJson({
            'favourites': [
              {
                'edition': 'bicc-tonga-2012',
                'item': bad,
                'saved_at': '2099-01-01T10:00:00Z',
              },
            ],
            'truncated': false,
          }),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test(
      'this Sunday\'s list: items with an edition, or none with neither',
      () {
        final p = PublicSundayHymns.fromJson({
          'sunday': sunday,
          'edition': 'bicc-tonga-2012',
          'items': ['hymn-12', 'chorus-3'],
          'publication_revision': 2,
        });
        expect(p.items, ['hymn-12', 'chorus-3']);
        final none = PublicSundayHymns.fromJson({
          'sunday': sunday,
          'edition': null,
          'items': <Object?>[],
          'publication_revision': null,
        });
        expect(none.items, isEmpty);
        expect(
          () => PublicSundayHymns.fromJson({
            'sunday': sunday,
            'edition': 'bicc-tonga-2012',
            'items': <Object?>[],
            'publication_revision': null,
          }),
          throwsFormatException,
        );
        expect(
          () => PublicSundayHymns.fromJson({
            'sunday': '4 Jan',
            'edition': null,
            'items': <Object?>[],
            'publication_revision': null,
          }),
          throwsFormatException,
        );
      },
    );

    test(
      'the editors\' read: an Admin gets the worship leaders, Media none',
      () {
        final admin = StaffSundayHymns.fromJson(
          staffJson(
            capacity: 'admin',
            admin: true,
            sundays: [
              sundayJson(sunday, ['hymn-1']),
            ],
          ),
        );
        expect(admin.capacity, SundayHymnsCapacity.admin);
        expect(admin.managesWorshipLeaders, isTrue);
        expect(
          admin.worshipLeaders!.single.displayName,
          'SYNTHETIC Worship Leader',
        );
        expect(admin.members!.length, 2);
        expect(
          admin.listFor(sunday)!.savedCapacity,
          SundayHymnsCapacity.worshipLeader,
        );
        final media = StaffSundayHymns.fromJson(staffJson());
        expect(media.managesWorshipLeaders, isFalse);
        final json = staffJson(admin: true)..['members'] = null;
        expect(() => StaffSundayHymns.fromJson(json), throwsFormatException);
        expect(
          () => StaffSundayHymns.fromJson(staffJson(capacity: 'pastor')),
          throwsFormatException,
        );
      },
    );

    test(
      'who sets the list (navigation only): Admin, Media, worship leaders',
      () {
        expect(setsSundayHymns(grantsOf(roles: ['admin'])), isTrue);
        expect(setsSundayHymns(grantsOf(roles: ['media'])), isTrue);
        expect(
          setsSundayHymns(
            grantsOf(
              scopes: [
                const ScopeGrant(scopeKind: 'worship_leader', scopeId: _listId),
              ],
            ),
          ),
          isTrue,
        );
        expect(setsSundayHymns(grantsOf(roles: ['pastor'])), isFalse);
        expect(setsSundayHymns(grantsOf()), isFalse);
        expect(setsSundayHymns(null), isFalse);
      },
    );
  });

  group('the church-time Sunday window', () {
    test('this Sunday is today on a Sunday, else the coming Sunday', () {
      expect(SundayHymnsWindow.thisSunday(fridayLate), sunday);
      expect(SundayHymnsWindow.thisSunday(saturdayStart), sunday);
      expect(SundayHymnsWindow.thisSunday(sundayLate), sunday);
      expect(SundayHymnsWindow.thisSunday(mondayStart), '2099-01-11');
      expect(SundayHymnsWindow.sundayAfter(sunday, 1), '2099-01-11');
    });

    test('Home shows the list from Saturday 00:00 to Sunday 23:59', () {
      expect(SundayHymnsWindow.onHome(fridayLate), isFalse);
      expect(SundayHymnsWindow.onHome(saturdayStart), isTrue);
      expect(SundayHymnsWindow.onHome(sundayLate), isTrue);
      expect(SundayHymnsWindow.onHome(mondayStart), isFalse);
    });

    test('the hymn book marks the items all week, for that Sunday only', () {
      final p = testSundayHymns(sunday, ['hymn-1']);
      expect(p.idsFor(DateTime.utc(2098, 12, 29, 10)), {'hymn-1'}); // Mon
      expect(p.idsFor(mondayStart), isEmpty);
    });
  });

  group('Home', () {
    void withList(ClientTestHarness h) => h.hymnLists.sunday = AccessReadOk(
      testSundayHymns(sunday, ['hymn-1', 'chorus-2']),
    );

    testWidgets('the chips appear on Saturday and not on Friday', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: withList,
        clock: fridayLate,
      );
      expect(byKey('home-sunday-hymns'), findsNothing);
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: withList,
        clock: saturdayStart,
      );
      expect(byKey('home-sunday-hymns'), findsOneWidget);
      expect(find.text('Hymns for this Sunday'), findsOneWidget);
      expect(find.text('SYNTHETIC hymn 1'), findsOneWidget);
      expect(find.text('SYNTHETIC chorus 2'), findsOneWidget);
    });

    testWidgets('the chips stay on Sunday until 23:59 and go on Monday', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: withList,
        clock: sundayLate,
      );
      expect(byKey('home-sunday-hymns'), findsOneWidget);
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: withList,
        clock: mondayStart,
      );
      expect(byKey('home-sunday-hymns'), findsNothing);
    });

    testWidgets('a chip opens its hymn', (tester) async {
      await pumpAt(tester, ClientPaths.home, account: null, setUp: withList);
      await tapKey(tester, 'home-sunday-hymn-chorus-2');
      expect(tester.widget<Text>(byKey('hymn-bar-title')).data, 'Chorus 2');
    });

    testWidgets('no list, or a list of another Sunday, shows nothing', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.home, account: null);
      expect(byKey('home-sunday-hymns'), findsNothing);
      await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) => h.hymnLists.sunday = AccessReadOk(
          testSundayHymns('2098-12-28', ['hymn-1']),
        ),
      );
      expect(byKey('home-sunday-hymns'), findsNothing);
    });

    testWidgets('a failed read on Saturday says so and can be retried', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        account: null,
        setUp: (h) =>
            h.hymnLists.sunday = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('home-sunday-hymns-failed'), findsOneWidget);
      h.hymnLists.sunday = AccessReadOk(testSundayHymns(sunday, ['hymn-2']));
      await tapKey(tester, 'home-sunday-hymns-retry');
      expect(find.text('SYNTHETIC hymn 2'), findsOneWidget);
    });
  });

  group('hymn book', () {
    testWidgets('this Sunday\'s items carry a Sunday chip', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.hymnBook,
        account: null,
        clock: DateTime.utc(2098, 12, 30, 10), // Tuesday
        setUp: (h) => h.hymnLists.sunday = AccessReadOk(
          testSundayHymns(sunday, ['hymn-2', 'chorus-1']),
        ),
      );
      expect(byKey('hymn-sunday-hymn-2'), findsOneWidget);
      expect(byKey('hymn-sunday-chorus-1'), findsOneWidget);
      expect(byKey('hymn-sunday-hymn-1'), findsNothing);
      // Search results keep the chip.
      await tester.enterText(byKey('hymn-search'), '2');
      await settle(tester);
      expect(byKey('hymn-sunday-hymn-2'), findsOneWidget);
    });

    testWidgets('a guest sees no Saved group', (tester) async {
      await pumpAt(tester, ClientPaths.hymnBook, account: null);
      expect(byKey('hymn-saved'), findsNothing);
      expect(byKey('hymn-saved-header'), findsNothing);
    });

    testWidgets(
      'a member\'s saved hymns come first, at most five, with See all',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.hymnBook,
          setUp: (h) {
            h.grants.myAccess = AccessReadOk(grantsOf());
            h.hymnBook.book = testHymnBook(hymns: 5, choruses: 2);
            h.hymnLists.favourites = AccessReadOk(
              MyHymnFavourites.fromJson({
                'favourites': [
                  for (final (i, id) in [
                    'hymn-3',
                    'chorus-1',
                    'hymn-1',
                    'hymn-2',
                    'hymn-4',
                    'hymn-5',
                  ].indexed)
                    {
                      'edition': 'test-1',
                      'item': id,
                      'saved_at': '2099-01-0${6 - i % 6}T10:00:00Z',
                    },
                ],
                'truncated': false,
              }),
            );
          },
        );
        expect(byKey('hymn-saved-header'), findsOneWidget);
        expect(byKey('hymn-saved-row-hymn-3'), findsOneWidget);
        expect(byKey('hymn-saved-row-hymn-4'), findsOneWidget);
        expect(byKey('hymn-saved-row-hymn-5'), findsNothing);
        expect(h.hymnLists.favouritesCalls, greaterThanOrEqualTo(1));
        await tapKey(tester, 'hymn-saved-see-all');
        expect(byKey('hymn-saved-list'), findsOneWidget);
        expect(find.text('SYNTHETIC hymn 5'), findsOneWidget);
      },
    );

    testWidgets('a failed favourites read says so, never "none saved"', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.hymnBook,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(grantsOf());
          h.hymnLists.favourites = const AccessReadFailed(unreachable: true);
        },
      );
      expect(byKey('hymn-saved-failed'), findsOneWidget);
      expect(byKey('hymn-saved-retry'), findsOneWidget);
    });
  });

  group('Save pill', () {
    testWidgets('a guest is asked to sign in and nothing is sent', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.hymn('hymn-1'), account: null);
      expect(find.text('Save'), findsOneWidget);
      await tapKey(tester, 'hymn-favourite');
      expect(byKey('hymn-favourite-sign-in-prompt'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
      await tapKey(tester, 'hymn-favourite-sign-in');
      expect(byKey('hymn-favourite-sign-in-prompt'), findsNothing);
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets('a Pending account is told saving is for members', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.hymn('hymn-1'));
      await tapKey(tester, 'hymn-favourite');
      expect(byKey('hymn-favourite-members-only'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets('a member saves and removes; Saved only once confirmed', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.hymn('hymn-1'),
        setUp: (h) => h.grants.myAccess = AccessReadOk(grantsOf()),
      );
      await tapKey(tester, 'hymn-favourite');
      final save = h.gateway.sent.single;
      expect(save.function, 'content_command');
      expect(save.wire['command'], 'content.save_hymn_favourite');
      expect(save.wire['expected_revision'], isNull);
      expect(save.wire['payload'], {'edition': 'test-1', 'item': 'hymn-1'});
      expect(find.text('Saving…'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      h.hymnLists.favourites = AccessReadOk(
        MyHymnFavourites.fromJson({
          'favourites': [
            {
              'edition': 'test-1',
              'item': 'hymn-1',
              'saved_at': '2099-01-03T10:00:00Z',
            },
          ],
          'truncated': false,
        }),
      );
      save.confirm({
        'edition': 'test-1',
        'item': 'hymn-1',
        'saved': true,
        'revision': 1,
      }, 1);
      await settle(tester);
      expect(find.text('Saved'), findsOneWidget);
      expect(byKey('hymn-favourite-notice-saved'), findsOneWidget);
      await tapKey(tester, 'hymn-favourite');
      final remove = h.gateway.sent.last;
      expect(remove.wire['command'], 'content.remove_hymn_favourite');
      h.hymnLists.favourites = const AccessReadOk(MyHymnFavourites.empty);
      remove.confirm({
        'edition': 'test-1',
        'item': 'hymn-1',
        'saved': false,
        'revision': 2,
      }, 2);
      await settle(tester);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('an unknown outcome is checked again with the same request', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.hymn('hymn-2'),
        setUp: (h) => h.grants.myAccess = AccessReadOk(grantsOf()),
      );
      await tapKey(tester, 'hymn-favourite');
      final first = h.gateway.sent.single;
      first.unknown();
      await settle(tester);
      expect(byKey('hymn-favourite-notice-unconfirmed'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      await tester.tap(byKey('hymn-favourite-check-again'));
      await settle(tester);
      expect(h.gateway.sent.length, 2);
      expect(h.gateway.sent.last.request.requestId, first.request.requestId);
    });

    testWidgets('a refusal by the server is said, and nothing shows as saved', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.hymn('hymn-2'),
        setUp: (h) => h.grants.myAccess = AccessReadOk(grantsOf()),
      );
      await tapKey(tester, 'hymn-favourite');
      h.gateway.sent.single.refuse(ErrorCode.forbidden);
      await settle(tester);
      expect(byKey('hymn-favourite-notice-membersOnly'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
    });
  });

  group('Saved hymns screen', () {
    testWidgets('a guest is asked to sign in', (tester) async {
      await pumpAt(tester, ClientPaths.savedHymns, account: null);
      expect(byKey('hymn-saved-signed-out'), findsOneWidget);
    });

    testWidgets('no saved hymns is said in the list frame', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.savedHymns,
        setUp: (h) => h.grants.myAccess = AccessReadOk(grantsOf()),
      );
      expect(byKey('hymn-saved-empty'), findsOneWidget);
    });
  });

  group('staff Sunday hymns', () {
    testWidgets('Media adds items by number and saves this Sunday\'s list', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentSundayHymns,
        staff: true,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(grantsOf(roles: ['media']));
          h.hymnLists.staff = AccessReadOk(
            StaffSundayHymns.fromJson(staffJson()),
          );
        },
      );
      expect(
        find.textContaining('This Sunday (Sun 4 Jan 2099): not set'),
        findsOneWidget,
      );
      expect(byKey('sunday-hymns-leaders'), findsNothing);
      expect(byKey('sunday-hymns-empty'), findsOneWidget);
      await tester.enterText(byKey('sunday-hymns-search'), '2');
      await settle(tester);
      await tapKey(tester, 'sunday-hymns-add-hymn-2');
      await tester.enterText(byKey('sunday-hymns-search'), 'chorus 1');
      await settle(tester);
      await tapKey(tester, 'sunday-hymns-add-chorus-1');
      expect(byKey('sunday-hymns-item-hymn-2'), findsOneWidget);
      expect(byKey('sunday-hymns-item-chorus-1'), findsOneWidget);
      await tapKey(tester, 'sunday-hymns-save');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'content_command');
      expect(sent.wire['command'], 'content.set_sunday_hymns');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {
        'sunday': sunday,
        'edition': 'test-1',
        'items': ['hymn-2', 'chorus-1'],
      });
      expect(byKey('sunday-hymns-pending'), findsOneWidget);
      h.hymnLists.staff = AccessReadOk(
        StaffSundayHymns.fromJson(
          staffJson(
            revision: 4,
            sundays: [
              sundayJson(sunday, ['hymn-2', 'chorus-1']),
            ],
          ),
        ),
      );
      sent.confirm({
        'list_id': _listId,
        'revision': 4,
        'sunday': sunday,
        'revision_no': 1,
      }, 4);
      await settle(tester);
      expect(byKey('sunday-hymns-notice-saved'), findsOneWidget);
      expect(byKey('sunday-hymns-clear'), findsOneWidget);
    });

    testWidgets('a set list is cleared after a confirmation', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentSundayHymns,
        staff: true,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(
            grantsOf(
              scopes: [
                const ScopeGrant(scopeKind: 'worship_leader', scopeId: _listId),
              ],
            ),
          );
          h.hymnLists.staff = AccessReadOk(
            StaffSundayHymns.fromJson(
              staffJson(
                capacity: 'worship_leader',
                sundays: [
                  sundayJson(sunday, ['hymn-1']),
                ],
              ),
            ),
          );
        },
      );
      expect(byKey('sunday-hymns-item-hymn-1'), findsOneWidget);
      await tapKey(tester, 'sunday-hymns-clear');
      expect(byKey('sunday-hymns-clear-dialog'), findsOneWidget);
      await tapKey(tester, 'sunday-hymns-clear-confirm');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'content.clear_sunday_hymns');
      expect(sent.wire['payload'], {'sunday': sunday});
      sent.refuse(ErrorCode.conflict, currentRevision: const Optional.of(5));
      await settle(tester);
      expect(byKey('sunday-hymns-notice-changedElsewhere'), findsOneWidget);
    });

    testWidgets('an Admin makes a member a worship leader and removes one', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentSundayHymns,
        staff: true,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(grantsOf(roles: ['admin']));
          h.hymnLists.staff = AccessReadOk(
            StaffSundayHymns.fromJson(
              staffJson(capacity: 'admin', admin: true),
            ),
          );
        },
      );
      expect(byKey('sunday-hymns-leaders'), findsOneWidget);
      await tester.ensureVisible(byKey('sunday-hymns-candidate'));
      await tester.tap(byKey('sunday-hymns-candidate'));
      await settle(tester);
      await tester.tap(find.text('SYNTHETIC Choir Member').last);
      await settle(tester);
      await tapKey(tester, 'sunday-hymns-add-leader');
      final grant = h.gateway.sent.single;
      expect(grant.function, 'identity_grant_command');
      expect(grant.wire['command'], 'identity.grant_scope');
      expect(grant.wire['expected_revision'], 2);
      expect(grant.wire['payload'], {
        'member_id': _member,
        'scope_kind': 'worship_leader',
        'scope_id': _listId,
      });
      grant.confirm(null, 3);
      await settle(tester);
      expect(byKey('sunday-hymns-notice-granted'), findsOneWidget);
      await tapKey(tester, 'sunday-hymns-remove-leader-$_leader');
      final revoke = h.gateway.sent.last;
      expect(revoke.wire['command'], 'identity.revoke_scope');
      expect(revoke.wire['expected_revision'], 4);
    });

    testWidgets('a member without the scope is told who sets the lists', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.contentSundayHymns,
        staff: true,
        setUp: (h) => h.grants.myAccess = AccessReadOk(grantsOf()),
      );
      expect(byKey('sunday-hymns-denied-notGranted'), findsOneWidget);
    });
  });
}
