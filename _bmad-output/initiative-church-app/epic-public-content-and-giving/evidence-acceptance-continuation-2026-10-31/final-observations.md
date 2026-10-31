# Final continuation observations

## Full deletion, recovery and isolated restore: 12/12 passed

Exact source: `8ed2387e67564469c4e6ddb04773f752e3c5e1a7`. The final mail-enabled, readiness-checked run used actual local Auth, Data API, the deletion worker, Edge Function, local email capture and an isolated PostgreSQL restore. See `identity-deletion-with-mail-stable-result.json` and the matching JSONL.

The checks cover last-Admin protection; immediate denial of existing sessions and fresh password sign-in; interruption/resumption and journal acknowledgements; recovery from an unreachable function; actual Auth/Identity erasure; repeat no-op; accountless staff deletion; opaque journal entries; held restore with deletion replay; identity-leftover checks; last-two-Admin concurrency; and no SMS. Read the JSONL's grouping rather than treating this prose as additional test cases.

Cleanup reports zero fixture users, its credential revoked, its principal disabled and its uniquely owned restore container removed. The temporary local environment marker was removed. This is backend evidence, not a signed-in UI or device test. The runner does not populate every possible Content object in one account; RSVP-specific erasure and SQL tests provide separate coverage.

The earlier attempts remain distinct: Windows `spawn npx ENOENT` before scenarios; a mail-disabled 11/12 run (email-change HTTP 500/no one-time token); and one mail-enabled reset attempt interrupted by `fetch failed` before assertions, with cleanup executed. The final 12/12 followed three successful Auth readiness reads and used a fresh private journal directory. None of the earlier attempts has been relabelled passed.

## Exact engineering-head CI: all four jobs passed

[Run 41184512896](https://github.com/raeltec-systems/church-app/actions/runs/41184512896) is **completed/success** on `8ed2387e67564469c4e6ddb04773f752e3c5e1a7`. The saved run and job JSON confirm:

- Policy checks completed successfully. A credential-dependent hosted-drift step is not independent live staging parity evidence.
- Offline harness/function unit tests completed successfully on Linux.
- Database pgTAP, API smoke, contract fixtures and isolated restore rehearsal completed successfully.
- Flutter analyses/tests, VM/Chrome contracts, real non-Lusaka checks and staff/trial web builds completed successfully.

Planning run 41184512974 and manual history validation run 41184512877 also succeeded on `8ed2387`. The preceding `c3b633d` full CI run 41184121916 was cancelled after the newer push; it is not counted as a pass. Final documentation commits need their own checks; this result is not reassigned to a later SHA.

The Windows offline retry remains **433/436**, and its policy retry **55/56**. Linux success does not make those Windows executions pass. Their scanner-path and POSIX mode failures are recorded in `failures-and-limits.json`; no test was disabled. The Dart VM line-ending failure is separately resolved by the 284/284 LF retry, not erased from the original 19-step ledger.

## Native build and device boundary

This Windows host has Flutter 3.47.6, Android SDK/build-tools 36, JDK 21 and accepted Android SDK licences. Attached targets were Windows, Chrome and Edge only. No Android/iOS phone was attached; iOS compilation/signing is not available on this host. Android compilation is a separate observation below, not implied by tool availability.

The repository's Android Gradle release block currently uses debug signing. This is not a production-signing configuration. Proper release signing and distribution remain prerequisites; no private signing material was read or changed. No Firebase push defines were provided for the local compile check.

## Restored workstation state

`cleanup-result.json` records local phone auth off, only `church-content-acceptance-20261031` stopped, its private test volumes/journals preserved, and `supabase/config.toml` restored to its original byte hash. The original shared database's container ID and start time are unchanged, and its checkout was not edited.

The initial cleanup hash guard stopped because the temporary config had been normalized from CRLF to LF during the fixture correction. A reconstructed comparison proved exactly that line-ending-only difference, with no semantic edits. Both temporary hashes are recorded; only then were the original bytes restored.

## Acceptance remains open

Signed-in browser automation was blocked by the tool safety check and not retried by another route. Native playback/dialler/offline/push, the owner's staging walkthrough, hymn source review, product-limit dispositions, broader deployed parity, independent review and controlled production promotion remain unverified. **6.15 stays in-progress; 6.17 stays planned.** Use the closeout checklist rather than test counts to complete them.

## Resumed verification: native artifact and Windows scanner

The recovered Android debug build finished with exit 0 on engineering source
`8ed2387e67564469c4e6ddb04773f752e3c5e1a7`. Its result JSON and build log are now
retained here. The actual 183,406,254-byte APK was rehashed on the workstation:
`5075862587a9cbd8d352ec418f005830b4db1104d45917206d75ca9e15cdd6fe`.
It is a debug-signed, local-backend compile artifact without Firebase push
configuration, not a staging pilot package, installation result or release.
The Kotlin/plugin and SDK XML compatibility warnings remain visible in the log;
no dependency or SDK version was silently upgraded to remove them.

The resumed work fixes the scanner test launcher, not the scanner policy. A
file URL pathname was not a decoded Windows filesystem path, and Node could
select the System32 WSL launcher rather than Git Bash. The tests now use decoded
paths, portable separators and the documented Git Bash executable (overridable
with SCAN_EVIDENCE_BASH). They reject abnormal scanner exits rather than letting
launch failure count as successful detection of forbidden evidence. Fixtures
exercise paths with spaces and a hash character. The focused Windows run passed
3/3 with no skipped cases; broader reruns are recorded separately. Historical
433/436 and 55/56 results above remain failed observations, not rewritten passes.
## Completed resumed validation

The resumed 53b3176 engineering checkpoint passed 436/436 offline tests on native Windows, 436/436 offline tests plus 56/56 policy tests in network-disabled Linux, and 267/267 TypeScript contracts. The full four-job CI also completed successfully at that exact SHA. See `resumed-validation.md` and `resumed-ci.json`. The native Windows POSIX-mode assertion remains an earlier failed observation; it is not proof of Windows ACL protection, and no production credential was minted for these checks. No owner/device, independent-review or promotion gate was closed.
