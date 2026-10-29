import {uuid,text,fail} from '../functions/film-device/domain.mjs';
import {transportMAC,validMAC,limitedText} from '../functions/film-device/verifier-proxy.mjs';
export function createVerifierHandler({secret,verify,now=Date.now}) {
 if(typeof secret!=='string'||secret.length<32)throw new Error('Missing verifier shared secret');
 const nonces=new Map();
 return async request=>{
  const timestamp=request.headers.get('x-film-timestamp')||'',nonce=request.headers.get('x-film-nonce')||'';
  const reply=async(body,status)=>{const raw=JSON.stringify(body);return new Response(raw,{status,headers:{'content-type':'application/json','cache-control':'no-store','x-film-signature':await transportMAC(secret,'response',timestamp,nonce,raw)}});};
  try{
   if(request.method!=='POST'||new URL(request.url).pathname!=='/verify-subscription')return new Response(null,{status:404});
   if(!/^\d{10}$/.test(timestamp)||Math.abs(now()/1000-Number(timestamp))>60)fail('subscription_invalid');uuid(nonce);
   const raw=await limitedText(request.body,131072);
   if(!await validMAC(secret,'request',timestamp,nonce,raw,request.headers.get('x-film-signature')))return new Response(null,{status:401});
   for(const [id,expiry]of nonces)if(expiry<now())nonces.delete(id);
   if(nonces.has(nonce)||nonces.size>=5000)fail('subscription_invalid');nonces.set(nonce,now()+120000);
   const body=JSON.parse(raw);uuid(body.userID);text(body.signedTransaction,100000);
   return reply({receipt:await verify(body.signedTransaction,body.userID)},200);
  }catch(error){const code=/^subscription_[a-z_]+$/.test(error.message)?error.message:'subscription_invalid';return reply({error:code},code==='subscription_unavailable'?503:400);}
 };
}
