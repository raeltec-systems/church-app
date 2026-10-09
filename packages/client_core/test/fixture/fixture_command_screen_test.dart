import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Harness = ClientTestHarness;

Future<Harness> pumpFixture(
  WidgetTester tester, {
  String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool configured = true,
}) async {
  final h = ClientTestHarness(account: account);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(configured: configured),
      child: MaterialApp(
        theme: churchMobileTheme(brightness),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: const FixtureCommandScreen(),
        ),
      ),
    ),
  );
  return h;
}

final Finder intentField = find.byKey(const Key('intent-key-field'));
final Finder byField = find.byKey(const Key('by-field'));

TextField field(WidgetTester tester, Finder f) => tester.widget<TextField>(f);

bool enabled(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(Key(key))).onPressed != null;

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
}

/// Creates a counter and confirms it at revision 1.
Future<void> createConfirmed(
  WidgetTester tester,
  Harness h, {
  int value = 0,
}) async {
  await tester.enterText(intentField, 'synthetic-demo');
  await tapKey(tester, 'create-button');
  h.gateway.sent.last.confirm(fixtureCounterData(value: value), 1);
  await tester.pump();
}

/// Whether keyboard focus sits inside the widget keyed [key].
bool focusIn(String key) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget.key == Key(key)) return true;
  var found = false;
  ctx.visitAncestorElements((e) {
    found = e.widget.key == Key(key);
    return !found;
  });
  return found;
}

List<String> announced(WidgetTester tester) =>
    tester.takeAnnouncements().map((a) => a.message).toList();

void main() {
  testWidgets('pending: Sending…, inputs read-only, no success claimed', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await tester.enterText(intentField, 'synthetic-demo');
    await tapKey(tester, 'create-button');

    expect(find.byKey(const Key('state-pending')), findsOneWidget);
    expect(find.text('Sending…'), findsOneWidget);
    expect(field(tester, intentField).readOnly, isTrue);
    expect(enabled(tester, 'create-button'), isFalse);
    expect(find.textContaining('Saved'), findsNothing);
    expect(find.byKey(const Key('counter-card')), findsNothing);

    final wire = h.gateway.sent.single.wire;
    expect(h.gateway.sent.single.function, 'fixture_counter_command');
    expect(wire, {
      'version': 1,
      'command': 'fixture_counter.create',
      'request_id': '00000000-0000-4000-8000-000000000001',
      'expected_revision': null,
      'payload': {'intent_key': 'synthetic-demo'},
    });
    expect(check(ContractKind.commandRequest, wire).valid, isTrue);
  });

  testWidgets('success: only a server success envelope shows Saved', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await createConfirmed(tester, h, value: 7);
    expect(find.byKey(const Key('state-confirmed')), findsOneWidget);
    expect(find.text('Value 7'), findsOneWidget);
    expect(find.text('Confirmed by server · revision 1'), findsOneWidget);

    await tester.enterText(byField, '3');
    await tapKey(tester, 'increment-button');
    expect(h.gateway.sent.last.wire['expected_revision'], 1);
    expect(h.gateway.sent.last.wire['payload'], {
      'counter_id': '11111111-1111-4111-8111-111111111111',
      'by': 3,
    });
    // A new command gets a new request id.
    expect(
      h.gateway.sent.last.request.requestId,
      isNot(h.gateway.sent.first.request.requestId),
    );
  });

  testWidgets('validation: field message, input kept and editable', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await tester.enterText(intentField, 'synthetic-demo');
    await tapKey(tester, 'create-button');
    h.gateway.sent.single.refuse(
      ErrorCode.validationFailed,
      fieldErrors: {'intent_key': 'required'},
    );
    await tester.pump();

    expect(find.byKey(const Key('state-validation')), findsOneWidget);
    expect(
      find.text('Enter an intent key of 1 to 100 characters.'),
      findsOneWidget,
    );
    expect(field(tester, intentField).readOnly, isFalse);
    expect(field(tester, intentField).controller!.text, 'synthetic-demo');
    expect(enabled(tester, 'create-button'), isTrue);
  });

  testWidgets('local validation never sends', (tester) async {
    final h = await pumpFixture(tester);
    await tapKey(tester, 'create-button');
    expect(h.gateway.sent, isEmpty);
    expect(
      find.text('Enter an intent key of 1 to 100 characters.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'conflict: input kept, expected_revision never silently replaced, reload',
    (tester) async {
      final h = await pumpFixture(tester);
      await createConfirmed(tester, h);
      await tester.enterText(byField, '5');
      await tapKey(tester, 'increment-button');
      expect(h.gateway.sent.last.wire['expected_revision'], 1);
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        currentRevision: const Optional.of(3),
      );
      await tester.pump();

      expect(find.byKey(const Key('state-conflict')), findsOneWidget);
      expect(
        find.textContaining('the server is at revision 3'),
        findsOneWidget,
      );
      expect(field(tester, byField).controller!.text, '5');
      expect(enabled(tester, 'increment-button'), isFalse);
      // The confirmed snapshot is unchanged.
      expect(find.text('Confirmed by server · revision 1'), findsOneWidget);

      // Reload without a read endpoint: stays in conflict, says why.
      await tapKey(tester, 'reload-button');
      await tester.pump();
      expect(h.reader.calls, 1);
      expect(find.byKey(const Key('state-conflict')), findsOneWidget);
      expect(find.textContaining("Couldn't reload"), findsOneWidget);
      expect(enabled(tester, 'increment-button'), isFalse);
      expect(h.gateway.sent, hasLength(2));

      // A successful reload replaces the snapshot; the entry is still kept.
      h.reader.next = FixtureCounter.fromCommandData(
        fixtureCounterData(value: 9),
        3,
      );
      await tapKey(tester, 'reload-button');
      await tester.pump();
      expect(find.byKey(const Key('state-reloaded')), findsOneWidget);
      expect(find.text('Value 9'), findsOneWidget);
      expect(field(tester, byField).controller!.text, '5');
      expect(enabled(tester, 'increment-button'), isTrue);
      await tapKey(tester, 'increment-button');
      expect(h.gateway.sent.last.wire['expected_revision'], 3);
    },
  );

  testWidgets(
    'unavailable: nothing changed, Try again resends the same request',
    (tester) async {
      final h = await pumpFixture(tester);
      await createConfirmed(tester, h);
      await tester.enterText(byField, '2');
      await tapKey(tester, 'increment-button');
      final first = h.gateway.sent.last;
      first.refuse(ErrorCode.unavailable);
      await tester.pump();

      expect(find.byKey(const Key('state-unavailable')), findsOneWidget);
      expect(find.text('Not saved: service unavailable'), findsOneWidget);
      expect(field(tester, byField).controller!.text, '2');
      expect(find.text('Confirmed by server · revision 1'), findsOneWidget);

      await tapKey(tester, 'try-again-button');
      expect(h.gateway.sent, hasLength(3));
      expect(h.gateway.sent.last.wire, first.wire);
    },
  );

  testWidgets(
    'unknown outcome: locked, never success, Check again resends the same id',
    (tester) async {
      final h = await pumpFixture(tester);
      await createConfirmed(tester, h);
      await tester.enterText(byField, '4');
      await tapKey(tester, 'increment-button');
      final first = h.gateway.sent.last;
      first.unknown();
      await tester.pump();

      expect(find.byKey(const Key('state-unknown')), findsOneWidget);
      expect(find.text('Not confirmed'), findsOneWidget);
      expect(find.byKey(const Key('state-confirmed')), findsNothing);
      expect(find.text('Value 0'), findsOneWidget);
      expect(field(tester, byField).readOnly, isTrue);
      expect(enabled(tester, 'increment-button'), isFalse);
      expect(enabled(tester, 'create-button'), isFalse);

      await tapKey(tester, 'check-again-button');
      final second = h.gateway.sent.last;
      expect(second, isNot(same(first)));
      expect(second.request.requestId, first.request.requestId);
      expect(second.wire, first.wire);
      // The stored receipt answers: the change had applied once.
      second.confirm(fixtureCounterData(value: 4), 2);
      await tester.pump();
      expect(find.byKey(const Key('state-confirmed')), findsOneWidget);
      expect(find.text('Value 4'), findsOneWidget);
    },
  );

  testWidgets('unknown outcome: Stop checking keeps the outcome open', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await createConfirmed(tester, h);
    await tapKey(tester, 'increment-button');
    h.gateway.sent.last.unknown();
    await tester.pump();
    await tapKey(tester, 'discard-button');
    expect(find.byKey(const Key('state-discarded')), findsOneWidget);
    expect(find.textContaining('may still have been applied'), findsOneWidget);
    expect(find.text('Confirmed by server · revision 1'), findsOneWidget);
  });

  testWidgets('a malformed success body is unknown outcome, not success', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await tester.enterText(intentField, 'synthetic-demo');
    await tapKey(tester, 'create-button');
    h.gateway.sent.single.confirm({'id': 42}, 1);
    await tester.pump();
    expect(find.byKey(const Key('state-unknown')), findsOneWidget);
    expect(find.byKey(const Key('counter-card')), findsNothing);
  });

  for (final (code, text) in [
    (ErrorCode.unauthenticated, 'Not saved: sign-in required'),
    (ErrorCode.forbidden, 'Not saved: not allowed'),
    (ErrorCode.notFound, 'Not saved: counter not found'),
  ]) {
    testWidgets('denied ${code.wireName}: specific text, input kept', (
      tester,
    ) async {
      final h = await pumpFixture(tester);
      await tester.enterText(intentField, 'synthetic-demo');
      await tapKey(tester, 'create-button');
      h.gateway.sent.single.refuse(code);
      await tester.pump();
      expect(find.byKey(const Key('state-denied')), findsOneWidget);
      expect(find.text(text), findsOneWidget);
      expect(field(tester, intentField).controller!.text, 'synthetic-demo');
    });
  }

  testWidgets('create conflict (duplicate intent key) does not block changes', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await createConfirmed(tester, h);
    await tapKey(tester, 'create-button');
    h.gateway.sent.last.refuse(ErrorCode.conflict);
    await tester.pump();
    expect(find.byKey(const Key('state-conflict-create')), findsOneWidget);
    expect(enabled(tester, 'increment-button'), isTrue);
  });

  testWidgets('account switch clears protected state and input, with notice', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await createConfirmed(tester, h, value: 7);
    await tester.enterText(byField, '9');
    expect(find.text('Value 7'), findsOneWidget);

    h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('state-account-changed')), findsOneWidget);
    expect(find.text('The signed-in account changed'), findsOneWidget);
    expect(find.text('Value 7'), findsNothing);
    expect(find.byKey(const Key('no-counter')), findsOneWidget);
    expect(field(tester, intentField).controller!.text, isEmpty);
    expect(byField, findsNothing);

    await tapKey(tester, 'dismiss-account-change');
    expect(find.byKey(const Key('state-account-changed')), findsNothing);
    expect(find.byKey(const Key('no-counter')), findsOneWidget);
  });

  testWidgets('sign-out mid-request: late response is discarded', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await tester.enterText(intentField, 'synthetic-demo');
    await tapKey(tester, 'create-button');
    expect(find.byKey(const Key('state-pending')), findsOneWidget);

    h.session.switchTo(null);
    await tester.pump();
    await tester.pump();
    expect(find.text('You were signed out'), findsOneWidget);
    expect(find.byKey(const Key('state-pending')), findsNothing);

    h.gateway.sent.single.confirm(fixtureCounterData(value: 1), 1);
    await tester.pump();
    expect(find.byKey(const Key('counter-card')), findsNothing);
    expect(find.byKey(const Key('state-confirmed')), findsNothing);
    expect(find.textContaining('Not signed in'), findsOneWidget);
  });

  testWidgets('keyboard: Tab reaches field then button; Enter submits', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await tester.enterText(intentField, 'kb');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(h.gateway.sent, hasLength(1));
    h.gateway.sent.single.confirm(fixtureCounterData(), 1);
    await tester.pump();

    // Tab order: intent field -> Create -> Change by -> Apply change.
    final order = <String>[];
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final ctx = FocusManager.instance.primaryFocus!.context!;
      final key =
          ctx.findAncestorWidgetOfExactType<FilledButton>()?.key ??
          ctx.findAncestorWidgetOfExactType<TextField>()?.key;
      order.add('$key');
    }
    expect(order, [
      "[<'intent-key-field'>]",
      "[<'create-button'>]",
      "[<'by-field'>]",
      "[<'increment-button'>]",
    ]);
  });

  group('focus follows the request state', () {
    testWidgets('submit moves focus to Sending…, then to the outcome', (
      tester,
    ) async {
      final h = await pumpFixture(tester);
      await tester.enterText(intentField, 'synthetic-demo');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-pending'), isTrue);
      h.gateway.sent.last.unknown();
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-unknown'), isTrue);

      // Check again: pending, then the result.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusIn('check-again-button'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-pending'), isTrue);
      h.gateway.sent.last.refuse(ErrorCode.unavailable);
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-unavailable'), isTrue);

      // Try again: pending, then confirmed.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusIn('try-again-button'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      h.gateway.sent.last.confirm(fixtureCounterData(), 1);
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-confirmed'), isTrue);
    });

    testWidgets('Stop checking and Reload move focus to their result', (
      tester,
    ) async {
      final h = await pumpFixture(tester);
      await createConfirmed(tester, h);
      await tapKey(tester, 'increment-button');
      h.gateway.sent.last.unknown();
      await tester.pump();
      await tapKey(tester, 'discard-button');
      await tester.pump();
      expect(focusIn('state-discarded'), isTrue);

      await tapKey(tester, 'increment-button');
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        currentRevision: const Optional.of(3),
      );
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-conflict'), isTrue);
      await tapKey(tester, 'reload-button');
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-conflict'), isTrue);
      h.reader.next = FixtureCounter.fromCommandData(fixtureCounterData(), 3);
      await tapKey(tester, 'reload-button');
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-reloaded'), isTrue);
    });

    testWidgets('account notice takes focus; Dismiss returns to the form', (
      tester,
    ) async {
      final h = await pumpFixture(tester);
      h.session.switchTo(null);
      await tester.pump();
      await tester.pump();
      expect(focusIn('state-account-changed'), isTrue);
      await tapKey(tester, 'dismiss-account-change');
      await tester.pump();
      expect(focusIn('intent-key-field'), isTrue);
    });
  });

  group('announcements', () {
    testWidgets('outcomes, failed reload, reloaded and stopped checking', (
      tester,
    ) async {
      final h = await pumpFixture(tester);
      await createConfirmed(tester, h, value: 2);
      expect(announced(tester), contains('Saved. Value 2, revision 1.'));

      await tapKey(tester, 'increment-button');
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        currentRevision: const Optional.of(3),
      );
      await tester.pump();
      expect(
        announced(tester),
        contains(
          'Not saved. The counter changed. Reload before applying again.',
        ),
      );
      await tapKey(tester, 'reload-button');
      await tester.pump();
      expect(announced(tester).last, "Couldn't reload. test: no read endpoint");
      h.reader.next = FixtureCounter.fromCommandData(fixtureCounterData(), 3);
      await tapKey(tester, 'reload-button');
      await tester.pump();
      expect(announced(tester).last, 'Reloaded. The counter is at revision 3.');

      await tapKey(tester, 'increment-button');
      h.gateway.sent.last.unknown();
      await tester.pump();
      expect(announced(tester).last, 'Not confirmed. Check again.');
      await tapKey(tester, 'discard-button');
      expect(
        announced(tester).last,
        'Stopped checking. The last change may still have been applied.',
      );
    });

    testWidgets('account switch and sign-out are announced', (tester) async {
      final h = await pumpFixture(tester);
      h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await tester.pump();
      await tester.pump();
      expect(
        announced(tester).single,
        'The signed-in account changed. Information and unsent changes from '
        'the previous account were cleared from this screen.',
      );
      h.session.switchTo(null);
      await tester.pump();
      await tester.pump();
      expect(announced(tester).single, startsWith('You were signed out.'));
    });
  });

  testWidgets('unavailable then edited: Try again is withdrawn, never stale', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await createConfirmed(tester, h);
    await tester.enterText(byField, '2');
    await tapKey(tester, 'increment-button');
    final first = h.gateway.sent.last;
    first.refuse(ErrorCode.unavailable);
    await tester.pump();
    expect(find.byKey(const Key('try-again-button')), findsOneWidget);

    await tester.enterText(byField, '3');
    await tester.pump();
    expect(find.byKey(const Key('try-again-button')), findsNothing);
    expect(find.textContaining('You edited your entry'), findsOneWidget);
    await tapKey(tester, 'increment-button');
    final second = h.gateway.sent.last;
    expect((second.wire['payload']! as Map)['by'], 3);
    expect(second.request.requestId, isNot(first.request.requestId));
    second.confirm(fixtureCounterData(value: 3), 2);
    await tester.pump();
    expect(find.text('Value 3'), findsOneWidget);
  });

  testWidgets('after Stop checking, the same input keeps its request id', (
    tester,
  ) async {
    final h = await pumpFixture(tester);
    await createConfirmed(tester, h);
    await tester.enterText(byField, '4');
    await tapKey(tester, 'increment-button');
    final first = h.gateway.sent.last;
    first.unknown();
    await tester.pump();
    await tapKey(tester, 'discard-button');

    await tapKey(tester, 'increment-button');
    final again = h.gateway.sent.last;
    expect(again.request.requestId, first.request.requestId);
    expect(again.wire, first.wire);
    again.refuse(ErrorCode.unavailable);
    await tester.pump();

    // A changed input is a new request.
    await tester.enterText(byField, '5');
    await tapKey(tester, 'increment-button');
    expect(
      h.gateway.sent.last.request.requestId,
      isNot(first.request.requestId),
    );
  });

  testWidgets('unconfigured build: the command is reported as not sent', (
    tester,
  ) async {
    await pumpFixture(tester, configured: false);
    await tester.enterText(intentField, 'synthetic-demo');
    await tapKey(tester, 'create-button');
    await tester.pump();
    expect(find.byKey(const Key('state-not-sent')), findsOneWidget);
    expect(find.text('Not sent: no server configured'), findsOneWidget);
    expect(find.text(UnconfiguredCommandGateway.reason), findsOneWidget);
    expect(find.byKey(const Key('try-again-button')), findsNothing);
    expect(find.byKey(const Key('check-again-button')), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('2x text, $brightness: every state renders without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = await pumpFixture(tester, textScale: 2, brightness: brightness);
      await createConfirmed(tester, h);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'increment-button');
      expect(tester.takeException(), isNull); // pending
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        currentRevision: const Optional.of(2),
      );
      await tester.pump();
      await tapKey(tester, 'reload-button');
      await tester.pump();
      expect(tester.takeException(), isNull); // conflict + reload problem
      h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull); // account changed
      await tester.enterText(intentField, 'x');
      await tapKey(tester, 'create-button');
      h.gateway.sent.last.unknown();
      await tester.pump();
      expect(tester.takeException(), isNull); // unknown outcome
      await tapKey(tester, 'check-again-button');
      h.gateway.sent.last.refuse(ErrorCode.unavailable);
      await tester.pump();
      expect(tester.takeException(), isNull); // unavailable
      for (final b in find.byType(FilledButton).evaluate()) {
        expect(
          tester.getSize(find.byWidget(b.widget)).height,
          greaterThanOrEqualTo(ChurchGeometry.minTarget),
        );
      }
    });
  }
}
