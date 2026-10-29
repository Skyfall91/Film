import { createClient } from 'npm:@supabase/supabase-js@2.57.4';
import { createVerifierProxy } from './verifier-proxy.mjs';
import { createHandler } from './service.mjs';
import { withRollout } from './rollout.mjs';

const url = Deno.env.get('SUPABASE_URL');
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
if (!url || !key) throw new Error('Missing Supabase server configuration');
const server = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
const verifySubscription = createVerifierProxy({getenv:(key:string)=>Deno.env.get(key)});
const handler = createHandler({
  verifySubscription,
  getUser: async (jwt: string) => {
    const { data, error } = await server.auth.getUser(jwt);
    return error ? null : data.user;
  },
  rpc: async (name: string, args: Record<string, unknown>) => {
    const { data, error } = await server.rpc(name, args);
    if (error) throw new Error(error.message);
    return data;
  },
});
Deno.serve(withRollout(handler, () => Deno.env.get('FILM_DEVICE_ENABLED')));
