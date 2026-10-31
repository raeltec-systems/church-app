// Real PostgreSQL advisory-lock contention with independent HTTP commands.
// Called only by content-sermon-duty-drafts.mjs --contention on a verified LOCAL stack.
import { spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { dbContainer } from './harness.mjs';

export function uuid(value) {
  if (!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value ?? '')) throw new Error('invalid fixture id');
  return value;
}
export const commandDone = (answer) => answer?.status === 200 && !answer.code;
export function samePrivateDraft(answers) {
  return answers.length === 2 && answers.every(commandDone)
    && typeof answers[0].data?.sermon_id === 'string'
    && answers[0].data.sermon_id === answers[1].data?.sermon_id
    && answers.filter((answer) => answer.data?.created === true).length === 1
    && answers.filter((answer) => answer.data?.created === false).length === 1;
}

async function hold(occurrence) {
  uuid(occurrence);
  const child = spawn('docker', ['exec', '-i', dbContainer(), 'psql', '-U', 'postgres', '-X', '-qtA', '-v', 'ON_ERROR_STOP=1'],
    { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = ''; let failed = false; let ended = false;
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { output += chunk; });
  child.stderr.on('data', () => {}); // Do not expose raw SQL or any database diagnostics.
  child.on('error', () => { failed = true; });
  child.on('exit', () => { ended = true; });
  child.stdin.on('error', () => { failed = true; });
  const release = async () => {
    if (!ended && !child.stdin.destroyed) child.stdin.end('ROLLBACK;\n\\q\n');
    const until = Date.now() + 2500;
    while (!ended && Date.now() < until) await sleep(30);
    if (!ended) child.kill(); // Server-side idle timeout is the final bounded backstop.
  };
  child.stdin.write(`BEGIN;
SET LOCAL application_name = 'content-acceptance-lock-holder';
SET LOCAL idle_in_transaction_session_timeout = '15s';
SELECT pg_advisory_xact_lock(hashtextextended('content_sermon_duty_draft:${occurrence}', 0));
SELECT 'holder:' || pg_backend_pid();\n`);
  const until = Date.now() + 4000;
  while (!failed && !ended && Date.now() < until) {
    const match = /^holder:([0-9]+)\s*$/m.exec(output);
    if (match) return { pid: Number(match[1]), release };
    await sleep(30);
  }
  await release();
  throw new Error('independent advisory-lock holder did not become ready');
}

export function waiterQuery(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error('invalid holder pid');
  return `select count(*) from pg_locks held join pg_locks waiting
    on waiting.locktype = held.locktype and waiting.database is not distinct from held.database
    and waiting.classid = held.classid and waiting.objid = held.objid and waiting.objsubid = held.objsubid
    join pg_stat_activity a on a.pid = waiting.pid
    where held.pid = ${pid} and held.locktype = 'advisory' and held.granted
      and not waiting.granted and a.wait_event_type = 'Lock' and a.wait_event = 'advisory'`;
}
async function waitFor(psql, barrier, count) {
  const until = Date.now() + 4000;
  while (Date.now() < until) {
    const actual = Number(psql(waiterQuery(barrier.pid)));
    if (actual === count) return actual;
    await sleep(40);
  }
  throw new Error(`did not observe ${count} actual database lock waiters`);
}

export async function runContention({ check, log, psql, people, duty, send, grant, department, occRevision, publish }) {
  const { leader, member, other, usherLead } = people;
  const create = async (day, label) => {
    const answer = await publish(day, `SYNTHETIC contention ${label} (6.18 E2E)`);
    if (!commandDone(answer)) throw new Error('contention duty setup refused');
    const occurrence = uuid(answer.data?.occurrence_id);
    const topic = await duty(leader.token, 'duties.revise_duty', occRevision(occurrence),
      { occurrence_id: occurrence, topic: `SYNTHETIC Faithfulness ${label} (6.18 E2E)`, scripture: 'SYNTHETIC Luke 16:10' });
    if (!commandDone(topic)) throw new Error('contention topic setup refused');
    const slot = uuid(psql(`select slot_id from app.duties_slots where occurrence_id = '${occurrence}' order by position_no limit 1`));
    return { occurrence, slot, revision: occRevision(occurrence) };
  };
  const links = (occurrence) => Number(psql(`select count(*) from app.content_sermon_duty_drafts where occurrence_id = '${uuid(occurrence)}'`));
  const privateCount = (occurrence) => Number(psql(`select count(*) from app.content_sermon_duty_drafts d
    join app.content_items i on i.item_id = d.sermon_id
    where d.occurrence_id = '${uuid(occurrence)}' and i.lifecycle_state = 'draft'`));
  const runRevocation = async (id, item, actor, mutate, recoveryActor) => {
    if (links(item.occurrence) !== 0) throw new Error('contention fixture already has a draft');
    const barrier = await hold(item.occurrence);
    let request; let observed = 0; let stillBlocked = 0; let changed; let answer;
    try {
      request = send(actor.token, item.occurrence);
      // Consume rejection even if setup/proof fails, preventing an orphan promise.
      request.catch(() => {});
      observed = await waitFor(psql, barrier, 1);
      changed = await mutate();
      stillBlocked = Number(psql(waiterQuery(barrier.pid)));
    } finally {
      await barrier.release();
      if (request) answer = await request;
    }
    const beforeRecovery = links(item.occurrence);
    const recovery = await send(recoveryActor.token, item.occurrence);
    const after = links(item.occurrence);
    const privateDrafts = privateCount(item.occurrence);
    const cancelled = id === 'DL12';
    check(`${id}-real-wait-rechecks-${cancelled ? 'cancellation' : id === 'DL11' ? 'reassignment' : 'revoked-scope'}`,
      observed === 1 && stillBlocked === 1 && commandDone(changed) && answer?.code === 'not_found'
      && beforeRecovery === 0 && (cancelled ? recovery?.code === 'not_found' && after === 0
        : commandDone(recovery) && recovery.data?.created === true && after === 1 && privateDrafts === 1),
      { real_advisory_waiters: observed, still_blocked_after_provider_commit: stillBlocked,
        provider: changed?.code ?? (commandDone(changed) ? 'done' : 'failed'), old_sender: answer?.code ?? 'done',
        drafts_before_recovery: beforeRecovery, recovery: recovery?.code ?? 'done',
        links_after: after, private_drafts_after: privateDrafts });
  };

  const reassignment = await create(20, 'reassignment');
  await runRevocation('DL11', reassignment, member,
    () => duty(leader.token, 'duties.revise_duty', reassignment.revision, {
      occurrence_id: reassignment.occurrence, slot_changes: [{ slot_id: reassignment.slot, member_id: other.member }],
    }), other);

  const cancellation = await create(21, 'cancellation');
  await runRevocation('DL12', cancellation, member,
    () => duty(leader.token, 'duties.cancel_position', cancellation.revision, { slot_id: cancellation.slot }), leader);

  const granted = await grant('identity.grant_scope', usherLead, { scope_kind: 'department_deputy', scope_id: department });
  if (granted !== 'done') throw new Error('deputy setup refused');
  const revocation = await create(22, 'scope revocation');
  await runRevocation('DL13', revocation, usherLead, async () => {
    const result = await grant('identity.revoke_scope', usherLead, { scope_kind: 'department_deputy', scope_id: department });
    return result === 'done' ? { status: 200 } : { status: 200, code: result };
  }, member);

  const concurrent = await create(23, 'two authorised senders');
  const barrier = await hold(concurrent.occurrence);
  let requests = []; let observed = 0; let answers;
  try {
    requests = [send(member.token, concurrent.occurrence), send(leader.token, concurrent.occurrence)];
    requests.forEach((request) => request.catch(() => {}));
    observed = await waitFor(psql, barrier, 2);
  } finally {
    await barrier.release();
    answers = await Promise.all(requests);
  }
  const count = links(concurrent.occurrence);
  const privateDrafts = privateCount(concurrent.occurrence);
  check('DL14-two-real-waiters-create-one-private-draft', observed === 2 && samePrivateDraft(answers)
    && count === 1 && privateDrafts === 1,
    { real_advisory_waiters: observed, statuses: answers.map((a) => a.code ?? 'done'),
      created: answers.map((a) => a.data?.created ?? null), same_draft: samePrivateDraft(answers),
      links_after: count, private_drafts_after: privateDrafts });
  log('DL90-scope', { actual_postgres_waits: true, actual_http_commands: true,
    mutated_app_functions: false, local_only: true, normal_ui: false, notification_worker_run: false });
}
