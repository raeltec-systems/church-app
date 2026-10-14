// Story 3.1: drives the REAL client adapters (SupabaseCommandGateway and
// SupabaseInboxRepository) against a running LOCAL stack. Member A runs the
// synthetic source command, the real worker script turns the due job into an
// inbox item, and two clients of A (mobile and staff web) read the same single
// item, while member B and a signed-out client see nothing. Story 3.2: the
// staff client opens the item (current, with its target) and B cannot.
//
//   dart run tool/live_inbox_check.dart <env-file> <member-a-email> <member-b-email>
//
// The accounts are SYNTHETIC (created, linked and cleaned up by
// tools/identity-e2e/live-inbox-check.sh); they sign in through their verified
// email alias (same account and predicate as phone sign-in). The password
// comes from LIVE_CHECK_PASSWORD and the worker's local credential from
// NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL (passed on to the worker only).
// Publishable key only; prints outcomes, never tokens, passwords or ids.
import 'dart:io';

import 'package:church_client_core/src/domain/access_grants.dart';
import 'package:church_client_core/src/domain/commands.dart';
import 'package:church_client_core/src/domain/inbox.dart';
import 'package:church_client_core/src/domain/notification_settings.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: <env-file> <member-a-email> <member-b-email>');
    exit(2);
  }
  final env = <String, String>{};
  for (final line in File(args[0]).readAsLinesSync()) {
    final i = line.indexOf('=');
    if (i > 0) {
      env[line.substring(0, i)] = line.substring(i + 1).replaceAll('"', '');
    }
  }
  final url = env['API_URL'];
  final key = env['PUBLISHABLE_KEY'];
  final password = Platform.environment['LIVE_CHECK_PASSWORD'];
  final credential =
      Platform.environment['NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL'];
  if (url != 'http://127.0.0.1:54321' ||
      key == null ||
      password == null ||
      credential == null) {
    stderr.writeln(
      'LOCAL only; set LIVE_CHECK_PASSWORD and NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL.',
    );
    exit(2);
  }
  for (final e in args.skip(1)) {
    if (!RegExp(r'^synthetic-3-1-live-[a-z0-9-]+@example\.test$').hasMatch(e)) {
      stderr.writeln('refusing a non-synthetic email');
      exit(2);
    }
  }
  SupabaseClient client() => SupabaseClient(
    url!,
    key,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final mobileA = client();
  final staffA = client();
  final mobileB = client();
  final signedOut = client();
  await mobileA.auth.signInWithPassword(email: args[1], password: password);
  await staffA.auth.signInWithPassword(email: args[1], password: password);
  await mobileB.auth.signInWithPassword(email: args[2], password: password);

  var ok = true;
  void report(String step, bool pass, Object detail) {
    ok = ok && pass;
    stdout.writeln('${pass ? 'PASS' : 'FAIL'} $step: $detail');
  }

  String items(AccessRead<Inbox> r) => switch (r) {
    AccessReadOk(:final value) =>
      value.items.map((i) => i.reminderKind).join(','),
    AccessReadDenied(:final denial) => 'denied:${denial.name}',
    AccessReadFailed() => 'failed',
  };
  List<String> ids(AccessRead<Inbox> r) => r is AccessReadOk<Inbox>
      ? r.value.items.map((i) => i.itemId).toList()
      : const [];

  final before = await SupabaseInboxRepository(mobileA).fetchMyInbox();
  report(
    'L1 member A starts with an empty inbox',
    items(before) == '',
    items(before),
  );

  final created = await SupabaseCommandGateway(mobileA).send(
    'fixture_reminder_command',
    CommandRequest(
      command: 'fixture.reminder_create',
      requestId: SecureRequestIds().next(),
      expectedRevision: const Optional.of(null),
      payload: {
        'due_at': Instant.fromDateTime(
          DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        ).wire,
      },
    ),
  );
  report(
    'L2 synthetic source command (command gateway)',
    created is CommandConfirmed && created.success.revision == 1,
    created.runtimeType,
  );

  final worker = await Process.run(
    'node',
    ['../../tools/notifications/worker.mjs', 'run-once'],
    environment: {
      'SUPABASE_URL': url!,
      'SUPABASE_PUBLISHABLE_KEY': key,
      'NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL': credential,
    },
  );
  report(
    'L3 worker run through the system route',
    worker.exitCode == 0 && '${worker.stdout}'.contains('"delivered":1'),
    'exit ${worker.exitCode}',
  );

  final onMobile = await SupabaseInboxRepository(mobileA).fetchMyInbox();
  final onStaff = await SupabaseInboxRepository(staffA).fetchMyInbox();
  report(
    'L4 mobile client shows the one item',
    items(onMobile) == 'fixture_due',
    items(onMobile),
  );
  report(
    'L5 staff web client shows the same single item',
    items(onStaff) == 'fixture_due' &&
        ids(onStaff).length == 1 &&
        ids(onStaff).first == ids(onMobile).firstOrNull,
    items(onStaff),
  );

  final other = await SupabaseInboxRepository(mobileB).fetchMyInbox();
  report('L6 member B sees nothing', items(other) == '', items(other));
  final nobody = await SupabaseInboxRepository(signedOut).fetchMyInbox();
  report(
    'L7 a signed-out client sees nothing',
    items(nobody) == 'denied:signedOut',
    items(nobody),
  );

  // Story 3.2: opening the item re-reads its source on the server.
  String opened(AccessRead<OpenedInboxItem> r) => switch (r) {
    AccessReadOk(:final value) =>
      '${value.state.name}${value.target == null ? '' : ':target'}',
    AccessReadDenied(:final denial) => 'denied:${denial.name}',
    AccessReadFailed() => 'failed',
  };
  final itemId = ids(onMobile).firstOrNull ?? '';
  final openA = await SupabaseInboxRepository(staffA).openItem(itemId);
  report(
    'L9 staff web opens the item: current, with its target',
    opened(openA) == 'current:target' &&
        openA is AccessReadOk<OpenedInboxItem> &&
        openA.value.item?.title == 'SYNTHETIC test reminder',
    opened(openA),
  );
  final openB = await SupabaseInboxRepository(mobileB).openItem(itemId);
  report(
    'L10 member B opening it learns nothing',
    opened(openB) == 'notFound',
    opened(openB),
  );

  // Story 3.7: markers, the refresh signal, snooze and settings through the
  // real adapters (SupabaseInboxSignals joins the private Realtime channel).
  final listed = await SupabaseInboxRepository(mobileA).fetchMyInbox();
  final firstItem = listed is AccessReadOk<Inbox>
      ? listed.value.items.firstOrNull
      : null;
  report(
    'L11 the opened item is listed as opened (never as delivered)',
    firstItem?.opened == true && firstItem?.snoozedUntil == null,
    'opened ${firstItem?.opened}',
  );

  final authA = mobileA.auth.currentUser!.id;
  final authB = mobileB.auth.currentUser!.id;
  var joinedA = 0, signalsA = 0, joinedB = 0, signalsB = 0;
  final subA = SupabaseInboxSignals(mobileA).changes(authA).listen((_) {
    if (joinedA == 0) {
      joinedA++;
    } else {
      signalsA++;
    }
  });
  final subB = SupabaseInboxSignals(mobileB).changes(authB).listen((_) {
    if (joinedB == 0) {
      joinedB++;
    } else {
      signalsB++;
    }
  });
  Future<void> waitFor(bool Function() done, [int seconds = 10]) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  await waitFor(() => joinedA > 0 && joinedB > 0);
  report(
    'L12 each member joins their own private channel',
    joinedA == 1 && joinedB == 1,
    'joined $joinedA/$joinedB',
  );

  final second = await SupabaseCommandGateway(mobileA).send(
    'fixture_reminder_command',
    CommandRequest(
      command: 'fixture.reminder_create',
      requestId: SecureRequestIds().next(),
      payload: {
        'due_at': Instant.fromDateTime(
          DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        ).wire,
      },
    ),
  );
  final worker2 = await Process.run(
    'node',
    ['../../tools/notifications/worker.mjs', 'run-once'],
    environment: {
      'SUPABASE_URL': url,
      'SUPABASE_PUBLISHABLE_KEY': key,
      'NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL': credential,
    },
  );
  await waitFor(() => signalsA > 0);
  await Future<void>.delayed(const Duration(seconds: 1));
  report(
    'L13 a delivery signals A\'s open inbox, and not B\'s',
    second is CommandConfirmed &&
        '${worker2.stdout}'.contains('"delivered":1') &&
        signalsA >= 1 &&
        signalsB == 0,
    'signals $signalsA/$signalsB',
  );
  final withNew = await SupabaseInboxRepository(mobileA).fetchMyInbox();
  final newItem = withNew is AccessReadOk<Inbox>
      ? withNew.value.items.firstOrNull
      : null;
  report(
    'L14 the re-read shows the new item as not opened',
    withNew is AccessReadOk<Inbox> &&
        withNew.value.items.length == 2 &&
        newItem?.opened == false,
    'items ${ids(withNew).length}, opened ${newItem?.opened}',
  );

  final openNew = await SupabaseInboxRepository(mobileA)
      .openItem(newItem?.itemId ?? '');
  final choices = openNew is AccessReadOk<OpenedInboxItem>
      ? openNew.value.snoozeChoices
      : const <String>[];
  report(
    'L15 opening offers the policy snooze choices',
    choices.join('|') == '1 hour|24 hours|2 days',
    choices.join('|'),
  );
  final before15 = signalsA;
  final snoozed = await SupabaseCommandGateway(mobileA).send(
    'notifications_command',
    CommandRequest(
      command: 'notifications.snooze_item',
      requestId: SecureRequestIds().next(),
      payload: {'item_id': newItem?.itemId ?? '', 'choice': '24 hours'},
    ),
  );
  SnoozeConfirmation? confirmation;
  if (snoozed is CommandConfirmed) {
    confirmation = SnoozeConfirmation.fromJson(snoozed.success.data);
  }
  await waitFor(() => signalsA > before15);
  final afterSnooze = await SupabaseInboxRepository(mobileA).fetchMyInbox();
  final snoozedItem = afterSnooze is AccessReadOk<Inbox>
      ? afterSnooze.value.items
            .where((i) => i.itemId == newItem?.itemId)
            .firstOrNull
      : null;
  report(
    'L16 the member snoozes their item; the list shows until when',
    confirmation != null &&
        !confirmation.clamped &&
        snoozedItem?.snoozedUntil == confirmation.scheduledAt &&
        signalsA > before15,
    'clamped ${confirmation?.clamped}, signals ${signalsA - before15}',
  );
  final foreign = await SupabaseCommandGateway(mobileB).send(
    'notifications_command',
    CommandRequest(
      command: 'notifications.snooze_item',
      requestId: SecureRequestIds().next(),
      payload: {'item_id': newItem?.itemId ?? '', 'choice': '1 hour'},
    ),
  );
  report(
    'L17 member B cannot snooze A\'s item',
    foreign is CommandRefused && foreign.error.code == ErrorCode.notFound,
    foreign is CommandRefused ? foreign.error.code.wireName : foreign,
  );

  final settings = await SupabaseNotificationSettingsRepository(mobileA)
      .fetchMySettings();
  report(
    'L18 notification settings list the registered categories',
    settings is AccessReadOk<NotificationSettings> &&
        settings.value.categories.any((c) => c.reminderKind == 'fixture_due'),
    settings is AccessReadOk<NotificationSettings>
        ? settings.value.categories.map((c) => c.reminderKind).join(',')
        : settings.runtimeType,
  );
  await subA.cancel();
  await subB.cancel();

  await staffA.auth.signOut();
  final afterSignOut = await SupabaseInboxRepository(staffA).fetchMyInbox();
  report(
    'L8 signing out on staff web drops access there',
    items(afterSignOut) == 'denied:signedOut',
    items(afterSignOut),
  );

  await mobileA.auth.signOut();
  await mobileB.auth.signOut();
  for (final c in [mobileA, staffA, mobileB, signedOut]) {
    c.dispose();
  }
  exit(ok ? 0 : 1);
}
