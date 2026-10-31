// Owner-invited commissioning only. Not a public Admin registration service.
// Never log request/response bodies, invitation digests, passwords, tokens or private identifiers.
import { MAX_REQUEST_BYTES, UUID_RE, parseRequest, providerResult, runRequest } from './logic.mjs';
import { clientIp, clientKey, keyHeaders, systemEnvelope } from '../identity-assisted-recovery/logic.mjs';

type Json = Record<string, unknown>;
const SYSTEM_CREDENTIAL = Deno.env.get('IDENTITY_ADMIN_SETUP_SYSTEM_CREDENTIAL') ?? '';
const ENVIRONMENT = Deno.env.get('IDENTITY_ADMIN_SETUP_ENVIRONMENT') ?? '';
const SUPABASE_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ALLOWED_ORIGINS = new Set((Deno.env.get('IDENTITY_ADMIN_SETUP_ALLOWED_ORIGINS') ?? '')
  .split(',').map(x => x.trim()).filter(Boolean));
const DEADLINE_MS = 10_000;
const MAX_PROVIDER_BYTES = 131072;

function configured(): boolean {
  if (!['local','staging','production'].includes(ENVIRONMENT)
      || !new RegExp(`^sysc_${ENVIRONMENT}_[A-Za-z0-9_-]{43}$`).test(SYSTEM_CREDENTIAL)
      || !ANON_KEY || !SERVICE_KEY) return false;
  try {
    const u = new URL(SUPABASE_URL);
    const localHost = ['kong','localhost','127.0.0.1','[::1]'].includes(u.hostname)
      || /^supabase_kong_[a-z0-9_-]+$/.test(u.hostname);
    return !u.username && !u.password && u.pathname === '/' && !u.search && !u.hash
      && (u.protocol === 'https:' || (ENVIRONMENT === 'local' && u.protocol === 'http:' && localHost));
  } catch { return false; }
}

async function cappedText(stream: ReadableStream<Uint8Array> | null, max: number): Promise<string | null> {
  if (!stream) return '';
  const reader = stream.getReader();
  const parts: Uint8Array[] = [];
  let size = 0;
  let expired = false;
  const timer = setTimeout(() => { expired = true; void reader.cancel().catch(() => {}); }, DEADLINE_MS);
  try {
    for (;;) {
      const {done,value} = await reader.read();
      if (expired) return null;
      if (done) break;
      size += value.length;
      if (size > max) { await reader.cancel(); return null; }
      parts.push(value);
    }
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const part of parts) { bytes.set(part,at); at += part.length; }
    return new TextDecoder('utf-8',{fatal:true}).decode(bytes);
  } catch { return null; }
  finally { clearTimeout(timer); reader.releaseLock(); }
}

// Fixed server origin, no redirects, bounded response and request deadline.
async function call(path: string, body: Json | null, headers: Record<string,string>, method='POST'):
  Promise<{status:number;body:Json} | null> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(),DEADLINE_MS);
  try {
    const response = await fetch(`${SUPABASE_URL}${path}`, {method,headers,
      body:body === null ? undefined : JSON.stringify(body), signal:abort.signal,redirect:'error'});
    const text = await cappedText(response.body,MAX_PROVIDER_BYTES);
    if (text === null) return null;
    const parsed = text ? JSON.parse(text) : {};
    return {status:response.status,body:parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {}};
  } catch { return null; }
  finally { clearTimeout(timer); }
}

const ports = {
  async system(payload: Json): Promise<Json> {
    const result = await call('/rest/v1/rpc/system_command',
      { ...(systemEnvelope('identity.admin_setup',payload,crypto.randomUUID()) as Json) },
      {...keyHeaders(ANON_KEY),'content-type':'application/json','content-profile':'api',
        'x-system-credential':SYSTEM_CREDENTIAL});
    if (!result || result.status !== 200 || 'code' in result.body || !result.body.data
        || typeof result.body.data !== 'object' || Array.isArray(result.body.data)) throw new Error('system_unavailable');
    return result.body.data as Json;
  },
  async createAuthUser(input: {id:string;phone:string;password:string;operationId:string;nonce:string}): Promise<string> {
    const result = await call('/auth/v1/admin/users', {
      id:input.id,phone:input.phone,password:input.password,phone_confirm:true,
      app_metadata:{church_setup_operation:input.operationId,church_setup_nonce:input.nonce},
    },{...keyHeaders(SERVICE_KEY),'content-type':'application/json'});
    // Provider confirmation is not proof of phone ownership. No Admin role is put in Auth metadata.
    return providerResult(result?.status,result?.body);
  },
  async authenticate(phone: string,password: string) {
    const result = await call('/auth/v1/token?grant_type=password',{phone,password},
      {...keyHeaders(ANON_KEY),'content-type':'application/json'});
    if (!result) throw new Error('authentication_unavailable');
    if (result.status === 400 || result.status === 401) return null;
    if (result.status !== 200) throw new Error('authentication_unavailable');
    const token = result.body.access_token;
    if (typeof token !== 'string' || token.length > 32768) throw new Error('authentication_unavailable');
    const dispose = async () => {
      await call('/auth/v1/logout?scope=local',null,
        {apikey:ANON_KEY,authorization:`Bearer ${token}`});
    };
    let sessionId: unknown;
    try {
      // This token comes directly from Auth's HTTPS password endpoint, NEVER from the incoming client.
      // SQL independently verifies the current auth.sessions row and its password AMR before binding.
      const segment = token.split('.')[1];
      const base64 = segment.replaceAll('-','+').replaceAll('_','/');
      sessionId = JSON.parse(atob(base64.padEnd(Math.ceil(base64.length/4)*4,'='))).session_id;
    } catch { await dispose(); throw new Error('authentication_unavailable'); }
    if (typeof sessionId !== 'string' || !UUID_RE.test(sessionId)) { await dispose(); return null; }
    return {sessionId,dispose};
  },
};

function response(status: number,body: Json,origin: string | null): Response {
  const headers: Record<string,string> = {'content-type':'application/json','cache-control':'no-store',
    'x-content-type-options':'nosniff','referrer-policy':'no-referrer','vary':'Origin'};
  if (origin && ALLOWED_ORIGINS.has(origin)) {
    headers['access-control-allow-origin']=origin;
    headers['access-control-allow-methods']='POST, OPTIONS';
    headers['access-control-allow-headers']='apikey, content-type, authorization';
  }
  return new Response(status===204 ? null : JSON.stringify(body),{status,headers});
}

Deno.serve(async request => {
  const origin = request.headers.get('origin');
  if (origin && !ALLOWED_ORIGINS.has(origin)) return response(403,{outcome:'refused'},null);
  if (request.method === 'OPTIONS') return response(204,{},origin);
  if (request.method !== 'POST') return response(405,{outcome:'refused'},origin);
  if (!configured()) return response(503,{outcome:'unavailable'},origin);
  if ((request.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') {
    return response(400,{outcome:'refused'},origin);
  }
  const declared = request.headers.get('content-length');
  if (declared !== null && (!/^\d{1,9}$/.test(declared) || Number(declared)>MAX_REQUEST_BYTES)) {
    return response(413,{outcome:'refused'},origin);
  }
  const text = await cappedText(request.body,MAX_REQUEST_BYTES);
  const parsed = text === null ? null : parseRequest(text,ENVIRONMENT);
  if (!parsed) return response(400,{outcome:'refused'},origin);
  try {
    const key = await clientKey(clientIp(request.headers.get('x-forwarded-for')),SYSTEM_CREDENTIAL);
    return response(200,await runRequest(parsed,key,ports),origin);
  } catch {
    return response(200,{outcome:parsed.action==='complete' ? 'uncertain' : 'unavailable'},origin);
  }
});
