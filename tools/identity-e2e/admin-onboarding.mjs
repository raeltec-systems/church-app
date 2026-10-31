#!/usr/bin/env node
// Real local Edge -> system RPC -> GoTrue -> ordinary member/admin RPC rehearsal.
// Requires a dedicated, empty church-admin-* project with public signup DISABLED
// and the local phone/password switch enabled. Never accepts the shared church-app
// stack or any hosted URL. Resets only this disposable local DB in finally.
// Usage: node tools/identity-e2e/admin-onboarding.mjs --scenario new|existing --evidence <jsonl>
import {execFileSync,spawn,spawnSync} from 'node:child_process';
import {createHash,randomBytes,randomUUID} from 'node:crypto';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {localTarget,localContainer,localStatus,assertContainer,ROOT} from '../auth-harness/local-target.mjs';
import {EPOCH_WAIT_MS,sleep,startRun} from './harness.mjs';

export function assertDisposableSetupTarget(t) {
  if (!t || !/^church-admin-[a-z0-9-]+$/.test(t.project)
      || !Number.isInteger(t.apiPort) || !Number.isInteger(t.dbPort)
      || t.apiPort<1024 || t.apiPort>65535 || t.dbPort<1024 || t.dbPort>65535
      || t.apiPort===t.dbPort || t.apiPort===54321 || t.dbPort===54322
      || t.origin!==`http://127.0.0.1:${t.apiPort}`) {
    throw new Error('dedicated_disposable_setup_stack_required');
  }
}
export const fictionalSetupPhone = p => /^\+44770090081[0-9]$/.test(p);
const q = s => `'${String(s).replaceAll("'","''")}'`;
const digest = s => createHash('sha256').update(s).digest('hex');

async function main() {
  const arg = n => process.argv[process.argv.indexOf(n)+1];
  const scenario = arg('--scenario');
  if (!['new','existing'].includes(scenario)) throw new Error('scenario_required');
  const target=localTarget(); assertDisposableSetupTarget(target);
  let db=localContainer('db',target); localContainer('kong',target);
  const env=localStatus();
  const {origin}=target;
  const cli=join(ROOT,'node_modules/supabase/dist/supabase.js');
  const apiKey=env.PUBLISHABLE_KEY;
  const adminKey=env.SECRET_KEY;
  const serviceKey=env.SERVICE_ROLE_KEY;
  if (!apiKey || !adminKey || !serviceKey) throw new Error('local_keys_missing');
  const sql = text => {
    const r=spawnSync('docker',['exec','-i',db,'psql','-U','postgres','-X','-qtA','-v','ON_ERROR_STOP=1'],
      {input:text,encoding:'utf8',stdio:['pipe','pipe','pipe'],maxBuffer:8<<20});
    if(r.status!==0) throw new Error('local_fixture_sql_failed');
    return r.stdout.trim();
  };
  const empty=JSON.parse(sql(`select json_build_object('accounts',(select count(*) from auth.users),
    'members',(select count(*) from app.identity_members),
    'commissioned',(select commissioned_at is not null from app.identity_admin_commissioning));`));
  if(empty.accounts!==0 || empty.members!==0 || empty.commissioned!==false) throw new Error('fresh_disposable_database_required');
  // Do not take over or stop somebody else's Edge-serving process.
  const existingEdge=spawnSync('docker',['container','inspect',`supabase_edge_runtime_${target.project}`],{stdio:'pipe'});
  if(existingEdge.status===0) throw new Error('existing_edge_runtime_must_be_stopped_by_its_owner');
  const {check,finish}=startRun();
  const startedAt=new Date().toISOString();
  const invite=`adm1_local_${randomBytes(32).toString('base64url')}`;
  const credential=`sysc_local_${randomBytes(32).toString('base64url')}`;
  const phone='+447700900818';
  const pw=`Synthetic-${randomBytes(18).toString('base64url')}`;
  if(!fictionalSetupPhone(phone)) throw new Error('fictional_phone_required');
  const secrets=[invite,credential,pw,digest(invite),serviceKey,adminKey];
  const responses=[];
  const http=async(path,{body,token,admin=false,headers={},method='POST',publicResponse=false}={})=>{
    const abort=new AbortController();const timer=setTimeout(()=>abort.abort(),30000);
    try {
      const h={apikey:admin?adminKey:apiKey,'content-type':'application/json',...headers};
      if(admin)h.authorization=`Bearer ${serviceKey}`;else if(token)h.authorization=`Bearer ${token}`;
      const r=await fetch(`${origin}${path}`,{method,headers:h,body:body===undefined?undefined:JSON.stringify(body),redirect:'error',signal:abort.signal});
      const text=await r.text();if(publicResponse)responses.push(text);
      let value;try{value=JSON.parse(text);}catch{value=null;}
      return {status:r.status,value};
    } finally {clearTimeout(timer);}
  };
  const rpc=(name,token,body={})=>http(`/rest/v1/rpc/${name}`,{token,body,headers:{'content-profile':'api'}});
  const command=(name,token,cmd,revision,payload,requestId=randomUUID())=>rpc(name,token,
    {version:1,command:cmd,request_id:requestId,expected_revision:revision,payload});
  const input={version:1,action:'inspect',invitation:invite,phone_username:phone};
  const fn=(body,headers={})=>http('/functions/v1/identity-admin-onboarding',{body,headers,publicResponse:true});
  let serve;let ownedEdge=null;let logs='';let temp;let mutated=false;
  try {
    const settings=await http('/auth/v1/settings',{method:'GET'});
    const disabled=await http('/auth/v1/signup',{body:{phone:'+447700900819',password:pw}});
    const closed=settings.status===200 && settings.value?.disable_signup===true
      && settings.value?.external?.phone===true && disabled.status>=400 && disabled.status<500
      && sql('select count(*) from auth.users;')==='0';
    check('public-signup-closed-phone-signin-enabled',closed,{scenario,settings_http:settings.status,signup_http:disabled.status});
    if(!closed)throw new Error('closed_signup_precondition_failed');
    sql("select app.platform_set_environment('local','SYNTHETIC commissioning HTTP rehearsal');");
    mutated=true;
    const principal=sql(`select app.sys_create_principal('setup-http-${randomBytes(4).toString('hex')}','identity_admin_onboarding','israel');`);
    sql(`select app.sys_register_credential(${q(principal)}::uuid,${q(digest(credential))},'synthetic setup http',interval '1 hour','israel');`);
    let existingId=null;let oldToken=null;
    if(scenario==='existing') {
      const created=await http('/auth/v1/admin/users',{admin:true,body:{phone,password:pw,phone_confirm:true}});
      if(created.status!==200 && created.status!==201)throw new Error('existing_fixture_creation_failed');
      existingId=created.value.id;
      const old=await http('/auth/v1/token?grant_type=password',{body:{phone,password:pw}});
      if(old.status!==200)throw new Error('existing_fixture_signin_failed');
      oldToken=old.value.access_token;
    }
    const issued=JSON.parse(sql(`select app.identity_admin_setup_issue(${q(digest(invite))},${q(phone)},
      ${existingId?q(existingId)+'::uuid':'null'},true,'in_person','SETUP-http-${scenario}','israel');`));
    check('operator-invitation-creates-no-member-or-role',sql('select count(*) from app.identity_members;')==='0'
      && sql("select count(*) from app.identity_grants where role='admin';")==='0',{scenario});
    temp=mkdtempSync(join(tmpdir(),'church-admin-e2e-'));
    if(process.platform==='win32') {
      const who=execFileSync('whoami',[],{encoding:'utf8'}).trim();
      execFileSync('icacls',[temp,'/inheritance:r','/grant:r',`${who}:(OI)(CI)F`],{stdio:'pipe'});
    }
    const envFile=join(temp,'functions.env');
    writeFileSync(envFile,`IDENTITY_ADMIN_SETUP_SYSTEM_CREDENTIAL=${credential}\nIDENTITY_ADMIN_SETUP_ENVIRONMENT=local\nIDENTITY_ADMIN_SETUP_ALLOWED_ORIGINS=http://127.0.0.1:56480\n`,{mode:0o600});
    serve=spawn(process.execPath,[cli,'functions','serve','identity-admin-onboarding','--env-file',envFile],
      {cwd:ROOT,stdio:['ignore','pipe','pipe'],windowsHide:true});
    serve.stdout.on('data',b=>{logs+=b;});serve.stderr.on('data',b=>{logs+=b;});
    let up=false;
    for(let i=0;i<90;i++) {
      try {const r=await fn({});if(r.status===400){up=true;break;}}catch{}
      if(serve.exitCode!==null)break;
      await sleep(1000);
    }
    if(!up)throw new Error('edge_runtime_not_ready');
    ownedEdge=localContainer('edge_runtime',target);
    const originDenied=await fn(input,{origin:'https://unapproved.invalid'});
    check('unapproved-browser-origin-refused',originDenied.status===403,{http:originDenied.status});
    const wrong=await fn({...input,phone_username:'+447700900819'});
    check('wrong-account-invitation-refused',wrong.value?.outcome==='refused',{outcome:wrong.value?.outcome});
    const ready=await fn(input,{origin:'http://127.0.0.1:56480'});
    check('real-edge-inspects-account-bound-invitation',ready.status===200 && ready.value?.outcome==='ready'
      && ready.value?.mode===(scenario==='new'?'new_account':'existing_account')
      && ready.value?.privacy_notice_text?.startsWith('SYNTHETIC'),{http:ready.status,mode:ready.value?.mode});
    if(ready.value?.outcome!=='ready')throw new Error('invitation_not_ready');
    const requestId=randomUUID();
    const submit={...input,action:'complete',request_id:requestId,full_name:'SYNTHETIC HTTP Administrator',
      password:pw,privacy_notice_version:ready.value.privacy_notice_version,privacy_accepted:true};
    if(scenario==='existing') {
      const bad=await fn({...submit,password:`Wrong-${randomBytes(12).toString('hex')}`});
      check('wrong-existing-password-cannot-commission',bad.value?.outcome==='password_rejected'
        && sql("select count(*) from app.identity_grants where role='admin';")==='0',{outcome:bad.value?.outcome});
    }
    const [one,two]=await Promise.all([fn(submit),fn(submit)]);
    const final=await fn({...input,action:'status',request_id:requestId});
    const counts=JSON.parse(sql(`select json_build_object('accounts',(select count(*) from auth.users),
      'members',(select count(*) from app.identity_members),'links',(select count(*) from app.identity_account_links),
      'admins',(select count(*) from app.identity_grants where role='admin' and revoked_at is null));`));
    const completed=final.value?.outcome==='completed' && counts.accounts===1 && counts.members===1
      && counts.links===1 && counts.admins===1;
    check('parallel-completion-produces-one-identity-and-grant',completed,{scenario,first:one.value?.outcome,second:two.value?.outcome,status:final.value?.outcome,counts});
    if(!completed)throw new Error('commissioning_completion_failed');
    check('completion-never-returns-a-session',final.value.sign_in_required===true
      && !('access_token' in final.value) && !('auth_user_id' in final.value),{});
    if(existingId) {
      check('existing-account-preserved-not-replaced',sql(`select auth_user_id=${q(existingId)}::uuid from app.identity_account_links;`)==='t',{});
      const stale=await rpc('identity_my_access',oldToken);
      check('pre-setup-session-is-revoked',stale.status===401 || stale.status===403,{http:stale.status});
    }
    await sleep(EPOCH_WAIT_MS);
    const signed=await http('/auth/v1/token?grant_type=password',{body:{phone,password:pw}});
    check('ordinary-password-signin-after-setup',signed.status===200,{http:signed.status,scenario});
    if(signed.status!==200)throw new Error('normal_signin_failed');
    const token=signed.value.access_token;
    const access=await rpc('identity_my_access',token);
    check('normal-current-access-reports-admin',access.status===200 && access.value?.roles?.includes('admin'),{http:access.status});
    const directory=await rpc('identity_admin_users',token,{role_filter:'admin'});
    check('normal-admin-directory-is-live',directory.status===200 && directory.value?.members?.length===1,{http:directory.status});
    const createdMember=await command('identity_review_command',token,'identity.create_member',null,
      {full_name:'SYNTHETIC Grace Banda',consent_basis:'in_person'});
    check('normal-admin-creates-accountless-member',createdMember.status===200 && Boolean(createdMember.value?.data?.member_id),{http:createdMember.status,code:createdMember.value?.code??null});
    if(!createdMember.value?.data?.member_id)throw new Error('member_fixture_command_failed');
    const memberId=createdMember.value.data.member_id;const revision=createdMember.value.revision;
    const correctionId=randomUUID();
    const correction={member_id:memberId,full_name:'SYNTHETIC Grace Phiri',consent_basis:'in_person',
      contact_routes:[{phone:'+447700900817',belongs_to:'relative',holder_label:'SYNTHETIC sister'}]};
    const saved=await command('identity_user_management_command',token,'identity.update_member_profile',revision,correction,correctionId);
    const replay=await command('identity_user_management_command',token,'identity.update_member_profile',revision,correction,correctionId);
    const detail=await rpc('identity_admin_user_detail',token,{member_id:memberId});
    check('profile-correction-persists-and-replays-once',saved.value?.data?.display_name===correction.full_name
      && replay.value?.revision===saved.value?.revision && detail.value?.member?.display_name===correction.full_name
      && sql(`select count(*) from app.identity_profile_audit where member_id=${q(memberId)}::uuid;`)==='1',
      {http:saved.status,code:saved.value?.code??null,detail_http:detail.status});
    const conflict=await command('identity_user_management_command',token,'identity.update_member_profile',revision,{...correction,full_name:'SYNTHETIC Stale edit'});
    check('stale-profile-edit-refused',conflict.value?.code==='conflict',{code:conflict.value?.code});
    check('contact-correction-does-not-change-login',sql(`select count(*) from auth.users where '+'||ltrim(phone,'+')=${q(phone)};`)==='1'
      && sql('select count(*) from auth.users;')==='1',{});
    const activity=await rpc('identity_admin_user_activity',token,{member_id:memberId});
    check('safe-activity-projection-reports-correction',activity.status===200 && activity.value?.events?.some(e=>e.action==='profile_corrected')
      && !JSON.stringify(activity.value).includes('+447700900817'),{http:activity.status});
    const deactivated=await command('identity_lifecycle_command',token,'identity.deactivate_membership',saved.value?.revision,
      {member_id:memberId,reason_code:'member_request'});
    const filtered=await rpc('identity_admin_users',token,{membership:'deactivated',query:'Grace'});
    check('deactivated-member-remains-manageable',deactivated.value?.data!==undefined && filtered.status===200
      && filtered.value?.members?.some(m=>m.member_id===memberId && m.membership_state==='deactivated'),
      {deactivation_code:deactivated.value?.code??null,directory_http:filtered.status});
    const guest=await rpc('identity_admin_users',null,{});
    check('guest-denied-directory',guest.status===401 || guest.status===403,{http:guest.status});
    const other=await http('/auth/v1/admin/users',{admin:true,body:{phone:'+447700900816',password:pw,phone_confirm:true}});
    if(!other.value?.id)throw new Error('negative_account_fixture_failed');
    const memberSignIn=await http('/auth/v1/token?grant_type=password',{body:{phone:'+447700900816',password:pw}});
    const denied=await rpc('identity_admin_user_detail',memberSignIn.value?.access_token,{member_id:memberId});
    check('signed-in-non-admin-denied-details',denied.status===401 || denied.status===403,{http:denied.status});
    sql(`insert into app.identity_holds(member_id,hold_kind,reason,placed_by)
      select member_id,'security','SYNTHETIC HTTP test hold','pgtap' from app.identity_account_links
      where auth_user_id=${q(signed.value.user.id)}::uuid;`);
    const held=await rpc('identity_admin_users',token,{});
    check('held-admin-session-loses-management-access',held.status===401 || held.status===403,{http:held.status});
    check('commissioning-remains-closed-with-no-usable-admin',sql('select commissioned_at is not null from app.identity_admin_commissioning;')==='t'
      && sql('select app.identity_usable_admin_count();')==='0',{});
    const allLogs=[logs];
    for(const kind of ['auth','rest','kong','db','edge_runtime']) {
      const log=spawnSync('docker',['logs','--since',startedAt,`supabase_${kind}_${target.project}`],{encoding:'utf8',maxBuffer:64<<20});
      allLogs.push(`${log.stdout??''}${log.stderr??''}`);
    }
    check('no-setup-secrets-in-public-replies-or-service-logs',
      secrets.every(s=>!responses.join('\n').includes(s) && !allLogs.join('\n').includes(s)),{});
  } finally {
    if(serve && serve.exitCode===null && serve.signalCode===null) {
      if(process.platform==='win32')spawnSync('taskkill',['/PID',String(serve.pid),'/T','/F'],{stdio:'pipe'});
      else serve.kill('SIGTERM');
      await sleep(1000);
    }
    if(ownedEdge)spawnSync('docker',['rm','-f',ownedEdge],{stdio:'pipe'});
    if(temp)rmSync(temp,{recursive:true,force:true});
    if(mutated) {
      // This project was independently verified as dedicated and empty before
      // any fixture was written. No shared stack or hosted database is reset.
      const reset=spawnSync(process.execPath,[cli,'db','reset','--local'],{cwd:ROOT,encoding:'utf8',maxBuffer:32<<20,timeout:180000});
      if(reset.status===0) {
        const info=JSON.parse(execFileSync('docker',['container','inspect',`supabase_db_${target.project}`],{encoding:'utf8'}));
        db=assertContainer(info[0],target,'db'); // reset replaces the container; revalidate its identity
      }
      check('disposable-database-cleanup',reset.status===0 && sql('select count(*) from auth.users;')==='0'
        && sql('select count(*) from app.identity_members;')==='0'
        && spawnSync('docker',['container','inspect',`supabase_edge_runtime_${target.project}`],{stdio:'pipe'}).status!==0,{reset_exit:reset.status});
    }
    finish();
  }
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  main().catch(error=>{
    const code=typeof error?.message==='string' && /^[a-z_]+$/.test(error.message) ? error.message : 'unexpected_failure';
    console.error(`admin-onboarding E2E stopped: ${code}; inspect the redacted case results.`);process.exitCode=1;
  });
}
