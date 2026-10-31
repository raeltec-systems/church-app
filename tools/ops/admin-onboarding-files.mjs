// Private operator material only. Never weaken execution policy or permissions.
import {execFileSync} from 'node:child_process';
import {existsSync,lstatSync,mkdirSync,readFileSync,writeFileSync,chmodSync,renameSync,unlinkSync,linkSync} from 'node:fs';
import {dirname,resolve,join} from 'node:path';
import {randomUUID} from 'node:crypto';

function ownerSid() {
  const text=execFileSync('whoami.exe',['/user','/fo','csv','/nh'],{encoding:'utf8',stdio:['ignore','pipe','pipe']});
  const sid=text.match(/S-1-5-21-[0-9-]+/g);
  if(sid?.length!==1)throw new Error('windows_owner_unavailable');
  return sid[0];
}
function windowsAcl(path) {
  const script="$a=Get-Acl -LiteralPath $env:CHURCH_ADMIN_ACL_PATH; @($a.Access | ForEach-Object { @{sid=$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value;allow=($_.AccessControlType -eq 'Allow')} }) | ConvertTo-Json -Compress";
  const text=execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',script],
    {encoding:'utf8',stdio:['ignore','pipe','pipe'],env:{...process.env,CHURCH_ADMIN_ACL_PATH:path}});
  const parsed=JSON.parse(text);return Array.isArray(parsed)?parsed:[parsed];
}
export function assertPrivate(path,{directory=false}={}) {
  const stat=lstatSync(path);
  if(stat.isSymbolicLink() || (directory?!stat.isDirectory():!stat.isFile()))throw new Error('private_path_invalid');
  if(process.platform==='win32') {
    const allowed=new Set([ownerSid(),'S-1-5-18','S-1-5-32-544']);
    const acl=windowsAcl(path);
    if(!acl.length||acl.some(x=>x.allow && !allowed.has(x.sid)))throw new Error('private_acl_required');
  } else {
    if((stat.mode & 0o077)!==0 || (process.getuid && stat.uid!==process.getuid()))throw new Error('private_permissions_required');
  }
  return stat;
}
export function privateDirectory(path) {
  const full=resolve(path);
  if(!existsSync(full)) {
    mkdirSync(full,{recursive:true,mode:0o700});
    if(process.platform==='win32') {
      const sid=ownerSid();
      execFileSync('icacls.exe',[full,'/inheritance:r','/grant:r',`*${sid}:(OI)(CI)F`,'*S-1-5-18:(OI)(CI)F'],{stdio:'pipe'});
    } else chmodSync(full,0o700);
  }
  assertPrivate(full,{directory:true});return full;
}
export function readPrivateJson(path) {
  const stat=assertPrivate(path);
  if(stat.size>16384)throw new Error('private_file_too_large');
  return JSON.parse(readFileSync(path,'utf8'));
}
export function writePrivateJson(path,value,{replace=false}={}) {
  const parent=privateDirectory(dirname(path));
  if(existsSync(path)) {
    assertPrivate(path);
    if(!replace)throw new Error('private_file_exists');
  }
  const temporary=join(parent,`.pending-${randomUUID()}.json`);
  try {
    writeFileSync(temporary,JSON.stringify(value,null,2)+'\n',{mode:0o600,flag:'wx'});
    assertPrivate(temporary);
    if(replace) renameSync(temporary,path);
    else linkSync(temporary,path); // Atomic no-clobber publication, including concurrent issue attempts.
    assertPrivate(path);
  } finally {
    if(existsSync(temporary))unlinkSync(temporary);
  }
}
