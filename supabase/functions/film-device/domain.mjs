const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ratings = {liked:1,disliked:-1,loved:2,unseen:0,notToday:-0.5,watchlist:0.6,alreadySeen:0,played:0.8,ratedDown:-1.2,ratedOkay:0.2,ratedUp:1,ratedLove:2};
export const fail = (code) => { throw new Error(code); };
export function uuid(value) { if(typeof value!=='string'||!UUID.test(value)) fail('invalid_id'); return value.toLowerCase(); }
export function text(value, max=5000) { if(typeof value!=='string'||value.length>max) fail('invalid_payload'); return value; }
export function object(value) { if(!value||typeof value!=='object'||Array.isArray(value)) fail('invalid_payload'); return value; }
export function hashValue(value) { if(typeof value!=='string'||!/^[a-f0-9]{64}$/.test(value)) fail('invalid_hash'); return value; }
const number = (v,max=1e6) => { if(typeof v!=='number'||!Number.isFinite(v)||Math.abs(v)>max) fail('invalid_payload'); return v; };
const pick=(v,keys)=>Object.fromEntries(keys.filter(k=>Object.hasOwn(v,k)).map(k=>[k,v[k]]));
const profileFields=['id','name','colorIndex','maxFSK','littleKid','affinity','interactions','watchlist','reviews','importedCount','exposure','signalTotal','signalN','samples','hints','weights','taste','external','avatar','progress','playbackPositions','onboardingComplete'];
const clean = (value) => JSON.parse(JSON.stringify(value));
export function wireState(input) {
 const s=clean(input||{}); delete s._sync;
 // Allow only shared snapshot fields. Local authentication/navigation never cross the wire.
 const out={profiles:Array.isArray(s.profiles)?s.profiles.map(p=>pick(p,profileFields)):[],pendingRatings:s.pendingRatings||[],onboardingDone:!!s.onboardingDone};
 if(s.account) out.account={...pick(s.account,['email','created','consented','subscription']),passwordHash:'',salt:''};
 return out;
}
function validateProfile(p,id) {
 object(p); if(uuid(p.id)!==uuid(id)) fail('invalid_id'); text(p.name,80);
 if(!p.name.trim()||![0,6,12,16,18].includes(p.maxFSK??18)||!Number.isInteger(p.colorIndex)||p.colorIndex<0||p.colorIndex>100) fail('invalid_profile');
 if(p.littleKid!==undefined&&typeof p.littleKid!=='boolean') fail('invalid_profile');
 if(p.avatar!=null) text(p.avatar,100);
 const finite=(v)=>typeof v==='number'&&Number.isFinite(v)&&Math.abs(v)<=1e6;
 for(const field of ['affinity','exposure','hints','weights','playbackPositions'])if(p[field]!==undefined){object(p[field]);if(Object.entries(p[field]).some(([key,v])=>key.length>200||!finite(v)||['__proto__','constructor','prototype'].includes(key)))fail('invalid_profile');}
 for(const field of ['signalN','importedCount'])if(p[field]!==undefined&&(!Number.isInteger(p[field])||p[field]<0||p[field]>1e6))fail('invalid_profile');
 if(p.signalTotal!==undefined&&!finite(p.signalTotal))fail('invalid_profile');
 if(p.samples!==undefined&&(!Array.isArray(p.samples)||p.samples.some(x=>typeof x.filmID!=='string'||x.filmID.length>150||!finite(x.target))))fail('invalid_profile');
 if(p.watchlist!==undefined&&(!Array.isArray(p.watchlist)||p.watchlist.some(x=>typeof x!=='string'||x.length>150)))fail('invalid_profile');
 if(p.taste!==undefined&&(!Array.isArray(p.taste)||p.taste.some(x=>!finite(x))))fail('invalid_profile');
 if(p.interactions!==undefined){object(p.interactions);if(Object.values(p.interactions).some(x=>!Object.hasOwn(ratings,x)))fail('invalid_profile');}
 if(p.external!==undefined)p.external=externalMetadata(p.external);
 if(p.onboardingComplete!==undefined&&typeof p.onboardingComplete!=='boolean')fail('invalid_profile');
 return p;
}
function externalMetadata(input) {
 object(input);if(Object.keys(input).length>2000)fail('invalid_external');const out={};
 for(const [key,value]of Object.entries(input)) {
  if(!/^ext:Q[1-9][0-9]{0,15}$/.test(key)||!value||typeof value!=='object'||Array.isArray(value)||value.id!==key||typeof value.title!=='string'||!value.title.trim()||value.title.length>500||typeof value.director!=='string'||value.director.length>300)fail('invalid_external');
  if(value.year!=null&&(!Number.isInteger(value.year)||value.year<0||value.year>3000))fail('invalid_external');
  for(const field of ['genres','moods','cast'])if(!Array.isArray(value[field])||value[field].length>100||value[field].some(v=>typeof v!=='string'||v.length>300))fail('invalid_external');
  out[key]=pick(value,['id','title','year','genres','moods','director','cast']);
 }
 return out;
}
function knownSample(p,id,catalog) {
 if(Object.hasOwn(catalog,id))return true;
 if(!Object.hasOwn(p.external||{},id))return false;
 externalMetadata({[id]:p.external[id]});return true;
}
function learning(p,l,catalog) {
 if(!l)return; object(l);
 for(const field of ['affinity','exposure']) { if(!l[field])continue; object(l[field]); if(Object.keys(l[field]).length>1000)fail('invalid_learning'); p[field]??={};
  for(const [key,v] of Object.entries(l[field])) { text(key,200); if(['__proto__','constructor','prototype'].includes(key)) fail('invalid_learning'); p[field][key]=number((p[field][key]||0)+number(v,1000)); }
 }
 if(l.samples!==undefined) { if(!Array.isArray(l.samples)||l.samples.length>1000)fail('invalid_learning');p.samples??=[];for(const sample of l.samples) {text(sample.filmID,150);if(!knownSample(p,sample.filmID,catalog))fail('invalid_learning');const delta=number(sample.delta,100);const old=p.samples.find(x=>x.filmID===sample.filmID);if(old)old.target=number(old.target+delta,1e5);else p.samples.push({filmID:sample.filmID,target:delta});} }
 if(l.signalTotal!==undefined)p.signalTotal=number((p.signalTotal||0)+number(l.signalTotal,100000));
 if(l.signalN!==undefined) { if(!Number.isInteger(l.signalN)||Math.abs(l.signalN)>100000)fail('invalid_learning');p.signalN=Math.max(0,(p.signalN||0)+l.signalN); }
}
export function applyOperations({state,operations,baseRevision,revision,seen=[],catalog={},metadata}) {
 if(!Number.isSafeInteger(baseRevision)||baseRevision<0||baseRevision>revision||!Number.isSafeInteger(revision)) fail('invalid_revision');
 if(!Array.isArray(operations)||operations.length>100) fail('invalid_operations');
 const s=wireState(state), meta=clean(metadata||state?._sync||{tombstones:[],fields:{},imports:[]});
 meta.tombstones??=[]; meta.fields??={};meta.imports??=[];
 const acknowledged=[], known=new Set(seen); let next=revision;
 const nativeLearningProfiles=new Set(operations.filter(op=>Array.isArray(op?.payload?.learning?.samples)&&op.profileID).map(op=>uuid(op.profileID)));
 const get=(id)=>s.profiles.find(p=>p.id.toLowerCase()===id);
 const allowed=(p,filmID)=>{text(filmID,150);const f=catalog[filmID];if(!f||f.fsk>(p.maxFSK??18)||(p.littleKid&&!f.forLittleKids))fail('age_restricted');};
 for(const op of operations) {
  object(op);const id=uuid(op.id); if(known.has(id)){acknowledged.push(id);continue;}
  const pid=op.profileID?uuid(op.profileID):null,payload=object(op.payload||{});const field=[pid,op.kind.startsWith('watchlist')?'watchlist':op.kind,payload.positionKey||op.filmID||payload.key||''].join(':');
  if(payload.expectedOperationID&&meta.fields[field]!==uuid(payload.expectedOperationID))fail('undo_conflict');
  if(['profileUpdate','profileReplace','profileOrder'].includes(op.kind)&&baseRevision!==revision)fail('revision_conflict');
  if(op.kind==='subscriptionSet') {
   if(s.account?.subscription?.source==='appStore')fail('unverified_subscription');const sub=payload.subscription;if(sub!==null){object(sub);if(!['solo','duo','familie'].includes(sub.plan)||sub.source!=='demo')fail('unverified_subscription');}
   if(!s.account)fail('account_not_found');s.account.subscription=clean(sub);
  } else if(op.kind==='profileOrder') {
   if(!Array.isArray(payload.profileIDs))fail('invalid_profile_order');const ids=payload.profileIDs.map(uuid);if(new Set(ids).size!==ids.length)fail('invalid_profile_order');if(ids.some(id=>meta.tombstones.includes(id)))fail('profile_deleted');if(ids.length!==s.profiles.length||ids.some(id=>!get(id)))fail('invalid_profile_order');s.profiles=ids.map(get);
  } else if(op.kind==='pendingRatingSet') {
   const r=clean(object(payload.pending));if(!Array.isArray(r.profileIDs)||!r.profileIDs.length)fail('invalid_pending');number(r.date,1e11);text(r.filmID,150);r.id=r.filmID+'|'+String(r.date);
   for(const x of r.profileIDs){const owner=get(uuid(x));if(!owner)fail('profile_not_found');allowed(owner,r.filmID);}s.pendingRatings=s.pendingRatings.filter(x=>(x.id||x.filmID+'|'+String(x.date))!==r.id);s.pendingRatings.push(r);
  } else if(op.kind==='pendingRatingRemove') {text(payload.id,200);s.pendingRatings=s.pendingRatings.filter(x=>(x.id||x.filmID+'|'+String(x.date))!==payload.id);
  } else if(op.kind==='profileCreate') {
   if(!pid)fail('invalid_id');if(meta.tombstones.includes(pid))fail('profile_deleted');if(get(pid))fail('profile_exists');
   const limit={solo:2,duo:4,familie:8}[s.account?.subscription?.plan]||8;if(s.profiles.length>=limit)fail('profile_limit');
   const created=clean(validateProfile(payload.profile,pid));for(const film of new Set([...(created.watchlist||[]),...Object.keys(created.interactions||{}),...Object.keys(created.progress||{})]))allowed(created,film);if((created.samples||[]).some(sample=>!knownSample(created,sample.filmID,catalog)))fail('invalid_learning');created.weights={};created.taste=[];s.profiles.push(created);
  } else {
   if(!pid)fail('invalid_id');if(meta.tombstones.includes(pid))fail('profile_deleted');const p=get(pid);if(!p)fail('profile_not_found');
   if(op.kind==='profileDelete') {s.profiles=s.profiles.filter(x=>x!==p);meta.tombstones.push(pid);s.pendingRatings=s.pendingRatings.map(r=>({...r,profileIDs:r.profileIDs.filter(i=>i.toLowerCase()!==pid)})).filter(r=>r.profileIDs.length);}
   else if(op.kind==='profileUpdate') {const patch={};for(const key of ['name','colorIndex','maxFSK','littleKid','avatar','onboardingComplete'])if(key in payload)patch[key]=payload[key];validateProfile({...p,...patch},pid);if(patch.onboardingComplete!==undefined&&typeof patch.onboardingComplete!=='boolean')fail('invalid_profile');Object.assign(p,patch);s.onboardingDone=!!s.onboardingDone||s.profiles.some(x=>x.onboardingComplete===true);if(payload.importedCountDelta!==undefined){if(!Number.isInteger(payload.importedCountDelta)||Math.abs(payload.importedCountDelta)>1000)fail('invalid_payload');p.importedCount=Math.max(0,(p.importedCount||0)+payload.importedCountDelta);}if(payload.external){p.external={...(p.external||{}),...externalMetadata(payload.external)};}learning(p,payload.learning,catalog);if(payload.learning){p.weights={};p.taste=[];} }
   else if(op.kind==='profileReplace') {const replacement=clean(validateProfile(payload.profile,pid));for(const film of new Set([...(replacement.watchlist||[]),...Object.keys(replacement.interactions||{}),...Object.keys(replacement.progress||{})]))allowed(replacement,film);if((replacement.samples||[]).some(sample=>!knownSample(replacement,sample.filmID,catalog)))fail('invalid_learning');replacement.weights={};replacement.taste=[];s.profiles[s.profiles.indexOf(p)]=replacement;}
   else if(op.kind==='hintSet') {const key=text(payload.key,200);if(['__proto__','constructor','prototype'].includes(key))fail('invalid_payload');p.hints??={};const delta=number(payload.value,1000);p.hints[key]=number((p.hints[key]||0)+delta);p.affinity??={};p.affinity[key]=number((p.affinity[key]||0)+delta);p.weights={};p.taste=[];}
   else if(op.kind==='importApply') {
    const fingerprint=hashValue(payload.fingerprint);const key=pid+':'+fingerprint;
    if(!meta.imports.includes(key)) {
     if(!Array.isArray(payload.ratings)||payload.ratings.length>1000)fail('invalid_import');
     for(const r of payload.ratings) {allowed(p,r.filmID);if(!Object.hasOwn(ratings,r.rating))fail('invalid_rating');p.interactions??={};p.interactions[r.filmID]=r.rating;p.samples??=[];p.samples=p.samples.filter(x=>x.filmID!==r.filmID);if(ratings[r.rating])p.samples.push({filmID:r.filmID,target:ratings[r.rating]});}
     learning(p,payload.learning,catalog);p.importedCount=(p.importedCount||0)+payload.ratings.length;p.weights={};p.taste=[];meta.imports.push(key);
    }
   } else {
    allowed(p,op.filmID);
    switch(op.kind) {
    case 'ratingSet': if(payload.rating===null){if(p.interactions)delete p.interactions[op.filmID];if(!nativeLearningProfiles.has(pid))p.samples=(p.samples||[]).filter(x=>x.filmID!==op.filmID);learning(p,payload.learning,catalog);p.samples=p.samples.filter(x=>Math.abs(x.target)>1e-9);p.weights={};p.taste=[];break;}if(!Object.hasOwn(ratings,payload.rating))fail('invalid_rating');p.interactions??={};p.interactions[op.filmID]=payload.rating;p.samples??=[];
     if(!nativeLearningProfiles.has(pid)) {const sample={filmID:op.filmID,target:ratings[payload.rating]},i=p.samples.findIndex(x=>x.filmID===op.filmID);if(i<0)p.samples.push(sample);else p.samples[i]=sample;}
     learning(p,payload.learning,catalog);p.weights={};p.taste=[];break;
    case 'reviewSet': {if(payload.review===null){p.reviews=(p.reviews||[]).filter(x=>x.filmID!==op.filmID);break;}const r=object(payload.review);if(r.filmID!==op.filmID||!Object.hasOwn(ratings,r.rating))fail('invalid_rating');text(r.text,5000);number(r.date,1e11);p.reviews=(p.reviews||[]).filter(x=>x.filmID!==op.filmID);p.reviews.push(clean(r));break;}
    case 'watchlistAdd':p.watchlist=[...new Set([...(p.watchlist||[]),op.filmID])];break;
    case 'watchlistRemove':p.watchlist=(p.watchlist||[]).filter(x=>x!==op.filmID);break;
    case 'progressSet': {if(payload.progress===null){if(baseRevision!==revision)fail('revision_conflict');if(p.progress)delete p.progress[op.filmID];break;}if(payload.positionKey!==undefined){const key=text(payload.positionKey,200);if(!key.startsWith(op.filmID+'|')||typeof payload.seconds!=='number'||!Number.isFinite(payload.seconds)||payload.seconds<0||payload.seconds>1e7)fail('invalid_progress');p.playbackPositions??={};p.playbackPositions[key]=payload.seconds;break;}const r=clean(object(payload.progress));for(const k of ['season','episode'])if(!Number.isInteger(r[k])||r[k]<0||r[k]>10000)fail('invalid_progress');if(r.position!==undefined&&number(r.position,1e7)<0)fail('invalid_progress');if(r.completed!==undefined&&typeof r.completed!=='boolean')fail('invalid_progress');
     p.progress??={};const old=p.progress[op.filmID];if(r.restart&&baseRevision!==revision)fail('revision_conflict');if(!r.restart&&old&&old.season===r.season&&old.episode===r.episode){r.position=Math.max(old.position||0,r.position||0);r.completed=!!old.completed||!!r.completed;}delete r.restart;p.progress[op.filmID]=r;break;}
    case 'pendingRatingSet': {const r=clean(object(payload.pending));r.id=op.filmID+'|'+String(r.date);if(r.filmID!==op.filmID||!Array.isArray(r.profileIDs)||!r.profileIDs.length)fail('invalid_pending');for(const x of r.profileIDs){const owner=get(uuid(x));if(!owner)fail('profile_not_found');allowed(owner,op.filmID);}number(r.date,1e11);s.pendingRatings=s.pendingRatings.filter(x=>x.id!==r.id);s.pendingRatings.push(r);break;}
    case 'pendingRatingRemove':s.pendingRatings=s.pendingRatings.filter(x=>(x.id||x.filmID+'|'+String(x.date))!==text(payload.id,200));break;
    default:fail('invalid_operation');
    }
   }
  }
  meta.fields[field]=id;known.add(id);acknowledged.push(id);next++;
 }
 s._sync=meta;return {state:s,metadata:meta,revision:next,acknowledged};
}
export function publicPairing(p,now=Date.now()) {return {id:p.id,code:p.code,deviceName:p.device_name,expiresAt:p.expires_at,status:Date.parse(p.expires_at)<=now?'expired':p.status};}
export function rotateSession(s,{hash,newHash,operationID,now}) {
 if(s.revoked||s.expiresAt<=now)fail('unauthorized');
 if(s.previousHash===hash&&s.operationID===operationID&&s.hash===newHash&&s.retryUntil>=now)return s;
 if(s.hash!==hash)fail('unauthorized');return {...s,hash:newHash,previousHash:hash,operationID,retryUntil:now+60000,expiresAt:now+30*86400000};
}
export function transitionJob(j,action,{version,claimant,now,profileExists,result}) {
 if(j.expiresAt<=now)fail('job_expired');if(!profileExists)fail('profile_not_found');if(j.version!==version)fail('job_conflict');
 if(action==='claim'&&j.status==='pending')return {...j,status:'claimed',claimant,version:version+1};
 if(action==='complete'&&j.status==='claimed'&&j.claimant===claimant)return {...j,status:'completed',result,version:version+1};
 if(action==='cancel'&&['pending','claimed'].includes(j.status))return {...j,status:'cancelled',version:version+1};
 fail('job_conflict');
}

export function bootstrapState(input,email) {const s=wireState(object(input));object(s.account);if(s.account.subscription?.source==='appStore')s.account.subscription=null;if(typeof email!=='string'||s.account.email?.trim().toLowerCase()!==email.trim().toLowerCase())fail('invalid_account');number(s.account.created,1e11);number(s.account.consented,1e11);if(s.profiles.length>8)fail('profile_limit');const seen=new Set();for(const p of s.profiles){validateProfile(p,p.id);const id=uuid(p.id);if(seen.has(id))fail('invalid_profile');seen.add(id);}return s;}
