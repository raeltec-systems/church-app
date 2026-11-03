// Pure, purpose-limited operator commands. No credentials, passwords or I/O.
import {createHash, randomBytes} from 'node:crypto';

export const ENVIRONMENTS = ['local','staging','production'];
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const INVITATION = /^adm1_(local|staging|production)_[A-Za-z0-9_-]{43}$/;
const PHONE = /^\+[1-9][0-9]{7,14}$/;
const CASE = /^[A-Za-z0-9][A-Za-z0-9._:/-]{2,63}$/;
export function validateIssue(input, environment) {
  if (!ENVIRONMENTS.includes(environment) || !input || typeof input!=='object' || Array.isArray(input)
      || Object.keys(input).some(k=>!['phone_username','existing_account','synthetic','identity_check','case_reference'].includes(k))
      || typeof input.phone_username!=='string' || !PHONE.test(input.phone_username)
      || !(input.existing_account===null || typeof input.existing_account==='string' && UUID.test(input.existing_account))
      || typeof input.synthetic!=='boolean'
      || !['in_person','established_relationship'].includes(input.identity_check)
      || typeof input.case_reference!=='string' || !CASE.test(input.case_reference)) throw new Error('invalid_issue_request');
  if (input.synthetic && (environment==='production' || !/^\+(120255501[0-9]{2}|447700900[0-9]{3})$/.test(input.phone_username))) {
    throw new Error('synthetic_account_required');
  }
  return Object.freeze({phone_username:input.phone_username,existing_account:input.existing_account,synthetic:input.synthetic,identity_check:input.identity_check,case_reference:input.case_reference});
}
export function mintInvitation(environment) {
  if (!ENVIRONMENTS.includes(environment)) throw new Error('invalid_environment');
  return `adm1_${environment}_${randomBytes(32).toString('base64url')}`;
}
export function invitationDigest(token,environment) {
  if (typeof token!=='string' || !INVITATION.test(token) || !token.startsWith(`adm1_${environment}_`)) throw new Error('invalid_invitation');
  return createHash('sha256').update(token).digest('hex');
}
const literal=value=>value===null?'null':`'${String(value).replaceAll("'","''")}'`;
export function operatorSql(environment,action,parameters={}) {
  if (!ENVIRONMENTS.includes(environment)) throw new Error('invalid_environment');
  const operator='israel'; // Owner-selected restricted operator; database checks it again.
  let expression;
  if (action==='issue') {
    const p=validateIssue(parameters.request,environment);
    const digest=invitationDigest(parameters.invitation,environment);
    expression=`app.identity_admin_setup_issue(${literal(digest)},${literal(p.phone_username)},${literal(p.existing_account)}::uuid,${p.synthetic},${literal(p.identity_check)},${literal(p.case_reference)},${literal(operator)})`;
  } else if (action==='lookup') {
    const digest=invitationDigest(parameters.invitation,environment);
    expression=`app.identity_admin_setup_lookup_digest(${literal(digest)},${literal(operator)})`;
  } else if (action==='candidates') {
    expression=`app.identity_admin_setup_cleanup_candidates(${literal(operator)})`;
  } else {
    const id=parameters.invitationId??null;
    if (id!==null && (typeof id!=='string'||!UUID.test(id))) throw new Error('invalid_invitation_id');
    if (action!=='status' && id===null) throw new Error('invitation_id_required');
    const functions={status:'identity_admin_setup_operator_view',revoke:'identity_admin_setup_revoke',
      prepare:'identity_admin_setup_cleanup_prepare',finish:'identity_admin_setup_cleanup_finish'};
    const fn=functions[action];if(!fn)throw new Error('unknown_operator_action');
    expression=`app.${fn}(${literal(id)}::uuid,${literal(operator)})`;
  }
  // Repeat the marker check in the same SQL statement as every operation.
  return `select case when app.platform_current_environment()=${literal(environment)} then ${expression} else null end as value;`;
}

/** Return only explicitly public-to-operator metadata, not the provider account id. */
export function operatorSummary(value) {
  if (!value || typeof value!=='object') throw new Error('operator_result_unavailable');
  if (Array.isArray(value)) return value.map(operatorSummary);
  const out={};
  for(const key of ['outcome','invitation_id','state','mode','environment','expires_at','expired','commissioned',
    'commissioned_at','provider_reconciliation_required','provider_account_present','cleanup_pending',
    'late_provider_fenced','existing_account_preserved','cleanup_eligible']) {
    const v=value[key];
    if(v===null || typeof v==='boolean' || typeof v==='string') out[key]=v;
  }
  return out;
}

/** An unknown deletion result is reconciled from SQL; it is never treated as a pass. */
export async function reconcileInvitation(environment,invitationId,ports) {
  const prepared=await ports.query(operatorSql(environment,'prepare',{invitationId}));
  if(!prepared || typeof prepared!=='object') throw new Error('cleanup_prepare_unconfirmed');
  if(['cleaned','completed','operator_review_required'].includes(prepared.outcome)) return operatorSummary(prepared);
  if(prepared.outcome!=='delete_orphan'||prepared.invitation_id!==invitationId
      ||!UUID.test(prepared.auth_user_id??'')||!UUID.test(prepared.operation_id??'')) throw new Error('cleanup_authority_invalid');
  // SQL has revoked creation authority, revoked sessions, fenced new linking,
  // and proved this exact account was created by this still-unclaimed operation.
  // The Auth API delete is idempotent; the final SQL absence check is authoritative.
  try { await ports.deleteAuthUser(prepared.auth_user_id); } catch { /* check, never guess */ }
  const settled=await ports.query(operatorSql(environment,'finish',{invitationId}));
  if(!settled||!['cleaned','cleanup_pending'].includes(settled.outcome)) throw new Error('cleanup_finish_unconfirmed');
  return operatorSummary(settled);
}
