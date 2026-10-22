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
  planFrom,
  refusal,
  sha256Hex,
  sanitizeImage,
} from './logic.mjs';

const SUPABASE_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
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

async function sync(auth: string): Promise<Response> {
  let placed = 0;
  let removed = 0;
  let plan = { place: [] as Json[], remove: [] as string[], waiting: 0, removals_pending: 0 };
  for (let round = 0; round < MAX_PLAN_ROUNDS; round++) {
    const read = await asCaller(auth, 'content_file_plan', {});
    const refused = readRefusal(read.status);
    if (refused) return refused;
    plan = planFrom(read.json) as typeof plan;
    const progressBefore = placed + removed;
    for (const p of plan.place) {
      const draft = await timed(`${SUPABASE_URL}/storage/v1/object/authenticated/${DRAFT_BUCKET}/${p.draft_path}`,
        { method: 'GET', headers: storageHeaders() }, FILE_TIMEOUT_MS);
      if (!draft || !draft.ok) {
        await draft?.body?.cancel();
        continue;
      }
      const bytes = new Uint8Array(await draft.arrayBuffer());
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
      if (put?.ok) placed++;
    }
    if (plan.remove.length > 0) {
      const del = await timed(`${SUPABASE_URL}/storage/v1/object/${PUBLIC_BUCKET}`, {
        method: 'DELETE',
        headers: storageHeaders({ 'content-type': 'application/json' }),
        body: JSON.stringify({ prefixes: plan.remove }),
      });
      const deleted = del?.ok ? await del.json().catch(() => null) : null;
      if (!del?.ok) await del?.body?.cancel();
      if (Array.isArray(deleted)) removed += deleted.length;
    }
    if (placed + removed === progressBefore || (plan.waiting <= plan.place.length
        && plan.removals_pending <= plan.remove.length)) break;
  }
  const after = await asCaller(auth, 'content_file_plan', {});
  const refused = readRefusal(after.status);
  if (refused) return refused;
  plan = planFrom(after.json) as typeof plan;
  return reply(200, { outcome: 'synced', placed, removed, waiting: plan.waiting, removals_pending: plan.removals_pending });
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
  const auth = bearerFrom(req.headers.get('authorization'));
  if (!auth) {
    note(parsed.value.action, 'unauthenticated');
    return reply(401, { outcome: 'unauthenticated' });
  }
  const v = parsed.value as Json;
  try {
    let res: Response;
    if (v.action === 'upload') res = await upload(req, auth, v.itemId as string, v.purpose as string);
    else if (v.action === 'sync') res = await sync(auth);
    else res = await preview(auth, v.assetId as string);
    note(v.action as string, String(res.status));
    return res;
  } catch {
    note(v.action as string, 'unavailable');
    return reply(503, { outcome: 'unavailable' });
  }
});
