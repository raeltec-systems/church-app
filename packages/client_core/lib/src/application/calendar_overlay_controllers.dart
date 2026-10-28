import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/calendar_overlays.dart';
import 'providers.dart' show accountGenerationProvider;

/// Epic 6 entry 19: the member's own cell meetings for the Calendar overlay
/// (`api.cells_my_meetings`). Unconfigured by default; the composition root
/// supplies the Supabase adapter.
final cellCalendarRepositoryProvider = Provider<CellCalendarRepository>(
  (ref) => const UnconfiguredCellCalendarRepository(),
);

/// Which of the member's overlays are switched on. Both start off, so the
/// Calendar opens as everyone's calendar; the choice lasts for the app
/// session and is dropped on any account change (memory only).
class CalendarOverlaySwitches {
  const CalendarOverlaySwitches({this.duties = false, this.cell = false});

  final bool duties;
  final bool cell;

  bool get any => duties || cell;
}

class CalendarOverlaySwitchesController
    extends Notifier<CalendarOverlaySwitches> {
  @override
  CalendarOverlaySwitches build() {
    ref.watch(accountGenerationProvider);
    return const CalendarOverlaySwitches();
  }

  void setDuties(bool on) =>
      state = CalendarOverlaySwitches(duties: on, cell: state.cell);

  void setCell(bool on) =>
      state = CalendarOverlaySwitches(duties: state.duties, cell: on);
}

final calendarOverlaySwitchesProvider =
    NotifierProvider<
      CalendarOverlaySwitchesController,
      CalendarOverlaySwitches
    >(CalendarOverlaySwitchesController.new);

/// The cell overlay's read: null until the first answer.
class MyCellMeetingsState {
  const MyCellMeetingsState({this.loading = false, this.result});

  final bool loading;
  final AccessRead<MyCellMeetingsWindow>? result;
}

/// Reads the member's own cell meetings when first watched (the My cell
/// switch is on) and again on [reload]. Memory only, scoped to the account
/// generation; the server rechecks live access and the confirmed cell on
/// every read.
class MyCellMeetingsController extends Notifier<MyCellMeetingsState> {
  int _epoch = 0;

  @override
  MyCellMeetingsState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _load(epoch));
    return const MyCellMeetingsState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _load(_epoch);

  Future<void> _load(int epoch) async {
    if (!_current(epoch)) return;
    state = MyCellMeetingsState(loading: true, result: state.result);
    final r = await ref.read(cellCalendarRepositoryProvider).fetchMyMeetings();
    if (!_current(epoch)) return;
    state = MyCellMeetingsState(result: r);
  }
}

final myCellMeetingsProvider =
    NotifierProvider<MyCellMeetingsController, MyCellMeetingsState>(
      MyCellMeetingsController.new,
    );
