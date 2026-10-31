#!/usr/bin/env node
// Restricted installation tooling, not a public signup or role-grant endpoint.
// Passwords are NEVER accepted here. The intended Admin enters their own password
// in the app. Invitations stay in a private file, never URLs, arguments or logs.
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createInterface} from 'node:readline/promises';
import {stdin,stdout} from 'node:process';
import {loadEnvironments,resolveDeployTarget} from '../env/environments.mjs';
import {localTarget,localContainer,localStatus} from '../auth-harness/local-target.mjs';
import {keyHeaders} from '../../supabase/functions/identity-assisted-recovery/logic.mjs';
import {ENVIRONMENTS,UUID,validateIssue,mintInvitation,operatorSql,operatorSummary,reconcileInvitation} from './admin-onboarding-core.mjs';
import {privateDirectory,readPrivateJson,writePrivateJson} from './admin-onboarding-files.mjs';

const ROOT=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const MANAGEMENT='https://api.supabase.com';
const ACTIONS=['issue','status','revoke','reconcile','cleanup','candidates'];
const OPTIONS=['--env','--confirm-target','--project-ref','--state-dir','--request-file','--invitation-id'];
export function parseArgs(argv) {
  if(argv.length===1 && ['--help','help'].includes(argv[0]))return {help:true};
  const [action,...rest]=argv;if(!ACTIONS.includes(action))throw new Error('invalid_action');
  const opts={action};
  for(let i=0;i<rest.length;i+=2) {
    if(!OPTIONS.includes(rest[i])||!rest[i+1]||rest[i+1].startsWith('--')||Object.hasOwn(opts,rest[i]))throw new Error('invalid_arguments');
    opts[rest[i]]=rest[i+1];
  }
  if(!ENVIRONMENTS.includes(opts['--env']) || !opts['--confirm-target'])throw new Error('explicit_target_required');
  if(opts['--invitation-id'] && !UUID.test(opts['--invitation-id']))throw new Error('invalid_invitation_id');
  if(action==='issue' && !opts['--state-dir'])throw new Error('private_state_directory_required');
  if(['revoke','reconcile','cleanup'].includes(action)&&!opts['--invitation-id']&&!opts['--state-dir'])throw new Error('invitation_id_required');
  if(action!=='issue' && opts['--request-file'])throw new Error('unexpected_request_file');
  return opts;
}

export function hostedTarget(environment,projectRef,confirmation,productionRef,envs=loadEnvironments()) {
  if(environment==='local'||confirmation!==projectRef)throw new Error('target_confirmation_mismatch');
  if(environment==='production' && (!productionRef||productionRef!==projectRef))throw new Error('production_target_not_reviewed');
  return resolveDeployTarget(envs,environment,projectRef);
}

async function boundedFetch(url,options) {
  const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),15000);
  try {
    const res=await fetch(url,{...options,redirect:'error',signal:controller.signal});
    let size=0;const parts=[];
    if(res.body)for await (const part of res.body) {
      size+=part.length;if(size>1048576){controller.abort();throw new Error('operator_response_too_large');}parts.push(part);
    }
    const text=Buffer.concat(parts).toString('utf8');let value=null;
    try{value=text?JSON.parse(text):null;}catch{throw new Error('operator_response_invalid');}
    return {status:res.status,value};
  } finally {clearTimeout(timer);}
}

function buildPorts(opts) {
  const environment=opts['--env'];
  if(environment==='local') {
    if(opts['--project-ref'])throw new Error('unexpected_hosted_target');
    const target=localTarget();
    if(opts['--confirm-target']!==target.project)throw new Error('target_confirmation_mismatch');
    const container=localContainer('db',target);
    return {tag:target.project,
      async query(sql) {
        try {
          // stdin rather than process arguments: phone/digest never appear in a process listing.
          const result=execFileSync('docker',['exec','-i',container,'psql','-U','postgres','-X','-qAt','-v','ON_ERROR_STOP=1'],
            {input:sql,encoding:'utf8',stdio:['pipe','pipe','pipe'],maxBuffer:1048576,timeout:20000}).trim();
          return result?JSON.parse(result):null;
        } catch {throw new Error('operator_database_refused_or_unavailable');}
      },
      async deleteAuthUser(id) {
        if(!UUID.test(id))throw new Error('cleanup_authority_invalid');
        const keys=localStatus();
        const result=await boundedFetch(`${target.origin}/auth/v1/admin/users/${id}`,{
          method:'DELETE',headers:{...keyHeaders(keys.SERVICE_ROLE_KEY),'content-type':'application/json'},
          body:JSON.stringify({should_soft_delete:false})});
        if(![200,204,404].includes(result.status))throw new Error('orphan_delete_unconfirmed');
      },
    };
  }
  const target=hostedTarget(environment,opts['--project-ref'],opts['--confirm-target'],process.env.PRODUCTION_PROJECT_REF);
  const accessToken=process.env.SUPABASE_ACCESS_TOKEN;
  if(!accessToken)throw new Error('management_token_required');
  // The server key is needed only for the explicitly authorised orphan deletion.
  // It never enters SQL, files written by this CLI, stdout or a public client.
  const service=process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SECRET_KEY;
  if(['cleanup','reconcile'].includes(opts.action)&&!service)throw new Error('server_key_required_for_cleanup');
  return {tag:target.projectRef,
    async query(sql) {
      const result=await boundedFetch(`${MANAGEMENT}/v1/projects/${target.projectRef}/database/query`,{
        method:'POST',headers:{authorization:`Bearer ${accessToken}`,'content-type':'application/json'},body:JSON.stringify({query:sql})});
      if(result.status!==200||!Array.isArray(result.value)||result.value.length!==1||!Object.hasOwn(result.value[0],'value')) {
        throw new Error('operator_database_refused_or_unavailable');
      }
      return result.value[0].value;
    },
    async deleteAuthUser(id) {
      if(!service||!UUID.test(id))throw new Error('cleanup_authority_invalid');
      const result=await boundedFetch(`${target.apiUrl}/auth/v1/admin/users/${id}`,{
        method:'DELETE',headers:{...keyHeaders(service),'content-type':'application/json'},body:JSON.stringify({should_soft_delete:false})});
      if(![200,204,404].includes(result.status))throw new Error('orphan_delete_unconfirmed');
    },
  };
}

async function promptIssue(environment) {
  if(!stdin.isTTY||!stdout.isTTY)throw new Error('private_request_file_required_for_noninteractive_issue');
  const rl=createInterface({input:stdin,output:stdout});
  try {
    const phone_username=(await rl.question('Intended Admin phone username, including +country code: ')).trim();
    const existing=(await rl.question('Explicit existing Auth account UUID, or leave blank for a new account: ')).trim();
    const synthetic=(await rl.question('Fictional test account only? Type yes or no: ')).trim();
    if(!['yes','no'].includes(synthetic))throw new Error('explicit_synthetic_choice_required');
    const identity_check=(await rl.question('Identity check (in_person or established_relationship): ')).trim();
    const case_reference=(await rl.question('Restricted case reference (no personal details): ')).trim();
    return validateIssue({phone_username,existing_account:existing||null,synthetic:synthetic==='yes',identity_check,case_reference},environment);
  } finally {rl.close();}
}

export async function executeOperator(opts,ports,{load=readPrivateJson,save=writePrivateJson,prompt=promptIssue}={}) {
  const environment=opts['--env'];
  let file=null,stored=null;
  if(opts['--state-dir']) {
    const dir=privateDirectory(opts['--state-dir']);file=join(dir,'invitation.json');
    if(existsSync(file)) {
      stored=load(file);
      if(stored?.version!==1||stored.environment!==environment||stored.target!==ports.tag)throw new Error('state_target_mismatch');
      validateIssue(stored.request,environment);
      // Validation happens inside operatorSql before any secret reaches a query.
      operatorSql(environment,'lookup',{invitation:stored.invitation});
    }
  }
  if(opts.action==='issue') {
    if(!file)throw new Error('private_state_directory_required');
    const request=opts['--request-file']?validateIssue(load(resolve(opts['--request-file'])),environment)
      :stored?.request??await prompt(environment);
    if(stored && JSON.stringify(request)!==JSON.stringify(stored.request))throw new Error('prepared_request_cannot_change');
    if(!stored) {
      stored={version:1,environment,target:ports.tag,request,invitation:mintInvitation(environment),prepared_at:new Date().toISOString()};
      save(file,stored); // Exclusive publication; simultaneous issue cannot replace it.
    }
    const issued=await ports.query(operatorSql(environment,'issue',{request:stored.request,invitation:stored.invitation}));
    if(!issued||!UUID.test(issued.invitation_id??'')||typeof issued.expires_at!=='string')throw new Error('issue_outcome_unconfirmed_use_status');
    save(file,{...stored,invitation_id:issued.invitation_id,expires_at:issued.expires_at},{replace:true});
    return {...operatorSummary(issued),outcome:'issued',private_invitation_file:file};
  }
  let invitationId=opts['--invitation-id']??stored?.invitation_id??null;
  if(!invitationId && stored) {
    const known=await ports.query(operatorSql(environment,'lookup',{invitation:stored.invitation}));
    if(known?.invitation_id)invitationId=known.invitation_id;
  }
  if(opts.action==='status') {
    if(stored && !invitationId) return {outcome:'not_observed',guidance:'Retry issue with the same prepared file; do not generate a replacement invitation.'};
    const status=await ports.query(operatorSql(environment,'status',{invitationId}));
    return status?operatorSummary(status):{outcome:'not_found_or_environment_mismatch'};
  }
  if(opts.action==='candidates') {
    const rows=await ports.query(operatorSql(environment,'candidates'));
    if(!Array.isArray(rows))throw new Error('candidate_read_unconfirmed');return operatorSummary(rows);
  }
  if(!invitationId)throw new Error('invitation_id_required');
  if(opts.action==='revoke') {
    const result=await ports.query(operatorSql(environment,'revoke',{invitationId}));
    if(result?.outcome!=='revoked')throw new Error('revocation_unconfirmed');return operatorSummary(result);
  }
  return reconcileInvitation(environment,invitationId,ports);
}

export async function main(argv) {
  const opts=parseArgs(argv);
  if(opts.help) {
    console.log(`Restricted Admin onboarding (no passwords, deployment or policy activation)\n\nnode tools/ops/admin-onboarding.mjs issue|status|revoke|reconcile|cleanup|candidates\n  --env local|staging|production --confirm-target <exact-project>\n  [--project-ref <hosted-project-ref>] [--state-dir <private-folder>]\n  [--request-file <private-json>] [--invitation-id <uuid>]\n\nIssue requires --state-dir. Its invitation.json holds the private code for secure manual delivery.\nA retry uses that SAME file and never renews expiry. Reconcile/cleanup invalidates the\nold invitation, fences late provider writes, and removes only a proven unclaimed new account.\nExisting accounts and completed members are never deleted by this tool.\nSee docs/runbooks/admin-onboarding-operations.md before use.`);
    return 0;
  }
  const ports=buildPorts(opts);
  const result=await executeOperator(opts,ports);
  console.log(JSON.stringify({environment:opts['--env'],target:ports.tag,result}));
  return result?.outcome==='operator_review_required'?2:result?.outcome==='cleanup_pending'?3:0;
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(code=>{process.exitCode=code;},error=>{
    const safe=typeof error?.message==='string'&&/^[a-z_]{3,90}$/.test(error.message)?error.message:'operator_action_unconfirmed';
    console.error(`admin-onboarding: ${safe}. No success is assumed. Check status before retrying; never share the private invitation file or keys in a ticket.`);
    process.exitCode=1;
  });
}
