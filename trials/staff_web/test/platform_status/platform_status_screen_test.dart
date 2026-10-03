import 'package:staff_web_trial/platform_status/platform_status.dart';
import 'package:staff_web_trial/platform_status/platform_status_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform_status_repository.dart';

Future<FakePlatformStatusRepository> pumpScreen(WidgetTester tester) async {
  final repo = FakePlatformStatusRepository();
  await tester.pumpWidget(
    MaterialApp(home: PlatformStatusScreen(repository: repo)),
  );
  return repo;
}

void main() {
  testWidgets('shows loading, then the status, message and updated time', (
    tester,
  ) async {
    final repo = await pumpScreen(tester);
    expect(find.byKey(const Key('state-loading')), findsOneWidget);
    expect(find.text('Loading platform status…'), findsOneWidget);

    repo.requests.single.complete(sampleStatus);
    await tester.pump();

    expect(find.byKey(const Key('state-data')), findsOneWidget);
    expect(find.text('Status: operational'), findsOneWidget);
    expect(find.text('SYNTHETIC tracer status'), findsOneWidget);
    expect(find.text('Updated 2026-10-03 09:05 UTC'), findsOneWidget);
    expect(find.text('Synthetic test data'), findsOneWidget);
  });

  testWidgets('zero rows shows the empty state, distinct from an error', (
    tester,
  ) async {
    final repo = await pumpScreen(tester);
    repo.requests.single.complete(null);
    await tester.pump();

    expect(find.byKey(const Key('state-empty')), findsOneWidget);
    expect(find.text('No platform status recorded'), findsOneWidget);
    expect(find.byKey(const Key('state-error')), findsNothing);
    expect(find.text("Couldn't reach the server"), findsNothing);
  });

  testWidgets('unreachable shows the error panel; Try again re-requests', (
    tester,
  ) async {
    final repo = await pumpScreen(tester);
    repo.requests.single.completeError(
      const PlatformStatusException(PlatformStatusFailure.unreachable),
    );
    await tester.pump();

    expect(find.byKey(const Key('state-error')), findsOneWidget);
    expect(find.text("Couldn't reach the server"), findsOneWidget);
    expect(find.byKey(const Key('state-data')), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(repo.calls, 2, reason: 'retry must send a fresh request');
    expect(find.byKey(const Key('state-loading')), findsOneWidget);

    repo.requests.last.complete(sampleStatus);
    await tester.pump();
    expect(find.text('Status: operational'), findsOneWidget);
    expect(find.byKey(const Key('state-error')), findsNothing);
  });

  testWidgets('a server error is reported differently from no network', (
    tester,
  ) async {
    final repo = await pumpScreen(tester);
    repo.requests.single.completeError(
      const PlatformStatusException(PlatformStatusFailure.rejected),
    );
    await tester.pump();

    expect(
      find.text("The server couldn't provide the platform status"),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('reload hides the old value while the new request runs', (
    tester,
  ) async {
    final repo = await pumpScreen(tester);
    repo.requests.single.complete(sampleStatus);
    await tester.pump();

    await tester.tap(find.byKey(const Key('reload')));
    await tester.pump();
    expect(repo.calls, 2);
    expect(find.text('Status: operational'), findsNothing);

    repo.requests.last.completeError(
      const PlatformStatusException(PlatformStatusFailure.unreachable),
    );
    await tester.pump();
    expect(find.text("Couldn't reach the server"), findsOneWidget);
    expect(find.text('Status: operational'), findsNothing);
  });

  testWidgets('actions meet the minimum tap target', (tester) async {
    final repo = await pumpScreen(tester);
    repo.requests.single.completeError(
      const PlatformStatusException(PlatformStatusFailure.unreachable),
    );
    await tester.pump();

    final retry = tester.getSize(
      find.widgetWithText(FilledButton, 'Try again'),
    );
    expect(retry.height, greaterThanOrEqualTo(44));
    final reload = tester.getSize(find.byKey(const Key('reload')));
    expect(reload.height, greaterThanOrEqualTo(44));
    expect(reload.width, greaterThanOrEqualTo(44));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  });
}
