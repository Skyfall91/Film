import {fail} from './domain.mjs';
const encoder=new TextEncoder();
export async function transportMAC(secret,direction,timestamp,nonce,body) {
 const key=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,encoder.encode(['film-apple-v1',direction,timestamp,nonce,body].join('\n')))),b=>b.toString(16).padStart(2,'0')).join('');
}
export async function validMAC(secret,direction,timestamp,nonce,body,signature) {
 if(!/^[a-f0-9]{64}$/.test(signature||''))return false;
 const key=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
 const bytes=Uint8Array.from(signature.match(/../g),v=>parseInt(v,16));
 return crypto.subtle.verify('HMAC',key,bytes,encoder.encode(['film-apple-v1',direction,timestamp,nonce,body].join('\n')));
}
export async function limitedText(stream,max) {
 const reader=stream?.getReader();if(!reader)return '';let bytes=0,text='';const decoder=new TextDecoder();
 while(true){const part=await reader.read();if(part.done)break;bytes+=part.value.byteLength;if(bytes>max){await reader.cancel();fail('subscription_invalid');}text+=decoder.decode(part.value,{stream:true});}return text+decoder.decode();
}
export function createVerifierProxy({getenv,fetcher=fetch,now=Date.now}) {
 return async(signedTransaction,userID)=>{
  const endpoint=getenv('APPLE_VERIFIER_URL'),secret=getenv('APPLE_VERIFIER_SHARED_SECRET');
  let url;try{url=new URL(endpoint);}catch{fail('subscription_unavailable');}
  if(url.protocol!=='https:'||url.pathname!=='/verify-subscription'||url.username||url.password||url.search||url.hash||!secret||secret.length<32)fail('subscription_unavailable');
  const timestamp=String(Math.floor(now()/1000)),nonce=crypto.randomUUID(),body=JSON.stringify({signedTransaction,userID});
  let response;try{response=await fetcher(url.href,{method:'POST',redirect:'error',signal:AbortSignal.timeout(45000),headers:{'content-type':'application/json','x-film-timestamp':timestamp,'x-film-nonce':nonce,'x-film-signature':await transportMAC(secret,'request',timestamp,nonce,body)},body});}catch{fail('subscription_unavailable');}
  let raw;try{raw=await limitedText(response.body,32768);}catch{fail('subscription_unavailable');}
  if(!await validMAC(secret,'response',timestamp,nonce,raw,response.headers.get('x-film-signature')))fail('subscription_unavailable');
  let result;try{result=JSON.parse(raw);}catch{fail('subscription_unavailable');}
  if(!response.ok){if(/^subscription_[a-z_]+$/.test(result.error))fail(result.error);fail('subscription_unavailable');}
  if(!result.receipt||typeof result.receipt!=='object')fail('subscription_unavailable');
  return result.receipt;
 };
}
