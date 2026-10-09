# Staging apply (2026-10-07, parent session)

- Migration applied through the connector as `20261007050512_membership_applications` (local file renamed to match).
- `select app.cells_seed_synthetic_cells('israel')` → 3 synthetic options.
- Function definitions: 21 of 22 hash-match the local reset. `app.identity_application_name` differs only textually: in the applied copy the `\uXXXX` escapes inside the two character-class constants arrived as the literal characters they denote (same character sets, different source text).
- Behaviour check, same 10 inputs on staging and on the local function (tab/newline edges, NBSP, U+3000/U+2028, U+202E, U+200B, U+00AD, a tag character, U+0085, plain synthetic name, non-synthetic name): identical outputs on both.

| Input | Result (both) |
|---|---|
| tab + double space + newline | `SYNTHETIC John Doe` |
| NBSP edges/inside | `SYNTHETIC Jo Ann` |
| U+3000 edge, U+2028 inside | `SYNTHETIC Mary Jane` |
| U+0085 inside | `SYNTHETIC Y` |
| U+202E, U+200B, U+00AD, tag char | `validation_failed full_name: invalid` |
| `Real Name` (Q4 closed) | `validation_failed full_name: invalid` |
| `SYNTHETIC Plain Name` | accepted unchanged |

If byte-identical source is wanted later, re-apply the function from the repo file through the promotion workflow (`supabase db push`), which sends the file verbatim.

## Owner device demonstration (2026-10-07, Android release build against staging, commit a25ca29)

Owner-reported: "All steps worked" — Create account `+1 202 555 0152` → Join the church (SYNTHETIC name, a SYNTHETIC cell, privacy-notice checkbox) → status card (awaiting approval / cell requested) → Correct my request → Account shows the request, no member content.

Staging readback (read-only SQL): one application, phone `…0152`, name prefix `SYNTHETIC `, `cell_choice = cell`, state `submitted`, revision 2, `is_synthetic = true`; events `submitted:full_name,cell_choice,privacy_notice_version`, `corrected:cell_choice`; no account link and no grant for that account.
