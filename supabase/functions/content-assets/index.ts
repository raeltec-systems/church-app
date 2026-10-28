// content-assets: the Content asset path (story 6.2; AD-2, AD-13, AD-17, AD-19).
//
// The only writer of the two Content buckets. It serves staff web under the EDITOR'S LIVE SESSION:
// the caller's `Authorization: Bearer <access token>` is forwarded to PostgREST, so every decision
// (who may upload for which item, what is public) is the database's, made by the caller's own live
// access and roles (api.content_command, api.content_file_plan, api.content_asset_preview). The
// platform's service key is used for Storage only, after the database has said yes. No system
// credential is minted for this function, and verify_jwt is off because the database checks the
// session itself on every call.
//
// Environment (server-side only, never returned or logged):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY  provided by the platform
//
// Actions:
//   POST ?action=upload&item_id=<uuid>&purpose=<purpose>   body: the raw file
//     measure and sanitise (type from the bytes, dimensions from the header, a structurally complete
//     image, metadata and trailing data dropped; size and sha256 of what is kept) -> refuse anything
//     that is not a complete PNG, JPEG or WebP or whose declared type contradicts the bytes (415) ->
//     content.begin_asset_upload (the purpose's limits; 413/422 on refusal) -> store in
//     content-drafts (never public) -> content.complete_asset_upload (the database reads the stored
//     object's size and type)  => 200 {outcome: uploaded, asset_id, media_type, byte_size, width, height}
//   POST ?action=sync
//     api.content_file_plan -> copy each missing public file from content-drafts to its
//     revision-keyed path in content-public, delete every public object outside the desired set
//     => 200 {outcome: synced, placed, removed, waiting, removals_pending}
//   GET ?action=preview&asset_id=<uuid>
//     api.content_asset_preview -> the draft object's bytes, `cache-control: no-store`
//
// Logs carry the action and an outcome code only: never a body, token, path or id.

import {
  CORS_HEADERS,
  DRAFT_BUCKET,
  DRAFT_PATH_RE,
  IMAGE_TYPES,
  MAX_UPLOAD_BYTES,
  PUBLIC_BUCKET,
  PUBLIC_CACHE_CONTROL,
  bearerFrom,
  commandEnvelope,
  declaredTooLarge,
  declaredTypeMismatch,
  keyHeaders,
  parseRequest,
  parseRetentionBody,
  parseRetentionClaim,
  parseRetentionFinalize,
  planFrom,
  refusal,
  retentionConfigFrom,
  retentionSystemEnvelope,
  sha256Hex,
  sanitizeImage,
  syncPublicFiles,
  triggerMatches,
} from './logic.mjs';

const SUPABASE_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const RETENTION_CONFIG = retentionConfigFrom({
  credential: Deno.env.get('CONTENT_ASSET_RETENTION_SYSTEM_CREDENTIAL') ?? '',
  trigger: Deno.env.get('NOTIFICATIONS_WORKER_TRIGGER') ?? '',
});
const CALL_TIMEOUT_MS = 15_000;
const FILE_TIMEOUT_MS = 30_000;
const MAX_PLAN_ROUNDS = 4;

type Json = Record<string, unknown>;

function reply(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

function note(action: string, outcome: string) {
  console.log(JSON.stringify({ fn: 'content-assets', action, outcome }));
}

async function timed(url: string, init: RequestInit, ms = CALL_TIMEOUT_MS): Promise<Response | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

class Unavailable extends Error {}

class SystemRouteError extends Error {
  constructor(readonly code: 'unauthenticated' | 'forbidden' | 'unavailable') { super(code); }
}

// A PostgREST call under the caller's own session (the database decides everything).
async function asCaller(auth: string, fn: string, body: Json): Promise<{ status: number; json: Json | null }> {
  const res = await timed(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      authorization: auth,
      'content-type': 'application/json',
      'content-profile': 'api',
    },
    body: JSON.stringify(body),
  });
  if (!res) throw new Unavailable();
  const json = await res.json().catch(() => null) as Json | null;
  return { status: res.status, json };
}

// HTTP refusals of a read (PostgREST status) as the function answers them.
function readRefusal(status: number): Response | null {
  if (status === 401) return reply(401, { outcome: 'unauthenticated' });
  if (status === 403) return reply(403, { outcome: 'forbidden' });
  if (status < 200 || status >= 300) return reply(503, { outcome: 'unavailable' });
  return null;
}

// A Content command under the caller's session: its data, or the reply that refuses it.
async function command(auth: string, name: string, payload: Json): Promise<{ data?: Json; refused?: Response }> {
  // api.content_command takes one unnamed jsonb argument: the body is the envelope itself.
  const { status, json } = await asCaller(auth, 'content_command',
    commandEnvelope(name, payload, crypto.randomUUID()) as Json);
  if (status === 401) return { refused: reply(401, { outcome: 'unauthenticated' }) };
  if (!json || typeof json !== 'object') return { refused: reply(503, { outcome: 'unavailable' }) };
  if (typeof json.code === 'string') {
    const r = refusal(json);
    return { refused: reply(r.status, r.body as Json) };
  }
  if (status !== 200 || typeof json.data !== 'object' || json.data === null) {
    return { refused: reply(503, { outcome: 'unavailable' }) };
  }
  return { data: json.data as Json };
}

function storageHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return { ...keyHeaders(SERVICE_KEY), ...extra };
}

// The Content-only system credential reaches only the Content retention allowlist.
async function retentionSystem(commandName: string, payload: Json): Promise<Json> {
  const res = await timed(`${SUPABASE_URL}/rest/v1/rpc/system_command`, {
    method: 'POST',
    headers: {
      ...keyHeaders(ANON_KEY),
      'content-type': 'application/json',
      'content-profile': 'api',
      'x-system-credential': RETENTION_CONFIG!.credential,
    },
    body: JSON.stringify(retentionSystemEnvelope(commandName, payload, crypto.randomUUID())),
  });
  if (!res) throw new SystemRouteError('unavailable');
  const json = await res.json().catch(() => null) as Json | null;
  if (!json || typeof json !== 'object') throw new SystemRouteError('unavailable');
  if (typeof json.code === 'string') {
    const code = ['unauthenticated', 'forbidden'].includes(json.code)
      ? json.code as 'unauthenticated' | 'forbidden' : 'unavailable';
    throw new SystemRouteError(code);
  }
  if (!res.ok || typeof json.data !== 'object' || json.data === null) throw new SystemRouteError('unavailable');
  return json.data as Json;
}

async function retentionCleanup(req: Request): Promise<Response> {
  if (!RETENTION_CONFIG) return reply(503, { outcome: 'unavailable' });
  if (!triggerMatches(req.headers.get('x-worker-trigger'), RETENTION_CONFIG.trigger)) {
    return reply(401, { outcome: 'unauthenticated' });
  }
  // This is an Edge-to-Edge scheduler action, never a member or editor session route. A legacy
  // JWT anon key may be sent as Authorization by keyHeaders; no caller session is accepted.
  const authorization = req.headers.get('authorization');
  const anonBearer = ANON_KEY.startsWith('eyJ') ? `Bearer ${ANON_KEY}` : null;
  if (authorization && authorization !== anonBearer) return reply(403, { outcome: 'forbidden' });
  let body;
  try {
    const raw = await req.text();
    if (raw.length > 256) return reply(400, { outcome: 'invalid', reason: 'too_large' });
    body = parseRetentionBody(raw.trim() === '' ? null : JSON.parse(raw));
  } catch {
    body = { ok: false, error: 'invalid_body' };
  }
  if (!body.ok) return reply(400, { outcome: 'invalid', reason: body.error });

  const claimId = crypto.randomUUID();
  const claimData = await retentionSystem('content.asset_retention_claim', {
    claim_id: claimId,
    limit: body.value.limit,
  });
  const claim = parseRetentionClaim(claimData);
  if (!claim || claim.claim_id !== claimId) throw new SystemRouteError('unavailable');

  // Each request is restricted to a claimed content-drafts path. A failed or uncertain delete
  // keeps its claim and metadata for the database's 30-minute expiry/retry window.
  const removedIds: string[] = [];
  let failed = 0;
  const results = await Promise.all(claim.assets.map(async (asset) => {
    if (!DRAFT_PATH_RE.test(asset.draft_path)) return { assetId: asset.asset_id, removed: false };
    const res = await timed(`${SUPABASE_URL}/storage/v1/object/${DRAFT_BUCKET}/${asset.draft_path}`, {
      method: 'DELETE',
      headers: storageHeaders(),
    }, FILE_TIMEOUT_MS);
    if (res) await res.body?.cancel();
    return { assetId: asset.asset_id, removed: Boolean(res && (res.ok || res.status === 404)) };
  }));
  for (const result of results) {
    if (result.removed) removedIds.push(result.assetId);
    else failed++;
  }
  let deleted = 0;
  if (removedIds.length) {
    const finalized = parseRetentionFinalize(await retentionSystem('content.asset_retention_finalize', {
      claim_id: claimId,
      asset_ids: removedIds,
    }));
    if (!finalized) throw new SystemRouteError('unavailable');
    deleted = finalized.deleted;
    failed += removedIds.length - deleted;
  }
  return reply(200, { outcome: 'cleaned', claimed: claim.claimed, deleted, failed });
}

// The body, or null when it exceeds MAX_UPLOAD_BYTES (reading stops there) or fails.
async function readCapped(req: Request): Promise<Uint8Array | null> {
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_UPLOAD_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  return bytes;
}

async function upload(req: Request, auth: string, itemId: string, purpose: string): Promise<Response> {
  const tooBig = reply(413, { outcome: 'refused', code: 'validation_failed', field_errors: { file: 'too_large' } });
  if (declaredTooLarge(req.headers.get('content-length'))) return tooBig;
  const bytes = await readCapped(req);
  if (bytes === null) return tooBig;
  if (bytes.length === 0) return reply(400, { outcome: 'invalid', reason: 'empty_body' });
  // Measured and sanitised from the bytes: a complete PNG, JPEG or WebP, its metadata (Exif with
  // GPS, XMP, text, comments) and anything after its end dropped. Only these bytes are stored.
  const measured = await sanitizeImage(bytes);
  if ('error' in measured) {
    return reply(measured.error === 'too_large' ? 413 : 415,
      { outcome: 'refused', code: 'validation_failed', field_errors: { file: measured.error } });
  }
  const kept: Uint8Array = measured.bytes;
  if (declaredTypeMismatch(req.headers.get('content-type'), measured.type)) {
    return reply(415, { outcome: 'refused', code: 'validation_failed', field_errors: { file: 'type_mismatch' } });
  }
  const begun = await command(auth, 'content.begin_asset_upload', {
    item_id: itemId,
    purpose,
    media_type: measured.type,
    byte_size: kept.length,
    width: measured.width,
    height: measured.height,
    sha256: await sha256Hex(kept),
  });
  if (begun.refused) return begun.refused;
  const assetId = begun.data!.asset_id as string;
  const draftPath = begun.data!.draft_path as string;
  if (!DRAFT_PATH_RE.test(draftPath ?? '')) return reply(503, { outcome: 'unavailable' });
  const stored = await timed(`${SUPABASE_URL}/storage/v1/object/${DRAFT_BUCKET}/${draftPath}`, {
    method: 'POST',
    headers: storageHeaders({ 'content-type': measured.type, 'x-upsert': 'false', 'cache-control': 'no-store' }),
    body: kept,
  }, FILE_TIMEOUT_MS);
  if (stored) await stored.body?.cancel();
  if (!stored || !stored.ok) return reply(503, { outcome: 'unavailable' });
  const done = await command(auth, 'content.complete_asset_upload', { asset_id: assetId });
  if (done.refused) return done.refused;
  return reply(200, {
    outcome: 'uploaded',
    asset_id: assetId,
    media_type: measured.type,
    byte_size: kept.length,
    width: measured.width,
    height: measured.height,
  });
}

// The sync loop itself is syncPublicFiles (logic.mjs): placement revalidates against a fresh plan
// right before each upload and the final plan's removals are executed, so a withdrawal that lands
// mid-sync never leaves a public file behind (review F1, 2026-10-28).
async function sync(auth: string): Promise<Response> {
  const outcome = await syncPublicFiles({
    readPlan: async () => {
      const read = await asCaller(auth, 'content_file_plan', {});
      const refused = readRefusal(read.status);
      return refused ? { refused } : { plan: planFrom(read.json) };
    },
    readDraft: async (p: Json) => {
      const draft = await timed(`${SUPABASE_URL}/storage/v1/object/authenticated/${DRAFT_BUCKET}/${p.draft_path}`,
        { method: 'GET', headers: storageHeaders() }, FILE_TIMEOUT_MS);
      if (!draft || !draft.ok) {
        await draft?.body?.cancel();
        return null;
      }
      return new Uint8Array(await draft.arrayBuffer());
    },
    putPublic: async (p: Json, bytes: Uint8Array) => {
      const put = await timed(`${SUPABASE_URL}/storage/v1/object/${PUBLIC_BUCKET}/${p.public_path}`, {
        method: 'POST',
        headers: storageHeaders({
          'content-type': p.media_type as string,
          'x-upsert': 'true',
          'cache-control': PUBLIC_CACHE_CONTROL,
        }),
        body: bytes,
      }, FILE_TIMEOUT_MS);
      if (put) await put.body?.cancel();
      return put?.ok === true;
    },
    removePublic: async (paths: string[]) => {
      const del = await timed(`${SUPABASE_URL}/storage/v1/object/${PUBLIC_BUCKET}`, {
        method: 'DELETE',
        headers: storageHeaders({ 'content-type': 'application/json' }),
        body: JSON.stringify({ prefixes: paths }),
      });
      const deleted = del?.ok ? await del.json().catch(() => null) : null;
      if (!del?.ok) await del?.body?.cancel();
      return Array.isArray(deleted) ? deleted.length : 0;
    },
  }, MAX_PLAN_ROUNDS);
  if (outcome.refused) return outcome.refused as Response;
  return reply(200, { outcome: 'synced', ...(outcome.result as Json) });
}

async function preview(auth: string, assetId: string): Promise<Response> {
  const read = await asCaller(auth, 'content_asset_preview', { asset_id: assetId });
  const refused = readRefusal(read.status);
  if (refused) return refused;
  const asset = (read.json?.asset ?? null) as Json | null;
  if (!asset || !DRAFT_PATH_RE.test(String(asset.draft_path ?? '')) || !IMAGE_TYPES.includes(String(asset.media_type))) {
    return reply(404, { outcome: 'not_found' });
  }
  const res = await timed(`${SUPABASE_URL}/storage/v1/object/authenticated/${DRAFT_BUCKET}/${asset.draft_path}`,
    { method: 'GET', headers: storageHeaders() }, FILE_TIMEOUT_MS);
  if (!res || !res.ok) {
    await res?.body?.cancel();
    return reply(res?.status === 404 || res?.status === 400 ? 404 : 503,
      { outcome: res?.status === 404 || res?.status === 400 ? 'not_found' : 'unavailable' });
  }
  return new Response(res.body, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'content-type': String(asset.media_type),
      'cache-control': 'no-store, private',
      'x-content-type-options': 'nosniff',
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (!SUPABASE_URL || !ANON_KEY || !SERVICE_KEY) {
    note('any', 'not_configured');
    return reply(503, { outcome: 'unavailable' });
  }
  const parsed = parseRequest(req.method, req.url);
  if (!parsed.ok) {
    note('parse', parsed.error);
    return reply(parsed.error === 'method' ? 405 : 400, { outcome: 'invalid', reason: parsed.error });
  }
  const v = parsed.value as Json;
  try {
    let res: Response;
    if (v.action === 'retention-cleanup') {
      res = await retentionCleanup(req);
    } else {
      const auth = bearerFrom(req.headers.get('authorization'));
      if (!auth) {
        note(v.action as string, 'unauthenticated');
        return reply(401, { outcome: 'unauthenticated' });
      }
      if (v.action === 'upload') res = await upload(req, auth, v.itemId as string, v.purpose as string);
      else if (v.action === 'sync') res = await sync(auth);
      else res = await preview(auth, v.assetId as string);
    }
    note(v.action as string, String(res.status));
    return res;
  } catch (e) {
    const code = e instanceof SystemRouteError ? e.code : 'unavailable';
    note(v.action as string, code);
    return reply(code === 'unauthenticated' ? 401 : code === 'forbidden' ? 403 : 503,
      { outcome: code === 'unavailable' ? 'unavailable' : code });
  }
});
