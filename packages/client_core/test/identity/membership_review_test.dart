// Story 2.5: the Admin's membership review on staff web (approve, link an
// existing member, ask for details, reject, add a record without a login,
// unlink, reclaim a username) with honest command states, and the
// applicant's decided status on mobile. Fakes only; the server behaviour is
// covered by supabase/tests/membership_review_test.sql and
// tools/identity-e2e/review.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _app = '55555555-5555-4555-8555-555555555555';
const _member = '66666666-6666-4666-8666-666666666666';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    membershipRequests: true,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: churchStaffTheme(),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
  return h;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await tester.pump();
}

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

Map<String, Object?> candidate({bool eligible = true}) => {
  'member_id': _member,
  'display_name': 'SYNTHETIC Ruth Mwale',
  'account': 'no_login',
  'link_eligible': eligible,
  'signals': ['same_name', 'contact_route_phone'],
};

void main() {
  group('wire mapping', () {
    test('a queue entry carries the application and staff-only hints', () {
      final q = ReviewQueue.fromJson({
        'applications': [
          reviewApplicationData(priorNotApproved: 1, candidates: [candidate()]),
        ],
        'next': null,
      });
      final a = q.applications.single;
      expect(a.application.fullName, 'SYNTHETIC Ruth Mwale');
      expect(a.priorNotApproved, 1);
      expect(a.candidates.single.signals, ['same_name', 'contact_route_phone']);
      expect(a.candidates.single.account, AccountStanding.noLogin);
      for (final bad in [
        {...reviewApplicationData(), 'candidates': 'x'},
        {...reviewApplicationData(), 'own_account': null},
        {
          ...reviewApplicationData(),
          'candidates': [
            {
              ...candidate(),
              'signals': [1],
            },
          ],
        },
      ]) {
        expect(
          () => ReviewQueue.fromJson({
            'applications': [bad],
            'next': null,
          }),
          throwsFormatException,
        );
      }
    });

    test('member records and contact routes parse strictly', () {
      final m = MemberRecord.fromJson(
        memberRecordData(
          routes: [
            {
              'route_id': _app,
              'phone': '+12025550197',
              'belongs_to': 'relative',
              'holder_label': 'Daughter',
            },
          ],
        ),
      );
      expect(m.contactRoutes.single.owner, ContactOwner.relative);
      expect(m.linkEligible, isTrue);
      expect(
        () => MemberRecord.fromJson({...memberRecordData(), 'account': 'x'}),
        throwsFormatException,
      );
    });

    test('the applicant sees decision codes only when they apply', () {
      final rejected = MembershipApplication.fromJson({
        ...applicationData(),
        'application_state': 'rejected',
        'church_status': 'not_approved',
        'decision_reason': 'identity_not_confirmed',
        'reapply_from': '2026-10-01T00:00:00.000000Z',
      });
      expect(rejected.decisionReason, 'identity_not_confirmed');
      expect(rejected.canReapplyAt(DateTime.utc(2026, 10, 2)), isTrue);
      expect(rejected.canReapplyAt(DateTime.utc(2026, 9, 30)), isFalse);
      final plain = MembershipApplication.fromJson(applicationData());
      expect(plain.detailsRequested, isEmpty);
      expect(plain.reapplyFrom, isNull);
      expect(
        () => MembershipApplication.fromJson({
          ...applicationData(),
          'details_requested': [1],
        }),
        throwsFormatException,
      );
    });
  });

  group('staff web review screen', () {
    testWidgets('a non-Admin sees the server denial and nothing else', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.adminMembers);
      expect(byKey('review-denied-notGranted'), findsOneWidget);
      expect(byKey('review-sections'), findsNothing);
    });

    testWidgets('approve needs a recorded identity check and sends it', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) =>
            h.review.queue = reviewQueueWith([reviewApplicationData()]),
      );
      expect(byKey('application-card-$_app'), findsOneWidget);
      expect(enabled(tester, 'approve-$_app'), isFalse);
      await tapKey(tester, 'app-$_app-check-in_person');
      expect(enabled(tester, 'approve-$_app'), isTrue);
      await tapKey(tester, 'approve-$_app');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_review_command');
      expect(sent.wire['command'], 'identity.approve_application');
      expect(sent.wire['expected_revision'], 1);
      expect(sent.wire['payload'], {
        'application_id': _app,
        'identity_check': 'in_person',
      });
      expect(byKey('review-pending'), findsOneWidget);
      h.review.queue = reviewQueueWith([]);
      sent.confirm({'church_status': 'approved'}, 2);
      await settle(tester);
      expect(byKey('review-notice-approved'), findsOneWidget);
      expect(byKey('review-no-applications'), findsOneWidget);
    });

    testWidgets('a duplicate candidate is linked only when the Admin chooses', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) => h.review.queue = reviewQueueWith([
          reviewApplicationData(candidates: [candidate()]),
        ]),
      );
      expect(byKey('duplicates-$_app'), findsOneWidget);
      expect(find.text('Same name'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
      expect(enabled(tester, 'link-$_app-$_member'), isFalse);
      await tapKey(tester, 'app-$_app-check-established_relationship');
      await tapKey(tester, 'link-$_app-$_member');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.link_application');
      expect(sent.wire['payload'], {
        'application_id': _app,
        'member_id': _member,
        'identity_check': 'established_relationship',
      });
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'member_id': 'linked'},
      );
      await settle(tester);
      expect(byKey('review-notice-alreadyLinked'), findsOneWidget);
    });

    testWidgets('a candidate with a login or hold cannot be linked', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) => h.review.queue = reviewQueueWith([
          reviewApplicationData(candidates: [candidate(eligible: false)]),
        ]),
      );
      await tapKey(tester, 'app-$_app-check-in_person');
      expect(enabled(tester, 'link-$_app-$_member'), isFalse);
    });

    testWidgets('the Admin\'s own application cannot be decided', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) => h.review.queue = reviewQueueWith([
          reviewApplicationData(ownAccount: true),
        ]),
      );
      expect(
        find.text('Your own account: another Admin must decide this'),
        findsOneWidget,
      );
      expect(enabled(tester, 'approve-$_app'), isFalse);
      expect(enabled(tester, 'reject-$_app'), isFalse);
    });

    testWidgets('ask for details and reject send codes only', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) =>
            h.review.queue = reviewQueueWith([reviewApplicationData()]),
      );
      await tapKey(tester, 'details-$_app');
      await tapKey(tester, 'ask-$_app-visit_church_office');
      await tapKey(tester, 'ask-$_app-full_name');
      await tapKey(tester, 'send-details-$_app');
      final ask = h.gateway.sent.single;
      expect(ask.wire['command'], 'identity.request_application_details');
      expect(ask.wire['payload'], {
        'application_id': _app,
        'requested': ['full_name', 'visit_church_office'],
      });
      ask.confirm(const {}, 2);
      await settle(tester);
      expect(byKey('review-notice-detailsRequested'), findsOneWidget);

      await tapKey(tester, 'reject-$_app');
      await tapKey(tester, 'reason-$_app-not_known_to_church');
      await tapKey(tester, 'confirm-reject-$_app');
      final reject = h.gateway.sent.last;
      expect(reject.wire['command'], 'identity.reject_application');
      expect(reject.wire['payload'], {
        'application_id': _app,
        'reason': 'not_known_to_church',
      });
    });

    testWidgets('an unknown outcome is checked again with the same request', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) =>
            h.review.queue = reviewQueueWith([reviewApplicationData()]),
      );
      await tapKey(tester, 'app-$_app-check-in_person');
      await tapKey(tester, 'approve-$_app');
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(byKey('review-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'review-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(
        h.gateway.sent[1].wire['request_id'],
        h.gateway.sent[0].wire['request_id'],
      );
      h.gateway.sent[1].refuse(
        ErrorCode.forbidden,
        fieldErrors: const {'application_id': 'unsupported'},
      );
      await settle(tester);
      expect(byKey('review-notice-selfAction'), findsOneWidget);
    });

    testWidgets('add a member record without a login, with a labelled number', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) {
          h.review.queue = reviewQueueWith([]);
          h.review.search = AccessReadOk(
            MemberSearchPage.fromJson({
              'members': [memberRecordData()],
              'next': null,
            }),
          );
        },
      );
      await tester.tap(find.text('All members'));
      await settle(tester);
      expect(h.review.searchCalls, [null]);
      expect(byKey('member-record-$_member'), findsOneWidget);
      expect(byKey('unlink-$_member'), findsNothing);
      await tapKey(tester, 'add-member-record');
      await tester.enterText(byKey('add-member-name'), 'SYNTHETIC  New Person');
      await tapKey(tester, 'add-member-save');
      expect(byKey('consent-error'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
      await tapKey(tester, 'consent-leader_assisted');
      await tester.enterText(byKey('add-member-phone'), '+1 202 555 0197');
      await tester.tap(byKey('add-member-owner'));
      await settle(tester);
      await tester.tap(find.text('A relative\'s number').last);
      await settle(tester);
      await tester.enterText(byKey('add-member-holder'), 'Daughter');
      await tapKey(tester, 'add-member-save');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.create_member');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'full_name': 'SYNTHETIC New Person',
        'consent_basis': 'leader_assisted',
        'contact_route': {
          'phone': '+12025550197',
          'belongs_to': 'relative',
          'holder_label': 'Daughter',
        },
      });
      sent.confirm(memberRecordData(), 1);
      await settle(tester);
      expect(byKey('review-notice-memberCreated'), findsOneWidget);
    });

    testWidgets('unlinking needs a reason and the member revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) {
          h.review.queue = reviewQueueWith([]);
          h.review.search = AccessReadOk(
            MemberSearchPage.fromJson({
              'members': [
                memberRecordData(
                  account: 'app_account',
                  linkEligible: false,
                  revision: 4,
                ),
              ],
              'next': null,
            }),
          );
        },
      );
      await tester.tap(find.text('All members'));
      await settle(tester);
      expect(enabled(tester, 'unlink-$_member'), isFalse);
      await tester.tap(byKey('unlink-reason-$_member'));
      await settle(tester);
      await tester.tap(find.text('Ownership dispute').last);
      await settle(tester);
      await tapKey(tester, 'unlink-$_member');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.unlink_account');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'member_id': _member,
        'reason': 'ownership_dispute',
      });
      final reads = h.grants.myAccessCalls;
      sent.refuse(
        ErrorCode.forbidden,
        fieldErrors: const {'member_id': 'last_admin'},
      );
      await settle(tester);
      expect(byKey('review-notice-lastAdmin'), findsOneWidget);
      expect(byKey('review-notice-noLongerAdmin'), findsNothing);
      expect(h.grants.myAccessCalls, reads);
    });

    testWidgets('reclaim sends the normalised username and the check', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) => h.review.queue = reviewQueueWith([]),
      );
      await tester.tap(find.text('Reclaim a username'));
      await settle(tester);
      expect(enabled(tester, 'reclaim-send'), isFalse);
      await tester.enterText(byKey('reclaim-phone'), '+1 (202) 555-0195');
      await tapKey(tester, 'reclaim-check-in_person');
      await tapKey(tester, 'reclaim-send');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.reclaim_phone_username');
      expect(sent.wire['payload'], {
        'phone_username': '+12025550195',
        'identity_check': 'in_person',
      });
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'phone_username': 'linked'},
      );
      await settle(tester);
      expect(byKey('review-notice-alreadyLinked'), findsOneWidget);
    });

    testWidgets('signing out drops the queue', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembers,
        setUp: (h) =>
            h.review.queue = reviewQueueWith([reviewApplicationData()]),
      );
      expect(byKey('application-card-$_app'), findsOneWidget);
      h.review.queue = const AccessReadDenied(AccessDenial.signedOut);
      h.session.switchTo(null);
      await settle(tester);
      expect(byKey('application-card-$_app'), findsNothing);
    });
  });

  group('mobile: the applicant\'s decided status', () {
    testWidgets('details requested are listed for the applicant', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.membership,
        setUp: (h) => h.membership.mine = myApplicationWith({
          ...applicationData(churchStatus: 'details_requested'),
          'details_requested': ['full_name', 'visit_church_office'],
        }),
      );
      expect(
        find.text(
          'The church asked you to check your full name, and visit the '
          'church office.',
        ),
        findsOneWidget,
      );
      expect(byKey('correct-application'), findsOneWidget);
    });

    testWidgets('a rejection shows its reason and when to re-apply', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.membership,
        setUp: (h) => h.membership.mine = myApplicationWith({
          ...applicationData(),
          'application_state': 'rejected',
          'church_status': 'not_approved',
          'decision_reason': 'identity_not_confirmed',
          'reapply_from': DateTime.now()
              .toUtc()
              .add(const Duration(days: 6))
              .toIso8601String(),
        }),
      );
      expect(byKey('application-decision-reason'), findsOneWidget);
      expect(byKey('reapply-from'), findsOneWidget);
      expect(byKey('reapply'), findsNothing);
      expect(byKey('correct-application'), findsNothing);
    });

    testWidgets('after the cooldown a NEW request is sent', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.membership,
        setUp: (h) => h.membership.mine = myApplicationWith({
          ...applicationData(),
          'application_state': 'rejected',
          'church_status': 'not_approved',
          'reapply_from': '2026-01-01T00:00:00.000000Z',
        }),
      );
      await tapKey(tester, 'reapply');
      expect(byKey('application-form'), findsOneWidget);
      await tester.enterText(byKey('full-name-field'), 'SYNTHETIC Applicant');
      await tapKey(tester, 'cell-choice-not_sure');
      await tapKey(tester, 'privacy-accept');
      await tapKey(tester, 'send-application');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.submit_application');
      expect(sent.wire['expected_revision'], isNull);
      expect(
        (sent.wire['payload']! as Map)['privacy_notice_version'],
        'draft-2026-10-07',
      );
    });
  });

  test('the review screen never imports an adapter', () {
    // Covered globally by boundaries_test.dart; this pins the new provider.
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(
      c.read(reviewRepositoryProvider),
      isA<UnconfiguredReviewRepository>(),
    );
  });
}
