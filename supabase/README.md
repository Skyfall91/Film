# Film device backend

## Dienststatus · 16.10.2026

Der Dienst ist nach ausdrücklicher Freigabe aktiviert. Erstellung einer unbestätigten Kopplung und Abbruch wurden live erfolgreich geprüft. Vollständige Anmeldung auf zwei echten Geräten, Lichtscan und reale Käufe bleiben offen. Bestehende App-Versionen bleiben zunächst nutzbar; sobald ein Konto die neue Synchronisierung verwendet, benötigen dessen andere Geräte die aktuelle App für Online-Schreibzugriffe.

The implementation contains a Supabase Edge Function, additive PostgreSQL migration, PostgreSQL integration checks and Node request/domain tests. The rollout flag must be set explicitly for each deployment; this repository does not change a hosted flag automatically.

## Local verification

From the repository root:

```sh
npm ci --prefix supabase
npm test --prefix supabase
npm run test:sql --prefix supabase
deno check supabase/functions/film-device/index.ts
```

The SQL suite executes the unmodified migration in an isolated PGlite PostgreSQL database. It creates test-only `auth.users`, roles and `auth.role()`, then drives the actual Edge handler against the real SQL RPCs. It verifies pairing/activation, incorrect secrets, token rotation/retries/expiry, revocation, account deletion cascade, CAS/deduplication, atomic companion completion, profile scope, RPC privileges, five-guess pause, cancellation, legacy-write blocking, and bootstrap preservation. It does not prove hosted Supabase gateway configuration, live Auth validation or multi-connection scheduling. Verify those in staging before enabling clients.

Alternatively set `PGLITE_MODULE_ROOT` to an existing test-only `@electric-sql/pglite` package path. PGlite is a development dependency; the deployed function imports only its pinned Supabase SDK and local modules.

After changing catalog age metadata run `node supabase/scripts/generate-catalog.mjs`. The generated safety catalog mirrors `Film.forLittleKids`: FSK 0 and Animation/Familie. Client-provided FSK never authorizes a mutation.

## API

All routes are JSON `POST /functions/v1/film-device/<action>`. A body `action` is also supported. Requests are capped at 256 KiB of UTF-8 bytes; errors are `{ "error": "code" }` with HTTP 400/401/404/409/413/429/500/503. Responses disable caching. Account IDs always come from the authenticated principal. Supabase user JWTs are checked with `auth.getUser(jwt)`, not decoded and trusted locally. Opaque TV bearer tokens are SHA-256 hashed before lookup and work only in this function.

| Action | Authorization | Request | Response |
| --- | --- | --- | --- |
| createPairing | anonymous | `pollHash, sessionHash, deviceName` | `id, code, deviceName, expiresAt, status:pending` |
| resolveCode | anonymous | `code` (six digits) | pending public pairing projection |
| approvePairing / rejectPairing | verified phone JWT | `id, code` | approved / rejected public pairing projection |
| activateSession | poll secret | `id, pollSecret` | `status:active, userID, email, expiresAt`, or pending/rejected/expired/cancelled |
| cancelPairing | poll secret | `id, pollSecret` | `status:cancelled` (activation already completed conflicts) |
| rotateSession | TV bearer only | `newHash, operationID` | `status:rotated, expiresAt` |
| listSessions | phone JWT | `{}` | `{sessions:[{id,deviceName,createdAt,lastSeenAt,expiresAt}]}` |
| revokeSession | phone JWT or that TV | `id` session ID (TV may omit) | `status:revoked` |
| readState | phone JWT or TV bearer | `{}`; phone may include `bootstrapState` | `state, revision, userID, email` |
| verifySubscription | phone JWT or TV bearer | `signedTransaction` JWS only | `state, revision, userID, email` |
| applyMutations | phone JWT or TV bearer | `baseRevision, operations` | `state, revision, userID, email` |
| createJob | phone JWT or TV bearer | `kind, profileID?, payload, operationID` | job |
| listJobs | phone JWT or TV bearer | `{}` | `{jobs:[job]}` |
| claimJob | phone JWT | `id, version, claimant` | claimed job, version + 1 |
| completeJob | phone JWT | `id, version, claimant, result` | completed job, version + 1 |
| cancelJob | phone JWT or TV bearer | `id, version` | cancelled job, version + 1 |

A job contains `id, kind, profileID, payload, result, version, status, expiresAt, claimant`. Kinds are `import, taste, mood, review, deleteAccount, subscription, externalLink`. Import/taste/review require a profile. The phone generates and persists a stable claimant identifier, sending the same value when completing. Accepting/completing with a different version or claimant conflicts; profile deletion and expiry invalidate a result. A completion may include `result: {baseRevision, operations, ...summary}` to apply profile mutations and mark the job completed in one SQL transaction. Operations must target the job's profile when it has one. A CAS failure rolls back both writes. The same claim/completion version and result can be retried idempotently.

Jobs transport requested work and confirmed results. Creating a deleteAccount/subscription/externalLink job does not perform the destructive action or purchase by itself. The iPhone runs the existing explicit confirmation and platform workflow; deleting the Auth user cascades all new device credentials and jobs.

## Mutation and snapshot contract

Each operation is `{id:UUID, kind, profileID?, filmID?, payload:{...}}`. UUIDs are compared without case sensitivity. All operations in a batch are validated before a successful commit; a failed batch writes nothing. Different fields/titles merge over stale base revisions. Profile metadata changes and full profile replacements use compare-and-swap. Profile deletion records permanent tombstones; late offline profile creation cannot resurrect that UUID. The account ledger retains operation IDs for idempotent offline retry.

Supported payloads:

- `profileOrder {profileIDs:[UUID...]}` reorders the full live profile list with CAS, unique exact membership and tombstone checks. Unsubscribed households retain the existing eight-profile fallback; subscribed plans still use 2/4/8.
- `profileCreate {profile}`, `profileUpdate {name?,colorIndex?,maxFSK?,littleKid?,avatar?,onboardingComplete?,importedCountDelta?,external?,learning?}`, `profileDelete {}`, `profileReplace {profile}` (CAS).
- `ratingSet {rating:Interaction|null, learning?}`, `reviewSet {review:Review|null}`, `watchlistAdd {}`, `watchlistRemove {}`.
- `progressSet {progress:EpisodeRef|null}` (optional position/completed/restart), or `{positionKey:"filmID|season|episode",seconds:Double}`. Completion does not regress with delayed progress; deliberate restart/removal requires the current revision.
- `hintSet {key,value}` adds a confirmed hint delta and matching affinity delta.
- `importApply {fingerprint:SHA256,ratings:[{filmID,rating}],learning?}` deduplicates an identical import per profile.
- `subscriptionSet {subscription:Subscription|null}` accepts honest `source:"demo"` only when no server-owned App Store subscription exists. Client mutations cannot create, overwrite or remove verified StoreKit state; use `verifySubscription`. Bootstrap/legacy unverified App Store claims are deferred until a receipt is verified.
- `pendingRatingSet {pending:{filmID,profileIDs,date}}`, `pendingRatingRemove {id:"filmID|JSON-date"}` are account-level operations. Every referenced profile belongs to the account and passes the trusted age rule.

Any field operation may contain `expectedOperationID` for guarded undo; watchlist add/remove share the same identity. A later accepted edit makes stale undo conflict.

The native Swift learning algorithm remains authoritative. Send validated additive `learning:{affinity:{key:delta},exposure:{key:delta},signalTotal:delta,signalN:delta,samples:[{filmID,delta}]}` on the first changed interaction per profile. Always send `samples:[]` if no targets changed. This marker disables fallback rating-derived targets for the entire profile batch. Later rating operations in the same batch do not overwrite the aggregated native samples. Hint affinity must not also be included in a rating learning delta. For external-only learning, use `profileUpdate {external?:{id:metadata},learning}` with the current base revision. Metadata is validated as Wikidata `ext:Q...` records (`id,title,genres,moods,director,cast,year?`) before learning. Sample IDs must belong to the trusted catalog or the profile's validated external records. External metadata does not authorize rating/review/watchlist/playback operations for uncatalogued titles. Mixed catalog rating deltas may include known external samples. Cache fields `weights` and `taste` are reset for learning changes and recomputed by `Profile` decoding/refit. Clients without the native sample marker use the rating target fallback. Replaying an operation never learns twice.

The wire projection keeps shared snapshot fields and known Profile/Account fields only. `passwordHash` and `salt` are empty for Swift compatibility; device tokens, navigation, active viewers, sign-in state and local credentials are absent. Snapshot dates retain Swift's seconds-since-2001 encoding; pairing/session/job expiration uses ISO-8601 server time. Existing profile IDs, learning data and account snapshots are preserved by the migration.

For a household without an `account_state` row, a verified phone may send its credential-free local snapshot as `readState {bootstrapState}`. The service checks that snapshot email matches the verified Auth email and validates profile IDs/basic schema and actual numeric creation/consent dates. SQL inserts it only when no row exists. TV tokens cannot bootstrap. No creation or consent date is fabricated.

## Staging deployment and cutover

1. Use a separate Supabase staging project and test accounts. Install the Supabase CLI and Deno if absent. Run `scripts/preflight.sql` against staging and review the existing account_state schema, RLS, constraints, triggers and delete_own_account behavior. Do not print account JSON or secrets. Back up the old schema and snapshots privately before any hosted rollout.
2. Apply `migrations/202610150001_film_device.sql` to staging, preserving existing account_state policies. Run `scripts/verify-security.sql`. The migration creates a private schema with RLS and no anon/authenticated access; every new public RPC is service-role-only. It does not expose TV tokens through PostgREST.
3. Deploy the function to staging with `supabase functions deploy film-device --project-ref <STAGING_REF> --no-verify-jwt`. `supabase/config.toml` deliberately sets `verify_jwt=false` for this one function because an opaque TV token is not a Supabase JWT. The function's protected routes validate principals themselves. Never disable JWT verification globally.
4. Supabase supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to the server runtime. Never embed the service key in Swift, a test fixture or client-visible config. Do not add it to the repository. Keep request-body logging disabled for this function: codes, raw tokens and camera data are never logged by the handler.
5. Test two updated clients with staging Auth: wrong/expired/rejected/cancelled codes, simultaneous activation, lost responses, token rotation at the 60-second boundary, device revocation, account deletion, concurrent mutations, whole-profile CAS conflicts and invalid companion completion. Check actual hosted gateway forwarding and rate limits. Verify legacy direct upserts fail after the first new account read.
6. Ship both updated iOS and TV clients before enabling a production account cutover. The first new read creates a managed account_sync row; the trigger then rejects legacy authenticated snapshot writes for that account. Old clients cannot silently overwrite new concurrent edits. A rollback requires disabling new client writes first, restoring the reviewed old write path per account and revoking TV sessions; do not drop snapshots or RLS to get around the guard.

The handler limits code resolution to five attempts per IP per minute, pairing creation to ten per minute, polling to twelve per pairing per minute, plus account and global limits. Distributed guessing remains bounded by the global bucket. A verified reverse proxy must forward the real source IP. Limits are database-atomic. Add scheduled server-side maintenance for old rate buckets, expired unused pairings and expired jobs before sustained public traffic; keep operation receipts/tombstones while offline retries remain valid. Never prune active session-linked pairing rows.

The base migration and function deployment succeeded, and hosted unauthenticated smoke checks passed before the explicit hold. It does not claim live production receipt validation or physical TV/camera testing. The local SQL tests use one embedded connection; staging must also exercise real concurrent transactions and the existing production schema before rollout.

References: [Supabase getUser](https://supabase.com/docs/reference/javascript/auth-getuser), [database functions and execution privileges](https://supabase.com/docs/guides/database/functions).


## App Store verification runtime

The official Apple Node SDK 3.1.0 verifies ES256 signatures, certificate chain, Apple OIDs, bundle and environment. Actual runtime testing found `crypto.X509Certificate.raw` unimplemented in Deno 2.5.4; type checking alone did not reveal it. Therefore Apple verification runs in the provided **Node 22+ sidecar** (`apple-verifier/server.mjs`), while the Supabase Edge Function authenticates the phone/TV and atomically commits the verified result. No certificate-verification shim or Xcode/LocalTesting signature bypass is used.

Deploy the sidecar on a server/container behind HTTPS. From the `supabase/` directory, its container can be built with `docker build -f apple-verifier/Dockerfile .`. The container configuration supplies secrets; the image contains no private signing key. A direct local Node process binds `127.0.0.1:8080` by default. Public hosting must provide TLS and set HOST/PORT appropriately.

Configure the **Node sidecar**:

- `APPLE_VERIFIER_SHARED_SECRET`: at least 32 random characters, supplied privately to both services.
- `APPLE_ENVIRONMENT`: exactly `Sandbox` or `Production`, selected by deployment configuration. Requests cannot choose it. Sandbox performs real offline chain/signature verification against the bundled public Apple roots.
- `APPLE_BUNDLE_IDS`: optional, comma separated list of accepted app bundle IDs. Without it only the placeholder `app.film` and `app.film.tv` are accepted, so set your own IDs here instead of in the code.
- Production additionally requires `APPLE_APP_ID` (positive numeric App Store app ID), `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, and `APPLE_PRIVATE_KEY` (App Store Server API signing key). Production enables the official SDK's online certificate checks and fetches current `signedTransactionInfo` through Apple's `getTransactionInfo` API before validating again. Missing keys or Apple network failure fails closed.

Configure the **Supabase Edge Function** with `APPLE_VERIFIER_URL=https://<host>/verify-subscription` and the same `APPLE_VERIFIER_SHARED_SECRET`. HTTP URLs, credentials in the URL, redirects, unexpected paths, bad MACs and unsigned responses are rejected. Each server-to-server request and response has a direction-bound HMAC-SHA256 over timestamp, nonce and exact JSON bytes. The sidecar checks a 60-second timestamp window and one-use nonces. It accepts the verified account UUID from the authenticated Edge request, never an untrusted client account field. Neither service logs signed receipts or raw bearer tokens.

The only allowed products are `app.film.abo.solo`, `.duo`, `.familie`. Allowed purchase bundle IDs are `app.film` and the legacy TV ID `app.film.tv`; current universal iOS/TV purchases use `app.film`. The verified `appAccountToken`, when present, must equal the Supabase account UUID. Expired, revoked, upgraded, future-dated, wrong-product/app/environment and wrong-account proofs fail. Plan, dates, source and trial state derive from verified Apple data; client plan/source fields are ignored. Introductory offers are labelled trial only with Apple's verified FREE_TRIAL discount type.

SQL binds each environment/originalTransactionID to one account and rejects reuse or older proofs replacing a newer receipt. A spent receipt tombstone cannot transfer to another account after deletion; the deleted account association is cleared. Raw JWS is not stored. Known verified expiry marks the subscription canceled on subsequent reads. Existing client-only App Store snapshot claims are removed from entitlement state until proof arrives; profiles, dates and learning data remain preserved.

No hosted verifier, Apple account credentials, real sandbox purchase or production transaction was available in this workspace. Until the sidecar and server settings exist, `verifySubscription` returns `503 subscription_unavailable`; it never simulates a successful receipt. Server notifications and scheduled subscription-status refresh remain necessary for prompt background renewal/refund convergence between client verification calls. The official SDK's current transitive `jsrsasign` dependency emits a deprecation warning; review dependency security before production rollout.

The local suite verifies real ES256 test certificates/signatures with the official SDK, tampering, untrusted roots, wrong app/environment, semantic policy, authenticated Edge-to-Node transport, ownership, idempotence and immutable SQL state. Temporary test CA keys are generated locally and removed; they are not trusted by the production verifier. The SQL suite explicitly mocks only the cryptographic boundary; it never claims its JSON fixtures are Apple-signed receipts.

References: [official Apple server library](https://github.com/apple/app-store-server-library-node), [Apple PKI roots](https://www.apple.com/certificateauthority/).
