// Pure first-Admin request orchestration. No I/O, logs or credentials in this module.
export const MAX_REQUEST_BYTES = 16384;
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const PHONE_RE = /^\+[1-9][0-9]{7,14}$/;
const INVITATION_RE = /^adm1_(local|staging|production)_[A-Za-z0-9_-]{43}$/;
const SIMPLE_OUTCOMES = new Set(['refused','password_rejected','rate_limited','unavailable','uncertain']);

export function parseRequest(text, environment) {
  if (typeof text !== 'string' || new TextEncoder().encode(text).length > MAX_REQUEST_BYTES) return null;
  let p;
  try { p = JSON.parse(text); } catch { return null; }
  if (!p || typeof p !== 'object' || Array.isArray(p) || p.version !== 1
      || !['inspect','complete','status'].includes(p.action)) return null;
  const allowed = ['version','action','invitation','phone_username'];
  if (p.action !== 'inspect') allowed.push('request_id');
  if (p.action === 'complete') allowed.push('full_name','password','privacy_notice_version','privacy_accepted');
  if (Object.keys(p).some(k => !allowed.includes(k))) return null;
  if (typeof p.invitation !== 'string' || !INVITATION_RE.test(p.invitation)
      || p.invitation.split('_')[1] !== environment || typeof p.phone_username !== 'string'
      || !PHONE_RE.test(p.phone_username)) return null;
  if (p.action !== 'inspect' && (typeof p.request_id !== 'string' || !UUID_RE.test(p.request_id))) return null;
  if (p.action === 'complete') {
    if (typeof p.full_name !== 'string' || p.full_name.trim().length < 1 || p.full_name.length > 120
        || /[\u0000-\u001f\u007f]/.test(p.full_name) || typeof p.password !== 'string'
        || [...p.password].length < 8 || new TextEncoder().encode(p.password).length < 8 || new TextEncoder().encode(p.password).length > 72
        || p.privacy_accepted !== true || typeof p.privacy_notice_version !== 'string'
        || !/^[a-z0-9][a-z0-9_.-]{0,62}$/.test(p.privacy_notice_version)) return null;
  }
  return p;
}

export async function sha256(value) {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(hash)].map(x => x.toString(16).padStart(2,'0')).join('');
}

/** Internal identifiers, actor records and provider metadata never enter a public response. */
export function publicReply(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {outcome:'unavailable'};
  const outcome = value.outcome;
  if (SIMPLE_OUTCOMES.has(outcome)) return {outcome};
  if (['completed','activation_pending'].includes(outcome) && value.sign_in_required === true) {
    return {outcome, sign_in_required:true};
  }
  if (outcome === 'pending' && typeof value.request_id === 'string' && UUID_RE.test(value.request_id)) {
    return {outcome, request_id:value.request_id};
  }
  if (outcome === 'ready' && ['new_account','existing_account'].includes(value.mode)
      && typeof value.privacy_notice_version === 'string'
      && /^[a-z0-9][a-z0-9_.-]{0,62}$/.test(value.privacy_notice_version)
      && typeof value.privacy_notice_text === 'string' && value.privacy_notice_text.trim().length >= 20
      && value.privacy_notice_text.length <= 12000 && typeof value.expires_at === 'string'
      && value.expires_at.endsWith('Z') && Number.isFinite(Date.parse(value.expires_at))) {
    return {outcome, mode:value.mode, privacy_notice_version:value.privacy_notice_version,
      privacy_notice_text:value.privacy_notice_text, expires_at:value.expires_at};
  }
  return {outcome:'unavailable'};
}

export function providerResult(status, body) {
  if (typeof status !== 'number') return 'unknown';
  if (status >= 200 && status < 300) return 'observed';
  if ([400,422].includes(status) && (body?.code === 'weak_password' || body?.error_code === 'weak_password')) {
    return 'password_rejected';
  }
  if ([400,409,422].includes(status)) return 'rejected';
  return 'unknown';
}

/**
 * Ports are trusted, server-side operations. Their errors must never be logged with bodies.
 * system(payload) -> database result, using a NEW transport-envelope id each call.
 * createAuthUser({id,phone,password,operationId,nonce}) -> coarse provider outcome.
 * authenticate(phone,password) -> {sessionId, dispose()} or null; never resets credentials.
 */
export async function runRequest(p, clientKey, ports) {
  const common = {invitation_digest:await sha256(p.invitation), phone_username:p.phone_username, client_key:clientKey};
  const request = {...common, request_id:p.request_id};
  try {
    if (p.action === 'inspect') return publicReply(await ports.system({...common,action:'inspect'}));
    if (p.action === 'status') return publicReply(await ports.system({...request,action:'status'}));
    const inspected = await ports.system({...common,action:'inspect'});
    if (['pending','completed','activation_pending'].includes(inspected?.outcome)) {
      // A different browser submission must not borrow another request's success.
      // Status is read-only and tied to this original request, never its password.
      return publicReply(await ports.system({...request,action:'status'}));
    }
    if (inspected?.outcome !== 'ready') return publicReply(inspected);
    if (publicReply(inspected).outcome !== 'ready'
        || inspected.privacy_notice_version !== p.privacy_notice_version) return {outcome:'refused'};
    const begin = {...request,action:'begin',full_name:p.full_name.trim(),
      privacy_notice_version:p.privacy_notice_version,privacy_accepted:true};
    if (inspected.mode === 'existing_account') {
      const proof = await ports.authenticate(p.phone_username,p.password);
      if (!proof) return {outcome:'password_rejected'};
      try {
        if (!UUID_RE.test(proof.sessionId ?? '')) return {outcome:'refused'};
        return publicReply(await ports.system({...begin,session_id:proof.sessionId}));
      } finally {
        try { await proof.dispose(); } catch { /* no credentials or errors are emitted */ }
      }
    }
    const reserved = await ports.system(begin);
    if (reserved?.outcome !== 'provision') return publicReply(reserved);
    if (![reserved.auth_user_id,reserved.operation_id,reserved.correlation_nonce]
      .every(x => typeof x === 'string' && UUID_RE.test(x))) return {outcome:'uncertain'};
    let result = 'unknown';
    try {
      result = await ports.createAuthUser({id:reserved.auth_user_id,phone:p.phone_username,
        password:p.password,operationId:reserved.operation_id,nonce:reserved.correlation_nonce});
    } catch { /* Reconcile; do not repeat an unknown external operation. */ }
    if (!['observed','rejected','password_rejected','unknown'].includes(result)) result = 'unknown';
    return publicReply(await ports.system({...request,action:'finish',operation_id:reserved.operation_id,provider_result:result}));
  } catch {
    return {outcome:p.action === 'complete' ? 'uncertain' : 'unavailable'};
  }
}
