// supabase/functions/film-device/index.ts
import { createClient } from "npm:@supabase/supabase-js@2.57.4";

// supabase/functions/film-device/domain.mjs
var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
var ratings = { liked: 1, disliked: -1, loved: 2, unseen: 0, notToday: -0.5, watchlist: 0.6, alreadySeen: 0, played: 0.8, ratedDown: -1.2, ratedOkay: 0.2, ratedUp: 1, ratedLove: 2 };
var fail = (code) => {
  throw new Error(code);
};
function uuid(value) {
  if (typeof value !== "string" || !UUID.test(value)) fail("invalid_id");
  return value.toLowerCase();
}
function text(value, max = 5e3) {
  if (typeof value !== "string" || value.length > max) fail("invalid_payload");
  return value;
}
function object(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("invalid_payload");
  return value;
}
function hashValue(value) {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) fail("invalid_hash");
  return value;
}
var number = (v, max = 1e6) => {
  if (typeof v !== "number" || !Number.isFinite(v) || Math.abs(v) > max) fail("invalid_payload");
  return v;
};
var pick = (v, keys) => Object.fromEntries(keys.filter((k) => Object.hasOwn(v, k)).map((k) => [k, v[k]]));
var profileFields = ["id", "name", "colorIndex", "maxFSK", "littleKid", "affinity", "interactions", "watchlist", "reviews", "importedCount", "exposure", "signalTotal", "signalN", "samples", "hints", "weights", "taste", "external", "avatar", "progress", "playbackPositions", "onboardingComplete"];
var clean = (value) => JSON.parse(JSON.stringify(value));
function wireState(input) {
  const s = clean(input || {});
  delete s._sync;
  const out = { profiles: Array.isArray(s.profiles) ? s.profiles.map((p) => pick(p, profileFields)) : [], pendingRatings: s.pendingRatings || [], onboardingDone: !!s.onboardingDone };
  if (s.account) out.account = { ...pick(s.account, ["email", "created", "consented", "subscription"]), passwordHash: "", salt: "" };
  return out;
}
function validateProfile(p, id) {
  object(p);
  if (uuid(p.id) !== uuid(id)) fail("invalid_id");
  text(p.name, 80);
  if (!p.name.trim() || ![0, 6, 12, 16, 18].includes(p.maxFSK ?? 18) || !Number.isInteger(p.colorIndex) || p.colorIndex < 0 || p.colorIndex > 100) fail("invalid_profile");
  if (p.littleKid !== void 0 && typeof p.littleKid !== "boolean") fail("invalid_profile");
  if (p.avatar != null) text(p.avatar, 100);
  const finite = (v) => typeof v === "number" && Number.isFinite(v) && Math.abs(v) <= 1e6;
  for (const field of ["affinity", "exposure", "hints", "weights", "playbackPositions"]) if (p[field] !== void 0) {
    object(p[field]);
    if (Object.entries(p[field]).some(([key2, v]) => key2.length > 200 || !finite(v) || ["__proto__", "constructor", "prototype"].includes(key2))) fail("invalid_profile");
  }
  for (const field of ["signalN", "importedCount"]) if (p[field] !== void 0 && (!Number.isInteger(p[field]) || p[field] < 0 || p[field] > 1e6)) fail("invalid_profile");
  if (p.signalTotal !== void 0 && !finite(p.signalTotal)) fail("invalid_profile");
  if (p.samples !== void 0 && (!Array.isArray(p.samples) || p.samples.some((x) => typeof x.filmID !== "string" || x.filmID.length > 150 || !finite(x.target)))) fail("invalid_profile");
  if (p.watchlist !== void 0 && (!Array.isArray(p.watchlist) || p.watchlist.some((x) => typeof x !== "string" || x.length > 150))) fail("invalid_profile");
  if (p.taste !== void 0 && (!Array.isArray(p.taste) || p.taste.some((x) => !finite(x)))) fail("invalid_profile");
  if (p.interactions !== void 0) {
    object(p.interactions);
    if (Object.values(p.interactions).some((x) => !Object.hasOwn(ratings, x))) fail("invalid_profile");
  }
  if (p.external !== void 0) p.external = externalMetadata(p.external);
  if (p.onboardingComplete !== void 0 && typeof p.onboardingComplete !== "boolean") fail("invalid_profile");
  return p;
}
function externalMetadata(input) {
  object(input);
  if (Object.keys(input).length > 2e3) fail("invalid_external");
  const out = {};
  for (const [key2, value] of Object.entries(input)) {
    if (!/^ext:Q[1-9][0-9]{0,15}$/.test(key2) || !value || typeof value !== "object" || Array.isArray(value) || value.id !== key2 || typeof value.title !== "string" || !value.title.trim() || value.title.length > 500 || typeof value.director !== "string" || value.director.length > 300) fail("invalid_external");
    if (value.year != null && (!Number.isInteger(value.year) || value.year < 0 || value.year > 3e3)) fail("invalid_external");
    for (const field of ["genres", "moods", "cast"]) if (!Array.isArray(value[field]) || value[field].length > 100 || value[field].some((v) => typeof v !== "string" || v.length > 300)) fail("invalid_external");
    out[key2] = pick(value, ["id", "title", "year", "genres", "moods", "director", "cast"]);
  }
  return out;
}
function knownSample(p, id, catalog2) {
  if (Object.hasOwn(catalog2, id)) return true;
  if (!Object.hasOwn(p.external || {}, id)) return false;
  externalMetadata({ [id]: p.external[id] });
  return true;
}
function learning(p, l, catalog2) {
  if (!l) return;
  object(l);
  for (const field of ["affinity", "exposure"]) {
    if (!l[field]) continue;
    object(l[field]);
    if (Object.keys(l[field]).length > 1e3) fail("invalid_learning");
    p[field] ??= {};
    for (const [key2, v] of Object.entries(l[field])) {
      text(key2, 200);
      if (["__proto__", "constructor", "prototype"].includes(key2)) fail("invalid_learning");
      p[field][key2] = number((p[field][key2] || 0) + number(v, 1e3));
    }
  }
  if (l.samples !== void 0) {
    if (!Array.isArray(l.samples) || l.samples.length > 1e3) fail("invalid_learning");
    p.samples ??= [];
    for (const sample of l.samples) {
      text(sample.filmID, 150);
      if (!knownSample(p, sample.filmID, catalog2)) fail("invalid_learning");
      const delta = number(sample.delta, 100);
      const old = p.samples.find((x) => x.filmID === sample.filmID);
      if (old) old.target = number(old.target + delta, 1e5);
      else p.samples.push({ filmID: sample.filmID, target: delta });
    }
  }
  if (l.signalTotal !== void 0) p.signalTotal = number((p.signalTotal || 0) + number(l.signalTotal, 1e5));
  if (l.signalN !== void 0) {
    if (!Number.isInteger(l.signalN) || Math.abs(l.signalN) > 1e5) fail("invalid_learning");
    p.signalN = Math.max(0, (p.signalN || 0) + l.signalN);
  }
}
function applyOperations({ state, operations, baseRevision, revision, seen = [], catalog: catalog2 = {}, metadata }) {
  if (!Number.isSafeInteger(baseRevision) || baseRevision < 0 || baseRevision > revision || !Number.isSafeInteger(revision)) fail("invalid_revision");
  if (!Array.isArray(operations) || operations.length > 100) fail("invalid_operations");
  const s = wireState(state), meta = clean(metadata || state?._sync || { tombstones: [], fields: {}, imports: [] });
  meta.tombstones ??= [];
  meta.fields ??= {};
  meta.imports ??= [];
  const acknowledged = [], known = new Set(seen);
  let next = revision;
  const nativeLearningProfiles = new Set(operations.filter((op) => Array.isArray(op?.payload?.learning?.samples) && op.profileID).map((op) => uuid(op.profileID)));
  const get = (id) => s.profiles.find((p) => p.id.toLowerCase() === id);
  const allowed = (p, filmID) => {
    text(filmID, 150);
    const f = catalog2[filmID];
    if (!f || f.fsk > (p.maxFSK ?? 18) || p.littleKid && !f.forLittleKids) fail("age_restricted");
  };
  for (const op of operations) {
    object(op);
    const id = uuid(op.id);
    if (known.has(id)) {
      acknowledged.push(id);
      continue;
    }
    const pid = op.profileID ? uuid(op.profileID) : null, payload = object(op.payload || {});
    const field = [pid, op.kind.startsWith("watchlist") ? "watchlist" : op.kind, payload.positionKey || op.filmID || payload.key || ""].join(":");
    if (payload.expectedOperationID && meta.fields[field] !== uuid(payload.expectedOperationID)) fail("undo_conflict");
    if (["profileUpdate", "profileReplace", "profileOrder"].includes(op.kind) && baseRevision !== revision) fail("revision_conflict");
    if (op.kind === "subscriptionSet") {
      if (s.account?.subscription?.source === "appStore") fail("unverified_subscription");
      const sub = payload.subscription;
      if (sub !== null) {
        object(sub);
        if (!["solo", "duo", "familie"].includes(sub.plan) || sub.source !== "demo") fail("unverified_subscription");
      }
      if (!s.account) fail("account_not_found");
      s.account.subscription = clean(sub);
    } else if (op.kind === "profileOrder") {
      if (!Array.isArray(payload.profileIDs)) fail("invalid_profile_order");
      const ids = payload.profileIDs.map(uuid);
      if (new Set(ids).size !== ids.length) fail("invalid_profile_order");
      if (ids.some((id2) => meta.tombstones.includes(id2))) fail("profile_deleted");
      if (ids.length !== s.profiles.length || ids.some((id2) => !get(id2))) fail("invalid_profile_order");
      s.profiles = ids.map(get);
    } else if (op.kind === "pendingRatingSet") {
      const r = clean(object(payload.pending));
      if (!Array.isArray(r.profileIDs) || !r.profileIDs.length) fail("invalid_pending");
      number(r.date, 1e11);
      text(r.filmID, 150);
      r.id = r.filmID + "|" + String(r.date);
      for (const x of r.profileIDs) {
        const owner = get(uuid(x));
        if (!owner) fail("profile_not_found");
        allowed(owner, r.filmID);
      }
      s.pendingRatings = s.pendingRatings.filter((x) => (x.id || x.filmID + "|" + String(x.date)) !== r.id);
      s.pendingRatings.push(r);
    } else if (op.kind === "pendingRatingRemove") {
      text(payload.id, 200);
      s.pendingRatings = s.pendingRatings.filter((x) => (x.id || x.filmID + "|" + String(x.date)) !== payload.id);
    } else if (op.kind === "profileCreate") {
      if (!pid) fail("invalid_id");
      if (meta.tombstones.includes(pid)) fail("profile_deleted");
      if (get(pid)) fail("profile_exists");
      const limit = { solo: 2, duo: 4, familie: 8 }[s.account?.subscription?.plan] || 8;
      if (s.profiles.length >= limit) fail("profile_limit");
      const created = clean(validateProfile(payload.profile, pid));
      for (const film of /* @__PURE__ */ new Set([...created.watchlist || [], ...Object.keys(created.interactions || {}), ...Object.keys(created.progress || {})])) allowed(created, film);
      if ((created.samples || []).some((sample) => !knownSample(created, sample.filmID, catalog2))) fail("invalid_learning");
      created.weights = {};
      created.taste = [];
      s.profiles.push(created);
    } else {
      if (!pid) fail("invalid_id");
      if (meta.tombstones.includes(pid)) fail("profile_deleted");
      const p = get(pid);
      if (!p) fail("profile_not_found");
      if (op.kind === "profileDelete") {
        s.profiles = s.profiles.filter((x) => x !== p);
        meta.tombstones.push(pid);
        s.pendingRatings = s.pendingRatings.map((r) => ({ ...r, profileIDs: r.profileIDs.filter((i) => i.toLowerCase() !== pid) })).filter((r) => r.profileIDs.length);
      } else if (op.kind === "profileUpdate") {
        const patch = {};
        for (const key2 of ["name", "colorIndex", "maxFSK", "littleKid", "avatar", "onboardingComplete"]) if (key2 in payload) patch[key2] = payload[key2];
        validateProfile({ ...p, ...patch }, pid);
        if (patch.onboardingComplete !== void 0 && typeof patch.onboardingComplete !== "boolean") fail("invalid_profile");
        Object.assign(p, patch);
        s.onboardingDone = !!s.onboardingDone || s.profiles.some((x) => x.onboardingComplete === true);
        if (payload.importedCountDelta !== void 0) {
          if (!Number.isInteger(payload.importedCountDelta) || Math.abs(payload.importedCountDelta) > 1e3) fail("invalid_payload");
          p.importedCount = Math.max(0, (p.importedCount || 0) + payload.importedCountDelta);
        }
        if (payload.external) {
          p.external = { ...p.external || {}, ...externalMetadata(payload.external) };
        }
        learning(p, payload.learning, catalog2);
        if (payload.learning) {
          p.weights = {};
          p.taste = [];
        }
      } else if (op.kind === "profileReplace") {
        const replacement = clean(validateProfile(payload.profile, pid));
        for (const film of /* @__PURE__ */ new Set([...replacement.watchlist || [], ...Object.keys(replacement.interactions || {}), ...Object.keys(replacement.progress || {})])) allowed(replacement, film);
        if ((replacement.samples || []).some((sample) => !knownSample(replacement, sample.filmID, catalog2))) fail("invalid_learning");
        replacement.weights = {};
        replacement.taste = [];
        s.profiles[s.profiles.indexOf(p)] = replacement;
      } else if (op.kind === "hintSet") {
        const key2 = text(payload.key, 200);
        if (["__proto__", "constructor", "prototype"].includes(key2)) fail("invalid_payload");
        p.hints ??= {};
        const delta = number(payload.value, 1e3);
        p.hints[key2] = number((p.hints[key2] || 0) + delta);
        p.affinity ??= {};
        p.affinity[key2] = number((p.affinity[key2] || 0) + delta);
        p.weights = {};
        p.taste = [];
      } else if (op.kind === "importApply") {
        const fingerprint = hashValue(payload.fingerprint);
        const key2 = pid + ":" + fingerprint;
        if (!meta.imports.includes(key2)) {
          if (!Array.isArray(payload.ratings) || payload.ratings.length > 1e3) fail("invalid_import");
          for (const r of payload.ratings) {
            allowed(p, r.filmID);
            if (!Object.hasOwn(ratings, r.rating)) fail("invalid_rating");
            p.interactions ??= {};
            p.interactions[r.filmID] = r.rating;
            p.samples ??= [];
            p.samples = p.samples.filter((x) => x.filmID !== r.filmID);
            if (ratings[r.rating]) p.samples.push({ filmID: r.filmID, target: ratings[r.rating] });
          }
          learning(p, payload.learning, catalog2);
          p.importedCount = (p.importedCount || 0) + payload.ratings.length;
          p.weights = {};
          p.taste = [];
          meta.imports.push(key2);
        }
      } else {
        allowed(p, op.filmID);
        switch (op.kind) {
          case "ratingSet":
            if (payload.rating === null) {
              if (p.interactions) delete p.interactions[op.filmID];
              if (!nativeLearningProfiles.has(pid)) p.samples = (p.samples || []).filter((x) => x.filmID !== op.filmID);
              learning(p, payload.learning, catalog2);
              p.samples = p.samples.filter((x) => Math.abs(x.target) > 1e-9);
              p.weights = {};
              p.taste = [];
              break;
            }
            if (!Object.hasOwn(ratings, payload.rating)) fail("invalid_rating");
            p.interactions ??= {};
            p.interactions[op.filmID] = payload.rating;
            p.samples ??= [];
            if (!nativeLearningProfiles.has(pid)) {
              const sample = { filmID: op.filmID, target: ratings[payload.rating] }, i = p.samples.findIndex((x) => x.filmID === op.filmID);
              if (i < 0) p.samples.push(sample);
              else p.samples[i] = sample;
            }
            learning(p, payload.learning, catalog2);
            p.weights = {};
            p.taste = [];
            break;
          case "reviewSet": {
            if (payload.review === null) {
              p.reviews = (p.reviews || []).filter((x) => x.filmID !== op.filmID);
              break;
            }
            const r = object(payload.review);
            if (r.filmID !== op.filmID || !Object.hasOwn(ratings, r.rating)) fail("invalid_rating");
            text(r.text, 5e3);
            number(r.date, 1e11);
            p.reviews = (p.reviews || []).filter((x) => x.filmID !== op.filmID);
            p.reviews.push(clean(r));
            break;
          }
          case "watchlistAdd":
            p.watchlist = [.../* @__PURE__ */ new Set([...p.watchlist || [], op.filmID])];
            break;
          case "watchlistRemove":
            p.watchlist = (p.watchlist || []).filter((x) => x !== op.filmID);
            break;
          case "progressSet": {
            if (payload.progress === null) {
              if (baseRevision !== revision) fail("revision_conflict");
              if (p.progress) delete p.progress[op.filmID];
              break;
            }
            if (payload.positionKey !== void 0) {
              const key2 = text(payload.positionKey, 200);
              if (!key2.startsWith(op.filmID + "|") || typeof payload.seconds !== "number" || !Number.isFinite(payload.seconds) || payload.seconds < 0 || payload.seconds > 1e7) fail("invalid_progress");
              p.playbackPositions ??= {};
              p.playbackPositions[key2] = payload.seconds;
              break;
            }
            const r = clean(object(payload.progress));
            for (const k of ["season", "episode"]) if (!Number.isInteger(r[k]) || r[k] < 0 || r[k] > 1e4) fail("invalid_progress");
            if (r.position !== void 0 && number(r.position, 1e7) < 0) fail("invalid_progress");
            if (r.completed !== void 0 && typeof r.completed !== "boolean") fail("invalid_progress");
            p.progress ??= {};
            const old = p.progress[op.filmID];
            if (r.restart && baseRevision !== revision) fail("revision_conflict");
            if (!r.restart && old && old.season === r.season && old.episode === r.episode) {
              r.position = Math.max(old.position || 0, r.position || 0);
              r.completed = !!old.completed || !!r.completed;
            }
            delete r.restart;
            p.progress[op.filmID] = r;
            break;
          }
          case "pendingRatingSet": {
            const r = clean(object(payload.pending));
            r.id = op.filmID + "|" + String(r.date);
            if (r.filmID !== op.filmID || !Array.isArray(r.profileIDs) || !r.profileIDs.length) fail("invalid_pending");
            for (const x of r.profileIDs) {
              const owner = get(uuid(x));
              if (!owner) fail("profile_not_found");
              allowed(owner, op.filmID);
            }
            number(r.date, 1e11);
            s.pendingRatings = s.pendingRatings.filter((x) => x.id !== r.id);
            s.pendingRatings.push(r);
            break;
          }
          case "pendingRatingRemove":
            s.pendingRatings = s.pendingRatings.filter((x) => (x.id || x.filmID + "|" + String(x.date)) !== text(payload.id, 200));
            break;
          default:
            fail("invalid_operation");
        }
      }
    }
    meta.fields[field] = id;
    known.add(id);
    acknowledged.push(id);
    next++;
  }
  s._sync = meta;
  return { state: s, metadata: meta, revision: next, acknowledged };
}
function bootstrapState(input, email) {
  const s = wireState(object(input));
  object(s.account);
  if (s.account.subscription?.source === "appStore") s.account.subscription = null;
  if (typeof email !== "string" || s.account.email?.trim().toLowerCase() !== email.trim().toLowerCase()) fail("invalid_account");
  number(s.account.created, 1e11);
  number(s.account.consented, 1e11);
  if (s.profiles.length > 8) fail("profile_limit");
  const seen = /* @__PURE__ */ new Set();
  for (const p of s.profiles) {
    validateProfile(p, p.id);
    const id = uuid(p.id);
    if (seen.has(id)) fail("invalid_profile");
    seen.add(id);
  }
  return s;
}

// supabase/functions/film-device/verifier-proxy.mjs
var encoder = new TextEncoder();
async function transportMAC(secret, direction, timestamp, nonce, body) {
  const key2 = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return Array.from(new Uint8Array(await crypto.subtle.sign("HMAC", key2, encoder.encode(["film-apple-v1", direction, timestamp, nonce, body].join("\n")))), (b) => b.toString(16).padStart(2, "0")).join("");
}
async function validMAC(secret, direction, timestamp, nonce, body, signature) {
  if (!/^[a-f0-9]{64}$/.test(signature || "")) return false;
  const key2 = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const bytes = Uint8Array.from(signature.match(/../g), (v) => parseInt(v, 16));
  return crypto.subtle.verify("HMAC", key2, bytes, encoder.encode(["film-apple-v1", direction, timestamp, nonce, body].join("\n")));
}
async function limitedText(stream, max) {
  const reader = stream?.getReader();
  if (!reader) return "";
  let bytes = 0, text2 = "";
  const decoder = new TextDecoder();
  while (true) {
    const part = await reader.read();
    if (part.done) break;
    bytes += part.value.byteLength;
    if (bytes > max) {
      await reader.cancel();
      fail("subscription_invalid");
    }
    text2 += decoder.decode(part.value, { stream: true });
  }
  return text2 + decoder.decode();
}
function createVerifierProxy({ getenv, fetcher = fetch, now = Date.now }) {
  return async (signedTransaction, userID) => {
    const endpoint = getenv("APPLE_VERIFIER_URL"), secret = getenv("APPLE_VERIFIER_SHARED_SECRET");
    let url2;
    try {
      url2 = new URL(endpoint);
    } catch {
      fail("subscription_unavailable");
    }
    if (url2.protocol !== "https:" || url2.pathname !== "/verify-subscription" || url2.username || url2.password || url2.search || url2.hash || !secret || secret.length < 32) fail("subscription_unavailable");
    const timestamp = String(Math.floor(now() / 1e3)), nonce = crypto.randomUUID(), body = JSON.stringify({ signedTransaction, userID });
    let response2;
    try {
      response2 = await fetcher(url2.href, { method: "POST", redirect: "error", signal: AbortSignal.timeout(45e3), headers: { "content-type": "application/json", "x-film-timestamp": timestamp, "x-film-nonce": nonce, "x-film-signature": await transportMAC(secret, "request", timestamp, nonce, body) }, body });
    } catch {
      fail("subscription_unavailable");
    }
    let raw;
    try {
      raw = await limitedText(response2.body, 32768);
    } catch {
      fail("subscription_unavailable");
    }
    if (!await validMAC(secret, "response", timestamp, nonce, raw, response2.headers.get("x-film-signature"))) fail("subscription_unavailable");
    let result;
    try {
      result = JSON.parse(raw);
    } catch {
      fail("subscription_unavailable");
    }
    if (!response2.ok) {
      if (/^subscription_[a-z_]+$/.test(result.error)) fail(result.error);
      fail("subscription_unavailable");
    }
    if (!result.receipt || typeof result.receipt !== "object") fail("subscription_unavailable");
    return result.receipt;
  };
}

// supabase/functions/film-device/catalog.mjs
var catalog = { "dune": { "fsk": 12, "forLittleKids": false }, "dune-part-two": { "fsk": 12, "forLittleKids": false }, "dune-part-three": { "fsk": 12, "forLittleKids": false }, "avengers-doomsday": { "fsk": 12, "forLittleKids": false }, "oppenheimer": { "fsk": 12, "forLittleKids": false }, "barbie": { "fsk": 6, "forLittleKids": false }, "everything-everywhere-all-at-once": { "fsk": 16, "forLittleKids": false }, "top-gun-maverick": { "fsk": 12, "forLittleKids": false }, "spider-man-across-the-spider-verse": { "fsk": 12, "forLittleKids": false }, "knives-out": { "fsk": 12, "forLittleKids": false }, "interstellar": { "fsk": 12, "forLittleKids": false }, "inception": { "fsk": 12, "forLittleKids": false }, "the-batman": { "fsk": 12, "forLittleKids": false }, "joker": { "fsk": 16, "forLittleKids": false }, "parasite": { "fsk": 16, "forLittleKids": false }, "la-la-land": { "fsk": 0, "forLittleKids": false }, "mad-max-fury-road": { "fsk": 16, "forLittleKids": false }, "get-out": { "fsk": 16, "forLittleKids": false }, "hereditary": { "fsk": 16, "forLittleKids": false }, "a-quiet-place": { "fsk": 16, "forLittleKids": false }, "the-grand-budapest-hotel": { "fsk": 12, "forLittleKids": false }, "inside-out-2": { "fsk": 0, "forLittleKids": true }, "paddington-2": { "fsk": 0, "forLittleKids": true }, "past-lives": { "fsk": 6, "forLittleKids": false }, "poor-things": { "fsk": 16, "forLittleKids": false }, "conclave": { "fsk": 12, "forLittleKids": false }, "anora": { "fsk": 16, "forLittleKids": false }, "wicked": { "fsk": 6, "forLittleKids": false }, "sinners": { "fsk": 16, "forLittleKids": false }, "weapons": { "fsk": 16, "forLittleKids": false }, "f1": { "fsk": 12, "forLittleKids": false }, "superman": { "fsk": 12, "forLittleKids": false }, "the-substance": { "fsk": 18, "forLittleKids": false }, "john-wick": { "fsk": 18, "forLittleKids": false }, "arrival": { "fsk": 12, "forLittleKids": false }, "the-martian": { "fsk": 12, "forLittleKids": false }, "whiplash": { "fsk": 12, "forLittleKids": false }, "the-wild-robot": { "fsk": 6, "forLittleKids": false }, "bullet-train": { "fsk": 16, "forLittleKids": false }, "project-hail-mary": { "fsk": 12, "forLittleKids": false }, "coco": { "fsk": 0, "forLittleKids": true }, "shrek": { "fsk": 6, "forLittleKids": false }, "moon": { "fsk": 12, "forLittleKids": false }, "the-lighthouse": { "fsk": 16, "forLittleKids": false }, "aftersun": { "fsk": 12, "forLittleKids": false }, "portrait-of-a-lady-on-fire": { "fsk": 12, "forLittleKids": false }, "drive": { "fsk": 18, "forLittleKids": false }, "prisoners": { "fsk": 16, "forLittleKids": false }, "nightcrawler": { "fsk": 16, "forLittleKids": false }, "the-handmaiden": { "fsk": 16, "forLittleKids": false }, "burning": { "fsk": 12, "forLittleKids": false }, "perfect-days": { "fsk": 0, "forLittleKids": false }, "anatomy-of-a-fall": { "fsk": 12, "forLittleKids": false }, "decision-to-leave": { "fsk": 12, "forLittleKids": false }, "oldboy": { "fsk": 18, "forLittleKids": false }, "memories-of-murder": { "fsk": 16, "forLittleKids": false }, "paterson": { "fsk": 0, "forLittleKids": false }, "the-green-knight": { "fsk": 16, "forLittleKids": false }, "midsommar": { "fsk": 16, "forLittleKids": false }, "in-bruges": { "fsk": 16, "forLittleKids": false }, "the-nice-guys": { "fsk": 16, "forLittleKids": false }, "hunt-for-the-wilderpeople": { "fsk": 12, "forLittleKids": false }, "uncut-gems": { "fsk": 16, "forLittleKids": false }, "moonlight": { "fsk": 12, "forLittleKids": false }, "the-banshees-of-inisherin": { "fsk": 12, "forLittleKids": false }, "toni-erdmann": { "fsk": 12, "forLittleKids": false }, "victoria": { "fsk": 12, "forLittleKids": false }, "fallen-leaves": { "fsk": 12, "forLittleKids": false }, "drive-my-car": { "fsk": 12, "forLittleKids": false }, "shoplifters": { "fsk": 12, "forLittleKids": false }, "your-name": { "fsk": 6, "forLittleKids": false }, "mandy": { "fsk": 18, "forLittleKids": false }, "her": { "fsk": 12, "forLittleKids": false }, "eternal-sunshine-of-the-spotless-mind": { "fsk": 12, "forLittleKids": false }, "the-lobster": { "fsk": 16, "forLittleKids": false }, "enemy": { "fsk": 16, "forLittleKids": false }, "avatar-the-way-of-water": { "fsk": 12, "forLittleKids": false }, "guardians-of-the-galaxy-vol-3": { "fsk": 12, "forLittleKids": false }, "john-wick-chapter-4": { "fsk": 18, "forLittleKids": false }, "mission-impossible-dead-reckoning-part-one": { "fsk": 12, "forLittleKids": false }, "the-super-mario-bros-movie": { "fsk": 0, "forLittleKids": true }, "killers-of-the-flower-moon": { "fsk": 12, "forLittleKids": false }, "wonka": { "fsk": 6, "forLittleKids": false }, "godzilla-minus-one": { "fsk": 12, "forLittleKids": false }, "deadpool-wolverine": { "fsk": 16, "forLittleKids": false }, "furiosa-a-mad-max-saga": { "fsk": 16, "forLittleKids": false }, "twisters": { "fsk": 12, "forLittleKids": false }, "civil-war": { "fsk": 16, "forLittleKids": false }, "alien-romulus": { "fsk": 16, "forLittleKids": false }, "the-fall-guy": { "fsk": 12, "forLittleKids": false }, "gladiator-ii": { "fsk": 16, "forLittleKids": false }, "moana-2": { "fsk": 6, "forLittleKids": false }, "nosferatu": { "fsk": 16, "forLittleKids": false }, "a-complete-unknown": { "fsk": 6, "forLittleKids": false }, "mickey-17": { "fsk": 16, "forLittleKids": false }, "thunderbolts": { "fsk": 12, "forLittleKids": false }, "mission-impossible-the-final-reckoning": { "fsk": 12, "forLittleKids": false }, "jurassic-world-rebirth": { "fsk": 12, "forLittleKids": false }, "the-fantastic-four-first-steps": { "fsk": 12, "forLittleKids": false }, "zootopia-2": { "fsk": 6, "forLittleKids": false }, "avatar-fire-and-ash": { "fsk": 12, "forLittleKids": false }, "one-battle-after-another": { "fsk": 16, "forLittleKids": false }, "how-to-train-your-dragon": { "fsk": 12, "forLittleKids": false }, "wicked-for-good": { "fsk": 6, "forLittleKids": false }, "the-super-mario-galaxy-movie": { "fsk": 0, "forLittleKids": true }, "michael": { "fsk": 12, "forLittleKids": false }, "the-devil-wears-prada-2": { "fsk": 6, "forLittleKids": false }, "toy-story-5": { "fsk": 0, "forLittleKids": true }, "the-odyssey": { "fsk": 12, "forLittleKids": false }, "spider-man-brand-new-day": { "fsk": 12, "forLittleKids": false }, "madame-web": { "fsk": 12, "forLittleKids": false }, "morbius": { "fsk": 12, "forLittleKids": false }, "borderlands": { "fsk": 12, "forLittleKids": false }, "kraven-the-hunter": { "fsk": 16, "forLittleKids": false }, "argylle": { "fsk": 12, "forLittleKids": false }, "joker-folie-deux": { "fsk": 16, "forLittleKids": false }, "megalopolis": { "fsk": 12, "forLittleKids": false }, "black-adam": { "fsk": 12, "forLittleKids": false }, "the-crow": { "fsk": 18, "forLittleKids": false }, "red-one": { "fsk": 12, "forLittleKids": false }, "snow-white": { "fsk": 6, "forLittleKids": false }, "aquaman-and-the-lost-kingdom": { "fsk": 12, "forLittleKids": false }, "uncharted": { "fsk": 12, "forLittleKids": false }, "the-holdovers": { "fsk": 12, "forLittleKids": false }, "the-shawshank-redemption": { "fsk": 12, "forLittleKids": false }, "the-godfather": { "fsk": 16, "forLittleKids": false }, "pulp-fiction": { "fsk": 16, "forLittleKids": false }, "the-dark-knight": { "fsk": 16, "forLittleKids": false }, "fight-club": { "fsk": 18, "forLittleKids": false }, "forrest-gump": { "fsk": 12, "forLittleKids": false }, "the-matrix": { "fsk": 16, "forLittleKids": false }, "goodfellas": { "fsk": 16, "forLittleKids": false }, "the-silence-of-the-lambs": { "fsk": 16, "forLittleKids": false }, "gladiator": { "fsk": 16, "forLittleKids": false }, "the-lord-of-the-rings-the-fellowship-of-the-ring": { "fsk": 12, "forLittleKids": false }, "the-lord-of-the-rings-the-return-of-the-king": { "fsk": 12, "forLittleKids": false }, "back-to-the-future": { "fsk": 12, "forLittleKids": false }, "jurassic-park": { "fsk": 12, "forLittleKids": false }, "titanic": { "fsk": 12, "forLittleKids": false }, "alien": { "fsk": 16, "forLittleKids": false }, "blade-runner-2049": { "fsk": 16, "forLittleKids": false }, "the-prestige": { "fsk": 12, "forLittleKids": false }, "django-unchained": { "fsk": 16, "forLittleKids": false }, "inglourious-basterds": { "fsk": 16, "forLittleKids": false }, "the-departed": { "fsk": 16, "forLittleKids": false }, "no-country-for-old-men": { "fsk": 16, "forLittleKids": false }, "the-social-network": { "fsk": 12, "forLittleKids": false }, "gone-girl": { "fsk": 16, "forLittleKids": false }, "shutter-island": { "fsk": 16, "forLittleKids": false }, "the-wolf-of-wall-street": { "fsk": 16, "forLittleKids": false }, "catch-me-if-you-can": { "fsk": 6, "forLittleKids": false }, "saving-private-ryan": { "fsk": 16, "forLittleKids": false }, "amelie": { "fsk": 0, "forLittleKids": false }, "princess-mononoke": { "fsk": 12, "forLittleKids": false }, "up": { "fsk": 0, "forLittleKids": true }, "walle": { "fsk": 0, "forLittleKids": true }, "ratatouille": { "fsk": 0, "forLittleKids": true }, "finding-nemo": { "fsk": 0, "forLittleKids": true }, "the-incredibles": { "fsk": 6, "forLittleKids": false }, "frozen": { "fsk": 0, "forLittleKids": true }, "encanto": { "fsk": 0, "forLittleKids": true }, "soul": { "fsk": 0, "forLittleKids": true }, "spider-man-into-the-spider-verse": { "fsk": 6, "forLittleKids": false }, "the-truman-show": { "fsk": 6, "forLittleKids": false }, "groundhog-day": { "fsk": 6, "forLittleKids": false }, "the-big-lebowski": { "fsk": 16, "forLittleKids": false }, "fargo": { "fsk": 16, "forLittleKids": false }, "little-miss-sunshine": { "fsk": 12, "forLittleKids": false }, "superbad": { "fsk": 12, "forLittleKids": false }, "the-hangover": { "fsk": 12, "forLittleKids": false }, "bridesmaids": { "fsk": 12, "forLittleKids": false }, "crazy-rich-asians": { "fsk": 0, "forLittleKids": false }, "notting-hill": { "fsk": 0, "forLittleKids": false }, "love-actually": { "fsk": 6, "forLittleKids": false }, "pride-prejudice": { "fsk": 0, "forLittleKids": false }, "about-time": { "fsk": 0, "forLittleKids": false }, "the-notebook": { "fsk": 6, "forLittleKids": false }, "before-sunrise": { "fsk": 6, "forLittleKids": false }, "lost-in-translation": { "fsk": 6, "forLittleKids": false }, "black-swan": { "fsk": 16, "forLittleKids": false }, "gravity": { "fsk": 12, "forLittleKids": false }, "edge-of-tomorrow": { "fsk": 12, "forLittleKids": false }, "district-9": { "fsk": 16, "forLittleKids": false }, "terminator-2-judgment-day": { "fsk": 16, "forLittleKids": false }, "die-hard": { "fsk": 16, "forLittleKids": false }, "kill-bill-vol-1": { "fsk": 18, "forLittleKids": false }, "baby-driver": { "fsk": 16, "forLittleKids": false }, "casino-royale": { "fsk": 12, "forLittleKids": false }, "skyfall": { "fsk": 12, "forLittleKids": false }, "avengers-infinity-war": { "fsk": 12, "forLittleKids": false }, "avengers-endgame": { "fsk": 12, "forLittleKids": false }, "black-panther": { "fsk": 12, "forLittleKids": false }, "iron-man": { "fsk": 12, "forLittleKids": false }, "logan": { "fsk": 16, "forLittleKids": false }, "thor-ragnarok": { "fsk": 12, "forLittleKids": false }, "pirates-of-the-caribbean-the-curse-of-the-black-pearl": { "fsk": 12, "forLittleKids": false }, "harry-potter-and-the-sorcerer-s-stone": { "fsk": 6, "forLittleKids": false }, "harry-potter-and-the-deathly-hallows-part-2": { "fsk": 12, "forLittleKids": false }, "star-wars": { "fsk": 12, "forLittleKids": false }, "the-empire-strikes-back": { "fsk": 12, "forLittleKids": false }, "rogue-one-a-star-wars-story": { "fsk": 12, "forLittleKids": false }, "raiders-of-the-lost-ark": { "fsk": 12, "forLittleKids": false }, "the-shining": { "fsk": 16, "forLittleKids": false }, "it": { "fsk": 16, "forLittleKids": false }, "the-conjuring": { "fsk": 16, "forLittleKids": false }, "us": { "fsk": 16, "forLittleKids": false }, "scream": { "fsk": 18, "forLittleKids": false }, "the-sixth-sense": { "fsk": 16, "forLittleKids": false }, "barbarian": { "fsk": 18, "forLittleKids": false }, "nope": { "fsk": 16, "forLittleKids": false }, "longlegs": { "fsk": 16, "forLittleKids": false }, "saltburn": { "fsk": 16, "forLittleKids": false }, "promising-young-woman": { "fsk": 16, "forLittleKids": false }, "triangle-of-sadness": { "fsk": 12, "forLittleKids": false }, "the-menu": { "fsk": 16, "forLittleKids": false }, "glass-onion": { "fsk": 12, "forLittleKids": false }, "the-fabelmans": { "fsk": 12, "forLittleKids": false }, "elvis": { "fsk": 6, "forLittleKids": false }, "bohemian-rhapsody": { "fsk": 6, "forLittleKids": false }, "a-star-is-born": { "fsk": 12, "forLittleKids": false }, "mamma-mia": { "fsk": 0, "forLittleKids": false }, "the-greatest-showman": { "fsk": 6, "forLittleKids": false }, "ford-v-ferrari": { "fsk": 12, "forLittleKids": false }, "rush": { "fsk": 12, "forLittleKids": false }, "moneyball": { "fsk": 0, "forLittleKids": false }, "creed": { "fsk": 12, "forLittleKids": false }, "rocky": { "fsk": 12, "forLittleKids": false }, "the-intouchables": { "fsk": 6, "forLittleKids": false }, "good-bye-lenin": { "fsk": 6, "forLittleKids": false }, "the-lives-of-others": { "fsk": 12, "forLittleKids": false }, "all-quiet-on-the-western-front": { "fsk": 16, "forLittleKids": false }, "das-boot": { "fsk": 12, "forLittleKids": false }, "manitou-s-shoe": { "fsk": 6, "forLittleKids": false }, "soul-kitchen": { "fsk": 12, "forLittleKids": false }, "pan-s-labyrinth": { "fsk": 16, "forLittleKids": false }, "the-shape-of-water": { "fsk": 16, "forLittleKids": false }, "roma": { "fsk": 12, "forLittleKids": false }, "life-is-beautiful": { "fsk": 12, "forLittleKids": false }, "train-to-busan": { "fsk": 16, "forLittleKids": false }, "snowpiercer": { "fsk": 16, "forLittleKids": false }, "okja": { "fsk": 12, "forLittleKids": false }, "akira": { "fsk": 16, "forLittleKids": false }, "howl-s-moving-castle": { "fsk": 6, "forLittleKids": false }, "the-boy-and-the-heron": { "fsk": 12, "forLittleKids": false }, "weathering-with-you": { "fsk": 6, "forLittleKids": false }, "suzume": { "fsk": 12, "forLittleKids": false }, "a-silent-voice": { "fsk": 12, "forLittleKids": false }, "the-worst-person-in-the-world": { "fsk": 12, "forLittleKids": false }, "another-round": { "fsk": 12, "forLittleKids": false }, "the-hunt": { "fsk": 12, "forLittleKids": false }, "fantastic-mr-fox": { "fsk": 6, "forLittleKids": false }, "moonrise-kingdom": { "fsk": 6, "forLittleKids": false }, "asteroid-city": { "fsk": 6, "forLittleKids": false }, "annihilation": { "fsk": 16, "forLittleKids": false }, "under-the-skin": { "fsk": 16, "forLittleKids": false }, "the-florida-project": { "fsk": 12, "forLittleKids": false }, "lady-bird": { "fsk": 6, "forLittleKids": false }, "minari": { "fsk": 6, "forLittleKids": false }, "the-farewell": { "fsk": 6, "forLittleKids": false }, "petite-maman": { "fsk": 0, "forLittleKids": false }, "close": { "fsk": 12, "forLittleKids": false }, "the-killing-of-a-sacred-deer": { "fsk": 16, "forLittleKids": false }, "sorry-to-bother-you": { "fsk": 16, "forLittleKids": false }, "swiss-army-man": { "fsk": 12, "forLittleKids": false }, "a-ghost-story": { "fsk": 12, "forLittleKids": false }, "good-time": { "fsk": 16, "forLittleKids": false }, "first-reformed": { "fsk": 12, "forLittleKids": false }, "the-square": { "fsk": 12, "forLittleKids": false }, "holy-motors": { "fsk": 16, "forLittleKids": false }, "oslo-august-31st": { "fsk": 12, "forLittleKids": false }, "paddington": { "fsk": 0, "forLittleKids": true }, "klaus": { "fsk": 0, "forLittleKids": true }, "zootopia": { "fsk": 0, "forLittleKids": true }, "kung-fu-panda": { "fsk": 6, "forLittleKids": false }, "puss-in-boots-the-last-wish": { "fsk": 6, "forLittleKids": false }, "the-mitchells-vs-the-machines": { "fsk": 6, "forLittleKids": false }, "elemental": { "fsk": 0, "forLittleKids": true }, "turning-red": { "fsk": 6, "forLittleKids": false }, "nimona": { "fsk": 6, "forLittleKids": false }, "kpop-demon-hunters": { "fsk": 6, "forLittleKids": false }, "despicable-me": { "fsk": 0, "forLittleKids": true }, "the-grand-seduction": { "fsk": 0, "forLittleKids": false }, "wallace-gromit-the-curse-of-the-were-rabbit": { "fsk": 0, "forLittleKids": true }, "coraline": { "fsk": 12, "forLittleKids": false }, "inside-out": { "fsk": 0, "forLittleKids": true }, "cats": { "fsk": 0, "forLittleKids": true }, "the-last-airbender": { "fsk": 12, "forLittleKids": false }, "batman-robin": { "fsk": 12, "forLittleKids": false }, "fantastic-four": { "fsk": 12, "forLittleKids": false }, "suicide-squad": { "fsk": 16, "forLittleKids": false }, "transformers-the-last-knight": { "fsk": 12, "forLittleKids": false }, "the-mummy": { "fsk": 12, "forLittleKids": false }, "dragonball-evolution": { "fsk": 12, "forLittleKids": false }, "catwoman": { "fsk": 12, "forLittleKids": false }, "the-flash": { "fsk": 12, "forLittleKids": false }, "smile": { "fsk": 16, "forLittleKids": false }, "five-nights-at-freddy-s": { "fsk": 16, "forLittleKids": false }, "wonder-woman-1984": { "fsk": 12, "forLittleKids": false }, "venom": { "fsk": 16, "forLittleKids": false }, "eternals": { "fsk": 12, "forLittleKids": false }, "mortal-kombat": { "fsk": 18, "forLittleKids": false }, "don-t-look-up": { "fsk": 12, "forLittleKids": false }, "the-gray-man": { "fsk": 16, "forLittleKids": false }, "red-notice": { "fsk": 12, "forLittleKids": false }, "bird-box": { "fsk": 16, "forLittleKids": false }, "extraction": { "fsk": 18, "forLittleKids": false }, "glass": { "fsk": 16, "forLittleKids": false }, "fifty-shades-of-grey": { "fsk": 16, "forLittleKids": false }, "after": { "fsk": 12, "forLittleKids": false }, "the-room": { "fsk": 16, "forLittleKids": false }, "twilight": { "fsk": 12, "forLittleKids": false }, "the-hunger-games": { "fsk": 12, "forLittleKids": false }, "dune-1984": { "fsk": 12, "forLittleKids": false }, "the-iron-giant": { "fsk": 6, "forLittleKids": false }, "monsters-inc": { "fsk": 0, "forLittleKids": true }, "toy-story": { "fsk": 0, "forLittleKids": true }, "the-prince-of-egypt": { "fsk": 6, "forLittleKids": false }, "ponyo": { "fsk": 0, "forLittleKids": true }, "kiki-s-delivery-service": { "fsk": 0, "forLittleKids": true }, "grave-of-the-fireflies": { "fsk": 12, "forLittleKids": false }, "paprika": { "fsk": 12, "forLittleKids": false }, "tokyo-story": { "fsk": 0, "forLittleKids": false }, "12-angry-men": { "fsk": 12, "forLittleKids": false }, "psycho": { "fsk": 16, "forLittleKids": false }, "casablanca": { "fsk": 12, "forLittleKids": false }, "some-like-it-hot": { "fsk": 6, "forLittleKids": false }, "2001-a-space-odyssey": { "fsk": 12, "forLittleKids": false }, "jaws": { "fsk": 16, "forLittleKids": false }, "e-t-the-extra-terrestrial": { "fsk": 6, "forLittleKids": false }, "the-princess-bride": { "fsk": 6, "forLittleKids": false }, "ghostbusters": { "fsk": 12, "forLittleKids": false }, "heat": { "fsk": 16, "forLittleKids": false }, "leon-the-professional": { "fsk": 16, "forLittleKids": false }, "reservoir-dogs": { "fsk": 18, "forLittleKids": false }, "trainspotting": { "fsk": 16, "forLittleKids": false }, "pirates-of-the-caribbean-dead-man-s-chest": { "fsk": 12, "forLittleKids": false }, "prey": { "fsk": 16, "forLittleKids": false }, "the-northman": { "fsk": 16, "forLittleKids": false }, "babylon": { "fsk": 16, "forLittleKids": false }, "the-iron-claw": { "fsk": 12, "forLittleKids": false }, "challengers": { "fsk": 12, "forLittleKids": false }, "heretic": { "fsk": 16, "forLittleKids": false }, "companion": { "fsk": 16, "forLittleKids": false }, "a-minecraft-movie": { "fsk": 6, "forLittleKids": false }, "lilo-stitch": { "fsk": 6, "forLittleKids": false }, "28-years-later": { "fsk": 18, "forLittleKids": false }, "materialists": { "fsk": 12, "forLittleKids": false }, "bugonia": { "fsk": 16, "forLittleKids": false }, "frankenstein": { "fsk": 16, "forLittleKids": false }, "hamnet": { "fsk": 12, "forLittleKids": false }, "sentimental-value": { "fsk": 12, "forLittleKids": false }, "spirited-away": { "fsk": 6, "forLittleKids": false }, "my-neighbor-totoro": { "fsk": 0, "forLittleKids": true }, "a-coffee-in-berlin": { "fsk": 6, "forLittleKids": false }, "cinema-paradiso": { "fsk": 6, "forLittleKids": false }, "city-of-god": { "fsk": 16, "forLittleKids": false }, "se7en": { "fsk": 16, "forLittleKids": false }, "500-days-of-summer": { "fsk": 6, "forLittleKids": false }, "call-me-by-your-name": { "fsk": 12, "forLittleKids": false }, "memento": { "fsk": 16, "forLittleKids": false }, "ex-machina": { "fsk": 12, "forLittleKids": false }, "talk-to-me": { "fsk": 16, "forLittleKids": false }, "the-witch": { "fsk": 16, "forLittleKids": false }, "run-lola-run": { "fsk": 12, "forLittleKids": false }, "downfall": { "fsk": 12, "forLittleKids": false }, "the-wave": { "fsk": 12, "forLittleKids": false }, "saint-maud": { "fsk": 16, "forLittleKids": false }, "seven-samurai": { "fsk": 12, "forLittleKids": false }, "snatch": { "fsk": 16, "forLittleKids": false }, "serie-breaking-bad": { "fsk": 16, "forLittleKids": false }, "serie-better-call-saul": { "fsk": 16, "forLittleKids": false }, "serie-dark": { "fsk": 16, "forLittleKids": false }, "serie-stranger-things": { "fsk": 16, "forLittleKids": false }, "serie-the-last-of-us": { "fsk": 16, "forLittleKids": false }, "serie-severance": { "fsk": 16, "forLittleKids": false }, "serie-the-bear": { "fsk": 12, "forLittleKids": false }, "serie-succession": { "fsk": 16, "forLittleKids": false }, "serie-game-of-thrones": { "fsk": 16, "forLittleKids": false }, "serie-the-office": { "fsk": 12, "forLittleKids": false }, "serie-friends": { "fsk": 6, "forLittleKids": false }, "serie-sherlock": { "fsk": 12, "forLittleKids": false }, "serie-chernobyl": { "fsk": 16, "forLittleKids": false }, "serie-true-detective": { "fsk": 16, "forLittleKids": false }, "serie-fargo": { "fsk": 16, "forLittleKids": false }, "serie-the-crown": { "fsk": 12, "forLittleKids": false }, "serie-wednesday": { "fsk": 12, "forLittleKids": false }, "serie-squid-game": { "fsk": 16, "forLittleKids": false }, "serie-arcane": { "fsk": 16, "forLittleKids": false }, "serie-shogun": { "fsk": 16, "forLittleKids": false }, "serie-the-mandalorian": { "fsk": 12, "forLittleKids": false }, "serie-ted-lasso": { "fsk": 12, "forLittleKids": false }, "serie-black-mirror": { "fsk": 16, "forLittleKids": false }, "serie-peaky-blinders": { "fsk": 16, "forLittleKids": false }, "serie-house-of-the-dragon": { "fsk": 16, "forLittleKids": false }, "serie-fleabag": { "fsk": 16, "forLittleKids": false }, "serie-how-i-met-your-mother": { "fsk": 12, "forLittleKids": false }, "serie-brooklyn-nine-nine": { "fsk": 12, "forLittleKids": false }, "serie-the-boys": { "fsk": 18, "forLittleKids": false }, "serie-mindhunter": { "fsk": 16, "forLittleKids": false }, "serie-babylon-berlin": { "fsk": 16, "forLittleKids": false }, "serie-money-heist": { "fsk": 16, "forLittleKids": false }, "serie-andor": { "fsk": 12, "forLittleKids": false }, "serie-the-white-lotus": { "fsk": 16, "forLittleKids": false }, "serie-only-murders-in-the-building": { "fsk": 12, "forLittleKids": false }, "serie-adolescence": { "fsk": 12, "forLittleKids": false }, "serie-the-penguin": { "fsk": 16, "forLittleKids": false }, "serie-avatar-the-last-airbender": { "fsk": 6, "forLittleKids": false }, "serie-bluey": { "fsk": 0, "forLittleKids": true }, "serie-gilmore-girls": { "fsk": 6, "forLittleKids": false }, "serie-derry-girls": { "fsk": 12, "forLittleKids": false }, "serie-normal-people": { "fsk": 16, "forLittleKids": false }, "serie-slow-horses": { "fsk": 16, "forLittleKids": false }, "serie-heartstopper": { "fsk": 6, "forLittleKids": false }, "serie-bridgerton": { "fsk": 12, "forLittleKids": false }, "serie-the-witcher": { "fsk": 16, "forLittleKids": false }, "serie-ripley": { "fsk": 12, "forLittleKids": false }, "serie-one-piece": { "fsk": 12, "forLittleKids": false } };

// supabase/functions/film-device/service.mjs
async function sha256(value) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))), (b) => b.toString(16).padStart(2, "0")).join("");
}
var allowedActions = /* @__PURE__ */ new Set(["createPairing", "resolveCode", "approvePairing", "rejectPairing", "activateSession", "cancelPairing", "rotateSession", "revokeSession", "listSessions", "verifySubscription", "readState", "applyMutations", "createJob", "listJobs", "claimJob", "completeJob", "cancelJob"]);
var jobKinds = /* @__PURE__ */ new Set(["import", "taste", "mood", "review", "deleteAccount", "subscription", "externalLink"]);
var phoneOnly = /* @__PURE__ */ new Set(["approvePairing", "rejectPairing", "claimJob", "completeJob", "listSessions"]);
var response = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" } });
function createHandler({ rpc, getUser, verifySubscription: verifySubscription2 }) {
  return async (request) => {
    try {
      if (request.method !== "POST") return response({ error: "method_not_allowed" }, 405);
      if (Number(request.headers.get("content-length")) > 262144) return response({ error: "request_too_large" }, 413);
      let raw = "";
      const reader = request.body?.getReader();
      const decoder = new TextDecoder();
      let bytes = 0;
      if (reader) {
        while (true) {
          const part = await reader.read();
          if (part.done) break;
          bytes += part.value.byteLength;
          if (bytes > 262144) {
            await reader.cancel();
            return response({ error: "request_too_large" }, 413);
          }
          raw += decoder.decode(part.value, { stream: true });
        }
        raw += decoder.decode();
      }
      let b;
      try {
        b = object(JSON.parse(raw));
      } catch {
        return response({ error: "invalid_json" }, 400);
      }
      const tail = new URL(request.url).pathname.split("/").pop();
      const action = b.action || tail;
      if (!allowedActions.has(action)) return response({ error: "unknown_action" }, 404);
      const ip = await sha256((request.headers.get("x-forwarded-for") || "unknown").split(",")[0].trim());
      const limit = async (key2, n, seconds = 60) => {
        if (!await rpc("film_rate_limit", { p_key: key2, p_limit: n, p_seconds: seconds })) fail("rate_limited");
      };
      await limit("global:" + action, ["resolveCode", "createPairing"].includes(action) ? 300 : 5e3);
      await limit("ip:" + ip + ":" + action, action === "resolveCode" ? 5 : action === "createPairing" ? 10 : 120);
      if (action === "createPairing") {
        hashValue(b.pollHash);
        hashValue(b.sessionHash);
        if (b.pollHash === b.sessionHash) fail("invalid_hash");
        const name = text(b.deviceName, 80).replace(/[\x00-\x1f\x7f]/g, "").trim();
        if (!name) fail("invalid_device_name");
        return response(await rpc("film_create_pairing", { p_poll_hash: b.pollHash, p_session_hash: b.sessionHash, p_device_name: name }));
      }
      if (action === "resolveCode") {
        if (typeof b.code !== "string" || !/^\d{6}$/.test(b.code)) fail("invalid_code");
        return response(await rpc("film_resolve_code", { p_code: b.code }));
      }
      if (action === "activateSession" || action === "cancelPairing") {
        uuid(b.id);
        text(b.pollSecret, 256);
        if (b.pollSecret.length < 32) fail("unauthorized");
        await limit("poll:" + b.id, 12);
        return response(await rpc(action === "cancelPairing" ? "film_cancel_pairing" : "film_activate_session", { p_id: b.id, p_poll_hash: await sha256(b.pollSecret) }));
      }
      const auth = request.headers.get("authorization") || "";
      if (!auth.startsWith("Bearer ")) fail("unauthorized");
      const bearer = auth.slice(7);
      if (bearer.length < 20 || bearer.length > 4096) fail("unauthorized");
      const isJWT = bearer.split(".").length === 3;
      let principal;
      if (isJWT) {
        const u = await getUser(bearer);
        if (!u?.id) fail("unauthorized");
        principal = { userID: u.id, email: u.email, tokenHash: null, sessionID: null };
      } else {
        if (phoneOnly.has(action)) fail("unauthorized");
        const tokenHash = await sha256(bearer);
        const p = await rpc("film_principal", { p_token_hash: tokenHash, p_rotation_operation: action === "rotateSession" ? uuid(b.operationID) : null, p_new_hash: action === "rotateSession" ? hashValue(b.newHash) : null });
        if (!p?.userID) fail("unauthorized");
        principal = { ...p, tokenHash };
      }
      if (phoneOnly.has(action) && !isJWT) fail("unauthorized");
      const context = { p_user_id: principal.userID, p_token_hash: principal.tokenHash };
      await limit("account:" + principal.userID + ":" + action, 120);
      if (action === "approvePairing" || action === "rejectPairing") {
        uuid(b.id);
        if (typeof b.code !== "string" || !/^\d{6}$/.test(b.code)) fail("invalid_code");
        return response(await rpc("film_approve_pairing", { p_user_id: principal.userID, p_id: b.id, p_code: b.code, p_approve: action === "approvePairing" }));
      }
      if (action === "rotateSession") {
        if (isJWT) fail("unauthorized");
        return response(await rpc("film_rotate_session", { ...context, p_new_hash: hashValue(b.newHash), p_operation_id: uuid(b.operationID) }));
      }
      if (action === "listSessions") return response({ sessions: await rpc("film_list_sessions", context) });
      if (action === "revokeSession") {
        return response(await rpc("film_revoke_session", { ...context, p_session_id: b.id ? uuid(b.id) : principal.sessionID }));
      }
      if (action === "verifySubscription") {
        text(b.signedTransaction, 1e5);
        if (!verifySubscription2) fail("subscription_unavailable");
        const receipt = await verifySubscription2(b.signedTransaction, principal.userID);
        const data = await rpc("film_verify_subscription", { ...context, p_receipt: receipt });
        return response({ state: wireState(data.state), revision: data.revision, userID: principal.userID, email: principal.email });
      }
      if (action === "readState") {
        if (b.bootstrapState && !isJWT) fail("unauthorized");
        const bootstrap = b.bootstrapState ? bootstrapState(b.bootstrapState, principal.email) : null;
        const data = await rpc("film_read_state", { ...context, p_bootstrap: bootstrap });
        return response({ state: wireState(data.state), revision: data.revision, userID: principal.userID, email: principal.email });
      }
      if (action === "applyMutations") {
        if (!Array.isArray(b.operations) || b.operations.length > 100) fail("invalid_operations");
        for (let attempt = 0; attempt < 5; attempt++) {
          const data = await rpc("film_read_state", context);
          const result = applyOperations({ state: data.state, metadata: data.metadata, operations: b.operations, baseRevision: b.baseRevision, revision: data.revision, seen: data.seen, catalog });
          const committed = await rpc("film_commit_state", { ...context, p_expected_revision: data.revision, p_revision: result.revision, p_state: wireState(result.state), p_metadata: result.metadata, p_operation_ids: result.acknowledged });
          if (committed) return response({ state: wireState(result.state), revision: result.revision, userID: principal.userID, email: principal.email });
        }
        fail("revision_conflict");
      }
      if (action === "createJob") {
        if (!jobKinds.has(b.kind)) fail("invalid_job");
        if (b.profileID) uuid(b.profileID);
        object(b.payload || {});
        return response(await rpc("film_create_job", { ...context, p_kind: b.kind, p_profile_id: b.profileID || null, p_payload: b.payload || {}, p_operation_id: uuid(b.operationID) }));
      }
      if (action === "listJobs") return response({ jobs: await rpc("film_list_jobs", context) });
      uuid(b.id);
      if (!Number.isSafeInteger(b.version) || b.version < 1) fail("invalid_version");
      if (action === "completeJob" && b.result?.operations) {
        object(b.result);
        const claimant2 = "phone:" + text(b.claimant || "", 100);
        if (claimant2 === "phone:") fail("invalid_claimant");
        for (let attempt = 0; attempt < 5; attempt++) {
          const data = await rpc("film_read_state", context);
          const result = applyOperations({ state: data.state, metadata: data.metadata, operations: b.result.operations, baseRevision: b.result.baseRevision, revision: data.revision, seen: data.seen, catalog });
          try {
            return response(await rpc("film_complete_job", { ...context, p_id: b.id, p_version: b.version, p_claimant: claimant2, p_result: b.result, p_expected_revision: data.revision, p_revision: result.revision, p_state: wireState(result.state), p_metadata: result.metadata, p_operation_ids: result.acknowledged }));
          } catch (e) {
            if (e.message !== "revision_conflict") throw e;
          }
        }
        fail("revision_conflict");
      }
      const claimant = isJWT ? "phone:" + text(b.claimant || "", 100) : principal.sessionID;
      if (action === "claimJob" && claimant === "phone:") fail("invalid_claimant");
      return response(await rpc("film_transition_job", { ...context, p_id: b.id, p_version: b.version, p_action: { claimJob: "claim", completeJob: "complete", cancelJob: "cancel" }[action], p_claimant: claimant, p_result: b.result || {} }));
    } catch (error) {
      const message = String(error?.message || "server_error");
      const code = message.match(/\b(unauthorized|rate_limited|not_found|pairing_expired|pairing_conflict|invalid_[a-z_]+|profile_[a-z_]+|revision_conflict|undo_conflict|age_restricted|unverified_subscription|subscription_[a-z_]+|account_not_found|job_[a-z_]+)\b/)?.[1] || "server_error";
      const status = code === "subscription_unavailable" ? 503 : code === "unauthorized" ? 401 : code === "rate_limited" ? 429 : code === "not_found" ? 404 : /conflict|expired|deleted/.test(code) ? 409 : code === "server_error" ? 500 : 400;
      return response({ error: code }, status);
    }
  };
}

// supabase/functions/film-device/rollout.mjs
function withRollout(handler2, enabled) {
  return (request) => enabled() === "true" ? handler2(request) : new Response(JSON.stringify({ error: "service_not_enabled" }), {
    status: 503,
    headers: { "content-type": "application/json", "cache-control": "no-store" }
  });
}

// supabase/functions/film-device/index.ts
var url = Deno.env.get("SUPABASE_URL");
var key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!url || !key) throw new Error("Missing Supabase server configuration");
var server = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
var verifySubscription = createVerifierProxy({ getenv: (key2) => Deno.env.get(key2) });
var handler = createHandler({
  verifySubscription,
  getUser: async (jwt) => {
    const { data, error } = await server.auth.getUser(jwt);
    return error ? null : data.user;
  },
  rpc: async (name, args) => {
    const { data, error } = await server.rpc(name, args);
    if (error) throw new Error(error.message);
    return data;
  }
});
Deno.serve(withRollout(handler, () => Deno.env.get("FILM_DEVICE_ENABLED")));
