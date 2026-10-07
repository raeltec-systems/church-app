/// Story 2.4: an applicant's own membership request and the safe cell
/// chooser, as the server reports them. Applying grants nothing: church
/// approval (entry 5) and cell confirmation (entry 6) are separate server
/// decisions. Free of widgets and SDKs.
library;

import 'access_grants.dart' show AccessRead, AccessDenial, AccessReadDenied;

/// The answer to "Which cell group do you belong to?" (wire names).
enum CellChoiceKind {
  cell('cell'),
  notSure('not_sure'),
  notInCell('not_in_cell');

  const CellChoiceKind(this.wire);
  final String wire;

  static CellChoiceKind? fromWire(Object? v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

class CellChoice {
  const CellChoice.cell({
    required String this.cellId,
    required int this.cellRevision,
  }) : kind = CellChoiceKind.cell;
  const CellChoice.notSure()
    : kind = CellChoiceKind.notSure,
      cellId = null,
      cellRevision = null;
  const CellChoice.notInCell()
    : kind = CellChoiceKind.notInCell,
      cellId = null,
      cellRevision = null;

  factory CellChoice.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('cell choice is not an object');
    }
    final kind = CellChoiceKind.fromWire(json['choice']);
    final id = json['cell_id'];
    final revision = json['cell_revision'];
    switch (kind) {
      case CellChoiceKind.cell:
        if (id is! String || revision is! int || revision < 1) {
          throw const FormatException('unexpected cell choice');
        }
        return CellChoice.cell(cellId: id, cellRevision: revision);
      case CellChoiceKind.notSure:
      case CellChoiceKind.notInCell:
        if (id != null || revision != null) {
          throw const FormatException('unexpected cell choice');
        }
        return kind == CellChoiceKind.notSure
            ? const CellChoice.notSure()
            : const CellChoice.notInCell();
      case null:
        throw const FormatException('unknown cell choice');
    }
  }

  final CellChoiceKind kind;
  final String? cellId;
  final int? cellRevision;

  Map<String, Object?> toJson() => {
    'choice': kind.wire,
    if (kind == CellChoiceKind.cell) ...{
      'cell_id': cellId,
      'cell_revision': cellRevision,
    },
  };

  /// Same answer (a new option revision of the same cell is the same answer).
  bool sameAs(CellChoice other) => kind == other.kind && cellId == other.cellId;
}

/// One entry of the safe sign-up projection: a church-approved label and a
/// broad area. Nothing else about a cell ever reaches an applicant.
class CellOption {
  const CellOption({
    required this.cellId,
    required this.label,
    required this.broadArea,
    required this.revision,
  });

  factory CellOption.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('cell option is not an object');
    }
    final id = json['cell_id'];
    final label = json['label'];
    final area = json['broad_area'];
    final revision = json['revision'];
    if (id is! String ||
        label is! String ||
        area is! String ||
        revision is! int ||
        revision < 1) {
      throw const FormatException('unexpected cell option');
    }
    return CellOption(
      cellId: id,
      label: label,
      broadArea: area,
      revision: revision,
    );
  }

  final String cellId;
  final String label;
  final String broadArea;
  final int revision;
}

/// `api.cells_signup_options`.
List<CellOption> cellOptionsFromJson(Object? json) {
  if (json is! Map || json['options'] is! List) {
    throw const FormatException('unexpected cell options');
  }
  return List.unmodifiable((json['options'] as List).map(CellOption.fromJson));
}

/// Church approval, separate from the cell.
enum ChurchStatus {
  awaitingApproval('awaiting_approval'),
  detailsRequested('details_requested'),
  approved('approved'),
  notApproved('not_approved'),
  withdrawn('withdrawn');

  const ChurchStatus(this.wire);
  final String wire;
}

/// The cell, separate from church approval. Confirmation is entry 6.
enum CellStatus {
  /// A cell was chosen; its leader or Admin has not confirmed it.
  requested('requested'),

  /// "I'm not sure" or "I'm not in a cell yet": the church follows up.
  followUp('follow_up');

  const CellStatus(this.wire);
  final String wire;
}

T _enum<T extends Enum>(List<T> values, String Function(T) wire, Object? v) {
  for (final e in values) {
    if (wire(e) == v) return e;
  }
  throw FormatException('unexpected value $v');
}

class MembershipApplication {
  const MembershipApplication({
    required this.applicationId,
    required this.revision,
    required this.applicationState,
    required this.churchStatus,
    required this.fullName,
    required this.phoneUsername,
    required this.cellChoice,
    required this.cellStatus,
    required this.privacyNoticeVersion,
    required this.isSynthetic,
  });

  factory MembershipApplication.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('application is not an object');
    }
    final id = json['application_id'];
    final revision = json['revision'];
    final state = json['application_state'];
    final name = json['full_name'];
    final phone = json['phone_username'];
    final notice = json['privacy_notice_version'];
    final synthetic = json['is_synthetic'];
    if (id is! String ||
        revision is! int ||
        revision < 1 ||
        state is! String ||
        name is! String ||
        phone is! String ||
        notice is! String ||
        synthetic is! bool) {
      throw const FormatException('unexpected application shape');
    }
    return MembershipApplication(
      applicationId: id,
      revision: revision,
      applicationState: state,
      churchStatus: _enum(
        ChurchStatus.values,
        (e) => e.wire,
        json['church_status'],
      ),
      fullName: name,
      phoneUsername: phone,
      cellChoice: CellChoice.fromJson(json['cell_choice']),
      cellStatus: _enum(CellStatus.values, (e) => e.wire, json['cell_status']),
      privacyNoticeVersion: notice,
      isSynthetic: synthetic,
    );
  }

  final String applicationId;
  final int revision;
  final String applicationState;
  final ChurchStatus churchStatus;
  final String fullName;

  /// The unverified sign-in username, as submitted.
  final String phoneUsername;
  final CellChoice cellChoice;
  final CellStatus cellStatus;
  final String privacyNoticeVersion;
  final bool isSynthetic;

  /// The applicant may still correct it (the server decides; this only
  /// shows or hides the action).
  bool get correctable =>
      churchStatus == ChurchStatus.awaitingApproval ||
      churchStatus == ChurchStatus.detailsRequested;
}

class PrivacyNotice {
  const PrivacyNotice({required this.version, required this.draft});
  final String version;

  /// Not yet approved by the church (Q4): shown with a draft label.
  final bool draft;
}

/// `api.identity_my_application`.
class MyApplication {
  const MyApplication({
    required this.application,
    required this.privacyNotice,
    required this.accepting,
  });

  factory MyApplication.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('not an object');
    final notice = json['privacy_notice'];
    final accepting = json['accepting_applications'];
    if (notice is! Map ||
        notice['version'] is! String ||
        notice['draft'] is! bool ||
        accepting is! bool) {
      throw const FormatException('unexpected my-application shape');
    }
    final app = json['application'];
    return MyApplication(
      application: app == null ? null : MembershipApplication.fromJson(app),
      privacyNotice: PrivacyNotice(
        version: notice['version'] as String,
        draft: notice['draft'] as bool,
      ),
      accepting: accepting,
    );
  }

  final MembershipApplication? application;
  final PrivacyNotice privacyNotice;

  /// The server accepts new requests here (Q4 personal-data gate).
  final bool accepting;

  MyApplication withApplication(MembershipApplication a) => MyApplication(
    application: a,
    privacyNotice: privacyNotice,
    accepting: accepting,
  );
}

/// Application port for the applicant's reads. Never throws; a fresh request
/// every call.
abstract interface class MembershipRepository {
  Future<AccessRead<MyApplication>> fetchMyApplication();
  Future<AccessRead<List<CellOption>>> fetchCellOptions();
}

class UnconfiguredMembershipRepository implements MembershipRepository {
  const UnconfiguredMembershipRepository();

  @override
  Future<AccessRead<MyApplication>> fetchMyApplication() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<List<CellOption>>> fetchCellOptions() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// The application command function and command names (1.4 envelope).
abstract final class ApplicationCommands {
  static const function = 'identity_application_command';
  static const submit = 'identity.submit_application';
  static const correct = 'identity.correct_application';
}

/// The privacy notice text bundled for each server version. A DRAFT until
/// the church approves the wording (Q4); the screen labels it as such.
const privacyNoticeTexts = <String, String>{
  'draft-2026-10-07':
      'The church keeps your name, your sign-in phone number and your cell '
      'answer to review your membership request. Church staff use them only '
      'for membership and cell follow-up, and they are not shown to other '
      'members. Church approval and your cell are checked separately. Ask '
      'the church office to correct or remove your details.',
};
