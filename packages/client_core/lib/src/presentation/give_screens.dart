import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/content_controllers.dart' show PublicReadState;
import '../application/giving_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/content_giving.dart';
import 'church_widgets.dart';

// Story 6.3 (mobile): the Give tab, read by everyone, signed in or not, from
// the published projection only. The screen answers "how do I give to the
// church?": the methods in the church's order, then one method's values to
// copy, its steps and the beneficiary to check before confirming. The app
// never processes or records a gift: no amount, no success state, nothing
// to "record". A failed read never looks like an empty list.

/// The public giving routes.
abstract final class GivePaths {
  /// The Give tab ("How to give").
  static const give = '/give';

  /// One published method.
  static String method(String methodId) => '/give/methods/$methodId';
}

const _explainer =
    'Choose a method and follow the steps. You give through your provider; '
    'the app doesn\'t process or record gifts.';

/// "09:14" on the phone's clock: when kept data was last good.
String _clock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

/// The notice over data kept from an earlier answer when the latest refresh
/// failed. Null when the data is current.
Widget? _staleNotice<T>(PublicReadState<T> s, {required String key}) {
  final failed = s.refreshFailed;
  final at = s.asOf;
  if (failed == null || at == null) return null;
  return RequestStateBanner(
    key: Key(key),
    tone: StatusTone.warning,
    icon: failed.unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: 'Couldn\'t refresh',
    message: failed.unreachable
        ? 'No connection. These details are as they were at ${_clock(at)}; '
              'they may have changed since. Check them with the church if '
              'you are unsure.'
        : 'The server answered in an unexpected way. These details are as '
              'they were at ${_clock(at)}.',
  );
}

/// A public read that did not answer, said plainly (it is not an empty
/// list), with Try again.
Widget _readProblem<T>(
  AccessRead<T> r, {
  required String keyPrefix,
  required VoidCallback? onRetry,
}) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadFailed(:final unreachable) => RequestStateBanner(
    key: Key('$keyPrefix-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load',
    message: unreachable
        ? 'We couldn\'t reach the church server, so no giving details are '
              'shown. This does not mean the church has none.'
        : 'The server answered in an unexpected way, so no giving details '
              'are shown.',
    actions: [
      BannerAction(
        'Try again',
        onRetry,
        key: Key('$keyPrefix-try-again'),
        primary: true,
      ),
    ],
  ),
  AccessReadDenied() => RequestStateBanner(
    key: Key('$keyPrefix-unavailable'),
    tone: StatusTone.warning,
    icon: Icons.lock_outline,
    title: 'Not available yet',
    message: 'Giving details are not available from this app right now.',
  ),
};

/// Story 6.3, mobile: the Give tab. The published methods in the church's
/// order; each row opens the method.
class GiveScreen extends ConsumerStatefulWidget {
  const GiveScreen({super.key});

  @override
  ConsumerState<GiveScreen> createState() => _GiveScreenState();
}

class _GiveScreenState extends ConsumerState<GiveScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the tab asks the server again.
    if (ref.read(publicGivingMethodsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    if (mounted && !ref.read(publicGivingMethodsProvider).loading) {
      ref.read(publicGivingMethodsProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(publicGivingMethodsProvider);
    final children = <Widget>[
      Text(
        _explainer,
        key: const Key('give-explainer'),
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      const SizedBox(height: 16),
    ];
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('give-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading giving methods…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        if (_staleNotice(s, key: 'give-stale') case final n?) {
          children.addAll([n, const SizedBox(height: 16)]);
        }
        if (value.methods.isEmpty) {
          children.add(
            ChurchCard(
              key: const Key('give-empty'),
              child: Text(
                'The church hasn\'t published any giving methods yet.',
                style: ChurchType.body.copyWith(color: c.muted),
              ),
            ),
          );
        } else {
          children.add(
            ChurchCard(
              key: const Key('give-methods'),
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, m) in value.methods.indexed) ...[
                    if (i > 0) Divider(height: 1, color: c.line),
                    _GiveMethodRow(
                      method: m,
                      onTap: () => context.push(GivePaths.method(m.methodId)),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        if (value.truncated) {
          children.addAll([
            const SizedBox(height: 12),
            Text(
              'Only the first methods are listed here.',
              key: const Key('give-truncated'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          ]);
        }
        if (value.sharedContact case final contact?) {
          children.addAll([
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Questions about giving? $contact',
                key: const Key('give-contact'),
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
            ),
          ]);
        }
      case final AccessRead<PublicGivingMethods> problem:
        children.add(
          _readProblem(
            problem,
            keyPrefix: 'give',
            onRetry: s.loading ? null : _reload,
          ),
        );
    }
    return MemberTabPage(
      title: 'How to give',
      reloadKey: const Key('give-reload'),
      onReload: s.loading ? null : _reload,
      children: children,
    );
  }
}

/// One method in the list: its name and what it is for.
class _GiveMethodRow extends StatelessWidget {
  const _GiveMethodRow({required this.method, required this.onTap});

  final PublicGivingMethod method;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final m = method;
    final sub = m.subline;
    return Semantics(
      button: true,
      label: sub.isEmpty ? m.name : '${m.name}, $sub',
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: Key('give-method-${m.methodId}'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          m.name,
                          style: ChurchType.itemTitle.copyWith(color: c.ink),
                        ),
                        if (sub.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            sub,
                            key: Key('give-method-sub-${m.methodId}'),
                            style: ChurchType.secondary.copyWith(
                              color: c.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  ExcludeSemantics(
                    child: Icon(Icons.chevron_right, size: 20, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Story 6.3, mobile: one published method. The values to copy into the
/// giver's provider, the steps, the beneficiary to check before confirming,
/// when the church checked the details and who to ask. Opened from How to
/// give; a method that is no longer published says so instead of showing an
/// old copy.
class GiveMethodScreen extends ConsumerStatefulWidget {
  const GiveMethodScreen({super.key, required this.methodId});

  final String methodId;

  @override
  ConsumerState<GiveMethodScreen> createState() => _GiveMethodScreenState();
}

class _GiveMethodScreenState extends ConsumerState<GiveMethodScreen> {
  /// The value copied last: its row, the exact value and the publication it
  /// came from. Its button says "Copied" only while all three still match,
  /// so a refresh that brings a new account number never shows "Copied" for
  /// a value that was not copied.
  _Copied? _copied;

  Future<void> _copy(_Copied copied, String label) async {
    await Clipboard.setData(ClipboardData(text: copied.value));
    if (!mounted) return;
    setState(() => _copied = copied);
    announce(context, '$label copied');
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final provider = publicGivingMethodProvider(widget.methodId);
    final s = ref.watch(provider);
    final ctl = ref.read(provider.notifier);
    final reload = s.loading ? null : ctl.reload;
    final children = <Widget>[];
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('give-method-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading the method…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(
        value: PublicGivingMethodRead(:final sample, :final method),
      ):
        if (_staleNotice(s, key: 'give-method-stale') case final n?) {
          children.addAll([n, const SizedBox(height: 16)]);
        }
        if (method == null) {
          children.add(
            RequestStateBanner(
              key: const Key('give-method-gone'),
              tone: StatusTone.neutral,
              title: 'No longer listed',
              message: 'This giving method is no longer listed.',
              actions: [
                BannerAction(
                  'See how to give',
                  () => context.go(GivePaths.give),
                  key: const Key('give-method-gone-list'),
                  primary: true,
                ),
              ],
            ),
          );
        } else {
          children.addAll(_methodBody(context, c, method, sample: sample));
        }
      case final AccessRead<PublicGivingMethodRead> problem:
        children.add(
          _readProblem(problem, keyPrefix: 'give-method', onRetry: reload),
        );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('How to give'),
        actions: [
          FocusRing(
            radius: 22,
            child: IconButton(
              key: const Key('give-method-reload'),
              tooltip: 'Reload',
              onPressed: reload,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => reload?.call(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
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
      ),
    );
  }

  List<Widget> _methodBody(
    BuildContext context,
    ChurchColors c,
    PublicGivingMethod m, {
    required bool sample,
  }) {
    final rows = <({String key, String label, String value})>[
      for (final d in m.details)
        (key: d.key, label: d.labelFor(m.methodType), value: d.value),
      if (m.ussdCode case final code?)
        (key: 'ussd_code', label: 'Starting code', value: code),
    ];
    final sub = m.subline;
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    return [
      Semantics(
        header: true,
        child: Text(
          m.name,
          key: const Key('give-method-name'),
          style: ChurchType.mobileScreenTitle.copyWith(color: c.brand),
        ),
      ),
      if (sub.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(sub, key: const Key('give-method-subline'), style: muted),
      ],
      if (sample) ...[
        const SizedBox(height: 14),
        Container(
          key: const Key('give-sample'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: c.amberBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            'Sample details for testing. The church must supply and verify '
            'its own.',
            style: ChurchType.secondary.copyWith(
              color: c.amberFg,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
      if (rows.isNotEmpty) ...[
        const SizedBox(height: 16),
        ChurchCard(
          key: const Key('give-values'),
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, r) in rows.indexed) ...[
                if (i > 0) Divider(height: 1, color: c.line),
                _CopyRow(
                  rowKey: r.key,
                  label: r.label,
                  value: r.value,
                  copied:
                      _copied ==
                      (
                        key: r.key,
                        value: r.value,
                        revision: m.publicationRevision,
                      ),
                  onCopy: () => _copy((
                    key: r.key,
                    value: r.value,
                    revision: m.publicationRevision,
                  ), r.label),
                ),
              ],
            ],
          ),
        ),
      ],
      const SizedBox(height: ChurchGeometry.sectionGap),
      const SectionHeader(title: 'Steps'),
      const SizedBox(height: 10),
      for (final (i, step) in m.steps.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Semantics(
            label: 'Step ${i + 1}: $step',
            excludeSemantics: true,
            child: Row(
              key: Key('give-step-${i + 1}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.blueBg,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: ChurchType.chip.copyWith(
                      color: c.blueFg,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      step,
                      style: ChurchType.body.copyWith(color: c.ink),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      if (m.note case final note?) ...[
        const SizedBox(height: 4),
        Text(
          note,
          key: const Key('give-method-note'),
          style: ChurchType.body.copyWith(color: c.ink),
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 4),
      Container(
        key: const Key('give-before-confirm'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Before you confirm',
                style: ChurchType.label.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(height: 6),
            switch (m.beneficiary) {
              final name? when m.methodType.hasBeneficiary => Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Check that your provider shows '),
                    TextSpan(
                      text: name,
                      style: TextStyle(
                        color: c.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const TextSpan(
                      text:
                          ' before you confirm. If it does not, stop and '
                          'contact the church.',
                    ),
                  ],
                ),
                key: const Key('give-beneficiary-check'),
                style: muted,
              ),
              _ => Text(
                'Give only through the church\'s own channels. If anyone '
                'asks you to give another way, stop and contact the church.',
                key: const Key('give-beneficiary-check'),
                style: muted,
              ),
            },
          ],
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'Details checked by the church on ${churchDateText(m.verifiedOn)}',
        key: const Key('give-verified'),
        style: muted,
      ),
      const SizedBox(height: 2),
      Text(
        'Questions? ${m.contact}',
        key: const Key('give-method-contact'),
        style: muted,
      ),
    ];
  }
}

/// What was copied last on a method's detail.
typedef _Copied = ({String key, String value, int revision});

/// One value to copy: its label, the value and a Copy button that puts
/// exactly the value on the clipboard.
class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.rowKey,
    required this.label,
    required this.value,
    required this.copied,
    required this.onCopy,
  });

  final String rowKey;
  final String label;
  final String value;
  final bool copied;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 62),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: ChurchType.secondary.copyWith(color: c.muted),
                    ),
                    Text(
                      value,
                      key: Key('give-value-$rowKey'),
                      style: ChurchType.body.copyWith(
                        color: c.ink,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            FocusRing(
              child: OutlinedButton.icon(
                key: Key('give-copy-$rowKey'),
                onPressed: onCopy,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: Icon(
                  copied ? Icons.check : Icons.copy_outlined,
                  size: 16,
                ),
                label: Text(
                  copied ? 'Copied' : 'Copy',
                  semanticsLabel: copied ? '$label copied' : 'Copy $label',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
