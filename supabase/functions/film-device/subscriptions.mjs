import {fail,uuid} from './domain.mjs';
const defaultBundles=['app.film','app.film.tv'];
// The real bundle IDs come from APPLE_BUNDLE_IDS (comma separated), so they never live in the public code.
export const bundleIDsFrom=raw=>{const list=String(raw??'').split(',').map(v=>v.trim()).filter(Boolean);return new Set(list.length?list:defaultBundles);};
const products={'app.film.abo.solo':'solo','app.film.abo.duo':'duo','app.film.abo.familie':'familie'};
const millis=v=>Number.isSafeInteger(v)&&v>0;
// This function accepts an already cryptographically verified SDK payload only.
export function subscriptionFromVerifiedTransaction(t,{userID,environment,now=Date.now(),bundles=bundleIDsFrom()}) {
 if(!['Sandbox','Production'].includes(environment)||t.environment!==environment)fail('subscription_environment');
 if(!bundles.has(t.bundleId)||!Object.hasOwn(products,t.productId)||t.type!=='Auto-Renewable Subscription')fail('subscription_product');
 if(t.revocationDate!=null||t.revocationReason!=null||t.isUpgraded===true)fail('subscription_revoked');
 if(!millis(t.expiresDate)||t.expiresDate<=now)fail('subscription_expired');
 if(!millis(t.purchaseDate)||!millis(t.signedDate)||t.purchaseDate>now+60000||t.signedDate>now+60000)fail('subscription_invalid');
 if(typeof t.transactionId!=='string'||!/^\d{1,40}$/.test(t.transactionId)||typeof t.originalTransactionId!=='string'||!/^\d{1,40}$/.test(t.originalTransactionId))fail('subscription_invalid');
 if(t.appAccountToken!=null&&uuid(t.appAccountToken)!==uuid(userID))fail('subscription_owner');
 const start=millis(t.originalPurchaseDate)?t.originalPurchaseDate:t.purchaseDate;
 return {environment,bundleID:t.bundleId,transactionID:t.transactionId,originalTransactionID:t.originalTransactionId,purchaseAt:new Date(t.purchaseDate).toISOString(),signedAt:new Date(t.signedDate).toISOString(),expiresAt:new Date(t.expiresDate).toISOString(),subscription:{plan:products[t.productId],source:'appStore',started:start/1000-978307200,renews:t.expiresDate/1000-978307200,trial:t.offerType===1&&t.offerDiscountType==='FREE_TRIAL',canceled:false}};
}
// SDK/roots/config are server dependencies; none can be selected by a request.
export function createAppleVerifier({sdk,roots,getenv,now=Date.now}) {
 let configured;
 return async(signedTransaction,userID)=>{
  const environment=getenv('APPLE_ENVIRONMENT');
  if(!['Sandbox','Production'].includes(environment)||!roots.length)fail('subscription_unavailable');
  if(!configured) {
   const rawID=getenv('APPLE_APP_ID'),appID=rawID?Number(rawID):undefined;
   const issuer=getenv('APPLE_ISSUER_ID'),keyID=getenv('APPLE_KEY_ID'),key=getenv('APPLE_PRIVATE_KEY');
   if(environment==='Production'&&(!Number.isSafeInteger(appID)||appID<=0||!issuer||!keyID||!key))fail('subscription_unavailable');
   configured=[...bundleIDsFrom(getenv('APPLE_BUNDLE_IDS'))].map(bundleID=>({bundleID,verifier:new sdk.SignedDataVerifier(roots,environment==='Production',environment,bundleID,appID),client:environment==='Production'?new sdk.AppStoreServerAPIClient(key.replace(/\\n/g,'\n'),keyID,issuer,bundleID,environment):null}));
  }
  let decoded,selected;
  for(const item of configured) {try{decoded=await item.verifier.verifyAndDecodeTransaction(signedTransaction);selected=item;break;}catch{/* No payload or SDK diagnostics are exposed. */}}
  if(!selected)fail('subscription_invalid');
  if(selected.client) {
   // Re-fetch Apple's current signed record to catch a revocation after issuance
   // of the JWS held by the client. Never fall back to stale data on API failure.
   let refreshed;try{refreshed=await selected.client.getTransactionInfo(decoded.transactionId);}catch{fail('subscription_unavailable');}
   if(!refreshed?.signedTransactionInfo)fail('subscription_invalid');
   try{const current=await selected.verifier.verifyAndDecodeTransaction(refreshed.signedTransactionInfo);if(current.transactionId!==decoded.transactionId)fail('subscription_invalid');decoded=current;}catch{fail('subscription_invalid');}
  }
  return subscriptionFromVerifiedTransaction(decoded,{userID,environment,now:now(),bundles:new Set(configured.map(c=>c.bundleID))});
 };
}
