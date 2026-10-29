import { applyOperations, wireState, fail, uuid, text, object, hashValue, bootstrapState } from './domain.mjs';
import { catalog } from './catalog.mjs';
export async function sha256(value) {return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),b=>b.toString(16).padStart(2,'0')).join('');}
const allowedActions=new Set(['createPairing','resolveCode','approvePairing','rejectPairing','activateSession','cancelPairing','rotateSession','revokeSession','listSessions','verifySubscription','readState','applyMutations','createJob','listJobs','claimJob','completeJob','cancelJob']);
const jobKinds=new Set(['import','taste','mood','review','deleteAccount','subscription','externalLink']);
const phoneOnly=new Set(['approvePairing','rejectPairing','claimJob','completeJob','listSessions']);
const response=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'}});
export function createHandler({rpc,getUser,verifySubscription}) {
 return async(request)=>{
  try {
   if(request.method!=='POST')return response({error:'method_not_allowed'},405);
   if(Number(request.headers.get('content-length'))>262144)return response({error:'request_too_large'},413);
   let raw='';const reader=request.body?.getReader();const decoder=new TextDecoder();let bytes=0;if(reader){while(true){const part=await reader.read();if(part.done)break;bytes+=part.value.byteLength;if(bytes>262144){await reader.cancel();return response({error:'request_too_large'},413);}raw+=decoder.decode(part.value,{stream:true});}raw+=decoder.decode();}
   let b;try {b=object(JSON.parse(raw));}catch {return response({error:'invalid_json'},400);}
   const tail=new URL(request.url).pathname.split('/').pop();const action=b.action||tail;
   if(!allowedActions.has(action))return response({error:'unknown_action'},404);
   const ip=await sha256((request.headers.get('x-forwarded-for')||'unknown').split(',')[0].trim());
   const limit=async(key,n,seconds=60)=>{if(!await rpc('film_rate_limit',{p_key:key,p_limit:n,p_seconds:seconds}))fail('rate_limited');};
   await limit('global:'+action,['resolveCode','createPairing'].includes(action)?300:5000);
   await limit('ip:'+ip+':'+action,action==='resolveCode'?5:action==='createPairing'?10:120);
   if(action==='createPairing') {
    hashValue(b.pollHash);hashValue(b.sessionHash);if(b.pollHash===b.sessionHash)fail('invalid_hash');
    const name=text(b.deviceName,80).replace(/[\x00-\x1f\x7f]/g,'').trim();if(!name)fail('invalid_device_name');
    return response(await rpc('film_create_pairing',{p_poll_hash:b.pollHash,p_session_hash:b.sessionHash,p_device_name:name}));
   }
   if(action==='resolveCode') {if(typeof b.code!=='string'||!/^\d{6}$/.test(b.code))fail('invalid_code');return response(await rpc('film_resolve_code',{p_code:b.code}));}
   if(action==='activateSession'||action==='cancelPairing') {
    uuid(b.id);text(b.pollSecret,256);if(b.pollSecret.length<32)fail('unauthorized');
    await limit('poll:'+b.id,12);
    return response(await rpc(action==='cancelPairing'?'film_cancel_pairing':'film_activate_session',{p_id:b.id,p_poll_hash:await sha256(b.pollSecret)}));
   }
   const auth=request.headers.get('authorization')||'';if(!auth.startsWith('Bearer '))fail('unauthorized');
   const bearer=auth.slice(7);if(bearer.length<20||bearer.length>4096)fail('unauthorized');
   const isJWT=bearer.split('.').length===3;
   let principal;
   if(isJWT) {const u=await getUser(bearer);if(!u?.id)fail('unauthorized');principal={userID:u.id,email:u.email,tokenHash:null,sessionID:null};}
   else {if(phoneOnly.has(action))fail('unauthorized');const tokenHash=await sha256(bearer);const p=await rpc('film_principal',{p_token_hash:tokenHash,p_rotation_operation:action==='rotateSession'?uuid(b.operationID):null,p_new_hash:action==='rotateSession'?hashValue(b.newHash):null});if(!p?.userID)fail('unauthorized');principal={...p,tokenHash};}
   if(phoneOnly.has(action)&&!isJWT)fail('unauthorized');
   const context={p_user_id:principal.userID,p_token_hash:principal.tokenHash};
   await limit('account:'+principal.userID+':'+action,120);
   if(action==='approvePairing'||action==='rejectPairing') {uuid(b.id);if(typeof b.code!=='string'||!/^\d{6}$/.test(b.code))fail('invalid_code');return response(await rpc('film_approve_pairing',{p_user_id:principal.userID,p_id:b.id,p_code:b.code,p_approve:action==='approvePairing'}));}
   if(action==='rotateSession') {if(isJWT)fail('unauthorized');return response(await rpc('film_rotate_session',{...context,p_new_hash:hashValue(b.newHash),p_operation_id:uuid(b.operationID)}));}
   if(action==='listSessions')return response({sessions:await rpc('film_list_sessions',context)});
   if(action==='revokeSession') {return response(await rpc('film_revoke_session',{...context,p_session_id:b.id?uuid(b.id):principal.sessionID}));}
   if(action==='verifySubscription'){text(b.signedTransaction,100000);if(!verifySubscription)fail('subscription_unavailable');const receipt=await verifySubscription(b.signedTransaction,principal.userID);const data=await rpc('film_verify_subscription',{...context,p_receipt:receipt});return response({state:wireState(data.state),revision:data.revision,userID:principal.userID,email:principal.email});}
   if(action==='readState') {if(b.bootstrapState&&!isJWT)fail('unauthorized');const bootstrap=b.bootstrapState?bootstrapState(b.bootstrapState,principal.email):null;const data=await rpc('film_read_state',{...context,p_bootstrap:bootstrap});return response({state:wireState(data.state),revision:data.revision,userID:principal.userID,email:principal.email});}
   if(action==='applyMutations') {
    if(!Array.isArray(b.operations)||b.operations.length>100)fail('invalid_operations');
    for(let attempt=0;attempt<5;attempt++) {
     const data=await rpc('film_read_state',context);
     const result=applyOperations({state:data.state,metadata:data.metadata,operations:b.operations,baseRevision:b.baseRevision,revision:data.revision,seen:data.seen,catalog});
     const committed=await rpc('film_commit_state',{...context,p_expected_revision:data.revision,p_revision:result.revision,p_state:wireState(result.state),p_metadata:result.metadata,p_operation_ids:result.acknowledged});
     if(committed)return response({state:wireState(result.state),revision:result.revision,userID:principal.userID,email:principal.email});
    }fail('revision_conflict');
   }
   if(action==='createJob') {
    if(!jobKinds.has(b.kind))fail('invalid_job');if(b.profileID)uuid(b.profileID);object(b.payload||{});
    return response(await rpc('film_create_job',{...context,p_kind:b.kind,p_profile_id:b.profileID||null,p_payload:b.payload||{},p_operation_id:uuid(b.operationID)}));
   }
   if(action==='listJobs')return response({jobs:await rpc('film_list_jobs',context)});
   uuid(b.id);if(!Number.isSafeInteger(b.version)||b.version<1)fail('invalid_version');
   if(action==='completeJob'&&b.result?.operations) {
    object(b.result);const claimant='phone:'+text(b.claimant||'',100);if(claimant==='phone:')fail('invalid_claimant');
    for(let attempt=0;attempt<5;attempt++){
     const data=await rpc('film_read_state',context);
     const result=applyOperations({state:data.state,metadata:data.metadata,operations:b.result.operations,baseRevision:b.result.baseRevision,revision:data.revision,seen:data.seen,catalog});
     try{return response(await rpc('film_complete_job',{...context,p_id:b.id,p_version:b.version,p_claimant:claimant,p_result:b.result,p_expected_revision:data.revision,p_revision:result.revision,p_state:wireState(result.state),p_metadata:result.metadata,p_operation_ids:result.acknowledged}));}
     catch(e){if(e.message!=='revision_conflict')throw e;}
    }fail('revision_conflict');
   }
   const claimant=isJWT?'phone:'+text(b.claimant||'',100):principal.sessionID;
   if(action==='claimJob'&&claimant==='phone:')fail('invalid_claimant');
   return response(await rpc('film_transition_job',{...context,p_id:b.id,p_version:b.version,p_action:{claimJob:'claim',completeJob:'complete',cancelJob:'cancel'}[action],p_claimant:claimant,p_result:b.result||{}}));
  } catch(error) {
   const message=String(error?.message||'server_error');
   const code=message.match(/\b(unauthorized|rate_limited|not_found|pairing_expired|pairing_conflict|invalid_[a-z_]+|profile_[a-z_]+|revision_conflict|undo_conflict|age_restricted|unverified_subscription|subscription_[a-z_]+|account_not_found|job_[a-z_]+)\b/)?.[1]||'server_error';
   const status=code==='subscription_unavailable'?503:code==='unauthorized'?401:code==='rate_limited'?429:code==='not_found'?404:/conflict|expired|deleted/.test(code)?409:code==='server_error'?500:400;
   // Do not echo SQL details, tokens, codes or payloads in errors/logs.
   return response({error:code},status);
  }
 };
}
