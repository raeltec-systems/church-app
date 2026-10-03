/// Wire contract v1 shared by the Flutter clients (mobile and staff web).
///
/// SQL (`app.contract_check`) is authoritative; this mapping and the TypeScript mapping pass
/// the same fixtures in `packages/contracts/fixtures/v1`.
library;

export 'src/check.dart'
    show
        CheckResult,
        ContractKind,
        ContractViolation,
        check,
        contractVersion,
        errorCodeNames,
        lifecycleEventNames,
        maxRevision,
        require;
export 'src/models.dart';
