import test from 'node:test';
import assert from 'node:assert/strict';
import {withRollout} from '../functions/film-device/rollout.mjs';
test('disabled rollout rejects even signed requests before any account handler runs',async()=>{
 let calls=0;let enabled;
 const handler=withRollout(()=>{calls++;return new Response('unexpected');},()=>enabled);
 for(const value of [undefined,'false','TRUE','1']) {
  enabled=value;
  for(const route of ['readState','createPairing']) {
   const result=await handler(new Request('https://example.test/'+route,{method:'POST',headers:{authorization:'Bearer existing-session'},body:'{}'}));
   assert.equal(result.status,503);assert.equal(result.headers.get('cache-control'),'no-store');assert.deepEqual(await result.json(),{error:'service_not_enabled'});
  }
 }
 assert.equal(calls,0);
});
test('only explicit true enables the existing authenticated handler without changing its response',async()=>{
 const request=new Request('https://example.test/readState',{method:'POST',body:'{}'});
 const response=new Response('authenticated handler result',{status:401});let seen;
 const handler=withRollout(r=>{seen=r;return response;},()=>'true');
 assert.equal(await handler(request),response);assert.equal(seen,request);
});
