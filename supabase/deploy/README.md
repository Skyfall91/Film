# Browser deployment bundle

Generated on 15.10.2026 for the Supabase dashboard editor. The CLI continues to deploy the original multi-file function. This bundle contains no private keys; server configuration comes from runtime environment variables.

Regenerate from the repository root:

```sh
npx --yes esbuild@0.25.10 supabase/functions/film-device/index.ts --bundle --format=esm --platform=neutral --target=es2022 '--external:npm:*' --outfile=supabase/deploy/film-device.js
deno check supabase/functions/film-device/index.ts supabase/deploy/film-device.js
```

The output is JavaScript. When the dashboard requires an `index.ts` entrypoint, prefix the generated output with `// @ts-nocheck` to avoid applying TypeScript implicit-any rules to emitted JavaScript. The original typed entrypoint is checked separately; the imported JavaScript business logic is covered by Node/PostgreSQL tests. No verifier or authorization behavior is changed by bundling.

Dashboard preparation: original account_state schema/RLS/constraints/delete_own_account were read and match expectations; no pre-existing film_private schema. Migration and function are prepared as drafts. Execution/deployment awaits the requested action-time approval.

Current live state: deployed, but disabled by default via `withRollout` and `FILM_DEVICE_ENABLED`. Do not set it to true until the project owner explicitly says “jetzt”. Migration is present; hosted read-only audit confirms zero managed accounts and zero TV sessions, preserving legacy app compatibility.
