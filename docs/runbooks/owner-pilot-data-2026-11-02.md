# Owner pilot data: 2 November 2026

Status: **prepared, not seeded**. This package has not authenticated to staging or submitted hosted content commands. Its seven guard tests use an in-memory API double; they are not staging integration or physical-device acceptance evidence.

The owner authorized clearly fictional content in the existing hosted staging project, while the staff frontend runs locally and the Samsung Galaxy A26 APK uses the same hosted backend. The package pins project `tmurpotfluignacfueki` and `https://tmurpotfluignacfueki.supabase.co`. It does not provision accounts or change access, environment gates, schema, migrations, notification settings or production.

## Prepared content

[The manifest](../../tools/owner-pilot/manifest.mjs) generates twelve new items under `SYNTHETIC PILOT <Africa/Lusaka anchor date> | ...`. Every event, sermon, series and announcement identifies itself as a fictional test fixture.

| Content | Prepared examples |
| --- | --- |
| Four future events | Sunday welcome; Wednesday Scripture conversation (30 test spaces); neighbour-care planning (unlimited RSVP); two-day youth music programme (60 test spaces). The Sunday welcome has RSVP disabled. |
| Two sermon series | Faith in everyday Kafue life; Hope that becomes service. |
| Three sermons | Listening before speaking (James 1:19-27); Care that crosses the road (Luke 10:25-37); Encouragement for the ordinary week (Romans 12:9-18). Original teaching notes, discussion prompts and prayers; fictional speakers; future preparation dates, with no claim that a sermon was delivered. |
| Three announcements | A pinned owner-pilot introduction, sample reading plan and hymn suggestions. Publication always uses `notify: false`. |

Dates are computed in Africa/Lusaka (UTC+02:00), starting with the next Sunday strictly after the anchor date. On 2 November 2026 the first event is 8 November at 09:00 local. A receipt preserves the chosen anchor across retries; the runner refuses to start an incomplete plan after one of its events has begun.

The suggested Sunday hymns are checked against the existing bundled `bicc-tonga-2012` edition: hymn 1, **Leza Usimanga (Cila)**; 12, **Pupulala Basinkombe (Cila)**; 45, **Mbunono Ncobeni**; and 100, **Ibbwe Eli Ngu-Mwami Wesu**. They remain suggestions. The script does not overwrite the shared Sunday-list singleton.

No video, poster, logo or rights record is fabricated. Positive media playback needs owner-supplied cleared links and the applicable recorded rights approval. Existing published WEB may be read if present; no Bible import or source/rights approval is attempted. The giving appendix is a non-executable SAMPLE proposal with no payment destination. Giving publication still needs the real details and the required eligible independent verification.

## Run preparation and dry-run

Use the repository-pinned Node 22 from this isolated checkout. The existing private client configuration is `.owner-local/client-staging.json`; it contains `SUPABASE_URL` and a client `SUPABASE_PUBLISHABLE_KEY`. Keep the existing approved test editor's short-lived access token in an owner-only file such as `.owner-local/owner-pilot-editor.jwt`, or set `OWNER_PILOT_EDITOR_TOKEN` in the process environment. Do not put a token in a command argument, repository document, chat or evidence output. This tool neither logs in nor creates/grants an editor.

Preview the complete manifest without credentials or any network access:

```powershell
node tools/owner-pilot/seed-staging.mjs --preview
```

With approved editor access available, the default mode performs authentication and read preflight only:

```powershell
node tools/owner-pilot/seed-staging.mjs --token-file .owner-local/owner-pilot-editor.jwt
```

Dry-run verifies the live user and all four editor catalogs, refuses truncated or ambiguous catalogs, checks fixture names, and reports counts and existing WEB availability. It sends no content command and creates no receipt. Ordinary authenticated reads can still record normal account activity on the server.

## Explicit application after reviewing the dry-run

The user's synthetic-data authorization supplies the scope; an existing approved editor session is still needed. Use the exact staging confirmation:

```powershell
node tools/owner-pilot/seed-staging.mjs --token-file .owner-local/owner-pilot-editor.jwt --apply --confirm-project tmurpotfluignacfueki
```

The runner creates and publishes only the twelve namespaced items through `api.content_command`. It uses no privileged key, database connection, notification call, save/update command, deletion, reset, backdating or policy approval. It rejects existing matching names unless its own receipt proves the original creation. Unrelated real content remains untouched.

The default receipt is `.owner-local/owner-pilot-receipt.json`, bound to this exact project, client-key hash, authenticated actor, anchor and manifest hash. The private directory is ignored in this checkout. Each request ID and payload are saved durably **before** transmission; a lost response is retried with the identical request. Keep the receipt, refresh the same editor's token if necessary, and rerun the same command. Never delete the receipt to retry, change its IDs, switch actors, or run concurrent seeders. If a process is forcibly stopped, inspect that process before manually removing its leftover `.lock` file.

A changed or renamed fixture stops the run; the script does not overwrite it. Applied content is read back through public projections, and the receipt records verification time only after every item is found. A partial run is possible: preserve its receipt and inspect the specific failure. There is no automatic cleanup or destructive rollback.

## Validation and remaining owner work

`node --test tools/owner-pilot/seed-staging.test.mjs` checks the date/label guards, project/key/token restrictions, dry-run behavior, notification refusal, unowned/truncated catalog refusal, and lost-create/lost-publish response recovery. It also checks that a completed retry sends no new commands and that changed fixtures or a changed actor are refused.

Preparation and these guard tests do not close Story 6.15 or 6.17. Phone sign-in and live editor access, the witnessed Samsung pilot, any remaining platform acceptance, cleared media, specific launch decisions and production-promotion authorization remain distinct gates. See [owner decisions](epic-6-owner-decisions-2026-11-02.md), [owner walkthrough](content-owner-walkthrough.md), and [acceptance closeout](content-acceptance-closeout.md).
