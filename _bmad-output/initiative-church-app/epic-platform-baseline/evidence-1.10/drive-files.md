# Google Drive files for story 1.10 (SYNTHETIC only)

All files were created on 2026-10-03 through the Google Drive connector. None was shared, and no other Drive file was read, changed or trashed. A permissions check (`get_file_permissions`) on the root folder, the `journal` folder and `seg-0000000005-seal.json` returned a single permission each: `owner`, the owner's account.

| Drive file ID | Name | Parent | Content |
|---------------|------|--------|---------|
| `18v5zuOlrRr8UzJqNwLq5jpX5JOCI0t1h` | `bic-kafue-ops-SYNTHETIC-recovery-rehearsal` | My Drive | folder |
| `1vO9of9shtPnobUZlV3-hHdE-baXLc_VF` | `journal` | rehearsal folder | folder |
| `1YRE_ekxlBrXHyxhymMqGkDDrkVJnnqJW` | `backups` | rehearsal folder | folder |
| `1S6bK3i6Y1TfaL7bauacQXKxJwXsD8uGT` | `seg-0000000001-checkpoint.json` | journal | journal segment, 262 bytes |
| `1g5w8UNiNxTNWnyABbjZRdYFrWEXtYfKb` | `seg-0000000002-access_revoked.json` | journal | journal segment, 315 bytes |
| `1mfvD8hKFSvWMT59GxKD7DbET5sxjSr7n` | `seg-0000000003-deletion_manifest.json` | journal | journal segment, 415 bytes |
| `1btP7xjPe4wIrib4dvzrVQ350wzTH4dUv` | `seg-0000000004-deletion_completed.json` | journal | journal segment, 367 bytes |
| `1XKJ4ZF9GNLPUwmfxIlIe7hQpCIPRI897` | `seg-0000000005-seal.json` | journal | journal segment, 305 bytes |
| `1AUzQJoEmnMe2VJkqLfGUY5GMOkU723JV` | `t1-4802b0d7-SYNTHETIC.manifest.json` | backups | T1 backup manifest (sha256 of the database artifact and object) |
| `1bfAaBMsBFRh04x1GuAey2LSejxeJv8Aa` | `t1-4802b0d7-SYNTHETIC.object.rcv-synthetic-rehearsal.e58a36bf-7b02-4112-89fd-482542361bde` | backups | the synthetic object bytes (100 bytes) |

How the journal was read back:

- The connector's `search_files` (`parentId = journal`) listed all five segments.
- `download_file_content` fetched each one.
- The bytes were decoded into `drive-readback/`, and each was byte-identical to the local segment (`drive-readback-index.json`).
- The `restore:drive` scenario reconciled the isolated T1 restore from `drive-readback/` alone.

The 175 KB database artifact is not on Drive. The connector takes file content inline, so an artifact that size is impractical to upload this way. It stays in the gitignored `.recovery-state/`, and its sha256 is in the Drive manifest. The production journal and object store is an owner choice to make before real data.
