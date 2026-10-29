import test from 'node:test';
import assert from 'node:assert/strict';
import { applyOperations, publicPairing, rotateSession, transitionJob } from '../functions/film-device/domain.mjs';
const profileID = '11111111-1111-4111-8111-111111111111';
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const initial = () => ({profiles:[{id:profileID,name:'Test',maxFSK:12,colorIndex:0,watchlist:[],interactions:{},hints:{},samples:[],reviews:[],progress:{}}],account:{email:'test@example.invalid',passwordHash:'secret',salt:'secret',subscription:{plan:'solo'}},activeProfileIDs:[profileID]});
const catalog = {a:{fsk:6,forLittleKids:true},b:{fsk:12},adult:{fsk:18}};
const run = (state, operations, baseRevision=0, revision=0, seen=[]) => applyOperations({state,operations,baseRevision,revision,seen,catalog});
const op = (n, kind, filmID='a', payload={}) => ({id:id(n),kind,profileID,filmID,payload});
test('different stale watchlist edits merge and sensitive/local fields leave the wire state',()=>{
 const a=run(initial(),[op(1,'watchlistAdd')]);
 const b=run(a.state,[op(2,'watchlistAdd','b')],0,a.revision);
 assert.deepEqual(b.state.profiles[0].watchlist,['a','b']);
 assert.equal(b.state.account.passwordHash,''); assert.equal(b.state.account.salt,'');
 assert.equal(b.state.activeProfileIDs,undefined); assert.equal(b.revision,2);
});
test('idempotent replay never learns or increments the revision again',()=>{
 const a=run(initial(),[op(1,'ratingSet','a',{rating:'ratedLove'})]);
 const b=run(a.state,[op(1,'ratingSet','a',{rating:'ratedLove'})],0,a.revision,[id(1)]);
 assert.equal(b.revision,a.revision); assert.equal(b.state.profiles[0].samples.length,1);
});
test('same-film rating replaces its sample while preserving another film rating',()=>{
 let a=run(initial(),[op(1,'ratingSet','a',{rating:'ratedLove'})]);
 let b=run(a.state,[op(2,'ratingSet','b',{rating:'ratedDown'})],0,a.revision);
 let c=run(b.state,[op(3,'ratingSet','a',{rating:'ratedOkay'})],0,b.revision);
 assert.deepEqual(c.state.profiles[0].samples,[{filmID:'a',target:0.2},{filmID:'b',target:-1.2}]);
});
test('whole-profile learned snapshots conflict instead of deleting concurrent edits',()=>{
 const a=run(initial(),[op(1,'watchlistAdd')]);
 assert.throws(()=>run(a.state,[{...op(2,'profileReplace'),payload:{profile:initial().profiles[0]}}],0,a.revision),/revision_conflict/);
});
test('tombstones prevent late offline resurrection',()=>{
 const a=run(initial(),[op(1,'profileDelete')]);
 assert.throws(()=>run(a.state,[{id:id(2),kind:'profileCreate',profileID,payload:{profile:initial().profiles[0]}}],0,a.revision),/profile_deleted/);
});
test('profile ownership, trusted FSK, profile count and rating schemas are enforced',()=>{
 assert.throws(()=>run(initial(),[{...op(1,'watchlistAdd'),profileID:id(99)}]),/profile_not_found/);
 assert.throws(()=>run(initial(),[op(1,'watchlistAdd','adult',{fsk:0})]),/age_restricted/);
 assert.throws(()=>run(initial(),[op(1,'watchlistAdd','unknown',{fsk:0})]),/age_restricted/);
 assert.throws(()=>run(initial(),[op(1,'ratingSet','a',{rating:'hacked'})]),/invalid_rating/);
 let s=initial(); s.profiles.push({...s.profiles[0],id:id(98)});
 assert.throws(()=>run(s,[{id:id(1),kind:'profileCreate',profileID:id(97),payload:{profile:{id:id(97),name:'Third',maxFSK:18,colorIndex:0}}}]),/profile_limit/);
});
test('delayed progress cannot undo completion but explicit restart can',()=>{
 let a=run(initial(),[op(1,'progressSet','a',{progress:{season:1,episode:1,position:120,completed:true}})]);
 let b=run(a.state,[op(2,'progressSet','a',{progress:{season:1,episode:1,position:20,completed:false}})],0,a.revision);
 assert.equal(b.state.profiles[0].progress.a.completed,true);
 let c=run(b.state,[op(3,'progressSet','a',{progress:{season:1,episode:1,position:0,completed:false,restart:true}})],b.revision,b.revision);
 assert.equal(c.state.profiles[0].progress.a.position,0);
});
test('stale undo is rejected after someone else changed the same field',()=>{
 let a=run(initial(),[op(1,'ratingSet','a',{rating:'ratedLove'})]);
 let b=run(a.state,[op(2,'ratingSet','a',{rating:'ratedDown'})],0,a.revision);
 assert.throws(()=>run(b.state,[op(3,'ratingSet','a',{rating:'ratedOkay',expectedOperationID:id(1)})],b.revision,b.revision),/undo_conflict/);
});
test('pairing projection never leaks hashes and expiry takes precedence',()=>{
 const p={id:id(1),code:'123456',device_name:'TV',expires_at:'2026-01-01T00:05:00Z',status:'approved',poll_hash:'secret',session_hash:'secret'};
 assert.deepEqual(publicPairing(p,Date.parse('2026-01-01T00:04:00Z')),{id:id(1),code:'123456',deviceName:'TV',expiresAt:p.expires_at,status:'approved'});
 assert.equal(publicPairing(p,Date.parse('2026-01-01T00:06:00Z')).status,'expired');
});
test('rotation permits only same operation retry for 60 seconds and revocation wins',()=>{
 const s={hash:'old',expiresAt:100000,revoked:false};
 const a=rotateSession(s,{hash:'old',newHash:'new',operationID:id(1),now:1000});
 assert.equal(a.hash,'new');
 assert.deepEqual(rotateSession(a,{hash:'old',newHash:'new',operationID:id(1),now:2000}),a);
 assert.throws(()=>rotateSession(a,{hash:'old',newHash:'evil',operationID:id(2),now:2000}),/unauthorized/);
 assert.throws(()=>rotateSession(a,{hash:'old',newHash:'new',operationID:id(1),now:62000}),/unauthorized/);
 assert.throws(()=>rotateSession({...a,revoked:true},{hash:'old',newHash:'new',operationID:id(1),now:2000}),/unauthorized/);
});
test('jobs bind claimant, version, profile and expiry before accepting results',()=>{
 const j={id:id(1),profileID,version:1,status:'pending',expiresAt:10000};
 const a=transitionJob(j,'claim',{version:1,claimant:'phone',now:1,profileExists:true});
 assert.equal(a.status,'claimed'); assert.equal(a.version,2);
 assert.throws(()=>transitionJob(a,'complete',{version:2,claimant:'other',now:2,profileExists:true}),/job_conflict/);
 assert.throws(()=>transitionJob(a,'complete',{version:2,claimant:'phone',now:10001,profileExists:true}),/job_expired/);
 assert.throws(()=>transitionJob(a,'complete',{version:2,claimant:'phone',now:2,profileExists:false}),/profile_not_found/);
 assert.equal(transitionJob(a,'complete',{version:2,claimant:'phone',now:2,profileExists:true,result:{text:'done'}}).status,'completed');
});
test('Swift learning sample deltas accumulate independently and uppercase profile IDs match',()=>{
 const a=run(initial(),[{...op(20,'ratingSet'),profileID:profileID.toUpperCase(),payload:{rating:'liked',learning:{samples:[{filmID:'a',delta:1}],affinity:{'g:Drama':1},exposure:{'g:Drama':1},signalN:1,signalTotal:1}}}]);
 const b=run(a.state,[{...op(21,'ratingSet','b'),payload:{rating:'loved',learning:{samples:[{filmID:'a',delta:2},{filmID:'b',delta:2}],affinity:{'g:Drama':2},signalN:1,signalTotal:2}}}],0,a.revision);
 assert.deepEqual(b.state.profiles[0].samples,[{filmID:'a',target:3},{filmID:'b',target:2}]);assert.equal(b.state.profiles[0].affinity['g:Drama'],3);
});
test('hint deltas add and profile metadata patch preserves existing learned state',()=>{
 let a=run(initial(),[op(30,'hintSet',undefined,{key:'d:Nolan',value:2})]);
 let b=run(a.state,[op(31,'hintSet',undefined,{key:'d:Nolan',value:1})],0,a.revision);
 assert.equal(b.state.profiles[0].hints['d:Nolan'],3);assert.equal(b.state.profiles[0].affinity['d:Nolan'],3);
 let c=run(b.state,[op(32,'profileUpdate',undefined,{importedCountDelta:4,external:{'ext:Q1':{id:'ext:Q1',title:'Test',genres:[],moods:[],director:'',cast:[]}}})],b.revision,b.revision);
 assert.equal(c.state.profiles[0].importedCount,4);assert.equal(c.state.profiles[0].external['ext:Q1'].title,'Test');
});
test('playback positions merge by episode key and reject malformed values',()=>{
 const a=run(initial(),[op(40,'progressSet','a',{positionKey:'a|1|2',seconds:42})]);
 const b=run(a.state,[op(41,'progressSet','a',{positionKey:'a|1|3',seconds:84})],0,a.revision);
 assert.deepEqual(b.state.profiles[0].playbackPositions,{'a|1|2':42,'a|1|3':84});
 assert.throws(()=>run(b.state,[op(42,'progressSet','a',{positionKey:'b|film',seconds:-1})],b.revision,b.revision),/invalid_progress/);
});
test('watchlist add and remove share one undo identity',()=>{
 let a=run(initial(),[op(50,'watchlistAdd')]);let b=run(a.state,[op(51,'watchlistRemove')],0,a.revision);
 assert.throws(()=>run(b.state,[op(52,'watchlistAdd','a',{expectedOperationID:id(50)})],b.revision,b.revision),/undo_conflict/);
});
test('imports reject inherited rating names and never relearn identical fingerprint',()=>{
 assert.throws(()=>run(initial(),[op(53,'importApply',undefined,{fingerprint:'a'.repeat(64),ratings:[{filmID:'a',rating:'constructor'}]})]),/invalid_rating/);
 let a=run(initial(),[op(54,'importApply',undefined,{fingerprint:'a'.repeat(64),ratings:[{filmID:'a',rating:'liked'}],learning:{affinity:{'g:Drama':1}}})]);
 let b=run(a.state,[op(55,'importApply',undefined,{fingerprint:'a'.repeat(64),ratings:[{filmID:'a',rating:'liked'}],learning:{affinity:{'g:Drama':1}}})],0,a.revision);
 assert.equal(b.state.profiles[0].affinity['g:Drama'],1);assert.equal(b.state.profiles[0].importedCount,1);
});
test('rating/review removals and onboarding patches support granular undo',()=>{
 const a=run(initial(),[op(60,'ratingSet','a',{rating:'liked'})]);
 const b=run(a.state,[op(61,'ratingSet','a',{rating:null}),op(62,'reviewSet','a',{review:null}),op(63,'profileUpdate',undefined,{onboardingComplete:true})],a.revision,a.revision);
 assert.equal(b.state.profiles[0].interactions.a,undefined);assert.equal(b.state.profiles[0].samples.length,0);assert.equal(b.state.onboardingDone,true);assert.equal(b.state.profiles[0].onboardingComplete,true);
});
test('profile updates never reset a finished onboarding for profiles without the flag',()=>{
 const start={...initial(),onboardingDone:true};
 const b=run(start,[op(64,'profileUpdate',undefined,{name:'Neu'})]);
 assert.equal(b.state.onboardingDone,true);
});
test('account-level pending rating ops validate every profile and derive Swift date identity',()=>{
 const pending={filmID:'a',profileIDs:[profileID],date:800000000};
 const a=run(initial(),[{id:id(70),kind:'pendingRatingSet',payload:{pending}}]);
 assert.equal(a.state.pendingRatings[0].id,'a|800000000');
 const b=run(a.state,[{id:id(71),kind:'pendingRatingRemove',payload:{id:'a|800000000'}}],0,a.revision);
 assert.equal(b.state.pendingRatings.length,0);
 assert.throws(()=>run(initial(),[{id:id(72),kind:'pendingRatingSet',payload:{pending:{...pending,profileIDs:[id(99)]}}}]),/profile_not_found/);
});
test('wire snapshots discard accidentally nested credentials while preserving subscription dates',async()=>{
 const {wireState}=await import('../functions/film-device/domain.mjs');const s=initial();s.account.accessToken='sensitive';s.account.refreshToken='sensitive';s.profiles[0].cloudSession='sensitive';s.account.created=800000000;s.account.consented=800000000;
 const wire=wireState(s);assert.equal(wire.account.accessToken,undefined);assert.equal(wire.account.refreshToken,undefined);assert.equal(wire.profiles[0].cloudSession,undefined);assert.equal(wire.account.created,800000000);
});
test('full profile payloads cannot smuggle malformed learned state or age-blocked titles',()=>{
 assert.throws(()=>run(initial(),[op(80,'profileReplace',undefined,{profile:{...initial().profiles[0],affinity:{'g:Drama':'bad'}}})]),/invalid_profile/);
 assert.throws(()=>run(initial(),[op(81,'profileReplace',undefined,{profile:{...initial().profiles[0],watchlist:['adult']}})]),/age_restricted/);
});
const externalFilm={id:'ext:Q123',title:'External film',year:2020,genres:['Drama'],moods:['ruhig'],director:'Test Director',cast:['Test Actor']};
test('external-only learning uses profileUpdate while granting no media access',()=>{
 const a=run(initial(),[op(90,'profileUpdate',undefined,{external:{[externalFilm.id]:externalFilm},learning:{affinity:{'g:Drama':2},samples:[{filmID:externalFilm.id,delta:2}]}})]);
 assert.deepEqual(a.state.profiles[0].samples,[{filmID:externalFilm.id,target:2}]);assert.equal(a.state.profiles[0].affinity['g:Drama'],2);
 const b=run(a.state,[op(91,'profileUpdate',undefined,{learning:{samples:[{filmID:externalFilm.id,delta:1}]}})],a.revision,a.revision);
 assert.equal(b.state.profiles[0].samples[0].target,3);
 for(const kind of ['watchlistAdd','ratingSet','reviewSet','progressSet'])assert.throws(()=>run(b.state,[op(92,kind,externalFilm.id,{rating:'liked',review:{filmID:externalFilm.id,rating:'liked',text:'',date:1},progress:{season:1,episode:1}})],b.revision,b.revision),/age_restricted/);
});
test('unknown sample IDs and malformed external metadata cannot enter learning',()=>{
 assert.throws(()=>run(initial(),[op(93,'ratingSet','a',{rating:'liked',learning:{samples:[{filmID:'unknown',delta:1}]}})]),/invalid_learning/);
 assert.throws(()=>run(initial(),[op(94,'profileUpdate',undefined,{external:{[externalFilm.id]:{...externalFilm,genres:'wrong'}},learning:{samples:[{filmID:externalFilm.id,delta:1}]}})]),/invalid_external/);
});
test('mixed catalog and known external sample deltas merge and deduplicate',()=>{
 const s=initial();s.profiles[0].external={[externalFilm.id]:externalFilm};s.profiles[0].samples=[{filmID:externalFilm.id,target:2}];
 const operation=op(95,'ratingSet','a',{rating:'liked',learning:{samples:[{filmID:'a',delta:1},{filmID:externalFilm.id,delta:1}]}});
 const a=run(s,[operation]);const b=run(a.state,[operation],0,a.revision,[id(95)]);
 assert.deepEqual(b.state.profiles[0].samples,[{filmID:externalFilm.id,target:3},{filmID:'a',target:1}]);assert.equal(b.revision,a.revision);
});
test('profile order uses exact live membership, CAS and tombstones',()=>{
 const s=initial();s.account.subscription.plan='duo';s.profiles.push({...s.profiles[0],id:id(101),name:'Other'});
 const a=run(s,[{id:id(102),kind:'profileOrder',payload:{profileIDs:[id(101),profileID.toUpperCase()]}}]);assert.deepEqual(a.state.profiles.map(p=>p.id),[id(101),profileID]);
 assert.throws(()=>run(a.state,[{id:id(103),kind:'profileOrder',payload:{profileIDs:[profileID,id(101)]}}],0,a.revision),/revision_conflict/);
 assert.throws(()=>run(s,[{id:id(104),kind:'profileOrder',payload:{profileIDs:[profileID,profileID]}}]),/invalid_profile_order/);
 const b=run(s,[{id:id(105),kind:'profileDelete',profileID:id(101),payload:{}}]);assert.throws(()=>run(b.state,[{id:id(106),kind:'profileOrder',payload:{profileIDs:[profileID,id(101)]}}],b.revision,b.revision),/profile_deleted/);
});
test('unsubscribed households retain the existing eight-profile fallback',()=>{
 const s=initial();s.account.subscription=null;s.profiles.push({...s.profiles[0],id:id(110)});
 const a=run(s,[{id:id(111),kind:'profileCreate',profileID:id(112),payload:{profile:{id:id(112),name:'Third',maxFSK:18,colorIndex:0}}}]);assert.equal(a.state.profiles.length,3);
});
test('client mutation cannot overwrite an existing App Store subscription',()=>{
 const s=initial();s.account.subscription={plan:'solo',source:'appStore'};
 assert.throws(()=>run(s,[{id:id(113),kind:'subscriptionSet',payload:{subscription:{plan:'familie',source:'demo'}}}]),/unverified_subscription/);
});
