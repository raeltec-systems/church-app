// Story 1.3 recovery-fence commands for run.mjs (`rc-*`). See README.md.
//
// Roles in a run:
//   operator  the harness caller; holds the operator token (state only).
//   staff     a synthetic staff account; staff actions use its live password session.
//   member    a synthetic member account; recovery actions use the anon key,
//             because a member in recovery has no session.
//
// Secrets (grant secrets, chosen passwords, operator token, tokens) live only
// in the private state dir. Evidence lines pass through tagUuids(scrub(...)).

import { randomBytes } from 'node:crypto';
import { decodeJwtPayloadNode, maskIdentifier, sha256Hex, tagUuids } from './lib.mjs';

const FN = 'harness-recovery';
const OWN_REF = 'szfyfezfvxyuvovnnakr';

function anonJwt() {
  const k = process.env.SUPABASE_ANON_JWT;
  const c = decodeJwtPayloadNode(k);
  if (!c || c.role !== 'anon' || c.ref !== OWN_REF) {
    throw new Error('SUPABASE_ANON_JWT must be the auth-test project legacy anon key');
  }
  return k;
}

function rcState(state) {
  state.rc ??= { operator: null, accounts: {}, grants: {}, ops: {} };
  return state.rc;
}

function need(map, key, what) {
  const v = map[key];
  if (!v) throw new Error(`no ${what} "${key}"`);
  return v;
}

function newSecret(prefix) {
  return prefix + randomBytes(32).toString('base64url');
}

function newMemberPassword() {
  // The member's own choice in the real flow; synthetic and high-entropy here.
  return 'Hx!' + randomBytes(18).toString('base64url');
}

export async function rcCommand(command, { pos, opt, step, client, state, saveState, record }) {
  const rc = rcState(state);
  const operator = () => need(rc, 'operator', 'operator token (run rc-operator-token)');
  const bearerFor = (spec) => {
    if (!spec || spec === 'anon') return anonJwt();
    if (spec === 'none') return undefined;
    if (spec.startsWith('session:')) return need(state.sessions, spec.slice(8), 'session').access_token;
    throw new Error('--as must be anon | none | session:<label>');
  };
  const fn = async (body, { as = 'anon', withOperator = true } = {}) =>
    client.fn(FN, body, { bearer: bearerFor(as), operator: withOperator ? operator() : undefined });
  const out = (data) => record(step, command, tagUuids(data));

  switch (command) {
    case 'rc-operator-token': {
      // Prints only the digest. The operator registers it with
      // sql/register_operator_token.sql through the Supabase MCP.
      rc.operator = newSecret('ho_');
      saveState(state);
      console.log(JSON.stringify({ operator_token_digest: sha256Hex(rc.operator) }));
      return;
    }

    case 'rc-provision': {
      const [account] = pos;
      const role = opt.role === 'staff' ? 'staff' : 'member';
      const password = newMemberPassword();
      const r = await fn({ action: 'provision', tag: String(opt.tag), role, password });
      if (r.status === 200) {
        state.passwords[account] = password;
        rc.accounts[account] = {
          role,
          email: `israelmuyoba+bicauth-${opt.tag}@gmail.com`,
          auth_user_id: r.json.auth_user_id,
          member_id: r.json.member_id ?? null,
          link_revision: r.json.link_revision ?? null,
        };
      }
      saveState(state);
      out({ account, role, email: maskIdentifier(rc.accounts[account]?.email), status: r.status, response: r.json });
      return;
    }

    case 'rc-request': {
      // Member device: generate the secret locally, send only its digest.
      const [grant] = pos;
      const secret = newSecret('hg_');
      const r = await fn({ action: 'request', grant_digest: sha256Hex(secret) });
      if (r.status === 200) rc.grants[grant] = { secret, request_ref: r.json.request_ref };
      saveState(state);
      out({ grant_label: grant, status: r.status, response: r.json, sent: 'digest_only' });
      return;
    }

    case 'rc-issue': {
      // Staff binds a request to (case, member, account, link revision); the
      // response never contains the secret.
      const [grant] = pos;
      const g = need(rc.grants, grant, 'grant request');
      const acct = need(rc.accounts, String(opt.account), 'account');
      const memberOf = opt['member-of'] ? need(rc.accounts, String(opt['member-of']), 'account') : acct;
      const body = {
        action: 'issue',
        request_ref: g.request_ref,
        case_id: String(opt.case || `case-${grant}`),
        member_id: memberOf.member_id,
        auth_user_id: acct.auth_user_id,
        link_revision: opt['link-revision'] !== undefined ? Number(opt['link-revision']) : acct.link_revision,
        ttl_s: opt.ttl !== undefined ? Number(opt.ttl) : 900,
      };
      const r = await fn(body, { as: `session:${opt.staff}` });
      if (r.status === 200) Object.assign(g, { account: String(opt.account), grant_id: r.json.grant_id });
      saveState(state);
      out({
        grant_label: grant,
        staff_session: opt.staff,
        account: opt.account,
        bound_member_of: opt['member-of'] || opt.account,
        status: r.status,
        staff_output: r.json,
        staff_output_contains_secret: JSON.stringify(r.json ?? {}).includes(g.secret),
      });
      return;
    }

    case 'rc-redeem':
    case 'rc-resume': {
      // Member redeems with the secret it holds and a password it chose.
      const [grant] = pos;
      const g = need(rc.grants, grant, 'grant');
      const account = String(opt.account);
      const loginAs = opt['login-as'] ? need(rc.accounts, String(opt['login-as']), 'account') : need(rc.accounts, account, 'account');
      const password = opt.weak ? 'Hx!1' : newMemberPassword();
      const body = command === 'rc-redeem'
        ? { action: 'redeem', grant: g.secret, login_email: loginAs.email, password }
        : { action: 'resume', grant: g.secret, op_id: need(rc.ops, String(opt.op), 'op').op_id, password };
      if (opt.inject) body.inject = String(opt.inject);
      const n = Math.max(1, Math.min(Number(opt.parallel || 1), 10));
      const pending = Promise.all(Array.from({ length: n }, () => fn(body)));
      let concurrent = null;
      if (opt['concurrent-change']) {
        // While the op is dispatched (use --inject delay_apply), the member
        // changes the password natively from an existing session.
        await new Promise((r) => setTimeout(r, 1500));
        const s = need(state.sessions, String(opt['concurrent-change']), 'session');
        const direct = newMemberPassword();
        const u = await client.updateUser(s.access_token, { password: direct });
        if (u.status === 200) state.passwords[`${account}@direct`] = direct;
        concurrent = { session: opt['concurrent-change'], native_password_change_status: u.status,
          error: u.status === 200 ? undefined : u.json };
      }
      const results = await pending;
      const opLabel = String(opt.op || `${grant}-op`);
      for (const r of results) {
        if (r.json?.op_id) rc.ops[opLabel] = { op_id: r.json.op_id, grant, account };
        // Keep the chosen password locally whenever Auth may have applied it.
        if (r.json?.op_id && !opt.weak) state.passwords[`${account}@${opLabel}`] = password;
        if (r.json?.status === 'succeeded') {
          state.passwords[`${account}@previous`] = state.passwords[account];
          state.passwords[account] = password;
        }
      }
      saveState(state);
      out({
        grant_label: grant,
        account,
        login_as: opt['login-as'] || account,
        inject: opt.inject || null,
        parallel: n,
        concurrent_native_change: concurrent,
        op_label: results.some((r) => r.json?.op_id) ? opLabel : null,
        results: results.map((r) => ({ status: r.status, body: r.json })),
      });
      return;
    }

    case 'rc-relink': {
      const acct = need(rc.accounts, String(opt.account), 'account');
      const body = {
        action: 'relink',
        auth_user_id: acct.auth_user_id,
        expected_link_revision: opt.expected !== undefined ? Number(opt.expected) : acct.link_revision,
      };
      const r = await fn(body, { as: `session:${opt.staff}` });
      if (r.status === 200) {
        acct.link_revision = r.json.link_revision;
        acct.member_id = r.json.member_id;
      }
      saveState(state);
      out({ account: opt.account, staff_session: opt.staff, status: r.status, response: r.json });
      return;
    }

    case 'rc-hold': {
      const acct = need(rc.accounts, String(opt.account), 'account');
      const r = await fn({ action: 'hold', auth_user_id: acct.auth_user_id, on: !opt.off }, { as: `session:${opt.staff}` });
      out({ account: opt.account, on: !opt.off, status: r.status, response: r.json });
      return;
    }

    case 'rc-reconcile':
    case 'rc-replay': {
      const op = need(rc.ops, String(opt.op), 'op');
      const action = command === 'rc-reconcile' ? 'reconcile' : 'replay_complete';
      const r = await fn({ action, op_id: op.op_id, note: opt.note ? String(opt.note) : undefined },
        { as: `session:${opt.staff}` });
      out({ op: opt.op, account: op.account, action, status: r.status, response: r.json });
      return;
    }

    case 'rc-observe': {
      // Raw DB fence state (harness_rc_observe = sql/observe_recovery_state.sql),
      // recorded as returned: no transcription.
      const r = await fn({ action: 'observe', tag_prefix: String(opt.prefix || 'r13-'), since: opt.since ? String(opt.since) : undefined },
        { as: `session:${opt.staff}` });
      out({ source: 'tools/auth-harness/sql/observe_recovery_state.sql (via harness_rc_observe)', prefix: opt.prefix || 'r13-',
        since: opt.since || null, status: r.status, raw_result: r.json?.observation ?? r.json });
      return;
    }

    case 'rc-probe': {
      const [label] = pos;
      const s = need(state.sessions, label, 'session');
      const gate = await client.rpc('harness_recovery_probe', s.access_token);
      const probe = await client.rpc('harness_private_probe', s.access_token);
      out({ label, recovery_gate: { status: gate.status, body: gate.json }, private_probe: { status: probe.status, body: probe.json } });
      return;
    }

    case 'rc-call': {
      // Negative caller tests. --body is recorded, so never put a secret in it.
      const body = opt.body ? JSON.parse(String(opt.body)) : {};
      if (opt.action) body.action = String(opt.action);
      if (opt['grant-of']) body.grant = need(rc.grants, String(opt['grant-of']), 'grant').secret;
      const r = await fn(body, { as: opt.as ? String(opt.as) : 'anon', withOperator: !opt['no-operator'] });
      out({ as: opt.as || 'anon', operator_sent: !opt['no-operator'], body, status: r.status, response: r.json });
      return;
    }

    default:
      throw new Error(`unknown rc command ${command}`);
  }
}
