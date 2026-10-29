import test from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';import {execFileSync} from 'node:child_process';import {X509Certificate,sign,createHash} from 'node:crypto';
import * as sdk from '@apple/app-store-server-library';
import {createVerifierProxy} from '../functions/film-device/verifier-proxy.mjs';
import {createVerifierHandler} from '../apple-verifier/service.mjs';
import {createAppleVerifier} from '../functions/film-device/subscriptions.mjs';
import {appleRootDERBase64} from '../functions/film-device/apple-roots.mjs';
let directory,roots,chain,key;
const userID='11111111-1111-4111-8111-111111111111';
await(async()=>{
 directory=await mkdtemp(join(tmpdir(),'film-test-only-apple-ca-'));
 const openssl=(...args)=>execFileSync('openssl',args,{cwd:directory,stdio:'pipe'});
 for(const name of ['root','intermediate','leaf'])openssl('ecparam','-name','prime256v1','-genkey','-noout','-out',name+'.key');
 openssl('req','-new','-x509','-key','root.key','-subj','/CN=Film Test Only Root','-days','2','-out','root.pem');
 for(const [name,parent,oid,ca]of [['intermediate','root','1.2.840.113635.100.6.2.1',true],['leaf','intermediate','1.2.840.113635.100.6.11.1',false]]){
  openssl('req','-new','-key',name+'.key','-subj','/CN=Film Test Only '+name,'-out',name+'.csr');
  await writeFile(join(directory,name+'.ext'),`basicConstraints=critical,CA:${ca?'TRUE':'FALSE'}\nkeyUsage=critical,${ca?'keyCertSign,cRLSign':'digitalSignature'}\n${oid}=ASN1:NULL\n`);
  openssl('x509','-req','-in',name+'.csr','-CA',parent+'.pem','-CAkey',parent+'.key','-CAcreateserial','-days','2','-extfile',name+'.ext','-out',name+'.pem');
 }
 const certs=await Promise.all(['leaf','intermediate','root'].map(async name=>new X509Certificate(await readFile(join(directory,name+'.pem'))).raw));
 roots=[certs[2]];chain=certs.map(c=>c.toString('base64'));key=await readFile(join(directory,'leaf.key'));
})();
await rm(directory,{recursive:true,force:true});
function fixture(patch={}){
 const now=Date.now();const payload={environment:'Sandbox',bundleId:'app.film',productId:'app.film.abo.solo',type:'Auto-Renewable Subscription',transactionId:'100001',originalTransactionId:'100000',purchaseDate:now-1000,expiresDate:now+600000,signedDate:now,appAccountToken:userID,...patch};
 const encode=x=>Buffer.from(JSON.stringify(x)).toString('base64url');const body=encode({alg:'ES256',x5c:chain})+'.'+encode(payload);
 return body+'.'+sign('sha256',Buffer.from(body),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
}
const getenv=key=>key==='APPLE_ENVIRONMENT'?'Sandbox':undefined;
test('official Apple SDK verifies a signed test chain and ES256 signature',async()=>{const verify=createAppleVerifier({sdk,roots,getenv});const receipt=await verify(fixture(),userID);assert.equal(receipt.subscription.plan,'solo');assert.equal(receipt.environment,'Sandbox');});
test('official verifier rejects tampering and untrusted chains without bypass',async()=>{
 const verify=createAppleVerifier({sdk,roots,getenv});const original=fixture();const parts=original.split('.');parts[2]=(parts[2][0]==='A'?'B':'A')+parts[2].slice(1);await assert.rejects(()=>verify(parts.join('.'),userID),/subscription_invalid/);
 const productionRoots=appleRootDERBase64.map(c=>Buffer.from(c,'base64'));const withAppleRoots=createAppleVerifier({sdk,roots:productionRoots,getenv});await assert.rejects(()=>withAppleRoots(original,userID),/subscription_invalid/);
});
test('official SDK rejects signed wrong app and environment; semantic validator rejects revoked proof',async()=>{const verify=createAppleVerifier({sdk,roots,getenv});for(const patch of [{bundleId:'attacker.app'},{environment:'Production'},{revocationDate:Date.now()-1}])await assert.rejects(()=>verify(fixture(patch),userID),/subscription_/);});
test('bundled public roots match the downloaded Apple PKI trust anchors',async()=>{const names=['AppleIncRootCertificate.cer','AppleRootCA-G2.cer','AppleRootCA-G3.cer'];const fingerprints=['b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024','c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050','63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179'];for(let i=0;i<names.length;i++){const der=await readFile(new URL('../functions/film-device/certs/'+names[i],import.meta.url));assert.equal(der.toString('base64'),appleRootDERBase64[i]);assert.equal(createHash('sha256').update(der).digest('hex'),fingerprints[i]);assert.ok(new X509Certificate(der).ca);}});

test('signed receipt survives authenticated Edge-to-Node transport with the official SDK',async()=>{const secret='test-only-sidecar-secret-'.repeat(3);const verify=createAppleVerifier({sdk,roots,getenv});const handler=createVerifierHandler({secret,verify});const proxy=createVerifierProxy({getenv:key=>({APPLE_VERIFIER_URL:'https://verifier.invalid/verify-subscription',APPLE_VERIFIER_SHARED_SECRET:secret})[key],fetcher:async(url,init)=>handler(new Request(url,init))});const receipt=await proxy(fixture(),userID);assert.equal(receipt.subscription.source,'appStore');assert.equal(receipt.subscription.plan,'solo');});
