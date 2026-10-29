import test from 'node:test';import assert from 'node:assert/strict';
import {createVerifierProxy} from '../functions/film-device/verifier-proxy.mjs';
import {createVerifierHandler} from '../apple-verifier/service.mjs';
const secret='test-only-hmac-secret-'.repeat(3),user='11111111-1111-4111-8111-111111111111';
test('authenticated verifier transport binds receipt, caller and response',async()=>{
 const calls=[];const handler=createVerifierHandler({secret,verify:async(signed,userID)=>{calls.push({signed,userID});return {transactionID:'123',subscription:{source:'appStore',plan:'solo'}};}});
 const proxy=createVerifierProxy({getenv:key=>({APPLE_VERIFIER_URL:'https://verifier.invalid/verify-subscription',APPLE_VERIFIER_SHARED_SECRET:secret})[key],fetcher:async(url,init)=>handler(new Request(url,init))});
 const receipt=await proxy('signed.fixture',user);assert.equal(receipt.transactionID,'123');assert.deepEqual(calls,[{signed:'signed.fixture',userID:user}]);
});
test('invalid shared secret and modified server responses fail closed',async()=>{
 const handler=createVerifierHandler({secret,verify:async()=>({transactionID:'123'})});
 const config=key=>({APPLE_VERIFIER_URL:'https://verifier.invalid/verify-subscription',APPLE_VERIFIER_SHARED_SECRET:secret})[key];
 const wrong=createVerifierProxy({getenv:key=>key==='APPLE_VERIFIER_SHARED_SECRET'?'wrong-test-secret'.repeat(4):config(key),fetcher:async(url,init)=>handler(new Request(url,init))});await assert.rejects(()=>wrong('proof',user),/subscription_unavailable/);
 const tampered=createVerifierProxy({getenv:config,fetcher:async(url,init)=>{const r=await handler(new Request(url,init));return new Response('{"receipt":{"transactionID":"attacker"}}',{headers:r.headers});}});await assert.rejects(()=>tampered('proof',user),/subscription_unavailable/);
});
test('missing verifier deployment and insecure URLs cannot grant entitlements',async()=>{for(const url of [undefined,'http://remote.invalid/verify-subscription','https://verifier.invalid/wrong']){const proxy=createVerifierProxy({getenv:key=>key==='APPLE_VERIFIER_URL'?url:secret,fetcher:()=>assert.fail('must not fetch')});await assert.rejects(()=>proxy('proof',user),/subscription_unavailable/);}});
test('replayed and stale signed transport requests never reach Apple verification twice',async()=>{let count=0,packet;const handler=createVerifierHandler({secret,verify:async()=>{count++;return {transactionID:'123'};}});const config=key=>({APPLE_VERIFIER_URL:'https://verifier.invalid/verify-subscription',APPLE_VERIFIER_SHARED_SECRET:secret})[key];const proxy=createVerifierProxy({getenv:config,fetcher:async(url,init)=>{packet={url,init};return handler(new Request(url,init));}});await proxy('proof',user);assert.equal((await handler(new Request(packet.url,packet.init))).status,400);assert.equal(count,1);const stale=createVerifierProxy({getenv:config,now:()=>Date.now()-120000,fetcher:async(url,init)=>handler(new Request(url,init))});await assert.rejects(()=>stale('proof',user),/subscription_invalid/);assert.equal(count,1);});
