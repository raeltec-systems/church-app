// Independent recovery journal (story 1.10, AD-14, AD-17).
//
// The journal lives OUTSIDE the database and its backups, so a restored older snapshot can learn
// which revocations and deletions happened after it was taken. It is:
//   * append-only: every entry is its own create-only segment (never rewritten or deleted here);
//   * hash-chained: entry.hash = sha256(canonical entry without `hash`); entry.prev_hash links to
//     the previous entry (genesis = 64 zeros);
//   * content-free: opaque UUIDs, a bucket name, kind, seq, times and hashes only;
//   * deny-only: kinds revoke access or delete objects, so replaying an entry whose database
//     transaction rolled back only denies more.
// Storage sits behind the JournalAdapter interface so production storage can be swapped in:
//   describe() -> {kind, location}
//   list()     -> entries sorted by seq, or null when the journal is absent
//   append(fields) -> the new entry (seq/prev_hash/hash assigned here)
// Implementations: LocalSegmentJournal (a directory of create-only files) and DriveJournal (a
// Google Drive folder through an injected client; DriveRestClient is a token-based client).
//
// verifyJournal() decides completeness through a recovery cut-off. Anything short of complete
// keeps the restore held (private access and sending disabled).

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export const JOURNAL_NAME = 'bic-kafue-recovery-SYNTHETIC';
export const GENESIS_HASH = '0'.repeat(64);
export const KINDS = ['checkpoint', 'access_revoked', 'deletion_manifest', 'deletion_completed', 'seal'];
const BASE_FIELDS = ['v', 'journal', 'seq', 'kind', 'at', 'prev_hash', 'hash'];
const KIND_FIELDS = {
  checkpoint: [],
  access_revoked: ['subject'],
  deletion_manifest: ['subject', 'object'],
  deletion_completed: ['object'],
  seal: ['head_seq', 'cutoff'],
};
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HASH_RE = /^[0-9a-f]{64}$/;
const BUCKET_RE = /^[a-z0-9][a-z0-9-]{2,62}$/;
export const SEGMENT_RE = /^seg-(\d{10})-([a-z_]+)\.json$/;
const claimName = (seq) => `claim-${String(seq).padStart(10, '0')}`;

/** Canonical JSON: object keys sorted recursively, no whitespace. */
export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

export function entryHash(entry) {
  const { hash: _ignored, ...rest } = entry;
  return createHash('sha256').update(canonical(rest)).digest('hex');
}

const isIso = (s) => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(s) && !Number.isNaN(Date.parse(s));

/** Returns a list of problems (empty = valid shape). Never echoes field values. */
export function validateEntry(entry) {
  const problems = [];
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return ['not an object'];
  if (!KINDS.includes(entry.kind)) return ['unknown kind'];
  const allowed = [...BASE_FIELDS, ...KIND_FIELDS[entry.kind]];
  for (const k of Object.keys(entry)) if (!allowed.includes(k)) problems.push(`field ${k} not allowed for ${entry.kind}`);
  for (const k of allowed) if (!(k in entry)) problems.push(`missing ${k}`);
  if (entry.v !== 1) problems.push('v must be 1');
  if (entry.journal !== JOURNAL_NAME) problems.push('wrong journal');
  if (!Number.isSafeInteger(entry.seq) || entry.seq < 1) problems.push('seq must be a positive integer');
  if (!isIso(entry.at)) problems.push('at must be an ISO time');
  if (!HASH_RE.test(entry.prev_hash ?? '')) problems.push('bad prev_hash');
  if ('hash' in entry && !HASH_RE.test(entry.hash ?? '')) problems.push('bad hash');
  if ('subject' in entry && !UUID_RE.test(entry.subject ?? '')) problems.push('subject must be a uuid');
  if ('object' in entry) {
    const o = entry.object;
    if (!o || typeof o !== 'object' || Object.keys(o).sort().join() !== 'bucket,object_id'
        || !BUCKET_RE.test(o.bucket ?? '') || !UUID_RE.test(o.object_id ?? '')) {
      problems.push('object must be {bucket, object_id}');
    }
  }
  if (entry.kind === 'seal') {
    if (!Number.isSafeInteger(entry.head_seq) || entry.head_seq !== entry.seq - 1) problems.push('seal head_seq must be seq - 1');
    if (!isIso(entry.cutoff)) problems.push('seal cutoff must be an ISO time');
    // A seal vouches only for what was journaled before it was written.
    else if (isIso(entry.at) && Date.parse(entry.cutoff) > Date.parse(entry.at)) problems.push('seal cutoff must not be after the seal');
  }
  return problems;
}

/** Builds the next entry after `head` (null for genesis). */
export function buildEntry(head, fields, now = new Date()) {
  const seq = head ? head.seq + 1 : 1;
  const entry = {
    v: 1, journal: JOURNAL_NAME, seq, at: now.toISOString(),
    prev_hash: head ? head.hash : GENESIS_HASH, ...fields,
  };
  if (entry.kind === 'seal') entry.head_seq = seq - 1;
  entry.hash = entryHash(entry);
  const problems = validateEntry(entry);
  if (problems.length) throw new Error(`invalid journal entry: ${problems.join('; ')}`);
  return entry;
}

export const segmentName = (entry) => `seg-${String(entry.seq).padStart(10, '0')}-${entry.kind}.json`;
export const serialize = (entry) => `${canonical(entry)}\n`;

function parseSegment(name, text) {
  try {
    return { name, entry: JSON.parse(text) };
  } catch {
    return { name, entry: null };
  }
}

/** Local directory of create-only segment files (the rehearsal adapter; also the Drive readback). */
export class LocalSegmentJournal {
  constructor(dir) { this.dir = dir; }
  describe() { return { kind: 'local_segments', location: this.dir }; }
  async segments() {
    if (!existsSync(this.dir)) return null;
    return readdirSync(this.dir).filter((n) => SEGMENT_RE.test(n)).sort()
      .map((n) => parseSegment(n, readFileSync(join(this.dir, n), 'utf8')));
  }
  async list() {
    const segs = await this.segments();
    return segs && segs.map((s) => s.entry);
  }
  async append(fields, now) {
    mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    const entries = (await this.list()) ?? [];
    const head = entries.length ? entries[entries.length - 1] : null;
    const entry = buildEntry(head, fields, now);
    // Single writer per journal. The per-seq claim ('wx', named by seq only) makes a concurrent
    // append of the same seq fail instead of forking the journal; 'wx' on the segment means
    // nothing is ever overwritten.
    try {
      writeFileSync(join(this.dir, claimName(entry.seq)), '', { flag: 'wx', mode: 0o600 });
    } catch (e) {
      if (e.code === 'EEXIST') throw new Error(`journal seq ${entry.seq} is already claimed (concurrent writer?); stop and check the journal`);
      throw e;
    }
    writeFileSync(join(this.dir, segmentName(entry)), serialize(entry), { flag: 'wx', mode: 0o600 });
    return entry;
  }
}

/**
 * Google Drive folder journal. `client` implements:
 *   listFolder(folderId) -> [{id, title}]
 *   download(fileId) -> text
 *   createFile({title, parentId, text}) -> {id, title}
 * It only ever creates files: no update, trash or permission call exists here, and sharing is
 * never requested (the folder stays owner-only).
 */
export class DriveJournal {
  constructor({ client, folderId }) {
    if (!client || !folderId) throw new Error('DriveJournal needs a client and a folderId');
    this.client = client;
    this.folderId = folderId;
  }
  describe() { return { kind: 'google_drive_folder', location: this.folderId }; }
  async segments() {
    const files = (await this.client.listFolder(this.folderId)).filter((f) => SEGMENT_RE.test(f.title))
      .sort((a, b) => a.title.localeCompare(b.title));
    const out = [];
    for (const f of files) out.push({ ...parseSegment(f.title, await this.client.download(f.id)), id: f.id });
    return out;
  }
  async list() {
    const segs = await this.segments();
    return segs.length ? segs.map((s) => s.entry) : null;
  }
  async append(fields, now) {
    const entries = (await this.list()) ?? [];
    const head = entries.length ? entries[entries.length - 1] : null;
    const entry = buildEntry(head, fields, now);
    const created = await this.client.createFile({ title: segmentName(entry), parentId: this.folderId, text: serialize(entry) });
    this.lastCreated = { id: created.id, title: segmentName(entry) };
    // Drive has no create-if-absent: re-list and fail loudly if another writer used this seq.
    const prefix = segmentName(entry).slice(0, 15);
    const same = (await this.client.listFolder(this.folderId)).filter((f) => f.title.startsWith(prefix));
    if (same.length !== 1) {
      throw new Error(`journal fork: ${same.length} Drive segments for seq ${entry.seq}; stop all writers and reconcile before continuing`);
    }
    return entry;
  }
}

/**
 * Drive REST v3 client from an OAuth access token (owner step before unattended use: a token
 * restricted to this folder, held only in a server/CI secret store). Not exercised live in the
 * milestone 1 rehearsal, which wrote through the Google Drive connector instead.
 */
export class DriveRestClient {
  constructor({ accessToken, fetchImpl = globalThis.fetch, base = 'https://www.googleapis.com' }) {
    if (!accessToken) throw new Error('DriveRestClient needs an access token');
    this.token = accessToken;
    this.fetch = fetchImpl;
    this.base = base;
  }
  async #call(url, init = {}) {
    const res = await this.fetch(url, { ...init, headers: { ...(init.headers ?? {}), authorization: `Bearer ${this.token}` } });
    if (!res.ok) throw new Error(`drive ${init.method ?? 'GET'} failed: HTTP ${res.status}`);
    return res;
  }
  async listFolder(folderId) {
    const files = [];
    let pageToken = '';
    do {
      const q = encodeURIComponent(`'${folderId.replace(/'/g, "\\'")}' in parents and trashed = false`);
      const res = await this.#call(`${this.base}/drive/v3/files?q=${q}&fields=nextPageToken,files(id,name)&pageSize=1000${pageToken ? `&pageToken=${pageToken}` : ''}`);
      const body = await res.json();
      files.push(...(body.files ?? []).map((f) => ({ id: f.id, title: f.name })));
      pageToken = body.nextPageToken ?? '';
    } while (pageToken);
    return files;
  }
  async download(fileId) {
    const res = await this.#call(`${this.base}/drive/v3/files/${encodeURIComponent(fileId)}?alt=media`);
    return res.text();
  }
  async createFile({ title, parentId, text }) {
    const boundary = `bic-rcv-${Date.now()}`;
    const meta = JSON.stringify({ name: title, parents: [parentId], mimeType: 'application/json' });
    const body = `--${boundary}\r\ncontent-type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n`
      + `--${boundary}\r\ncontent-type: application/json\r\n\r\n${text}\r\n--${boundary}--`;
    const res = await this.#call(`${this.base}/upload/drive/v3/files?uploadType=multipart&fields=id,name`, {
      method: 'POST', headers: { 'content-type': `multipart/related; boundary=${boundary}` }, body,
    });
    const created = await res.json();
    return { id: created.id, title: created.name };
  }
}

/**
 * Completeness through a recovery cut-off.
 *   entries: list() result (null = absent)
 *   cutoff: ISO time the journal must be sealed at or after
 *   databaseAcks: [{seq, hash}] the restored database already applied (its acknowledgements)
 *   databaseWatermark: highest acknowledged seq (derived from databaseAcks when given)
 * Returns {complete, reason, head_seq, head_hash, count}. Reasons: journal_absent,
 * journal_malformed, journal_gap, journal_chain_broken, journal_unsealed,
 * journal_seal_before_cutoff, journal_behind_database, journal_mismatch.
 */
export function verifyJournal(entries, { cutoff, databaseAcks = [], databaseWatermark = 0 } = {}) {
  const fail = (reason, extra = {}) => ({ complete: false, reason, head_seq: null, head_hash: null, count: entries?.length ?? 0, ...extra });
  if (!cutoff || !isIso(cutoff)) throw new Error('verifyJournal needs an ISO cutoff');
  if (!entries || entries.length === 0) return fail('journal_absent');
  if (entries.some((e) => e === null || validateEntry(e).length > 0)) return fail('journal_malformed');
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].seq !== i + 1) return fail('journal_gap', { at_seq: i + 1 });
  }
  for (let i = 0; i < entries.length; i++) {
    const prev = i === 0 ? GENESIS_HASH : entries[i - 1].hash;
    if (entries[i].prev_hash !== prev || entryHash(entries[i]) !== entries[i].hash) {
      return fail('journal_chain_broken', { at_seq: i + 1 });
    }
  }
  const head = entries[entries.length - 1];
  if (head.kind !== 'seal') return fail('journal_unsealed');
  if (Date.parse(head.cutoff) < Date.parse(cutoff)) return fail('journal_seal_before_cutoff');
  const watermark = Math.max(databaseWatermark, ...databaseAcks.map((a) => a.seq));
  if (watermark > head.seq) return fail('journal_behind_database');
  // The database's acknowledged entries must be this journal's entries, not another journal's.
  const bad = databaseAcks.find((a) => entries[a.seq - 1]?.hash !== a.hash);
  if (bad) return fail('journal_mismatch', { at_seq: bad.seq });
  return { complete: true, reason: null, head_seq: head.seq, head_hash: head.hash, count: entries.length };
}
