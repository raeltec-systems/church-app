// Story 6.3: verified giving methods and How to give. The wire parsing
// (public projection and the Admins' read), the mobile Give tab and a
// method's detail (copyable values, steps, the beneficiary check, the
// checked date, the contact, the sample banner, honest empty, failed, gone
// and stale states), and the staff Giving screen's commands (create, save,
// verify, publish, hide, archive, move) with an Admin who cannot verify their
// own save and a plain message for every refusal. Fakes only; the server
// behaviour is covered by supabase/tests/content_giving_test.sql and
// tools/identity-e2e/content-giving.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _airtel = '61616161-6161-4161-8161-616161616161';
const _bank = '62626262-6262-4262-8262-626262626262';
const _cash = '63636363-6363-4363-8363-636363636363';

/// Words of payment processing that must never appear in a giving payload.
final _paymentWords = RegExp(
  r'amount|payer|sender|donor|proof|receipt|gift|transaction',
);

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

Future<void> tapFinder(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await settle(tester);
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(byKey(key)).data!;

/// Records what the app puts on the clipboard.
List<String> captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

Map<String, Object?> cashData() => publicGivingMethodData(
  methodId: _cash,
  methodType: 'other',
  name: 'SAMPLE At church',
  purpose: 'Offering during the service',
  currency: null,
  details: const [],
  ussdCode: null,
  steps: const ['Place your offering in the bag during the Sunday service.'],
);

AccessRead<PublicGivingMethods> threeMethods({bool sample = true}) =>
    AccessReadOk(
      PublicGivingMethods.fromJson(
        publicGivingMethodsData([
          publicGivingMethodData(),
          publicBankMethodData(),
          cashData(),
        ], sample: sample),
      ),
    );

AccessRead<PublicGivingMethodRead> detail(
  Map<String, Object?> method, {
  bool sample = true,
}) => AccessReadOk(
  PublicGivingMethodRead.fromJson({'sample': sample, 'method': method}),
);

AccessRead<StaffGivingMethods> staffMethods(
  List<Map<String, Object?>> methods,
) => AccessReadOk(StaffGivingMethods.fromJson(staffGivingMethodsData(methods)));

/// A never-published draft, saved by [savedByYou] or another Admin, verified
/// or not.
Map<String, Object?> draftAirtel({
  bool savedByYou = false,
  bool verified = false,
  int revision = 1,
  int position = 1,
}) => staffGivingMethodData(
  revision: revision,
  position: position,
  draft: staffGivingRevisionData(
    savedByYou: savedByYou,
    verification: verified ? givingVerificationData() : null,
  ),
);

/// A live bank method with no open draft.
Map<String, Object?> liveBank({int position = 2, int revision = 4}) =>
    staffGivingMethodData(
      methodId: _bank,
      methodType: 'bank',
      position: position,
      revision: revision,
      state: 'published',
      publishedBy: 'SYNTHETIC Admin Mwale',
      publishedAt: '2026-09-28T10:00:00.000000Z',
      live: staffGivingRevisionData(
        methodType: 'bank',
        name: 'SAMPLE Bank transfer',
        publishedBy: 'SYNTHETIC Admin Mwale',
        publishedAt: '2026-09-28T10:00:00.000000Z',
        verification: givingVerificationData(),
      ),
    );

void main() {
  group('wire parsing', () {
    test('the public projection: values, beneficiary and checked date', () {
      final all = PublicGivingMethods.fromJson(
        publicGivingMethodsData([
          publicGivingMethodData(),
          publicBankMethodData(),
          cashData(),
        ], truncated: true),
      );
      expect(all.sample, isTrue);
      expect(all.truncated, isTrue);
      expect(all.sharedContact, 'SAMPLE church office, +260 97 000 0000');
      final airtel = all.methods[0];
      expect(airtel.methodType, GivingMethodType.mobileMoney);
      expect(airtel.subline, 'Tithes & Offerings · ZMW');
      expect(airtel.beneficiary, 'SAMPLE Brethren in Christ Church Kafue');
      expect(airtel.ussdCode, '*115#');
      expect(
        [for (final d in airtel.details) d.labelFor(airtel.methodType)],
        ['Beneficiary', 'Merchant ID'],
      );
      expect(churchDateText(airtel.verifiedOn), '28 Sep 2026');
      final bank = all.methods[1];
      expect(
        [for (final d in bank.details) d.labelFor(bank.methodType)],
        ['Bank', 'Account name', 'Account number', 'Branch', 'Reference'],
      );
      expect(bank.beneficiary, 'SAMPLE Brethren in Christ Church Kafue');
      final cash = all.methods[2];
      expect(cash.details, isEmpty);
      expect(cash.subline, 'Offering during the service');
      // A key a later entry adds (a logo, the dialler) is ignored.
      expect(
        PublicGivingMethod.fromJson({...publicGivingMethodData(), 'logo': null})
            .methodId,
        _airtel,
      );
      // Different contacts: no shared line.
      expect(
        PublicGivingMethods.fromJson(
          publicGivingMethodsData([
            publicGivingMethodData(),
            publicBankMethodData(contact: 'SAMPLE treasurer'),
          ]),
        ).sharedContact,
        isNull,
      );
      final gone = PublicGivingMethodRead.fromJson({
        'sample': false,
        'method': null,
      });
      expect(gone.method, isNull);
      expect(gone.sample, isFalse);
    });

    test('a malformed public answer is refused, never guessed', () {
      final thirteen = [for (var i = 1; i <= 13; i++) 'SAMPLE step $i'];
      for (final bad in <Object?>[
        null,
        {'methods': const <Object?>[], 'truncated': false},
        publicGivingMethodsData([
          {...publicGivingMethodData(), 'name': ' '},
        ]),
        publicGivingMethodsData([
          {...publicGivingMethodData(), 'method_type': 'cash'},
        ]),
        publicGivingMethodsData([publicGivingMethodData(steps: const [])]),
        publicGivingMethodsData([publicGivingMethodData(steps: thirteen)]),
        publicGivingMethodsData([publicGivingMethodData(currency: 'zmw')]),
        publicGivingMethodsData([publicGivingMethodData(ussdCode: '115')]),
        publicGivingMethodsData([
          {...publicGivingMethodData(), 'verified_on': '2026-02-30'},
        ]),
        // The identifier before the beneficiary, or a bank key on mobile
        // money.
        publicGivingMethodsData([
          publicGivingMethodData(
            details: const [
              {'key': 'merchant_id', 'value': '000000'},
              {'key': 'beneficiary', 'value': 'SAMPLE Church'},
            ],
          ),
        ]),
        publicGivingMethodsData([
          publicGivingMethodData(
            details: const [
              {'key': 'beneficiary', 'value': 'SAMPLE Church'},
              {'key': 'account_number', 'value': '0000'},
            ],
          ),
        ]),
        // A bank without its account number; a starting code on a bank.
        publicGivingMethodsData([
          publicGivingMethodData(
            methodType: 'bank',
            ussdCode: null,
            details: const [
              {'key': 'bank_name', 'value': 'SAMPLE Bank'},
              {'key': 'beneficiary', 'value': 'SAMPLE Church'},
            ],
          ),
        ]),
        publicGivingMethodsData([
          {...publicBankMethodData(), 'ussd_code': '*115#'},
        ]),
        // "Other" carries no destination values.
        publicGivingMethodsData([
          {
            ...cashData(),
            'details': const [
              {'key': 'beneficiary', 'value': 'SAMPLE Church'},
            ],
          },
        ]),
      ]) {
        expect(
          () => PublicGivingMethods.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
      expect(
        () => PublicGivingMethodRead.fromJson({'sample': true}),
        throwsFormatException,
      );
    });

    test('the Admins\' read: stages, verification and order', () {
      final staff = StaffGivingMethods.fromJson(
        staffGivingMethodsData([
          liveBank(position: 1),
          draftAirtel(savedByYou: true, position: 2),
          staffGivingMethodData(
            methodId: _cash,
            methodType: 'other',
            position: null,
            state: 'archived',
            archivedAt: '2026-09-29T08:00:00.000000Z',
            draft: staffGivingRevisionData(
              methodType: 'other',
              name: 'SAMPLE At church',
            ),
          ),
        ]),
      );
      expect(staff.capacity, 'admin');
      expect([for (final g in staff.ordered) g.methodId], [_bank, _airtel]);
      expect([for (final g in staff.archived) g.methodId], [_cash]);
      final bank = staff.ordered.first;
      expect(bank.stage, GivingStage.live);
      expect(bank.canHide, isTrue);
      expect(bank.canPublish, isFalse);
      expect(bank.live!.verification!.verifiedBy, 'SYNTHETIC Admin Banda');
      expect(bank.current.accountNumber, '0000 0000 0000');
      final airtel = staff.ordered.last;
      expect(airtel.stage, GivingStage.draftNeedsVerifying);
      expect(airtel.needsVerifying, isTrue);
      expect(airtel.verifyBlockedForYou, isTrue);
      expect(airtel.canPublish, isFalse);
      expect(airtel.current.identifierKind, MobileMoneyIdentifier.merchant);
      expect(staff.archived.single.stage, GivingStage.archived);
      expect(staff.archived.single.canEdit, isFalse);

      GivingStage stageOf(Map<String, Object?> m) =>
          StaffGivingMethod.fromJson(m).stage;
      expect(stageOf(draftAirtel(verified: true)), GivingStage.draftVerified);
      expect(
        stageOf({
          ...liveBank(),
          'draft': staffGivingRevisionData(methodType: 'bank', revisionNo: 2),
        }),
        GivingStage.liveChangesNeedVerifying,
      );
      expect(
        stageOf({
          ...liveBank(),
          'draft': staffGivingRevisionData(
            methodType: 'bank',
            revisionNo: 2,
            verification: givingVerificationData(),
          ),
        }),
        GivingStage.liveChangesVerified,
      );
      final hidden = StaffGivingMethod.fromJson({
        ...liveBank(),
        'state': 'withdrawn',
      });
      expect(hidden.stage, GivingStage.hidden);
      expect(hidden.canPublish, isTrue, reason: 'publish shows it again');
      // Discard needs a live revision and an open draft.
      expect(bank.canDiscard, isFalse, reason: 'no draft');
      expect(airtel.canDiscard, isFalse, reason: 'never published');
      expect(staff.archived.single.canDiscard, isFalse);
      final changes = {
        ...liveBank(),
        'draft': staffGivingRevisionData(methodType: 'bank', revisionNo: 2),
      };
      expect(StaffGivingMethod.fromJson(changes).canDiscard, isTrue);
      expect(
        StaffGivingMethod.fromJson({...changes, 'state': 'withdrawn'})
            .canDiscard,
        isTrue,
      );

      for (final bad in <Map<String, Object?>>[
        // A never-published method without its draft.
        staffGivingMethodData(),
        // An archived method keeps no position; a live one has one.
        {...draftAirtel(), 'state': 'archived'},
        {...liveBank(), 'position': null},
        // A mobile money revision without its identifier.
        staffGivingMethodData(
          draft: {...staffGivingRevisionData(), 'identifier': null},
        ),
        staffGivingMethodData(
          draft: {...staffGivingRevisionData(), 'identifier_kind': 'iban'},
        ),
      ]) {
        expect(
          () => StaffGivingMethods.fromJson(staffGivingMethodsData([bad])),
          throwsFormatException,
          reason: '$bad',
        );
      }
      expect(
        () => StaffGivingMethods.fromJson({
          ...staffGivingMethodsData([]),
          'capacity': 'media',
        }),
        throwsFormatException,
      );
    });

    test('an input sends every key of its type and nothing else', () {
      const mobile = GivingMethodInput(
        methodType: GivingMethodType.mobileMoney,
        name: ' SAMPLE Airtel Money ',
        currency: 'zmw',
        steps: ['  Dial the starting code. ', ' ', 'Pay merchant.'],
        contact: 'SAMPLE church office',
        beneficiary: 'SAMPLE Church',
        identifierKind: MobileMoneyIdentifier.till,
        identifier: '000000',
        ussdCode: ' ',
        bankName: 'ignored for mobile money',
      );
      final create = mobile.toPayload();
      expect(create, {
        'method_type': 'mobile_money',
        'name': 'SAMPLE Airtel Money',
        'purpose': null,
        'currency': 'ZMW',
        'steps': ['Dial the starting code.', 'Pay merchant.'],
        'note': null,
        'contact': 'SAMPLE church office',
        'beneficiary': 'SAMPLE Church',
        'identifier_kind': 'till',
        'identifier': '000000',
        'ussd_code': null,
      });
      const bank = GivingMethodInput(
        methodType: GivingMethodType.bank,
        name: 'SAMPLE Bank transfer',
        steps: ['Open your banking app.'],
        contact: 'SAMPLE church office',
        bankName: 'SAMPLE Bank',
        beneficiary: 'SAMPLE Church',
        accountNumber: '0000 0000',
        swiftCode: 'sampzmlu',
      );
      final save = bank.toPayload(methodId: _bank);
      expect(save['method_id'], _bank);
      expect(save.containsKey('method_type'), isFalse);
      expect(save['swift_code'], 'SAMPZMLU');
      expect(save.keys.toSet(), {
        'method_id',
        'name',
        'purpose',
        'currency',
        'steps',
        'note',
        'contact',
        'bank_name',
        'beneficiary',
        'account_number',
        'branch',
        'branch_code',
        'swift_code',
        'reference',
      });
      const other = GivingMethodInput(
        methodType: GivingMethodType.other,
        name: 'SAMPLE At church',
        steps: ['Use the offering bag.'],
        contact: 'SAMPLE church office',
        beneficiary: 'ignored',
      );
      expect(other.toPayload().keys.toSet(), {
        'method_type',
        'name',
        'purpose',
        'currency',
        'steps',
        'note',
        'contact',
      });
      for (final p in [create, save, other.toPayload()]) {
        expect(p.keys.where(_paymentWords.hasMatch), isEmpty);
      }
    });

    test('only Admins manage giving (navigation only)', () {
      expect(editsGiving(null), isFalse);
      expect(editsGiving(syntheticGrants()), isFalse);
      for (final role in ['media', 'pastor', 'lead_pastor']) {
        expect(editsGiving(syntheticGrants(roles: [role])), isFalse);
      }
      expect(editsGiving(syntheticGrants(roles: ['admin'])), isTrue);
    });
  });

  group('How to give (signed out)', () {
    testWidgets('the methods in order, what each is for, the shared contact', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.give,
        account: null,
        setUp: (h) => h.giving.publicMethods = threeMethods(),
      );
      expect(h.giving.publicMethodsCalls, 1);
      expect(find.text('How to give'), findsOneWidget);
      expect(
        textOf(tester, 'give-explainer'),
        'Choose a method and follow the steps. You give through your '
        'provider; the app doesn\'t process or record gifts.',
      );
      final rows = [
        for (final id in [_airtel, _bank, _cash])
          tester.getTopLeft(byKey('give-method-$id')).dy,
      ];
      expect(rows, orderedEquals([...rows]..sort()));
      expect(
        textOf(tester, 'give-method-sub-$_airtel'),
        'Tithes & Offerings · ZMW',
      );
      expect(
        textOf(tester, 'give-method-sub-$_cash'),
        'Offering during the service',
      );
      expect(
        textOf(tester, 'give-contact'),
        'Questions about giving? SAMPLE church office, +260 97 000 0000',
      );
      // Nothing to type: no amount, no "record my gift".
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('record my gift'), findsNothing);
    });

    testWidgets('a mobile money method: copy each value, steps, the check, '
        'the date, the contact and the sample banner', (tester) async {
      final copied = captureClipboard(tester);
      final h = await pumpAt(
        tester,
        ClientPaths.give,
        account: null,
        setUp: (h) {
          h.giving.publicMethods = threeMethods();
          h.giving.publicMethod[_airtel] = detail(publicGivingMethodData());
        },
      );
      await tapKey(tester, 'give-method-$_airtel');
      expect(h.giving.publicMethodAsked, [_airtel]);
      expect(find.byType(BackButton), findsOneWidget);
      expect(textOf(tester, 'give-method-name'), 'SAMPLE Airtel Money');
      expect(textOf(tester, 'give-method-subline'), 'Tithes & Offerings · ZMW');
      expect(byKey('give-sample'), findsOneWidget);
      expect(
        find.text(
          'Sample details for testing. The church must supply and verify '
          'its own.',
        ),
        findsOneWidget,
      );
      for (final (key, label, value) in [
        (
          'beneficiary',
          'Beneficiary',
          'SAMPLE Brethren in Christ Church Kafue',
        ),
        ('merchant_id', 'Merchant ID', '000000'),
        ('ussd_code', 'Starting code', '*115#'),
      ]) {
        expect(textOf(tester, 'give-value-$key'), value);
        await tapKey(tester, 'give-copy-$key');
        expect(copied.last, value, reason: key);
        expect(
          tester.takeAnnouncements().map((a) => a.message),
          contains('$label copied'),
        );
        // The button says so until the next copy.
        expect(
          find.descendant(
            of: byKey('give-copy-$key'),
            matching: find.text('Copied'),
          ),
          findsOneWidget,
        );
      }
      expect(copied, hasLength(3));
      expect(byKey('give-step-1'), findsOneWidget);
      expect(byKey('give-step-4'), findsOneWidget);
      expect(
        find.text('Choose Make payments, then Pay merchant.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(byKey('give-beneficiary-check'))
            .textSpan!
            .toPlainText(),
        'Check that your provider shows SAMPLE Brethren in Christ Church '
        'Kafue before you confirm. If it does not, stop and contact the '
        'church.',
      );
      expect(
        textOf(tester, 'give-verified'),
        'Details checked by the church on 28 Sep 2026',
      );
      expect(
        textOf(tester, 'give-method-contact'),
        'Questions? SAMPLE church office, +260 97 000 0000',
      );
      // No dialler, amount, success state or verifier on the phone.
      expect(find.textContaining('Open dialler'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('Banda'), findsNothing);
      expect(find.textContaining('provider showed'), findsNothing);
    });

    testWidgets('a refresh that brings new details never shows Copied for a '
        'value that was not copied', (tester) async {
      final copied = captureClipboard(tester);
      final h = await pumpAt(
        tester,
        ClientPaths.giveMethod(_airtel),
        account: null,
        setUp: (h) =>
            h.giving.publicMethod[_airtel] = detail(publicGivingMethodData()),
      );
      Finder copiedOn(String key) => find.descendant(
        of: byKey('give-copy-$key'),
        matching: find.text('Copied'),
      );
      await tapKey(tester, 'give-copy-merchant_id');
      expect(copied, ['000000']);
      expect(copiedOn('merchant_id'), findsOneWidget);
      // The same publication again: the copy still stands.
      await tapKey(tester, 'give-method-reload');
      expect(copiedOn('merchant_id'), findsOneWidget);
      // A republished method with a new merchant ID: nothing is copied yet.
      h.giving.publicMethod[_airtel] = detail(
        publicGivingMethodData(
          publicationRevision: 2,
          details: const [
            {
              'key': 'beneficiary',
              'value': 'SAMPLE Brethren in Christ Church Kafue',
            },
            {'key': 'merchant_id', 'value': '111111'},
          ],
        ),
      );
      await tapKey(tester, 'give-method-reload');
      expect(textOf(tester, 'give-value-merchant_id'), '111111');
      expect(copiedOn('merchant_id'), findsNothing);
      expect(find.text('Copied'), findsNothing);
      await tapKey(tester, 'give-copy-merchant_id');
      expect(copied, ['000000', '111111']);
      expect(copiedOn('merchant_id'), findsOneWidget);
    });

    testWidgets('a copy button is named by its value', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAt(
        tester,
        ClientPaths.giveMethod(_airtel),
        account: null,
        setUp: (h) =>
            h.giving.publicMethod[_airtel] = detail(publicGivingMethodData()),
      );
      expect(find.bySemanticsLabel('Copy Merchant ID'), findsOneWidget);
      expect(find.bySemanticsLabel('Copy Starting code'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a bank method lists its values; production shows no '
        'sample banner', (tester) async {
      final copied = captureClipboard(tester);
      await pumpAt(
        tester,
        ClientPaths.giveMethod(_bank),
        account: null,
        setUp: (h) => h.giving.publicMethod[_bank] = detail(
          publicBankMethodData(),
          sample: false,
        ),
      );
      expect(byKey('give-sample'), findsNothing);
      expect(textOf(tester, 'give-value-account_number'), '0000 0000 0000');
      expect(find.text('Account name'), findsOneWidget);
      expect(find.text('Reference'), findsOneWidget);
      expect(byKey('give-copy-ussd_code'), findsNothing);
      await tapKey(tester, 'give-copy-account_number');
      expect(copied, ['0000 0000 0000']);
      expect(
        tester
            .widget<Text>(byKey('give-beneficiary-check'))
            .textSpan!
            .toPlainText(),
        contains('shows SAMPLE Brethren in Christ Church Kafue before'),
      );
    });

    testWidgets('a method with nothing to copy says to give only through '
        'the church', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.giveMethod(_cash),
        account: null,
        setUp: (h) => h.giving.publicMethod[_cash] = detail(cashData()),
      );
      expect(byKey('give-values'), findsNothing);
      expect(
        textOf(tester, 'give-beneficiary-check'),
        startsWith('Give only through the church\'s own channels.'),
      );
    });

    testWidgets('a method that is no longer published says so', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.giveMethod(_airtel),
        account: null,
        setUp: (h) =>
            h.giving.publicMethod[_airtel] = detail(publicGivingMethodData()),
      );
      expect(textOf(tester, 'give-method-name'), 'SAMPLE Airtel Money');
      // Hidden on staff web: the next read answers null.
      h.giving.publicMethod.remove(_airtel);
      await tapKey(tester, 'give-method-reload');
      expect(byKey('give-method-gone'), findsOneWidget);
      expect(find.text('This giving method is no longer listed.'), findsOne);
      expect(byKey('give-method-name'), findsNothing);
      await tapKey(tester, 'give-method-gone-list');
      expect(byKey('give-explainer'), findsOneWidget);
    });

    testWidgets('no published method says so plainly', (tester) async {
      await pumpAt(tester, ClientPaths.give, account: null);
      expect(byKey('give-empty'), findsOneWidget);
      expect(find.text('No giving methods yet'), findsOneWidget);
      expect(
        find.text('When the church adds how to give, it will show here.'),
        findsOneWidget,
      );
      expect(byKey('give-failed'), findsNothing);
    });

    testWidgets('no connection is not an empty list; Try again asks again', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.give,
        account: null,
        setUp: (h) =>
            h.giving.publicMethods = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('give-failed'), findsOneWidget);
      expect(byKey('give-empty'), findsNothing);
      expect(
        find.textContaining('does not mean the church has none'),
        findsOne,
      );
      h.giving.publicMethods = threeMethods();
      await tapKey(tester, 'give-try-again');
      expect(h.giving.publicMethodsCalls, 2);
      expect(byKey('give-failed'), findsNothing);
      expect(byKey('give-method-$_airtel'), findsOneWidget);
    });

    testWidgets('a failed detail read offers Try again', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.giveMethod(_airtel),
        account: null,
        setUp: (h) => h.giving.publicMethod[_airtel] = const AccessReadFailed(
          unreachable: false,
        ),
      );
      expect(byKey('give-method-failed'), findsOneWidget);
      h.giving.publicMethod[_airtel] = detail(publicGivingMethodData());
      await tapKey(tester, 'give-method-try-again');
      expect(textOf(tester, 'give-method-name'), 'SAMPLE Airtel Money');
      expect(h.giving.publicMethodAsked, [_airtel, _airtel]);
    });

    testWidgets('a failed refresh keeps the methods shown and says from when', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.give,
        account: null,
        setUp: (h) => h.giving.publicMethods = threeMethods(),
      );
      h.giving.publicMethods = const AccessReadFailed(unreachable: true);
      await tapKey(tester, 'give-reload');
      expect(byKey('give-stale'), findsOneWidget);
      expect(find.textContaining('as they were at'), findsOneWidget);
      expect(byKey('give-method-$_airtel'), findsOneWidget);
      expect(byKey('give-failed'), findsNothing);
      h.giving.publicMethods = threeMethods();
      await tapKey(tester, 'give-reload');
      expect(byKey('give-stale'), findsNothing);
    });
  });

  group('staff web Giving', () {
    testWidgets('Media, Pastors and members are told only Admins manage it', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.contentGiving, staff: true);
      expect(byKey('giving-denied-notGranted'), findsOneWidget);
      expect(
        find.textContaining('Giving methods are managed by Admins.'),
        findsOneWidget,
      );
      expect(byKey('giving-new'), findsNothing);
    });

    testWidgets('a new mobile money method is saved as a draft that needs '
        'another Admin', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([]),
      );
      expect(textOf(tester, 'page-subtitle'), startsWith('No giving methods'));
      await tapKey(tester, 'giving-new');
      // Mobile money is the default kind; only its fields are shown.
      expect(byKey('giving-beneficiary-new'), findsOneWidget);
      expect(byKey('giving-bank-name-new'), findsNothing);
      for (final (key, value) in [
        ('giving-name-new', 'SAMPLE Airtel Money'),
        ('giving-purpose-new', 'Tithes & Offerings'),
        ('giving-currency-new', 'zmw'),
        ('giving-beneficiary-new', 'SAMPLE Brethren in Christ Church Kafue'),
        ('giving-identifier-new', '000000'),
        ('giving-ussd-new', '*115#'),
        ('giving-contact-new', 'SAMPLE church office'),
      ]) {
        await tester.enterText(byKey(key), value);
      }
      await tapFinder(
        tester,
        find.byKey(const ValueKey('segment-Till number')),
      );
      final steps = find.descendant(
        of: byKey('giving-steps-new'),
        matching: find.byType(TextField),
      );
      await tester.enterText(steps.at(0), 'Enter the till number.');
      await tapKey(tester, 'giving-step-add-new');
      await tester.enterText(steps.at(1), ' Dial the starting code. ');
      await settle(tester);
      // The second step belongs first.
      await tapFinder(tester, find.byTooltip('Move step 2 up'));
      await tapKey(tester, 'giving-save-new');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'content_command');
      expect(sent.wire['command'], 'content.create_giving_method');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'method_type': 'mobile_money',
        'name': 'SAMPLE Airtel Money',
        'purpose': 'Tithes & Offerings',
        'currency': 'ZMW',
        'steps': ['Dial the starting code.', 'Enter the till number.'],
        'note': null,
        'contact': 'SAMPLE church office',
        'beneficiary': 'SAMPLE Brethren in Christ Church Kafue',
        'identifier_kind': 'till',
        'identifier': '000000',
        'ussd_code': '*115#',
      });
      expect(byKey('giving-pending'), findsOneWidget);
      h.giving.staffMethods = staffMethods([draftAirtel(savedByYou: true)]);
      sent.confirm({
        'method_id': _airtel,
        'revision': 1,
        'state': 'draft',
        'live_revision_no': null,
        'draft_revision_no': 1,
      }, 1);
      await settle(tester);
      expect(byKey('giving-notice-created'), findsOneWidget);
      expect(byKey('giving-form-new'), findsNothing);
      expect(
        tester.widget<StatusLabel>(byKey('giving-mark-$_airtel')).label,
        'Draft, needs verifying',
      );
      expect(
        textOf(tester, 'page-subtitle'),
        '0 live in How to give · 1 waiting for a second Admin to verify',
      );
    });

    testWidgets('a bank method shows and sends only bank fields', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([]),
      );
      await tapKey(tester, 'giving-new');
      await tapFinder(tester, find.byKey(const ValueKey('segment-Bank')));
      expect(byKey('giving-identifier-new'), findsNothing);
      expect(byKey('giving-ussd-new'), findsNothing);
      for (final (key, value) in [
        ('giving-name-new', 'SAMPLE Bank transfer'),
        ('giving-bank-name-new', 'SAMPLE Bank Zambia'),
        ('giving-beneficiary-new', 'SAMPLE Brethren in Christ Church Kafue'),
        ('giving-account-number-new', '0000 0000 0000'),
        ('giving-reference-new', 'BUILDING + your name'),
        ('giving-contact-new', 'SAMPLE church office'),
      ]) {
        await tester.enterText(byKey(key), value);
      }
      await tester.enterText(
        find
            .descendant(
              of: byKey('giving-steps-new'),
              matching: find.byType(TextField),
            )
            .first,
        'Open your banking app.',
      );
      await settle(tester);
      await tapKey(tester, 'giving-save-new');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload['method_type'], 'bank');
      expect(payload['account_number'], '0000 0000 0000');
      expect(payload['reference'], 'BUILDING + your name');
      expect(payload['swift_code'], isNull);
      expect(payload.containsKey('identifier'), isFalse);
      expect(payload.containsKey('ussd_code'), isFalse);
      expect(payload.keys.where((k) => _paymentWords.hasMatch('$k')), isEmpty);
    });

    testWidgets('an Admin who saved changes cannot verify them and sees why', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([
          draftAirtel(savedByYou: true),
        ]),
      );
      await tapKey(tester, 'giving-open-$_airtel');
      final verify = tester.widget<OutlinedButton>(
        byKey('giving-verify-$_airtel'),
      );
      expect(verify.onPressed, isNull);
      expect(
        textOf(tester, 'giving-verify-reason-$_airtel'),
        'You saved changes to these details, so a different Admin must '
        'verify them.',
      );
      expect(find.textContaining('Saved by you'), findsOneWidget);
      expect(byKey('giving-publish-$_airtel'), findsNothing);
    });

    testWidgets('a different Admin verifies; a field error keeps the dialog', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([draftAirtel()]),
      );
      await tapKey(tester, 'giving-open-$_airtel');
      expect(byKey('giving-verify-reason-$_airtel'), findsNothing);
      expect(
        find.textContaining('Not verified yet: an Admin who saved none'),
        findsOneWidget,
      );
      await tapKey(tester, 'giving-verify-$_airtel');
      expect(find.text('Verify SAMPLE Airtel Money'), findsOneWidget);
      // The test note's guidance, and the earliest test date (the draft was
      // last saved on Sun 27 Sep church time).
      expect(
        find.text(
          'Say how the details were checked. Don\'t include phone numbers, '
          'amounts or transaction IDs.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'The day of the test: on or after 27 Sep 2026, within the last 90 '
          'days',
        ),
        findsOneWidget,
      );
      final today = ChurchTime.ymd(churchToday());
      expect(
        tester.widget<TextField>(byKey('giving-tested-on')).controller!.text,
        today,
      );
      expect(
        tester.widget<FilledButton>(byKey('giving-verify-send')).onPressed,
        isNull,
        reason: 'how it was tested is required',
      );
      await tester.enterText(byKey('giving-tested-on'), '2026-01-01');
      await tester.enterText(
        byKey('giving-test-method'),
        'SYNTHETIC the provider showed the beneficiary name for this ID.',
      );
      await settle(tester);
      await tapKey(tester, 'giving-verify-send');
      final first = h.gateway.sent.single;
      expect(first.wire['command'], 'content.verify_giving_method');
      expect(first.wire['expected_revision'], 1);
      expect(first.wire['payload'], {
        'method_id': _airtel,
        'tested_on': '2026-01-01',
        'test_method':
            'SYNTHETIC the provider showed the beneficiary name for this ID.',
      });
      first.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'tested_on': 'out_of_range'},
      );
      await settle(tester);
      // Still open, with the reason and what was typed.
      expect(find.text('Verify SAMPLE Airtel Money'), findsOneWidget);
      expect(
        find.text('Use a date in the last 90 days, not in the future'),
        findsOneWidget,
      );
      expect(h.giving.staffMethodsCalls, 1, reason: 'nothing to reload');
      // A test dated before the details were saved is refused too.
      await tester.enterText(byKey('giving-tested-on'), '2026-09-26');
      await settle(tester);
      await tapKey(tester, 'giving-verify-send');
      h.gateway.sent.last.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'tested_on': 'before_saved'},
      );
      await settle(tester);
      expect(find.text('Verify SAMPLE Airtel Money'), findsOneWidget);
      expect(
        find.text(
          'Use the day of the test, on or after the day these details were '
          'saved.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(byKey('giving-test-method')).controller!.text,
        'SYNTHETIC the provider showed the beneficiary name for this ID.',
      );
      expect(h.giving.staffMethodsCalls, 1, reason: 'nothing to reload');
      await tester.enterText(byKey('giving-tested-on'), today);
      await settle(tester);
      expect(
        find.text('Use a date in the last 90 days, not in the future'),
        findsNothing,
      );
      await tapKey(tester, 'giving-verify-send');
      final second = h.gateway.sent.last;
      expect((second.wire['payload'] as Map)['tested_on'], today);
      h.giving.staffMethods = staffMethods([
        draftAirtel(verified: true, revision: 2),
      ]);
      second.confirm({'method_id': _airtel, 'revision': 2}, 2);
      await settle(tester);
      await tester.pump(kAnnouncementAfterDialog);
      await settle(tester);
      expect(find.text('Verify SAMPLE Airtel Money'), findsNothing);
      expect(byKey('giving-notice-verified'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('giving-mark-$_airtel')).label,
        'Verified, ready to publish',
      );
      expect(
        find.textContaining('Verified by SYNTHETIC Admin Banda'),
        findsOneWidget,
      );
      expect(byKey('giving-publish-$_airtel'), findsOneWidget);
    });

    testWidgets('publish a verified draft; a closed gate says so', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) =>
            h.giving.staffMethods = staffMethods([draftAirtel(verified: true)]),
      );
      await tapKey(tester, 'giving-open-$_airtel');
      await tapKey(tester, 'giving-publish-$_airtel');
      final publish = h.gateway.sent.single;
      expect(publish.wire['command'], 'content.publish_giving_method');
      expect(publish.wire['expected_revision'], 1);
      expect(publish.wire['payload'], {'method_id': _airtel});
      publish.refuse(
        ErrorCode.unavailable,
        fieldErrors: const {'policy': 'gate_closed'},
      );
      await settle(tester);
      expect(byKey('giving-notice-gateClosed'), findsOneWidget);
      expect(find.textContaining('owner approves'), findsOneWidget);
      await tapKey(tester, 'giving-publish-$_airtel');
      h.giving.staffMethods = staffMethods([
        staffGivingMethodData(
          revision: 2,
          state: 'published',
          publishedBy: 'SYNTHETIC Admin Mwale',
          publishedAt: '2026-09-28T10:00:00.000000Z',
          live: staffGivingRevisionData(
            publishedBy: 'SYNTHETIC Admin Mwale',
            publishedAt: '2026-09-28T10:00:00.000000Z',
            verification: givingVerificationData(),
          ),
        ),
      ]);
      h.gateway.sent.last.confirm({'method_id': _airtel, 'revision': 2}, 2);
      await settle(tester);
      expect(byKey('giving-notice-published'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('giving-mark-$_airtel')).label,
        'Live',
      );
      expect(find.text('Live in How to give'), findsOneWidget);
      expect(
        find.textContaining('Published by SYNTHETIC Admin Mwale'),
        findsOne,
      );
      expect(byKey('giving-hide-$_airtel'), findsOneWidget);
    });

    testWidgets('a changed account number stays a draft; the live one stays '
        'public', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([liveBank()]),
      );
      await tapKey(tester, 'giving-open-$_bank');
      await tapKey(tester, 'giving-edit-$_bank');
      expect(
        find.textContaining('Givers keep seeing the live details'),
        findsOneWidget,
      );
      expect(find.text('Kind: Bank'), findsOneWidget);
      await tester.enterText(
        byKey('giving-account-number-$_bank'),
        '1111 2222 3333',
      );
      await settle(tester);
      await tapKey(tester, 'giving-save-$_bank');
      final save = h.gateway.sent.single;
      expect(save.wire['command'], 'content.save_giving_method');
      expect(save.wire['expected_revision'], 4);
      final payload = save.wire['payload'] as Map;
      expect(payload['method_id'], _bank);
      expect(payload['account_number'], '1111 2222 3333');
      expect(payload['bank_name'], 'SAMPLE Bank Zambia');
      // A field error keeps the form as typed.
      save.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'swift_code': 'invalid'},
      );
      await settle(tester);
      expect(byKey('giving-notice-invalid'), findsOneWidget);
      expect(find.text('Use an 8 or 11 character SWIFT code'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(byKey('giving-account-number-$_bank'))
            .controller!
            .text,
        '1111 2222 3333',
      );
      await tapKey(tester, 'giving-save-$_bank');
      h.giving.staffMethods = staffMethods([
        {
          ...liveBank(revision: 5),
          'draft': staffGivingRevisionData(
            methodType: 'bank',
            name: 'SAMPLE Bank transfer',
            revisionNo: 2,
            accountNumber: '1111 2222 3333',
            savedByYou: true,
          ),
        },
      ]);
      h.gateway.sent.last.confirm({'method_id': _bank, 'revision': 5}, 5);
      await settle(tester);
      expect(byKey('giving-notice-saved'), findsOneWidget);
      expect(byKey('giving-form-$_bank'), findsNothing);
      expect(
        tester.widget<StatusLabel>(byKey('giving-mark-$_bank')).label,
        'Live, changes need verifying',
      );
      // Both versions are shown: the live number and the draft's, and the
      // verifier is told what changed.
      expect(find.text('0000 0000 0000'), findsOneWidget);
      expect(find.text('1111 2222 3333'), findsOneWidget);
      expect(
        textOf(tester, 'giving-changed-2'),
        'Changed from the live version: Account number.',
      );
      expect(byKey('giving-publish-$_bank'), findsNothing);
      expect(byKey('giving-verify-reason-$_bank'), findsOneWidget);
    });

    testWidgets('a save that changes nothing is refused; the form keeps its '
        'input', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([liveBank()]),
      );
      await tapKey(tester, 'giving-open-$_bank');
      await tapKey(tester, 'giving-edit-$_bank');
      await tapKey(tester, 'giving-save-$_bank');
      final save = h.gateway.sent.single;
      expect(save.wire['command'], 'content.save_giving_method');
      save.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'method_id': 'unchanged'},
      );
      await settle(tester);
      expect(byKey('giving-notice-unchanged'), findsOneWidget);
      expect(
        find.text('Nothing changed, so nothing was saved.'),
        findsOneWidget,
      );
      expect(byKey('giving-form-$_bank'), findsOneWidget);
      expect(byKey('giving-form-unread-$_bank'), findsNothing);
      expect(
        tester
            .widget<TextField>(byKey('giving-account-number-$_bank'))
            .controller!
            .text,
        '0000 0000 0000',
      );
      expect(h.giving.staffMethodsCalls, 1, reason: 'nothing to reload');
    });

    testWidgets('unpublished changes of a live method can be discarded', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([
          {
            ...liveBank(revision: 5),
            'draft': staffGivingRevisionData(
              methodType: 'bank',
              name: 'SAMPLE Bank transfer (new)',
              revisionNo: 2,
              accountNumber: '1111 2222 3333',
            ),
          },
          draftAirtel(position: 2),
        ]),
      );
      // A never-published draft has nothing to go back to: no Discard.
      await tapKey(tester, 'giving-open-$_airtel');
      expect(byKey('giving-discard-$_airtel'), findsNothing);
      expect(byKey('giving-archive-$_airtel'), findsOneWidget);
      await tapKey(tester, 'giving-open-$_bank');
      await tapKey(tester, 'giving-discard-$_bank');
      // Named by the live name givers see.
      expect(
        find.text('Discard the unpublished changes to SAMPLE Bank transfer?'),
        findsOneWidget,
      );
      expect(find.text('Givers keep seeing the live details.'), findsOneWidget);
      await tapKey(tester, 'giving-confirm-yes');
      final discard = h.gateway.sent.single;
      expect(discard.wire['command'], 'content.discard_giving_draft');
      expect(discard.wire['expected_revision'], 5);
      expect(discard.wire['payload'], {'method_id': _bank});
      h.giving.staffMethods = staffMethods([
        liveBank(revision: 6),
        draftAirtel(position: 2),
      ]);
      discard.confirm({
        'method_id': _bank,
        'revision': 6,
        'state': 'published',
        'live_revision_no': 1,
        'draft_revision_no': null,
      }, 6);
      await settle(tester);
      expect(byKey('giving-notice-discarded'), findsOneWidget);
      expect(find.text('Changes discarded'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('giving-mark-$_bank')).label,
        'Live',
      );
      expect(byKey('giving-discard-$_bank'), findsNothing);
      expect(find.text('1111 2222 3333'), findsNothing);
    });

    testWidgets('move up and down send the new position at once', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([
          draftAirtel(position: 1, revision: 3),
          liveBank(position: 2),
        ]),
      );
      expect(
        tester.widget<IconButton>(byKey('giving-up-$_airtel')).onPressed,
        isNull,
      );
      expect(
        tester.widget<IconButton>(byKey('giving-down-$_bank')).onPressed,
        isNull,
      );
      expect(
        tester.widget<IconButton>(byKey('giving-up-$_airtel')).tooltip,
        'Move SAMPLE Airtel Money up',
      );
      await tapKey(tester, 'giving-up-$_bank');
      final move = h.gateway.sent.single;
      expect(move.wire['command'], 'content.move_giving_method');
      expect(move.wire['expected_revision'], 4);
      expect(move.wire['payload'], {'method_id': _bank, 'position': 1});
      h.giving.staffMethods = staffMethods([
        liveBank(position: 1, revision: 5),
        draftAirtel(position: 2, revision: 3),
      ]);
      move.confirm({'method_id': _bank, 'revision': 5}, 5);
      await settle(tester);
      expect(byKey('giving-notice-moved'), findsOneWidget);
      expect(
        tester.getTopLeft(byKey('giving-$_bank')).dy,
        lessThan(tester.getTopLeft(byKey('giving-$_airtel')).dy),
      );
      await tapKey(tester, 'giving-down-$_bank');
      expect(h.gateway.sent.last.wire['payload'], {
        'method_id': _bank,
        'position': 2,
      });
    });

    testWidgets('hide and archive ask first', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) => h.giving.staffMethods = staffMethods([liveBank()]),
      );
      await tapKey(tester, 'giving-open-$_bank');
      await tapKey(tester, 'giving-hide-$_bank');
      expect(find.text('Hide SAMPLE Bank transfer?'), findsOneWidget);
      await tapKey(tester, 'giving-confirm-yes');
      final hide = h.gateway.sent.single;
      expect(hide.wire['command'], 'content.hide_giving_method');
      h.giving.staffMethods = staffMethods([
        {
          ...liveBank(revision: 5),
          'state': 'withdrawn',
          'withdrawn_at': '2026-09-29T08:00:00.000000Z',
        },
      ]);
      hide.confirm({'method_id': _bank, 'revision': 5}, 5);
      await settle(tester);
      expect(byKey('giving-notice-hidden'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('giving-mark-$_bank')).label,
        'Hidden',
      );
      expect(find.text('Publish again'), findsOneWidget);
      await tapKey(tester, 'giving-archive-$_bank');
      await tapKey(tester, 'giving-confirm-yes');
      expect(
        h.gateway.sent.last.wire['command'],
        'content.archive_giving_method',
      );
      expect(h.gateway.sent.last.wire['expected_revision'], 5);
    });

    testWidgets('every refusal has a plain message', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) =>
            h.giving.staffMethods = staffMethods([draftAirtel(verified: true)]),
      );
      await tapKey(tester, 'giving-open-$_airtel');
      for (final (code, fields, notice) in [
        (
          ErrorCode.validationFailed,
          {'method_id': 'nothing_to_verify'},
          'nothingToVerify',
        ),
        (
          ErrorCode.validationFailed,
          {'method_id': 'already_verified'},
          'alreadyVerified',
        ),
        (
          ErrorCode.validationFailed,
          {'method_id': 'saved_by_you'},
          'savedByYou',
        ),
        (ErrorCode.validationFailed, {'method_id': 'unchanged'}, 'unchanged'),
        (
          ErrorCode.validationFailed,
          {'method_id': 'nothing_to_discard'},
          'nothingToDiscard',
        ),
        (
          ErrorCode.validationFailed,
          {'method_id': 'never_published'},
          'neverPublished',
        ),
        (
          ErrorCode.validationFailed,
          {'method_id': 'not_verified'},
          'notVerified',
        ),
        (
          ErrorCode.validationFailed,
          {'method_id': 'nothing_to_publish'},
          'nothingToPublish',
        ),
        (
          ErrorCode.validationFailed,
          {'method_id': 'not_published'},
          'notPublished',
        ),
        (
          ErrorCode.validationFailed,
          {'method_id': 'archived'},
          'alreadyArchived',
        ),
        (ErrorCode.validationFailed, {'name': 'sample_only'}, 'sampleOnly'),
        (
          ErrorCode.validationFailed,
          {'position': 'out_of_range'},
          'positionOutOfRange',
        ),
        (ErrorCode.validationFailed, {'amount': 'unknown_field'}, 'invalid'),
        (ErrorCode.unavailable, {'policy': 'gate_closed'}, 'gateClosed'),
        (ErrorCode.unavailable, <String, String>{}, 'notAvailable'),
        (ErrorCode.conflict, <String, String>{}, 'changedElsewhere'),
        (ErrorCode.notFound, <String, String>{}, 'notFound'),
        (ErrorCode.forbidden, <String, String>{}, 'notAllowed'),
        (ErrorCode.unauthenticated, <String, String>{}, 'signInAgain'),
      ]) {
        await tapKey(tester, 'giving-publish-$_airtel');
        h.gateway.sent.last.refuse(code, fieldErrors: fields);
        await settle(tester);
        expect(byKey('giving-notice-$notice'), findsOneWidget, reason: notice);
        final banner = tester.widget<RequestStateBanner>(
          byKey('giving-notice-$notice'),
        );
        expect(banner.message, isNot(contains('_')), reason: notice);
        expect(banner.message, isNotEmpty, reason: notice);
      }
    });

    testWidgets('an unknown outcome resends the same request', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentGiving,
        staff: true,
        setUp: (h) =>
            h.giving.staffMethods = staffMethods([draftAirtel(verified: true)]),
      );
      await tapKey(tester, 'giving-open-$_airtel');
      await tapKey(tester, 'giving-publish-$_airtel');
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(byKey('giving-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'giving-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(
        h.gateway.sent.last.wire['request_id'],
        h.gateway.sent.first.wire['request_id'],
      );
    });
  });
}
