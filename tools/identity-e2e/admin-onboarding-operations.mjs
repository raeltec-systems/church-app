#!/usr/bin/env node
// LOCAL-ONLY operator CLI + real Auth cleanup rehearsal. Provider uncertainty is
// injected at the reserved-operation boundary; actual creates/deletes use GoTrue.
// Never accepts the shared stack. Resets its initially empty disposable DB only.
import {spawnSync} from 'node:child_process';
import {randomBytes,randomUUID,createHash} from 'node:crypto';
import {rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {localTarget,localContainer,localStatus,assertContainer,ROOT} from '../auth-harness/local-target.mjs';
import {assertDisposableSetupTarget} from './admin-onboarding.mjs';
import {startRun} from './harness.mjs';
import {privateDirectory,writePrivateJson,readPrivateJson} from '../ops/admin-onboarding-files.mjs';
import {operatorSql,reconcileInvitation} from '../ops/admin-onboarding-core.mjs';

const q=s=>`'${String(s).replaceAll("'","''")}'`;
const digest=s=>createHash('sha256').update(s).digest('hex');
async function main() {
  const target=localTarget();assertDisposableSetupTarget(target);
  let db=localContainer('db',target);localContainer('kong',target);
  const env=localStatus();const {check,finish}=startRun();
  const sql=text=>{
    const r=spawnSync('docker',['exec','-i',db,'psql','-U','postgres','-X','-qtA','-v','ON_ERROR_STOP=1'],
      {input:text,encoding:'utf8',stdio:['pipe','pipe','pipe'],timeout:20000});
    if(r.status!==0)throw new Error('fixture_sql_failed');return r.stdout.trim();
  };
  if(sql('select count(*) from auth.users;')!=='0'||sql('select count(*) from app.identity_members;')!=='0'
      ||sql('select commissioned_at is null from app.identity_admin_commissioning;')!=='t')throw new Error('fresh_disposable_database_required');
  const dir=privateDirectory(join(tmpdir(),`church-admin-ops-${randomUUID()}`));
  const secrets=[env.SECRET_KEY,env.SERVICE_ROLE_KEY];const outputs=[];let mutated=false;
  const pw=`Synthetic-${randomBytes(18).toString('base64url')}`;secrets.push(pw);
  const must=(step,ok,details={})=>{check(step,ok,details);if(!ok)throw new Error('case_failed');};
  const cli=(action,state,extra=[])=>{
    const args=[join(ROOT,'tools/ops/admin-onboarding.mjs'),action,'--env','local','--confirm-target',target.project,
      ...(state?['--state-dir',state]:[]),...extra];
    const r=spawnSync(process.execPath,args,{cwd:ROOT,encoding:'utf8',timeout:30000,maxBuffer:2<<20});
    outputs.push(`${r.stdout??''}${r.stderr??''}`);let value;try{value=JSON.parse(r.stdout).result;}catch{}
    return {exit:r.status,value};
  };
  const issue=(label,existing=null)=>{
    const state=privateDirectory(join(dir,label));const request=join(state,'request.json');
    writePrivateJson(request,{phone_username:'+447700900818',existing_account:existing,synthetic:true,
      identity_check:'in_person',case_reference:`SETUP-ops-${label}`});
    const result=cli('issue',state,['--request-file',request]);
    if(result.exit!==0)throw new Error('issue_failed');
    const stored=readPrivateJson(join(state,'invitation.json'));secrets.push(stored.invitation,digest(stored.invitation));
    return {state,result,stored};
  };
  const reserve=stored=>JSON.parse(sql(`select app.identity_sys_admin_setup(null,gen_random_uuid(),
    jsonb_build_object('action','begin','invitation_digest',${q(digest(stored.invitation))},
      'phone_username','+447700900818','client_key',${q(digest(randomUUID()))},'request_id',${q(randomUUID())},
      'full_name','SYNTHETIC Operations Owner','privacy_notice_version','synthetic-admin-setup-1',
      'privacy_accepted',true))->'data';`));
  const auth=async(path,body,method='POST',admin=true)=>{
    const h={apikey:admin?env.SECRET_KEY:env.PUBLISHABLE_KEY,'content-type':'application/json'};
    if(admin)h.authorization=`Bearer ${env.SERVICE_ROLE_KEY}`;
    const r=await fetch(`${target.origin}/auth/v1/${path}`,{method,headers:h,
      body:body===undefined?undefined:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(20000)});
    let value;try{value=await r.json();}catch{}return {status:r.status,value};
  };
  const provider=reservation=>auth('admin/users',{id:reservation.auth_user_id,phone:'+447700900818',password:pw,
    phone_confirm:true,app_metadata:{church_setup_operation:reservation.operation_id,church_setup_nonce:reservation.correlation_nonce}});
  try {
    sql("select app.platform_set_environment('local','SYNTHETIC operator cleanup rehearsal');");mutated=true;
    const a=issue('missing');const again=cli('issue',a.state);
    must('cli-repeat-issue-preserves-invitation-and-expiry',again.exit===0
      &&again.value.invitation_id===a.result.value.invitation_id&&again.value.expires_at===a.result.value.expires_at);
    const saved=readPrivateJson(join(a.state,'invitation.json'));
    delete saved.invitation_id;delete saved.expires_at;writePrivateJson(join(a.state,'invitation.json'),saved,{replace:true});
    const lookup=cli('status',a.state);
    must('cli-status-recovers-lost-issue-response',lookup.exit===0&&lookup.value.invitation_id===a.result.value.invitation_id);
    const missing=reserve(a.stored);must('injected-lost-provider-has-one-reservation',missing.outcome==='provision');
    const clean=cli('reconcile',a.state);
    must('cli-cancels-uncertain-absent-provider',clean.exit===0&&clean.value.outcome==='cleaned'&&clean.value.late_provider_fenced===true);
    const late=await provider(missing);
    must('real-late-auth-create-is-refused',late.status>=400&&sql('select count(*) from auth.users;')==='0',{http:late.status,reserved_id_preserved:late.value?.id===missing.auth_user_id,provider_marker_present:late.value?.app_metadata?.church_setup_operation===missing.operation_id,accounts:Number(sql('select count(*) from auth.users;'))});
    const b=issue('orphan');const reserved=reserve(b.stored);const created=await provider(reserved);
    must('real-provider-creates-correlated-unclaimed-account',[200,201].includes(created.status)&&created.value.id===reserved.auth_user_id,{http:created.status});
    const pending=await reconcileInvitation('local',b.result.value.invitation_id,{
      query:async text=>JSON.parse(sql(text)),deleteAuthUser:async()=>{throw new Error('synthetic_lost_delete');},
    });
    must('unknown-deletion-stays-pending-while-account-exists',pending.outcome==='cleanup_pending'
      &&sql('select count(*) from auth.users;')==='1');
    const blockedState=privateDirectory(join(dir,'blocked'));const blockedRequest=join(blockedState,'request.json');
    writePrivateJson(blockedRequest,{phone_username:'+447700900819',existing_account:null,synthetic:true,
      identity_check:'in_person',case_reference:'SETUP-ops-blocked'});
    const blocked=cli('issue',blockedState,['--request-file',blockedRequest]);
    must('cli-reissue-refused-until-provider-deletion-confirmed',blocked.exit!==0);
    const deleted=cli('reconcile',b.state);
    must('cli-deletes-only-correlated-orphan-through-real-auth',deleted.exit===0&&deleted.value.outcome==='cleaned'
      &&sql('select count(*) from auth.users;')==='0');
    must('orphan-auth-audit-personal-data-is-erased',sql(`select app.identity_deletion_auth_audit_present(${q(reserved.auth_user_id)}::uuid);`)==='f');
    const replay=cli('cleanup',b.state);must('cli-cleanup-is-idempotent',replay.exit===0&&replay.value.outcome==='cleaned');
    const lateAgain=await provider(reserved);
    must('real-provider-retry-cannot-recreate-cleaned-orphan',lateAgain.status>=400&&sql('select count(*) from auth.users;')==='0',{http:lateAgain.status});
    const existing=await auth('admin/users',{phone:'+447700900818',password:pw,phone_confirm:true});
    if(![200,201].includes(existing.status))throw new Error('existing_fixture_failed');
    const c=issue('existing',existing.value.id);const revoked=cli('revoke',c.state);
    must('cli-revoke-removes-setup-authority',revoked.exit===0&&revoked.value.outcome==='revoked');
    const retained=cli('cleanup',c.state);
    const signin=await auth('token?grant_type=password',{phone:'+447700900818',password:pw},'POST',false);
    must('existing-account-and-password-survive-invitation-cleanup',retained.exit===0&&retained.value.existing_account_preserved===true
      &&signin.status===200&&signin.value.user.id===existing.value.id,{signin_http:signin.status});
    const existingDelete=await auth(`admin/users/${existing.value.id}`,{should_soft_delete:false},'DELETE');
    if(![200,204].includes(existingDelete.status))throw new Error('existing_fixture_cleanup_failed');
    const d=issue('expired');
    sql(`update app.identity_admin_setup_invites set issued_at=clock_timestamp()-interval '2 hours',
      expires_at=clock_timestamp()-interval '1 minute' where invitation_id=${q(d.result.value.invitation_id)}::uuid;`);
    const candidates=cli('candidates',null);
    must('expired-unclaimed-invitation-is-actionable-in-cli',candidates.exit===0&&candidates.value.some(x=>x.invitation_id===d.result.value.invitation_id&&x.expired));
    must('expired-cleanup-removes-temporary-private-data',cli('cleanup',d.state).value?.outcome==='cleaned'
      &&sql('select count(*) from app.identity_admin_setup_invites where digest is not null or phone_username is not null;')==='0');
    must('operator-never-grants-an-admin-during-issuance-or-cleanup',sql('select count(*) from app.identity_grants;')==='0');
    must('cli-output-contains-no-invitation-password-or-server-key',secrets.every(secret=>secret&&!outputs.join('\n').includes(secret)));
  }catch(error){check('operator-scenarios-completed',false,{reason:/^[a-z_]+$/.test(error?.message??'')?error.message:'unexpected_failure'});throw error;}
  finally {
    rmSync(dir,{recursive:true,force:true});
    if(mutated){
      const reset=spawnSync(process.execPath,[join(ROOT,'node_modules/supabase/dist/supabase.js'),'db','reset','--local'],
        {cwd:ROOT,encoding:'utf8',maxBuffer:32<<20,timeout:180000});
      if(reset.status===0){const info=JSON.parse(spawnSync('docker',['inspect',`supabase_db_${target.project}`],{encoding:'utf8'}).stdout);db=assertContainer(info[0],target,'db');}
      check('disposable-operator-fixtures-cleaned',reset.status===0&&sql('select count(*) from auth.users;')==='0'
        &&sql('select count(*) from app.identity_members;')==='0',{reset_exit:reset.status});
    }
    finish();
  }
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(()=>{console.error('Operator rehearsal failed; use redacted evidence.');process.exitCode=1;});
