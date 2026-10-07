# Fix: the v1 field-error vocabulary (after story 2.8)

Date: 2026-10-07. Status: decided and implemented.

## Defect

Story 1.5 published wire contract v1 with a closed list of 11 field error codes. The SQL authority (`app.contract_check`), the Dart mapping (`church_contracts`) and the TypeScript mapping all rejected any other code. From story 2.1 onward, the Identity and Cells commands return more specific codes through `app.cmd_fail`. The server never checks its own envelopes, so these refusals left the server unchanged. The Dart `CommandResponse.fromJson` then threw `ContractViolation`, and `SupabaseCommandGateway` turned every such refusal into `CommandUnknownOutcome`. The notices that 2.5, 2.7 and 2.8 had already mapped (`last_admin`, `reauthenticate`, `held`, `password_reset_required` and others) never appeared with the real gateway. Widget tests use `FakeCommandGateway`, so they missed it. Story 2.8's live check C4 exposed it, and C4 had been weakened to `released is! CommandConfirmed`.

## Codes the server emits beyond the core list

These come from `cmd_fail(` in `supabase/migrations`:

- **Codes named in the brief:** `last_admin`, `reauthenticate`, `password_reset_required`, `held`, `stale`, `other_changes`, `password_unreviewed`, `already_approved`, `open_request`, `current`, `decided`, `has_grants`, `unverified`.
- **Other codes:** `linked`, `not_linked`, `ambiguous`, `taken`, `changed`, `unchanged`, `unavailable`, `pending`, `pending_change`, `already_held`, `released`, `not_approved`, `phone_unsupported`, `phone_taken`, `email_unverified`, `email_taken`, `unsupported_factors`, `account_deleted`, `no_recovery_email`, `not_applicant`, `account_unavailable`.
- **Codes built at runtime:** the `v_errors` and `contract_check` paths.
- **Not a field error code:** `cancelled_by_admin` is a stored `decision_reason`.

## Decision

Field error codes are now an open, documented vocabulary in v1. Any value matching `^[a-z][a-z0-9_]{0,62}$` (the existing `contract_token_error` rule) is a valid code. A value of another shape still makes the envelope invalid.

- **No new version:** this remains contract v1, and no field, kind, or top-level error code changes. The server's output is unchanged. This change only makes the readers accept what v1 servers have sent since story 2.1. No client older than this fix could read these envelopes in any case.
- **Rejected option:** adding the roughly 35 codes to the closed list. The next command would bring the same break back, and every new code would need a contract bump in three implementations.
- **Client rule:** a client maps the codes it knows to specific notices. Any other code falls back to the notice for the top-level `code`, with its `message`. A well-formed error envelope never becomes an unknown outcome because of a field error code.
- **Core list kept:** `contract_field_error_codes()`, `fieldErrorCodeNames` and `FIELD_ERROR_CODES` stay as documentation of the core shape-check codes.
- **Runbook:** `docs/runbooks/contracts-and-owner-seams.md` is amended to match.

## Changes

- **Fixtures** (`command_response.json`):
  - New valid cases: Identity `forbidden {"member_id": "last_admin"}`, a conflict carrying 9 Identity/Cells codes, and a code at the 63-character limit.
  - New invalid cases: codes that break the pattern (uppercase, hyphen, leading digit, empty, 64 characters).
  - Removed: the old `too_big` case, which is now valid.
- **SQL:** migration `20261007160200_open_field_error_vocabulary.sql` changes only the `field_errors` clause of `app.contract_check`. pgTAP asserts that the real `release_hold` refusal is contract-valid.
- **Dart and TS:** pattern check, plus `isFieldErrorCode` and unit tests.
- **Real-gateway test:** `packages/client_core/test/adapters/real_gateway_refusals_test.dart` runs the real `SupabaseCommandGateway` over 10 recorded refusals, an unknown code, and a malformed code. It also includes Admin credential-review widget tests on the real gateway, where `passwordResetRequired` shows, and an unknown code falls back to `changedElsewhere`.
- **Live checks:**
  - `live_credentials_check.dart` C4 is restored. It now passes with `release=refused:conflict{"hold_id":"password_reset_required"}`.
  - `live_recovery_check.dart` L2 failed because of earlier drift. Since the 2.8 review fix, the in-review own read omits `verified`, so L2 now asserts the pending proposal.
