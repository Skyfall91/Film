import test from 'node:test';import assert from 'node:assert/strict';
import {subscriptionFromVerifiedTransaction,createAppleVerifier} from '../functions/film-device/subscriptions.mjs';
const user='11111111-1111-4111-8111-111111111111',now=1800000000000;
const transaction=()=>({environment:'Sandbox',bundleId:'app.film',productId:'app.film.abo.solo',type:'Auto-Renewable Subscription',transactionId:'1000001',originalTransactionId:'1000000',purchaseDate:now-1000,originalPurchaseDate:now-100000,expiresDate:now+100000,signedDate:now,appAccountToken:user,offerType:1,offerDiscountType:'FREE_TRIAL'});
test('only verified allowlisted receipt data derives a Swift subscription',()=>{const r=subscriptionFromVerifiedTransaction(transaction(),{userID:user,environment:'Sandbox',now});assert.equal(r.subscription.plan,'solo');assert.equal(r.subscription.source,'appStore');assert.equal(r.subscription.renews,(now+100000)/1000-978307200);assert.equal(r.subscription.trial,true);assert.equal(r.originalTransactionID,'1000000');});
test('revoked expired wrong account product bundle environment and type are rejected',()=>{
 for(const patch of [{revocationDate:now-1},{expiresDate:now-1},{appAccountToken:'22222222-2222-4222-8222-222222222222'},{productId:'fake.family'},{bundleId:'attacker.app'},{environment:'Production'},{type:'Consumable'},{signedDate:now+120000}])assert.throws(()=>subscriptionFromVerifiedTransaction({...transaction(),...patch},{userID:user,environment:'Sandbox',now}),/subscription_/);
});
test('unconfigured and Xcode/LocalTesting bypass environments never verify',async()=>{
 for(const env of [undefined,'Xcode','LocalTesting']){const verify=createAppleVerifier({sdk:{},roots:[],getenv:key=>key==='APPLE_ENVIRONMENT'?env:undefined});await assert.rejects(()=>verify('unsigned',user),/subscription_unavailable/);}
});
test('production verifier requires configured numeric app ID and Apple API credentials',async()=>{
 const verify=createAppleVerifier({sdk:{},roots:[],getenv:key=>key==='APPLE_ENVIRONMENT'?'Production':undefined});await assert.rejects(()=>verify('unsigned',user),/subscription_unavailable/);
});
test('production policy refreshes the transaction and fails closed when Apple API fails (SDK boundary stub)',async()=>{
 const calls=[],env={APPLE_ENVIRONMENT:'Production',APPLE_APP_ID:'123',APPLE_ISSUER_ID:'test-issuer',APPLE_KEY_ID:'test-key',APPLE_PRIVATE_KEY:'test-only-key'};
 let unavailable=false;
 const sdk={SignedDataVerifier:class{constructor(_roots,online,environment,bundle){calls.push({online,environment,bundle});}async verifyAndDecodeTransaction(signed){return {...transaction(),environment:'Production',offerDiscountType:'FREE_TRIAL',...(signed==='refreshed'?{productId:'app.film.abo.duo'}:{})};}},AppStoreServerAPIClient:class{async getTransactionInfo(id){calls.push(id);if(unavailable)throw Error('Apple unavailable');return {signedTransactionInfo:'refreshed'};}}};
 const verify=createAppleVerifier({sdk,roots:[Buffer.from('test-only')],getenv:key=>env[key],now:()=>now});const r=await verify('initial',user);assert.equal(r.subscription.plan,'duo');assert.ok(calls.some(c=>c?.online===true));assert.ok(calls.includes('1000001'));unavailable=true;await assert.rejects(()=>verify('initial',user),/subscription_unavailable/);
});
