// Disposable Flutter Web trial (Q10): dense rota grid, list alternative and
// safe CSV export over SYNTHETIC data. Do not build on this.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'csv_export.dart';
import 'download.dart';
import 'rota_fixture.dart';

/// Trial-local design-contract tokens. The semantic design system arrives with
/// entry 1.7; do not reuse these elsewhere.
abstract final class TrialTokens {
  static const bg = Color(0xFFF4F6FA);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFEDF0F6);
  static const ink = Color(0xFF0E1530);
  static const muted = Color(0xFF586079);
  static const line = Color(0xFFDFE4EE);
  static const primary = Color(0xFF14246B);
  static const accent = Color(0xFF0A7FE0);
  static const amberBg = Color(0xFFFFF1CF);
  static const amberFg = Color(0xFF6E4400);
}

/// Width of the visible keyboard focus ring.
const double kFocusRingWidth = 3;

typedef FileDownloader = bool Function(
  String filename,
  String content,
  String mimeType,
);

enum RotaView { grid, list }

/// Wait for a dialog's exit transition before announcing (see [_announce]).
const Duration kAnnouncementDelay = Duration(milliseconds: 400);

const String kCsvFilename = 'bic-kafue-rota-trial-SYNTHETIC.csv';

class RotaTrialScreen extends StatefulWidget {
  const RotaTrialScreen({
    super.key,
    required this.fixture,
    this.download = downloadTextFile,
  });

  final RotaFixture fixture;
  final FileDownloader download;

  @override
  State<RotaTrialScreen> createState() => _RotaTrialScreenState();
}

class _RotaTrialScreenState extends State<RotaTrialScreen> {
  late final List<List<RotaSlot>> _slots = [
    for (final row in widget.fixture.slots) [...row],
  ];
  late final List<List<FocusNode>> _cellNodes = [
    for (var r = 0; r < _slots.length; r++)
      [
        for (var c = 0; c < _slots[r].length; c++)
          FocusNode(debugLabel: 'slot $r,$c'),
      ],
  ];
  final _filter = TextEditingController();
  final _horizontal = ScrollController();
  RotaView _view = RotaView.grid;
  int _activeRow = 0;
  int _activeCol = 0;
  String _announcement = '';

  @override
  void initState() {
    super.initState();
    for (var r = 0; r < _cellNodes.length; r++) {
      for (var c = 0; c < _cellNodes[r].length; c++) {
        final node = _cellNodes[r][c];
        node.addListener(() {
          if (node.hasFocus && (r != _activeRow || c != _activeCol)) {
            setState(() {
              _activeRow = r;
              _activeCol = c;
            });
          }
        });
      }
    }
    _filter.addListener(() => setState(_ensureActiveVisible));
  }

  @override
  void dispose() {
    for (final row in _cellNodes) {
      for (final node in row) {
        node.dispose();
      }
    }
    _filter.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  List<int> get _visibleRows {
    final q = _filter.text.trim().toLowerCase();
    return [
      for (var r = 0; r < _slots.length; r++)
        if (q.isEmpty || widget.fixture.positions[r].toLowerCase().contains(q))
          r,
    ];
  }

  void _ensureActiveVisible() {
    final rows = _visibleRows;
    if (rows.isNotEmpty && !rows.contains(_activeRow)) {
      _activeRow = rows.first;
    }
  }

  String _slotLabel(RotaSlot slot) {
    final member = widget.fixture.memberById(slot.memberId)?.displayName;
    return '${slot.position}, ${slot.date.label}: '
        '${member ?? 'no one assigned'}, ${slot.status.label}';
  }

  /// Arrow keys move between slots; Home/End jump within a row, and with
  /// Control to the first/last slot. Tab is left to normal traversal, which
  /// enters and leaves the grid at the active slot (roving tab stop).
  KeyEventResult _onGridKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final rows = _visibleRows;
    final rowIndex = rows.indexOf(_activeRow);
    if (rowIndex < 0) return KeyEventResult.ignored;
    final lastCol = widget.fixture.dates.length - 1;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    var nextRowIndex = rowIndex;
    var nextCol = _activeCol;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        nextCol = math.max(0, _activeCol - 1);
      case LogicalKeyboardKey.arrowRight:
        nextCol = math.min(lastCol, _activeCol + 1);
      case LogicalKeyboardKey.arrowUp:
        nextRowIndex = math.max(0, rowIndex - 1);
      case LogicalKeyboardKey.arrowDown:
        nextRowIndex = math.min(rows.length - 1, rowIndex + 1);
      case LogicalKeyboardKey.home:
        nextCol = 0;
        if (ctrl) nextRowIndex = 0;
      case LogicalKeyboardKey.end:
        nextCol = lastCol;
        if (ctrl) nextRowIndex = rows.length - 1;
      default:
        return KeyEventResult.ignored;
    }
    _activate(rows[nextRowIndex], nextCol);
    return KeyEventResult.handled;
  }

  /// Makes slot (r, c) the grid's single tab stop and focuses it.
  void _activate(int r, int c) {
    setState(() {
      _activeRow = r;
      _activeCol = c;
    });
    final node = _cellNodes[r][c]
      ..canRequestFocus = true
      ..requestFocus();
    // requestFocus alone does not scroll; bring the slot into view in both
    // the grid's horizontal scroller and the page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final slotContext = node.context;
      if (slotContext != null && slotContext.mounted) {
        Scrollable.ensureVisible(slotContext, alignment: 0.5);
      }
    });
  }

  Future<void> _openSlot(int r, int c) async {
    final updated = await showDialog<RotaSlot>(
      context: context,
      builder: (context) =>
          _SlotDialog(slot: _slots[r][c], members: widget.fixture.members),
    );
    if (!mounted || updated == null) return;
    setState(() => _slots[r][c] = updated);
    _announce('Saved. ${_slotLabel(updated)}.');
  }

  /// Shows [message] as persistent status text and announces it to screen
  /// readers once the closing dialog has left the page.
  ///
  /// Trial finding: in Chromium, `Semantics(liveRegion: true)` around the
  /// status text produced no aria-live announcement, and the engine moves its
  /// announcement element into any still-open modal dialog. The explicit
  /// announcement is therefore sent after the dialog's exit transition.
  void _announce(String message) {
    setState(() => _announcement = message);
    final view = View.of(context);
    Future<void>.delayed(kAnnouncementDelay, () {
      if (mounted && _announcement == message) {
        SemanticsService.sendAnnouncement(view, message, TextDirection.ltr);
      }
    });
  }

  Future<void> _openExport() async {
    final rows = _visibleRows;
    final slots = [for (final r in rows) ..._slots[r]];
    final csv = buildRotaCsv(slots, widget.fixture.memberById);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ExportDialog(
        positions: rows.length,
        dates: widget.fixture.dates.length,
        rows: slots.length,
        preview: csv.substring(1).split('\r\n').take(4).join('\n'),
      ),
    );
    if (!mounted || confirmed != true) return;
    final ok = widget.download(kCsvFilename, csv, 'text/csv;charset=utf-8');
    _announce(
      ok
          ? 'Downloaded $kCsvFilename with ${slots.length} rows.'
          : 'The download did not start. Nothing was saved; try again.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visibleRows;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Scaffold(
      backgroundColor: TrialTokens.bg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final pad = constraints.maxWidth < 600 ? 16.0 : 32.0;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, 24, pad, 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  headingLevel: 1,
                  child: const Text(
                    'Duty rotas',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: TrialTokens.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Ushering · October–November 2026 · '
                  'SYNTHETIC test data — not real people',
                  style: TextStyle(fontSize: 15, color: TrialTokens.muted),
                ),
                const SizedBox(height: 20),
                _toolbar(rows, scale, constraints.maxWidth - 2 * pad),
                const SizedBox(height: 16),
                const _StatusKey(),
                const SizedBox(height: 12),
                Semantics(
                  container: true,
                  child: Text(
                    _announcement,
                    key: const Key('announcement'),
                    style: const TextStyle(
                      fontSize: 15,
                      color: TrialTokens.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty)
                  Padding(
                    key: const Key('empty-filter'),
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No positions match “${_filter.text.trim()}”. '
                      'Clear the filter to see the rota.',
                      style: const TextStyle(fontSize: 15),
                    ),
                  )
                else if (_view == RotaView.grid)
                  _grid(rows, scale)
                else
                  _list(rows),
                const SizedBox(height: 16),
                const Text(
                  'Grid keys: arrow keys move between slots; Home and End jump '
                  'within a row; Control+Home and Control+End jump to the first '
                  'and last slot; Enter opens a slot; Tab leaves the grid.',
                  style: TextStyle(fontSize: 14, color: TrialTokens.muted),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _toolbar(List<int> rows, double scale, double width) {
    final exportBlocked = rows.isEmpty;
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: math.min(320 * scale, width),
          child: TextField(
            key: const Key('position-filter'),
            controller: _filter,
            decoration: const InputDecoration(
              labelText: 'Filter positions',
              hintText: 'e.g. door',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        SegmentedButton<RotaView>(
          key: const Key('view-toggle'),
          // SegmentedButton does not expose which segment is selected to the
          // browser, so each segment is announced as a radio button.
          segments: [
            ButtonSegment(
              value: RotaView.grid,
              label: _segmentLabel('Grid', _view == RotaView.grid),
              icon: const Icon(Icons.grid_on),
            ),
            ButtonSegment(
              value: RotaView.list,
              label: _segmentLabel('List', _view == RotaView.list),
              icon: const Icon(Icons.view_list),
            ),
          ],
          selected: {_view},
          onSelectionChanged: (s) => setState(() => _view = s.single),
        ),
        FilledButton.icon(
          key: const Key('export-button'),
          onPressed: exportBlocked ? null : _openExport,
          icon: const Icon(Icons.download),
          label: const Text('Export CSV…'),
        ),
        if (exportBlocked)
          const Text(
            'Nothing to export: no positions match the filter.',
            key: Key('export-blocked-reason'),
            style: TextStyle(fontSize: 14, color: TrialTokens.muted),
          ),
      ],
    );
  }

  Widget _segmentLabel(String text, bool selected) => Semantics(
    inMutuallyExclusiveGroup: true,
    checked: selected,
    child: Text(text),
  );

  Widget _grid(List<int> rows, double scale) {
    final dates = widget.fixture.dates;
    _ensureActiveVisible();
    Widget header(String text) => Semantics(
      role: SemanticsRole.columnHeader,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          text.toUpperCase(),
          semanticsLabel: text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.72,
            color: TrialTokens.muted,
          ),
        ),
      ),
    );
    final table = Table(
      key: const Key('rota-grid'),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.all(color: TrialTokens.line),
      columnWidths: {
        0: FixedColumnWidth(140 * scale),
        for (var c = 1; c <= dates.length; c++)
          c: FixedColumnWidth(170 * scale),
      },
      children: [
        TableRow(
          decoration: const BoxDecoration(color: TrialTokens.surface2),
          children: [
            header('Position'),
            for (final d in dates) header(d.label),
          ],
        ),
        for (final r in rows)
          TableRow(
            decoration: const BoxDecoration(color: TrialTokens.surface),
            children: [
              TableCell(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    widget.fixture.positions[r],
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: TrialTokens.ink,
                    ),
                  ),
                ),
              ),
              for (var c = 0; c < dates.length; c++)
                TableCell(
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: _slotButton(r, c),
                  ),
                ),
            ],
          ),
      ],
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onGridKey,
      child: Scrollbar(
        controller: _horizontal,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _horizontal,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 14),
          child: table,
        ),
      ),
    );
  }

  Widget _slotButton(int r, int c) {
    final slot = _slots[r][c];
    final node = _cellNodes[r][c];
    // Roving tab stop: only the active slot is in the Tab order. Flutter's
    // own traversal honours skipTraversal, but the browser tabs through DOM
    // tabindex, which follows canRequestFocus; both are set.
    final active = r == _activeRow && c == _activeCol;
    node.skipTraversal = !active;
    final member = widget.fixture.memberById(slot.memberId)?.displayName;
    return _StatusButton(
      focusNode: node,
      canRequestFocus: active,
      status: slot.status,
      semanticLabel: _slotLabel(slot),
      onPressed: () {
        _activate(r, c);
        _openSlot(r, c);
      },
      primary: member ?? '+ Assign',
      secondary: slot.status.label,
    );
  }

  Widget _list(List<int> rows) {
    return Column(
      key: const Key('rota-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in rows) ...[
          Semantics(
            header: true,
            headingLevel: 2,
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Text(
                widget.fixture.positions[r],
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: TrialTokens.primary,
                ),
              ),
            ),
          ),
          Semantics(
            role: SemanticsRole.list,
            explicitChildNodes: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < _slots[r].length; c++)
                  Semantics(
                    role: SemanticsRole.listItem,
                    container: true,
                    child: _listItem(r, c),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _listItem(int r, int c) {
    final slot = _slots[r][c];
    final member = widget.fixture.memberById(slot.memberId)?.displayName;
    return Container(
      key: Key('list-$r-$c'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TrialTokens.surface,
        border: Border.all(color: TrialTokens.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            slot.date.label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          Text(
            member ?? 'No one assigned',
            style: const TextStyle(fontSize: 15),
          ),
          StatusChip(status: slot.status),
          OutlinedButton(
            onPressed: () => _openSlot(r, c),
            child: Text(
              'Change',
              semanticsLabel: 'Change ${slot.position}, ${slot.date.label}',
            ),
          ),
        ],
      ),
    );
  }
}

/// A rota slot rendered as one button: member and status label, status
/// colours, and a thick accent ring while it has focus.
///
/// Built on [InkWell] rather than a Material button so that [canRequestFocus]
/// can drop non-active slots from the browser's Tab order (roving tab stop).
class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.focusNode,
    required this.canRequestFocus,
    required this.status,
    required this.semanticLabel,
    required this.onPressed,
    required this.primary,
    required this.secondary,
  });

  final FocusNode focusNode;
  final bool canRequestFocus;
  final SlotStatus status;
  final String semanticLabel;
  final VoidCallback onPressed;
  final String primary;
  final String secondary;

  @override
  Widget build(BuildContext context) {
    final dashed = status == SlotStatus.unfilled || status == SlotStatus.draft;
    final radius = BorderRadius.circular(10);
    return Semantics(
      container: true,
      button: true,
      label: semanticLabel,
      child: Material(
        color: status.background,
        borderRadius: radius,
        child: InkWell(
          focusNode: focusNode,
          canRequestFocus: canRequestFocus,
          onTap: onPressed,
          borderRadius: radius,
          child: ExcludeSemantics(
            child: ListenableBuilder(
              listenable: focusNode,
              builder: (context, child) => Container(
                constraints: const BoxConstraints(minHeight: 48),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: focusNode.hasFocus
                      ? Border.all(
                          color: TrialTokens.accent,
                          width: kFocusRingWidth,
                        )
                      : Border.all(
                          color: dashed
                              ? const Color(0xFFC9D0E0)
                              : status.background,
                        ),
                ),
                child: child,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    primary,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: status.foreground,
                    ),
                  ),
                  Text(
                    secondary,
                    style: TextStyle(fontSize: 12, color: status.foreground),
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

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final SlotStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: status.background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: status.foreground.withValues(alpha: 0.35)),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: status.foreground,
        ),
      ),
    );
  }
}

class _StatusKey extends StatelessWidget {
  const _StatusKey();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Status key:', style: TextStyle(fontSize: 14)),
        for (final s in SlotStatus.values) StatusChip(status: s),
      ],
    );
  }
}

class _SlotDialog extends StatefulWidget {
  const _SlotDialog({required this.slot, required this.members});

  final RotaSlot slot;
  final List<Member> members;

  @override
  State<_SlotDialog> createState() => _SlotDialogState();
}

class _SlotDialogState extends State<_SlotDialog> {
  late String? _memberId = widget.slot.memberId;
  late SlotStatus _status = widget.slot.status;

  @override
  Widget build(BuildContext context) {
    final assignable = SlotStatus.values.where((s) => s != SlotStatus.unfilled);
    return AlertDialog(
      title: Text('${widget.slot.position} — ${widget.slot.date.label}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String?>(
              key: const Key('slot-member'),
              initialValue: _memberId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Member',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('No one assigned'),
                ),
                for (final m in widget.members)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text(m.displayName, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) => setState(() {
                _memberId = id;
                if (id == null) {
                  _status = SlotStatus.unfilled;
                } else if (_status == SlotStatus.unfilled) {
                  _status = SlotStatus.draft;
                }
              }),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<SlotStatus>(
              key: const Key('slot-status'),
              initialValue: _status,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Status',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final s
                    in _memberId == null ? [SlotStatus.unfilled] : assignable)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (s) => setState(() => _status = s ?? _status),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('slot-save'),
          onPressed: () => Navigator.of(context).pop(
            widget.slot.copyWith(
              memberId: _memberId,
              clearMember: _memberId == null,
              status: _status,
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ExportDialog extends StatelessWidget {
  const _ExportDialog({
    required this.positions,
    required this.dates,
    required this.rows,
    required this.preview,
  });

  final int positions;
  final int dates;
  final int rows;
  final String preview;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export rota CSV'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Scope: $positions positions × $dates Sundays = $rows rows '
                '(the positions shown by the current filter).',
                key: const Key('export-scope'),
              ),
              const SizedBox(height: 8),
              Text('Columns: ${kCsvColumns.join(', ')}.'),
              const SizedBox(height: 8),
              const Text('Not included: phone numbers and care notes.'),
              const SizedBox(height: 8),
              const Text(
                'Text that a spreadsheet could run as a formula is prefixed '
                'with an apostrophe so it shows as plain text.',
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                color: TrialTokens.amberBg,
                child: const Text(
                  'Warning: the downloaded file is outside the app’s access '
                  'controls. Store and delete it under the church’s agreed '
                  'process. It is not emailed or shared automatically.',
                  style: TextStyle(color: TrialTokens.amberFg),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Preview (first rows):'),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: TrialTokens.surface2,
                child: Text(
                  preview,
                  key: const Key('export-preview'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('export-download'),
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.download),
          label: const Text('Download CSV'),
        ),
      ],
    );
  }
}
