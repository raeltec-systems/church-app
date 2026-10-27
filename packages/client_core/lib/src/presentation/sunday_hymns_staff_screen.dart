import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/hymn_controllers.dart';
import '../application/hymn_list_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/hymn_book.dart';
import '../domain/hymn_lists.dart';
import 'calendar_screens.dart' show churchShortWhen;

// Story 6.8, staff web: Admin, Media and worship leaders set Hymns for this
// Sunday, a church-time Sunday's ordered list of items from the hymn book
// built into the app (search by number or title); members see it on Home
// from Saturday. An Admin also makes members worship leaders (the 2.3 scope
// on the church's one Sunday-list record). The screen answers "what are we
// singing this Sunday?" first: the finding line, then the Sundays with their
// lists, then the editor of the chosen one. Every list comes from a
// server-checked read and every change is a server-checked command; a list
// shows as set only after the server confirmed it. Only item numbers travel.

/// The staff route of the Sunday hymns editor.
abstract final class SundayHymnsStaffPaths {
  static const sundayHymns = '/content/sunday-hymns';
}

/// How many Sundays the editor offers, this Sunday first.
const _sundaysShown = 8;

const _monthsShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Sun 1 Nov 2026" for a `YYYY-MM-DD` Sunday.
String sundayLabel(String sunday) {
  final d = DateTime.parse('${sunday}T00:00:00Z');
  return 'Sun ${d.day} ${_monthsShort[d.month - 1]} ${d.year}';
}

String _itemLabel(String id, HymnBook? book) {
  final hymn = book?.byId(id);
  final chorus = id.startsWith('chorus-');
  final number = id.substring(id.indexOf('-') + 1);
  final kind = chorus ? 'Chorus' : 'Hymn';
  return hymn == null ? '$kind $number' : '$kind $number, ${hymn.title}';
}

(StatusTone, String, String) _noticeText(
  SundayHymnsNotice n,
  StaffSundayHymnsState s,
) {
  final a = s.noticeAction;
  final grant = a?.function == 'identity_grant_command';
  final what = a == null
      ? 'the list'
      : grant
      ? a.subject
      : sundayLabel(a.subject);
  return switch (n) {
    SundayHymnsNotice.saved => (
      StatusTone.success,
      'List saved',
      'The hymns for $what are set. Members see them on Home from the '
          'Saturday before, and as a Sunday chip in the hymn book that week.',
    ),
    SundayHymnsNotice.cleared => (
      StatusTone.success,
      'List cleared',
      '$what has no hymns now. Members no longer see a list for it.',
    ),
    SundayHymnsNotice.granted => (
      StatusTone.success,
      'Worship leader added',
      '$what can set Hymns for this Sunday now, on staff web.',
    ),
    SundayHymnsNotice.revoked => (
      StatusTone.success,
      'Worship leader removed',
      '$what can no longer set Hymns for this Sunday.',
    ),
    SundayHymnsNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      'Another editor changed the Sunday lists. The page now shows them as '
          'they are; check $what and save again.',
    ),
    SundayHymnsNotice.notSet => (
      StatusTone.neutral,
      'Nothing to clear',
      '$what has no list to clear.',
    ),
    SundayHymnsNotice.invalid => (
      StatusTone.warning,
      'Not saved',
      _invalidText(s.fieldErrors),
    ),
    SundayHymnsNotice.alreadyChanged => (
      StatusTone.warning,
      'Already changed',
      'Worship leaders changed in the meantime. The page now shows who '
          'leads; nothing else was changed.',
    ),
    SundayHymnsNotice.notAllowed => (
      StatusTone.danger,
      'Not allowed',
      'Hymns for this Sunday are set by Admins, Media and worship leaders. '
          'Nothing was changed.',
    ),
    SundayHymnsNotice.signInAgain => (
      StatusTone.warning,
      'Please sign in again',
      'Your session needs a fresh sign-in. Nothing was changed.',
    ),
    SundayHymnsNotice.notAvailable => (
      StatusTone.warning,
      'Not available right now',
      'The church server could not do this now. Try again later.',
    ),
    SundayHymnsNotice.refused => (
      StatusTone.danger,
      'Refused',
      'The church server refused this. Nothing was changed.',
    ),
    SundayHymnsNotice.unconfirmed => (
      StatusTone.warning,
      'Not confirmed',
      'We couldn\'t tell whether $what reached the church server. Check '
          'again sends the same request, so nothing is saved twice.',
    ),
    SundayHymnsNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
  };
}

String _invalidText(Map<String, String> f) {
  final sunday = f['sunday'];
  final items = f['items'];
  if (sunday == 'past') {
    return 'That Sunday is past. Choose this Sunday or a later one.';
  }
  if (sunday == 'too_far') return 'Lists can be set up to 52 weeks ahead.';
  if (items == 'out_of_range' || items == 'invalid' || f['edition'] != null) {
    return 'An item is not in the hymn book the church server knows. Update '
        'staff web and try again.';
  }
  if (items == 'too_many') {
    return 'A list has at most ${HymnListCommands.maxSundayItems} items.';
  }
  if (items == 'duplicate') return 'Each item can be in the list once.';
  return 'The church server could not accept this list. Nothing was saved.';
}

/// The finding under the title: this Sunday's list and next Sunday's.
String _finding(StaffSundayHymns v) {
  String part(String label, String sunday) {
    final list = v.listFor(sunday);
    final n = list == null || list.cleared ? 0 : list.items.length;
    return n == 0
        ? '$label: not set'
        : '$label: $n ${n == 1 ? 'item' : 'items'}';
  }

  return [
    part('This Sunday (${sundayLabel(v.thisSunday)})', v.thisSunday),
    part('next Sunday', SundayHymnsWindow.sundayAfter(v.thisSunday, 1)),
  ].join(' · ');
}

/// Story 6.8, staff web: the Sunday hymns editor.
class StaffSundayHymnsScreen extends ConsumerStatefulWidget {
  const StaffSundayHymnsScreen({super.key});

  @override
  ConsumerState<StaffSundayHymnsScreen> createState() =>
      _StaffSundayHymnsScreenState();
}

class _StaffSundayHymnsScreenState
    extends ConsumerState<StaffSundayHymnsScreen> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'sunday hymns notice');

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    if (ref.read(staffSundayHymnsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    final s = ref.read(staffSundayHymnsProvider);
    if (mounted && !s.busy && !s.loading) {
      ref.read(staffSundayHymnsProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _noticeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(staffSundayHymnsProvider);
    final ctl = ref.read(staffSundayHymnsProvider.notifier);
    ref.listen(staffSundayHymnsProvider.select((x) => x.notice), (prev, next) {
      if (next == null || next == prev) return;
      final (_, title, message) = _noticeText(
        next,
        ref.read(staffSundayHymnsProvider),
      );
      announce(context, '$title. $message');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _noticeFocus.context != null) {
          _noticeFocus.requestFocus();
        }
      });
    });
    final children = <Widget>[];
    if (s.pending case final p?) {
      children.add(
        RequestStateBanner(
          key: const Key('sunday-hymns-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the church server about '
              '${p.function == 'identity_grant_command' ? p.subject : sundayLabel(p.subject)}. '
              'Nothing is shown as done until it answers.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(n, s);
      children.add(
        RequestStateBanner(
          key: Key('sunday-hymns-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == SundayHymnsNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('sunday-hymns-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('sunday-hymns-dismiss'),
            ),
          ],
        ),
      );
    }
    if (children.isNotEmpty) {
      children.add(const SizedBox(height: ChurchGeometry.sectionGap));
    }
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('sunday-hymns-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading the Sunday lists…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        children.add(_SundayHymnsBody(value: value, state: s));
      case AccessReadDenied(:final denial):
        children.add(
          RequestStateBanner(
            key: Key('sunday-hymns-denied-${denial.name}'),
            tone: StatusTone.warning,
            icon: Icons.lock_outline,
            title: switch (denial) {
              AccessDenial.signedOut => 'Not signed in',
              AccessDenial.untrustedSession => 'Please sign in again',
              AccessDenial.notGranted => 'Not available to you',
              AccessDenial.notLinked => 'No member access yet',
              AccessDenial.unavailable => 'Not available yet',
              _ => 'Access review required',
            },
            message: denial == AccessDenial.notGranted
                ? 'Hymns for this Sunday are set by Admins, Media and worship '
                      'leaders. Permissions are checked by the server each '
                      'time.'
                : 'Nothing is shown until the server allows it.',
          ),
        );
      case AccessReadFailed(:final unreachable):
        children.add(
          RequestStateBanner(
            key: const Key('sunday-hymns-failed'),
            tone: StatusTone.danger,
            icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
            title: unreachable ? 'No connection' : 'Couldn\'t load',
            message: unreachable
                ? 'We couldn\'t reach the church server. This is not an empty '
                      'list: nothing is shown until it answers.'
                : 'The server answered in an unexpected way. Try again later.',
          ),
        );
    }
    final phone = !identical(layout, ChurchLayout.staff);
    final reload = s.loading || s.busy ? null : ctl.reload;
    final value = s.value;
    return ChurchPageScaffold(
      title: 'Sunday hymns',
      subtitle: value == null ? null : _finding(value),
      actions: phone
          ? [
              FocusRing(
                radius: 22,
                child: IconButton(
                  key: const Key('sunday-hymns-reload'),
                  tooltip: 'Reload',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 4),
            ]
          : [staffReloadButton(const Key('sunday-hymns-reload'), reload)],
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
}

class _SundayHymnsBody extends ConsumerStatefulWidget {
  const _SundayHymnsBody({required this.value, required this.state});

  final StaffSundayHymns value;
  final StaffSundayHymnsState state;

  @override
  ConsumerState<_SundayHymnsBody> createState() => _SundayHymnsBodyState();
}

class _SundayHymnsBodyState extends ConsumerState<_SundayHymnsBody> {
  late String _sunday = widget.value.thisSunday;

  /// The list as edited; null while it matches the server's.
  List<String>? _draft;
  final _search = TextEditingController();
  String _query = '';
  WorshipLeaderCandidate? _candidate;

  @override
  void didUpdateWidget(covariant _SundayHymnsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A confirmed save or a reload shows the server's list again.
    if (widget.value.revision != oldWidget.value.revision) _draft = null;
    if (!_sundays.contains(_sunday)) _sunday = widget.value.thisSunday;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> get _sundays => [
    for (var w = 0; w < _sundaysShown; w++)
      SundayHymnsWindow.sundayAfter(widget.value.thisSunday, w),
  ];

  List<String> _saved(String sunday) =>
      widget.value.listFor(sunday)?.items ?? const [];

  List<String> get _items => _draft ?? _saved(_sunday);

  void _choose(String sunday) => setState(() {
    _sunday = sunday;
    _draft = null;
    _search.clear();
    _query = '';
  });

  void _edit(List<String> items) => setState(() => _draft = items);

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(hymnBookProvider);
    final v = widget.value;
    final busy = widget.state.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sundaysSection(context, book.value),
        const SizedBox(height: ChurchGeometry.sectionGap),
        _editorSection(context, book),
        if (v.managesWorshipLeaders) ...[
          const SizedBox(height: ChurchGeometry.sectionGap),
          _leadersSection(context, busy),
        ],
      ],
    );
  }

  Widget _sundaysSection(BuildContext context, HymnBook? book) {
    final c = ChurchColors.of(context);
    final v = widget.value;
    return StaffSection(
      key: const Key('sunday-hymns-sundays'),
      title: 'Sundays',
      subtitle: 'Members see a list on Home from the Saturday before.',
      bodyPadding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (i, sunday) in _sundays.indexed)
            _SundayRow(
              key: Key('sunday-hymns-row-$sunday'),
              sunday: sunday,
              label: i == 0
                  ? 'This Sunday, ${sundayLabel(sunday)}'
                  : sundayLabel(sunday),
              list: v.listFor(sunday),
              book: book,
              selected: sunday == _sunday,
              first: i == 0,
              onTap: () => _choose(sunday),
              line: c.line,
            ),
        ],
      ),
    );
  }

  Widget _editorSection(BuildContext context, AsyncValue<HymnBook> book) {
    final c = ChurchColors.of(context);
    final v = widget.value;
    final state = widget.state;
    final ctl = ref.read(staffSundayHymnsProvider.notifier);
    final saved = v.listFor(_sunday);
    final items = _items;
    final changed = _draft != null;
    final known = book.value == null
        ? null
        : v.editionNamed(book.requireValue.edition);
    final Widget picker;
    if (book.hasValue) {
      final b = book.requireValue;
      final matches = hymnQueryTokens(_query).isEmpty
          ? const <Hymn>[]
          : b
                .search(_query)
                .where((h) => !items.contains(h.id))
                .take(8)
                .toList();
      final full = items.length >= HymnListCommands.maxSundayItems;
      picker = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('sunday-hymns-search'),
            controller: _search,
            enabled: !full && known != null,
            onChanged: (q) => setState(() => _query = q),
            decoration: InputDecoration(
              labelText: 'Add a hymn or chorus',
              hintText: 'Number or title',
              helperText: full
                  ? 'A list has at most ${HymnListCommands.maxSundayItems} items.'
                  : null,
              prefixIcon: Icon(Icons.search, color: c.muted),
            ),
          ),
          if (matches.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final h in matches)
              _PickRow(
                key: Key('sunday-hymns-match-${h.id}'),
                hymn: h,
                onAdd: () {
                  _search.clear();
                  setState(() => _query = '');
                  _edit([...items, h.id]);
                },
              ),
          ] else if (hymnQueryTokens(_query).isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'No hymns match "${_query.trim()}".',
              key: const Key('sunday-hymns-no-match'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          ],
        ],
      );
    } else if (book.hasError && !book.isLoading) {
      picker = RequestStateBanner(
        key: const Key('sunday-hymns-book-error'),
        tone: StatusTone.warning,
        icon: Icons.error_outline,
        title: 'The hymn book could not be opened',
        message: 'Lists can be read, but not changed, until it opens.',
        actions: [
          BannerAction(
            'Try again',
            () => ref.invalidate(hymnBookProvider),
            key: const Key('sunday-hymns-book-retry'),
            primary: true,
          ),
        ],
      );
    } else {
      picker = const LinearProgressIndicator(
        key: Key('sunday-hymns-book-loading'),
      );
    }
    return StaffSection(
      key: const Key('sunday-hymns-editor'),
      title: _sunday == v.thisSunday
          ? 'This Sunday, ${sundayLabel(_sunday)}'
          : sundayLabel(_sunday),
      subtitle: saved == null
          ? 'Not set yet.'
          : saved.cleared
          ? 'Cleared by ${saved.savedBy}, ${churchShortWhen(saved.savedAt)}.'
          : 'Set by ${saved.savedBy} (${saved.savedCapacity.label}), '
                '${churchShortWhen(saved.savedAt)}.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (book.hasValue && known == null)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: RequestStateBanner(
                key: Key('sunday-hymns-edition-unknown'),
                tone: StatusTone.warning,
                title: 'This hymn book edition is not on the server',
                message:
                    'Lists can be read but not changed from this version of '
                    'staff web. Update it and try again.',
              ),
            ),
          if (items.isEmpty)
            Text(
              changed
                  ? 'No items in the list.'
                  : 'No hymns are set for this Sunday.',
              key: const Key('sunday-hymns-empty'),
              style: ChurchType.body.copyWith(color: c.muted),
            )
          else
            for (final (i, id) in items.indexed)
              _ListRow(
                key: Key('sunday-hymns-item-$id'),
                position: i + 1,
                label: _itemLabel(id, book.value),
                first: i == 0,
                onUp: i == 0
                    ? null
                    : () => _edit(
                        [...items]
                          ..insert(i - 1, items[i])
                          ..removeAt(i + 1),
                      ),
                onDown: i == items.length - 1
                    ? null
                    : () => _edit(
                        [...items]
                          ..insert(i + 2, items[i])
                          ..removeAt(i),
                      ),
                onRemove: () => _edit([...items]..removeAt(i)),
              ),
          const SizedBox(height: 16),
          picker,
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FocusRing(
                child: FilledButton(
                  key: const Key('sunday-hymns-save'),
                  onPressed:
                      state.busy || !changed || items.isEmpty || known == null
                      ? null
                      : () => ctl.setList(v, _sunday, known.edition, items),
                  child: const Text('Save list'),
                ),
              ),
              if (changed)
                FocusRing(
                  child: OutlinedButton(
                    key: const Key('sunday-hymns-discard'),
                    onPressed: state.busy
                        ? null
                        : () => setState(() => _draft = null),
                    child: const Text('Discard changes'),
                  ),
                ),
              if (saved != null && !saved.cleared && !changed)
                FocusRing(
                  child: OutlinedButton(
                    key: const Key('sunday-hymns-clear'),
                    onPressed: state.busy ? null : () => _confirmClear(context),
                    child: const Text('Clear this Sunday'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => ChurchDialog(
        key: const Key('sunday-hymns-clear-dialog'),
        title: 'Clear ${sundayLabel(_sunday)}?',
        content: const Text(
          'Members will no longer see hymns for this Sunday. You can set a '
          'new list at any time.',
        ),
        actions: [
          TextButton(
            key: const Key('sunday-hymns-clear-cancel'),
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep the list'),
          ),
          FilledButton(
            key: const Key('sunday-hymns-clear-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref
          .read(staffSundayHymnsProvider.notifier)
          .clearList(widget.value, _sunday);
    }
  }

  Widget _leadersSection(BuildContext context, bool busy) {
    final c = ChurchColors.of(context);
    final v = widget.value;
    final ctl = ref.read(staffSundayHymnsProvider.notifier);
    final leaders = v.worshipLeaders ?? const <WorshipLeader>[];
    final leading = {for (final l in leaders) l.memberId};
    final candidates = [
      for (final m in v.members ?? const <WorshipLeaderCandidate>[])
        if (!leading.contains(m.memberId)) m,
    ];
    final chosen = candidates.any((m) => m.memberId == _candidate?.memberId)
        ? _candidate
        : null;
    return StaffSection(
      key: const Key('sunday-hymns-leaders'),
      title: 'Worship leaders',
      subtitle: 'Besides Media and Admins, worship leaders set these lists.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (leaders.isEmpty)
            Text(
              'No worship leaders yet.',
              key: const Key('sunday-hymns-no-leaders'),
              style: ChurchType.body.copyWith(color: c.muted),
            )
          else
            for (final l in leaders)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(l.displayName, style: ChurchType.itemTitle),
                    ),
                    FocusRing(
                      child: TextButton(
                        key: Key('sunday-hymns-remove-leader-${l.memberId}'),
                        onPressed: busy
                            ? null
                            : () => ctl.revokeWorshipLeader(v, l),
                        child: const Text('Remove'),
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: DropdownButtonFormField<String>(
                  key: const Key('sunday-hymns-candidate'),
                  initialValue: chosen?.memberId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Member'),
                  items: [
                    for (final m in candidates)
                      DropdownMenuItem(
                        value: m.memberId,
                        child: Text(
                          m.account == AccountStanding.appAccount
                              ? m.displayName
                              : '${m.displayName} (no app sign-in)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (id) => setState(
                          () => _candidate = candidates
                              .where((m) => m.memberId == id)
                              .firstOrNull,
                        ),
                ),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: const Key('sunday-hymns-add-leader'),
                  onPressed: busy || chosen == null
                      ? null
                      : () => ctl.grantWorshipLeader(v, chosen),
                  child: const Text('Make worship leader'),
                ),
              ),
            ],
          ),
          if (v.membersTruncated)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Only the first 500 members are listed.',
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// One Sunday in the Sundays list: its date and its list (or "Not set").
class _SundayRow extends StatelessWidget {
  const _SundayRow({
    super.key,
    required this.sunday,
    required this.label,
    required this.list,
    required this.book,
    required this.selected,
    required this.first,
    required this.onTap,
    required this.line,
  });

  final String sunday;
  final String label;
  final StaffSundayList? list;
  final HymnBook? book;
  final bool selected;
  final bool first;
  final VoidCallback onTap;
  final Color line;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final items = list == null || list!.cleared
        ? const <String>[]
        : list!.items;
    final summary = items.isEmpty
        ? 'Not set'
        : items
              .map(
                (id) => id.startsWith('chorus-')
                    ? 'Chorus ${id.substring(7)}'
                    : id.substring(5),
              )
              .join(', ');
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.surface2 : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: first
                ? null
                : BoxDecoration(
                    border: Border(top: BorderSide(color: line)),
                  ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: ChurchType.itemTitle.copyWith(
                      color: c.ink,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    summary,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ChurchType.figures.copyWith(
                      color: items.isEmpty ? c.muted : c.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One item of the list being edited, with its position and controls.
class _ListRow extends StatelessWidget {
  const _ListRow({
    super.key,
    required this.position,
    required this.label,
    required this.first,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });

  final int position;
  final String label;
  final bool first;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: first
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$position',
              style: ChurchType.figures.copyWith(color: c.muted),
            ),
          ),
          Expanded(child: Text(label, style: ChurchType.body)),
          IconButton(
            tooltip: 'Move up',
            onPressed: onUp,
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: 'Move down',
            onPressed: onDown,
            icon: const Icon(Icons.arrow_downward),
          ),
          IconButton(
            tooltip: 'Remove from the list',
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// One search match with its Add button.
class _PickRow extends StatelessWidget {
  const _PickRow({super.key, required this.hymn, required this.onAdd});

  final Hymn hymn;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final chorus = hymn.kind == HymnKind.chorus;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${chorus ? 'Chorus' : 'Hymn'} ${hymn.number}, ${hymn.title}',
                  style: ChurchType.body.copyWith(color: c.ink),
                ),
                Text(
                  hymn.firstLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ChurchType.secondary.copyWith(color: c.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FocusRing(
            child: TextButton(
              key: Key('sunday-hymns-add-${hymn.id}'),
              onPressed: onAdd,
              child: const Text('Add'),
            ),
          ),
        ],
      ),
    );
  }
}
