import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/application_controllers.dart';
import '../application/providers.dart';
import '../domain/access_grants.dart';
import '../domain/membership_application.dart';
import 'shell_routing.dart' show ClientPaths;

/// Story 2.4, mobile: the membership request after Create account, and its
/// status. Church approval and the cell are shown as two separate states;
/// the applicant can correct their own request but never set either state.
/// Until the church approves, this status and public content are all the
/// account can reach (the server enforces it; this screen only reports it).
class MembershipApplicationScreen extends ConsumerStatefulWidget {
  const MembershipApplicationScreen({super.key});

  @override
  ConsumerState<MembershipApplicationScreen> createState() =>
      _MembershipApplicationScreenState();
}

const _notSure = 'not_sure';
const _notInCell = 'not_in_cell';

class _MembershipApplicationScreenState
    extends ConsumerState<MembershipApplicationScreen> {
  late final AppLifecycleListener _lifecycle;
  final _name = TextEditingController();
  final _noticeFocus = FocusNode(debugLabel: 'application notice');

  /// The radio value: a cell id, [_notSure] or [_notInCell].
  String? _choice;
  bool _editing = false;

  /// Story 2.5: sending a NEW request after a rejection (cooldown passed).
  bool _reapplying = false;
  String? _nameError;
  String? _choiceError;

  /// "I have read the privacy notice": unchecked until the applicant ticks it.
  bool _noticeAccepted = false;
  String? _noticeError;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _revalidate);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _name.dispose();
    _noticeFocus.dispose();
    super.dispose();
  }

  void _revalidate() {
    if (!mounted || ref.read(accountProvider).accountId == null) return;
    final s = ref.read(membershipApplicationProvider);
    if (s.loading || s.busy) return;
    ref.read(membershipApplicationProvider.notifier).reload();
  }

  void _startCorrecting(MembershipApplication app) {
    setState(() {
      _editing = true;
      _name.text = app.fullName;
      _choice = switch (app.cellChoice.kind) {
        CellChoiceKind.cell => app.cellChoice.cellId,
        CellChoiceKind.notSure => _notSure,
        CellChoiceKind.notInCell => _notInCell,
      };
      _nameError = null;
      _choiceError = null;
    });
    ref.read(membershipApplicationProvider.notifier).dismissNotice();
  }

  void _send(List<CellOption> options, {required bool newRequest}) {
    final name = _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    CellChoice? choice;
    if (_choice == _notSure) {
      choice = const CellChoice.notSure();
    } else if (_choice == _notInCell) {
      choice = const CellChoice.notInCell();
    } else {
      for (final o in options) {
        if (o.cellId == _choice) {
          choice = CellChoice.cell(cellId: o.cellId, cellRevision: o.revision);
        }
      }
    }
    setState(() {
      _nameError = name.isEmpty
          ? 'Enter your full name.'
          : name.length > 120
          ? 'Use 120 characters or fewer.'
          : null;
      _choiceError = choice == null ? 'Choose one answer.' : null;
      _noticeError = newRequest && !_noticeAccepted
          ? 'Confirm that you have read the privacy notice.'
          : null;
    });
    if (_nameError != null || choice == null || _noticeError != null) return;
    ref
        .read(membershipApplicationProvider.notifier)
        .send(fullName: name, choice: choice, noticeAccepted: _noticeAccepted);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final signedIn =
        ref.watch(accountProvider.select((a) => a.accountId)) != null;
    final s = ref.watch(membershipApplicationProvider);
    ref.listen(membershipApplicationProvider, (prev, next) {
      final notice = next.notice;
      if (notice == null || notice == prev?.notice) return;
      if (notice == ApplicationNotice.submitted ||
          notice == ApplicationNotice.corrected) {
        setState(() {
          _editing = false;
          _reapplying = false;
        });
      }
      final (title, message, _) = _noticeText(notice);
      announce(context, '$title. $message');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _noticeFocus.context != null) {
          _noticeFocus.requestFocus();
        }
      });
    });

    final children = <Widget>[];
    if (!signedIn) {
      children.addAll([
        const Text(
          'Create an account with your phone number and a password, then ask '
          'to join the church here.',
        ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FocusRing(
              child: FilledButton(
                key: const Key('application-create-account'),
                onPressed: () => context.go(ClientPaths.createAccount),
                child: const Text('Create account'),
              ),
            ),
            FocusRing(
              child: OutlinedButton(
                key: const Key('application-sign-in'),
                onPressed: () => context.go(ClientPaths.signIn),
                child: const Text('Sign in'),
              ),
            ),
          ],
        ),
      ]);
    } else {
      final notice = s.notice;
      if (notice != null) {
        final (title, message, tone) = _noticeText(notice);
        children.addAll([
          RequestStateBanner(
            key: const Key('application-notice'),
            focusNode: _noticeFocus,
            tone: tone,
            icon: tone == StatusTone.success
                ? Icons.check_circle_outline
                : Icons.info_outline,
            title: title,
            message: message,
            actions: [
              if (notice == ApplicationNotice.unconfirmed)
                BannerAction(
                  'Check again',
                  s.busy
                      ? null
                      : () => ref
                            .read(membershipApplicationProvider.notifier)
                            .checkAgain(),
                  key: const Key('application-check-again'),
                  primary: true,
                ),
              BannerAction(
                'Dismiss',
                () => ref
                    .read(membershipApplicationProvider.notifier)
                    .dismissNotice(),
                key: const Key('application-dismiss'),
              ),
            ],
          ),
          const SizedBox(height: ChurchGeometry.sectionGap),
        ]);
      }
      if (s.busy) {
        children.addAll([
          const RequestStateBanner(
            key: Key('application-pending'),
            tone: StatusTone.info,
            busy: true,
            title: 'Sending your request…',
            message: 'Waiting for the server.',
          ),
          const SizedBox(height: ChurchGeometry.sectionGap),
        ]);
      }
      children.add(_body(context, s));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Join the church')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: DefaultTextStyle.merge(
                style: layout.body.copyWith(color: c.ink),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ApplicationState s) {
    final result = s.result;
    if (result == null) {
      return const RequestStateBanner(
        key: Key('application-loading'),
        tone: StatusTone.info,
        busy: true,
        title: 'Loading your request…',
        message: 'The server checks your account every time.',
      );
    }
    switch (result) {
      case AccessReadDenied(:final denial):
        final (title, message) = switch (denial) {
          AccessDenial.signedOut => (
            'Not signed in',
            'Sign in to see your membership request.',
          ),
          AccessDenial.untrustedSession => (
            'Please sign in again',
            'This sign-in is no longer valid. Sign in with your phone number '
                'and password.',
          ),
          AccessDenial.unavailable => (
            'Not available yet',
            'Membership requests are not available here yet.',
          ),
          _ => (
            'Access review required',
            'Your account needs a check by the church before it can continue. '
                'Please contact the church office for help.',
          ),
        };
        return RequestStateBanner(
          key: Key('application-denied-${denial.name}'),
          tone: StatusTone.warning,
          icon: Icons.lock_outline,
          title: title,
          message: message,
        );
      case AccessReadFailed(:final unreachable):
        return RequestStateBanner(
          key: const Key('application-failed'),
          tone: StatusTone.danger,
          icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
          title: unreachable ? 'No connection' : 'Couldn\'t load your request',
          message: unreachable
              ? 'We couldn\'t reach the church server. Nothing is shown until '
                    'it answers.'
              : 'The server answered in an unexpected way. Try again later.',
          actions: [
            BannerAction(
              'Try again',
              () => ref.read(membershipApplicationProvider.notifier).reload(),
              key: const Key('application-retry'),
            ),
          ],
        );
      case AccessReadOk(:final value):
        final app = value.application;
        if (_reapplying) return _form(context, s, value, null);
        if (app != null && !_editing) {
          return _status(context, app, s.options);
        }
        if (app == null && !value.accepting) {
          return const RequestStateBanner(
            key: Key('application-not-accepting'),
            tone: StatusTone.neutral,
            icon: Icons.hourglass_empty,
            title: 'Not open yet',
            message:
                'Membership requests are not being accepted here yet. Please '
                'ask the church office.',
          );
        }
        return _form(context, s, value, app);
    }
  }

  Widget _status(
    BuildContext context,
    MembershipApplication app,
    List<CellOption> options,
  ) {
    final c = ChurchColors.of(context);
    final (churchLabel, churchTone) = switch (app.churchStatus) {
      ChurchStatus.awaitingApproval => (
        'Awaiting church approval',
        StatusTone.info,
      ),
      ChurchStatus.detailsRequested => (
        'The church asked for more details',
        StatusTone.warning,
      ),
      ChurchStatus.approved => ('Approved by the church', StatusTone.success),
      ChurchStatus.notApproved => ('Not approved', StatusTone.neutral),
      ChurchStatus.withdrawn => ('Withdrawn', StatusTone.neutral),
    };
    String cellText;
    switch (app.cellChoice.kind) {
      case CellChoiceKind.cell:
        CellOption? option;
        for (final o in options) {
          if (o.cellId == app.cellChoice.cellId) option = o;
        }
        cellText = option == null
            ? 'Cell requested (no longer listed; the church will follow up)'
            : 'Cell requested: ${option.label} (${option.broadArea})';
      case CellChoiceKind.notSure:
        cellText = 'Cell: not sure yet. The church will follow up.';
      case CellChoiceKind.notInCell:
        cellText = 'Cell: not in a cell yet. The church will follow up.';
    }
    return Container(
      key: const Key('application-status'),
      padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(ChurchGeometry.mobileCardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Your membership request',
              style: ChurchType.cardTitle.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(height: 8),
          Text(app.fullName, key: const Key('application-name')),
          Text(
            'Sign-in username: ${app.phoneUsername}',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 12),
          Text(
            'Church approval',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 4),
          StatusLabel(
            key: const Key('church-status'),
            label: churchLabel,
            tone: churchTone,
          ),
          const SizedBox(height: 12),
          Text(
            'Cell group',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusLabel(
                key: const Key('cell-status'),
                label: cellText,
                tone: StatusTone.neutral,
              ),
              const StatusLabel(
                label: 'Not confirmed yet',
                tone: StatusTone.neutral,
              ),
            ],
          ),
          if (app.isSynthetic) ...[
            const SizedBox(height: 8),
            const StatusLabel(
              label: 'Synthetic test record',
              tone: StatusTone.neutral,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Church approval and your cell are checked separately. Until the '
            'church approves your request, this account shows only this '
            'status and public content.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          ..._decision(context, app),
          const SizedBox(height: 8),
          const _RecoveryEmailNote(),
          if (app.correctable) ...[
            const SizedBox(height: ChurchGeometry.sectionGap),
            FocusRing(
              child: OutlinedButton.icon(
                key: const Key('correct-application'),
                onPressed: () => _startCorrecting(app),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Correct my request'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Story 2.5: what the church decided, as the applicant may see it (codes
  /// mapped to church copy; never anything about other people).
  List<Widget> _decision(BuildContext context, MembershipApplication app) {
    final c = ChurchColors.of(context);
    switch (app.churchStatus) {
      case ChurchStatus.detailsRequested:
        final asked = [
          for (final d in app.detailsRequested)
            switch (d) {
              'full_name' => 'check your full name',
              'cell_choice' => 'check your cell group answer',
              'visit_church_office' => 'visit the church office',
              _ => 'contact the church office',
            },
        ];
        return [
          const SizedBox(height: 12),
          Text(
            asked.isEmpty
                ? 'The church asked for more details. Please contact the '
                      'church office.'
                : 'The church asked you to ${asked.join(', and ')}.',
            key: const Key('application-details-requested'),
          ),
        ];
      case ChurchStatus.notApproved:
        final reason = switch (app.decisionReason) {
          'identity_not_confirmed' =>
            'The church could not confirm who you are yet.',
          'not_known_to_church' => 'The church does not know you yet.',
          'contact_church_office' => 'Please contact the church office.',
          _ => null,
        };
        final from = app.reapplyFrom;
        final now = DateTime.now();
        return [
          const SizedBox(height: 12),
          if (reason != null)
            Text(reason, key: const Key('application-decision-reason')),
          Text(
            'Talking to the church office is the quickest way forward.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          if (from != null && app.canReapplyAt(now)) ...[
            const SizedBox(height: 12),
            FocusRing(
              child: OutlinedButton.icon(
                key: const Key('reapply'),
                onPressed: () {
                  setState(() {
                    _reapplying = true;
                    _name.text = '';
                    _choice = null;
                    _noticeAccepted = false;
                  });
                  ref
                      .read(membershipApplicationProvider.notifier)
                      .dismissNotice();
                },
                icon: const Icon(Icons.replay),
                label: const Text('Send a new request'),
              ),
            ),
          ] else if (from != null)
            Text(
              'You can send a new request from '
              '${MaterialLocalizations.of(context).formatMediumDate(from.toLocal())}.',
              key: const Key('reapply-from'),
            ),
        ];
      case ChurchStatus.approved:
      case ChurchStatus.awaitingApproval:
      case ChurchStatus.withdrawn:
        return const [];
    }
  }

  Widget _form(
    BuildContext context,
    ApplicationState s,
    MyApplication mine,
    MembershipApplication? existing,
  ) {
    final c = ChurchColors.of(context);
    final busy = s.busy;
    final options = s.options;
    final server = s.fieldErrors;
    final nameError =
        _nameError ??
        (server.containsKey('full_name') ? 'Check your name.' : null);
    final choiceError =
        _choiceError ??
        (server.keys.any((k) => k.startsWith('cell_choice'))
            ? 'Choose again from the current list.'
            : null);
    final noticeText = privacyNoticeTexts[mine.privacyNotice.version];
    return Column(
      key: const Key('application-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          existing == null
              ? 'Ask to join the church. Staff check who you are before '
                    'approving, and your cell is confirmed separately.'
              : 'Correct your request. Your church approval and cell are '
                    'still decided by the church.',
        ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        AutofillGroup(
          child: RevealOnFocus(
            child: TextField(
              key: const Key('full-name-field'),
              controller: _name,
              readOnly: busy,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.name],
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              decoration: InputDecoration(
                labelText: 'Full name',
                errorText: nameError,
              ),
            ),
          ),
        ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        Semantics(
          header: true,
          child: Text(
            'Which cell group do you belong to?',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'The list shows only each cell\'s name and broad area.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        if (s.optionsResult is! AccessReadOk<List<CellOption>>)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'The cell list could not be loaded. You can still choose one of '
              'the answers below.',
              key: const Key('cell-options-unavailable'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          ),
        RadioGroup<String>(
          groupValue: _choice,
          onChanged: (v) {
            if (busy) return;
            setState(() {
              _choice = v;
              _choiceError = null;
            });
          },
          child: Column(
            children: [
              for (final o in options)
                RadioListTile<String>(
                  key: Key('cell-choice-${o.cellId}'),
                  value: o.cellId,
                  title: Text(o.label),
                  subtitle: Text(o.broadArea),
                ),
              const RadioListTile<String>(
                key: Key('cell-choice-not_sure'),
                value: _notSure,
                title: Text('I\'m not sure'),
                subtitle: Text('The church will follow up with you.'),
              ),
              const RadioListTile<String>(
                key: Key('cell-choice-not_in_cell'),
                value: _notInCell,
                title: Text('I\'m not in a cell yet'),
                subtitle: Text('The church will follow up with you.'),
              ),
            ],
          ),
        ),
        if (choiceError != null)
          Text(
            choiceError,
            key: const Key('cell-choice-error'),
            style: ChurchType.secondary.copyWith(color: c.redFg),
          ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        Container(
          key: const Key('privacy-notice'),
          padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
          decoration: BoxDecoration(
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(
              ChurchGeometry.mobileCardRadius,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mine.privacyNotice.draft
                    ? 'Privacy notice (DRAFT, awaiting church approval)'
                    : 'Privacy notice',
                style: ChurchType.cardTitle.copyWith(color: c.ink),
              ),
              const SizedBox(height: 4),
              Text(
                noticeText ??
                    'Ask the church office for the privacy notice '
                        '(${mine.privacyNotice.version}).',
                style: ChurchType.secondary.copyWith(color: c.ink),
              ),
            ],
          ),
        ),
        if (existing == null && noticeText == null)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: RequestStateBanner(
              key: Key('privacy-notice-missing'),
              tone: StatusTone.warning,
              icon: Icons.info_outline,
              title: 'Update the app or ask the church office',
              message:
                  'This app does not have the current privacy notice, so it '
                  'cannot send a request. Please update the app or ask the '
                  'church office for help.',
            ),
          ),
        if (existing == null && noticeText != null) ...[
          CheckboxListTile(
            key: const Key('privacy-accept'),
            value: _noticeAccepted,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('I have read the privacy notice'),
            onChanged: busy
                ? null
                : (v) => setState(() {
                    _noticeAccepted = v ?? false;
                    _noticeError = null;
                  }),
          ),
          if (_noticeError != null)
            Text(
              _noticeError!,
              key: const Key('privacy-accept-error'),
              style: ChurchType.secondary.copyWith(color: c.redFg),
            ),
        ],
        const SizedBox(height: 12),
        const _RecoveryEmailNote(),
        const SizedBox(height: ChurchGeometry.sectionGap),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FocusRing(
              child: FilledButton(
                key: const Key('send-application'),
                onPressed: busy || (existing == null && noticeText == null)
                    ? null
                    : () => _send(options, newRequest: existing == null),
                child: Text(existing == null ? 'Send request' : 'Save changes'),
              ),
            ),
            if (existing != null || _reapplying)
              FocusRing(
                child: OutlinedButton(
                  key: const Key('cancel-correction'),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          _editing = false;
                          _reapplying = false;
                        }),
                  child: const Text('Cancel'),
                ),
              ),
          ],
        ),
      ],
    );
  }

  (String, String, StatusTone) _noticeText(ApplicationNotice n) => switch (n) {
    ApplicationNotice.submitted => (
      'Request sent',
      'Your request is awaiting church approval. Your cell is checked '
          'separately.',
      StatusTone.success,
    ),
    ApplicationNotice.corrected => (
      'Request updated',
      'Your corrected request is awaiting church approval.',
      StatusTone.success,
    ),
    ApplicationNotice.changedElsewhere => (
      'Your request changed',
      'It was changed elsewhere, so the latest version is shown. Check it '
          'and correct it again if needed.',
      StatusTone.warning,
    ),
    ApplicationNotice.alreadyApplied => (
      'You already have a request',
      'Your current request is shown below.',
      StatusTone.info,
    ),
    ApplicationNotice.cellListChanged => (
      'The cell list changed',
      'The cell you chose is no longer offered in that form. The list was '
          'reloaded; choose again.',
      StatusTone.warning,
    ),
    ApplicationNotice.invalid => (
      'Check your answers',
      'Some answers need fixing before the request can be sent.',
      StatusTone.danger,
    ),
    ApplicationNotice.signInAgain => (
      'Please sign in again',
      'This sign-in is no longer valid. Sign in with your phone number and '
          'password.',
      StatusTone.warning,
    ),
    ApplicationNotice.refused => (
      'Couldn\'t send the request',
      'This account can\'t send a membership request. Please ask the church '
          'office for help.',
      StatusTone.danger,
    ),
    ApplicationNotice.notAccepting => (
      'Not open yet',
      'Membership requests are not being accepted here yet.',
      StatusTone.neutral,
    ),
    ApplicationNotice.unconfirmed => (
      'Not confirmed yet',
      'We couldn\'t confirm whether your request arrived. Check again to '
          'find out; nothing is sent twice.',
      StatusTone.warning,
    ),
    ApplicationNotice.notSent => (
      'Not sent',
      'This app has no church server configured, so nothing was sent.',
      StatusTone.neutral,
    ),
  };
}

/// Email is optional and never blocks a request (FR "Joining from the app"
/// step 2). Adding a recovery email arrives with entry 7.
class _RecoveryEmailNote extends StatelessWidget {
  const _RecoveryEmailNote();

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Text(
      'Email is optional and not needed to join. Without a verified recovery '
      'email, church staff will help you in person if you forget your '
      'password. They never ask for or see your password.',
      key: const Key('recovery-email-note'),
      style: ChurchType.secondary.copyWith(color: c.muted),
    );
  }
}
