-- Additive device protocol. Run only against a reviewed staging schema first.
begin;
create schema if not exists film_private;
revoke all on schema film_private from public, anon, authenticated;
create table if not exists public.account_state (
 user_id uuid primary key references auth.users(id) on delete cascade,
 state jsonb not null, updated_at timestamptz not null default now()
);
-- Preserve the existing snapshot and RLS policies; conversion does not change JSON values.
alter table public.account_state alter column state type jsonb using state::jsonb;
alter table public.account_state enable row level security;
create table film_private.account_sync (
 user_id uuid primary key references auth.users(id) on delete cascade,
 revision bigint not null default 0 check(revision>=0), metadata jsonb not null default '{"tombstones":[],"fields":{},"imports":[]}',
 managed boolean not null default true
);
create table film_private.operations (
 user_id uuid not null references auth.users(id) on delete cascade, operation_id uuid not null,
 primary key(user_id,operation_id), created_at timestamptz not null default now()
);
create table film_private.pairings (
 id uuid primary key default gen_random_uuid(), code text not null check(code ~ '^\d{6}$'),
 poll_hash text not null unique check(poll_hash ~ '^[a-f0-9]{64}$'),
 session_hash text not null unique check(session_hash ~ '^[a-f0-9]{64}$'),
 device_name text not null check(length(device_name) between 1 and 80),
 status text not null default 'pending' check(status in ('pending','approved','rejected','activated','expired','cancelled')),
 user_id uuid references auth.users(id) on delete cascade,
 expires_at timestamptz not null default now()+interval '5 minutes', created_at timestamptz not null default now(),
 check(poll_hash<>session_hash)
);
create unique index film_live_code on film_private.pairings(code) where status in ('pending','approved');
create table film_private.sessions (
 id uuid primary key references film_private.pairings(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade, hash text not null unique,
 previous_hash text, rotation_id uuid, retry_until timestamptz,
 expires_at timestamptz not null default now()+interval '30 days', revoked_at timestamptz,
 created_at timestamptz not null default now(), last_seen_at timestamptz not null default now(), check(hash ~ '^[a-f0-9]{64}$')
);
create index on film_private.sessions(previous_hash) where previous_hash is not null;
create table film_private.jobs (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 operation_id uuid not null, profile_id uuid, kind text not null check(kind in ('import','taste','mood','review','deleteAccount','subscription','externalLink')),
 payload jsonb not null default '{}', result jsonb, version integer not null default 1,
 status text not null default 'pending' check(status in ('pending','claimed','completed','cancelled')),
 claimant text, expires_at timestamptz not null default now()+interval '15 minutes', created_at timestamptz not null default now(),
 unique(user_id,operation_id)
);
create table film_private.subscriptions (
 environment text not null check(environment in ('Sandbox','Production')),
 original_transaction_id text not null,
 -- Keep a spent receipt tombstone after account deletion; it cannot move to a new account.
 owner_id uuid references auth.users(id) on delete set null,
 transaction_id text not null, purchase_at timestamptz not null, signed_at timestamptz not null,
 expires_at timestamptz not null, subscription jsonb not null,
 primary key(environment,original_transaction_id)
);
alter table film_private.subscriptions enable row level security;
create table film_private.rate_limits (
 key text primary key, started_at timestamptz not null default now(), hits integer not null default 0
);
-- Private tables have no data API access, including authenticated JWTs.
alter table film_private.account_sync enable row level security;
alter table film_private.operations enable row level security;
alter table film_private.pairings enable row level security;
alter table film_private.sessions enable row level security;
alter table film_private.jobs enable row level security;
alter table film_private.rate_limits enable row level security;
revoke all on all tables in schema film_private from public, anon, authenticated;

create function public.film_rate_limit(p_key text,p_limit integer,p_seconds integer) returns boolean
language plpgsql security definer set search_path='' as $$
declare r film_private.rate_limits; begin
 if p_limit<1 or p_seconds<1 or length(p_key)>200 then raise exception 'invalid_limit';end if;
 insert into film_private.rate_limits(key) values(p_key) on conflict do nothing;
 select * into r from film_private.rate_limits where key=p_key for update;
 if r.started_at+make_interval(secs=>p_seconds)<=clock_timestamp() then
  update film_private.rate_limits set hits=1,started_at=clock_timestamp() where key=p_key;return true;
 end if;
 if r.hits>=p_limit then return false;end if;
 update film_private.rate_limits set hits=hits+1 where key=p_key;return true;
end $$;

create function film_private.pairing_json(p film_private.pairings) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_object('id',p.id,'code',p.code,'deviceName',p.device_name,'expiresAt',p.expires_at,'status',p.status)
$$;
create function public.film_create_pairing(p_poll_hash text,p_session_hash text,p_device_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p film_private.pairings; candidate text; i integer;begin
 if p_poll_hash!~'^[a-f0-9]{64}$' or p_session_hash!~'^[a-f0-9]{64}$' or p_poll_hash=p_session_hash then raise exception 'invalid_hash';end if;
 -- Codes are reusable only after expiry. Retain activated pairing row because its session references it.
 update film_private.pairings set status='expired' where expires_at<=now() and status in ('pending','approved');
 for i in 1..20 loop
  -- CSPRNG comes from PostgreSQL gen_random_uuid(), not random(). Modulo bias is immaterial to a public six-digit identifier.
  candidate := lpad(((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,8))::bit(32)::bigint)%1000000)::text,6,'0');
  begin
   insert into film_private.pairings(code,poll_hash,session_hash,device_name) values(candidate,p_poll_hash,p_session_hash,p_device_name) returning * into p;
   return film_private.pairing_json(p);
  exception when unique_violation then
   if exists(select 1 from film_private.pairings where poll_hash=p_poll_hash or session_hash=p_session_hash) then raise exception 'pairing_conflict';end if;
  end;
 end loop;raise exception 'rate_limited';
end $$;

create function public.film_resolve_code(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p film_private.pairings;begin
 select * into p from film_private.pairings where code=p_code and expires_at>now() and status='pending';
 if not found then raise exception 'not_found';end if;return film_private.pairing_json(p);
end $$;
create function public.film_approve_pairing(p_user_id uuid,p_id uuid,p_code text,p_approve boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p film_private.pairings;desired text;begin
 if not exists(select 1 from auth.users where id=p_user_id) then raise exception 'unauthorized';end if;
 select * into p from film_private.pairings where id=p_id and code=p_code for update;
 if not found then raise exception 'not_found';end if;
 if p.expires_at<=now() then raise exception 'pairing_expired';end if;
 desired:=case when p_approve then 'approved' else 'rejected' end;
 if p.status=desired and p.user_id=p_user_id then return film_private.pairing_json(p);end if;
 if p.status<>'pending' then raise exception 'pairing_conflict';end if;
 update film_private.pairings set status=desired,user_id=p_user_id where id=p_id returning * into p;
 return film_private.pairing_json(p);
end $$;
create function public.film_activate_session(p_id uuid,p_poll_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p film_private.pairings;s film_private.sessions;mail text;begin
 select * into p from film_private.pairings where id=p_id and poll_hash=p_poll_hash for update;
 if not found then raise exception 'unauthorized';end if;
 if p.status='activated' then
  select * into s from film_private.sessions where id=p_id and revoked_at is null and expires_at>now();
  -- Activation retry never resurrects a revoked or expired session.
  if not found then raise exception 'unauthorized';end if;
 elsif p.expires_at<=now() then return jsonb_build_object('status','expired');
 elsif p.status='approved' then
  insert into film_private.sessions(id,user_id,hash) values(p.id,p.user_id,p.session_hash) returning * into s;
  update film_private.pairings set status='activated' where id=p.id;
 else return jsonb_build_object('status',p.status);end if;
 select email into mail from auth.users where id=s.user_id;
 return jsonb_build_object('status','active','userID',s.user_id,'email',mail,'expiresAt',s.expires_at);
end $$;
create function public.film_cancel_pairing(p_id uuid,p_poll_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p film_private.pairings;begin
 select * into p from film_private.pairings where id=p_id and poll_hash=p_poll_hash for update;
 if not found then raise exception 'unauthorized';end if;
 if p.status='activated' then raise exception 'pairing_conflict';end if;
 update film_private.pairings set status='cancelled' where id=p_id returning * into p;
 return jsonb_build_object('status','cancelled');
end $$;
create function public.film_principal(p_token_hash text,p_rotation_operation uuid default null,p_new_hash text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s film_private.sessions;mail text;begin
 select * into s from film_private.sessions where revoked_at is null and expires_at>now() and
 (hash=p_token_hash or (p_rotation_operation is not null and previous_hash=p_token_hash and rotation_id=p_rotation_operation and hash=p_new_hash and retry_until>=now()));
 if not found then raise exception 'unauthorized';end if;
 select email into mail from auth.users where id=s.user_id;
 return jsonb_build_object('userID',s.user_id,'email',mail,'sessionID',s.id);
end $$;
create function film_private.assert_principal(p_user_id uuid,p_token_hash text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_token_hash is null then
  if not exists(select 1 from auth.users where id=p_user_id)then raise exception 'unauthorized';end if;
 else
  update film_private.sessions set last_seen_at=now() where user_id=p_user_id and hash=p_token_hash and revoked_at is null and expires_at>now();
  if not found then raise exception 'unauthorized';end if;
 end if;
end $$;
create function public.film_rotate_session(p_user_id uuid,p_token_hash text,p_new_hash text,p_operation_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s film_private.sessions;begin
 if p_new_hash!~'^[a-f0-9]{64}$' or p_new_hash=p_token_hash then raise exception 'invalid_hash';end if;
 select * into s from film_private.sessions where user_id=p_user_id and (hash=p_token_hash or previous_hash=p_token_hash) for update;
 if not found or s.revoked_at is not null or s.expires_at<=now()then raise exception 'unauthorized';end if;
 if s.hash=p_new_hash and s.previous_hash=p_token_hash and s.rotation_id=p_operation_id and s.retry_until>=now()then
  return jsonb_build_object('status','rotated','expiresAt',s.expires_at);
 end if;
 if s.hash<>p_token_hash then raise exception 'unauthorized';end if;
 update film_private.sessions set previous_hash=hash,hash=p_new_hash,rotation_id=p_operation_id,retry_until=now()+interval '60 seconds',expires_at=now()+interval '30 days' where id=s.id returning * into s;
 return jsonb_build_object('status','rotated','expiresAt',s.expires_at);
end $$;
create function public.film_list_sessions(p_user_id uuid,p_token_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;begin
 if p_token_hash is not null then raise exception 'unauthorized';end if;
 perform film_private.assert_principal(p_user_id,p_token_hash);
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'deviceName',p.device_name,'createdAt',s.created_at,'lastSeenAt',s.last_seen_at,'expiresAt',s.expires_at)order by s.created_at),'[]')into result
 from film_private.sessions s join film_private.pairings p on p.id=s.id where s.user_id=p_user_id and s.revoked_at is null and s.expires_at>now();
 return result;
end $$;
create function public.film_revoke_session(p_user_id uuid,p_token_hash text,p_session_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform film_private.assert_principal(p_user_id,p_token_hash);
 if p_token_hash is not null and not exists(select 1 from film_private.sessions where id=p_session_id and hash=p_token_hash)then raise exception 'unauthorized';end if;
 update film_private.sessions set revoked_at=now(),previous_hash=null,retry_until=null where id=p_session_id and user_id=p_user_id;
 if not found then raise exception 'not_found';end if;return jsonb_build_object('status','revoked');
end $$;

create function public.film_read_state(p_user_id uuid,p_token_hash text,p_bootstrap jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s jsonb;r film_private.account_sync;ids jsonb;begin
 perform film_private.assert_principal(p_user_id,p_token_hash);
 insert into film_private.account_sync(user_id)values(p_user_id)on conflict do nothing;
 select * into r from film_private.account_sync where user_id=p_user_id for update;
 if p_bootstrap is not null then
  if p_token_hash is not null then raise exception 'unauthorized';end if;
  insert into public.account_state(user_id,state)values(p_user_id,p_bootstrap)on conflict do nothing;
 end if;
 select state into s from public.account_state where user_id=p_user_id;
 -- Legacy/client bootstrap claims never confer verified StoreKit rights. Keep all other snapshot data.
 if s#>>'{account,subscription,source}'='appStore' then
  if not exists(select 1 from film_private.subscriptions v where v.owner_id=p_user_id and v.subscription->>'plan'=s#>>'{account,subscription,plan}' and v.subscription->'renews'=s#>'{account,subscription,renews}') then
   s:=jsonb_set(s,'{account,subscription}','null');
   update public.account_state set state=s where user_id=p_user_id;
   update film_private.account_sync set revision=revision+1 where user_id=p_user_id returning * into r;
  elsif (s#>>'{account,subscription,renews}')::double precision+978307200<=extract(epoch from now()) and coalesce(s#>>'{account,subscription,canceled}','false')<>'true' then
   s:=jsonb_set(s,'{account,subscription,canceled}','true');
   update public.account_state set state=s where user_id=p_user_id;
   update film_private.account_sync set revision=revision+1 where user_id=p_user_id returning * into r;
  end if;
 end if;
 select coalesce(jsonb_agg(operation_id),'[]')into ids from film_private.operations where user_id=p_user_id;
 return jsonb_build_object('state',coalesce(s,'{"profiles":[],"pendingRatings":[],"onboardingDone":false}'),'revision',r.revision,'metadata',r.metadata,'seen',ids);
end $$;
create function public.film_commit_state(p_user_id uuid,p_token_hash text,p_expected_revision bigint,p_revision bigint,p_state jsonb,p_metadata jsonb,p_operation_ids uuid[]) returns boolean
language plpgsql security definer set search_path='' as $$
declare r bigint;oldsub jsonb;newsub jsonb;begin
 perform film_private.assert_principal(p_user_id,p_token_hash);
 select revision into r from film_private.account_sync where user_id=p_user_id for update;
 if not found or r<>p_expected_revision then return false;end if;
 if p_revision<r or p_revision>r+cardinality(p_operation_ids)then raise exception 'invalid_revision';end if;
 select state#>'{account,subscription}' into oldsub from public.account_state where user_id=p_user_id;
 newsub:=p_state#>'{account,subscription}';
 if (oldsub->>'source'='appStore' or newsub->>'source'='appStore') and oldsub is distinct from newsub then raise exception 'unverified_subscription';end if;
 insert into public.account_state(user_id,state)values(p_user_id,p_state)on conflict(user_id)do update set state=excluded.state;
 update film_private.account_sync set revision=p_revision,metadata=p_metadata where user_id=p_user_id;
 insert into film_private.operations(user_id,operation_id)select p_user_id,unnest(p_operation_ids)on conflict do nothing;
 return true;
end $$;
-- Once a household uses the new mutation route, old snapshot upserts cannot erase concurrent edits.
create function film_private.block_legacy_write() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() in ('anon','authenticated') and exists(select 1 from film_private.account_sync where user_id=new.user_id and managed)then raise exception 'use_film_device_mutations';end if;
 return new;
end $$;
create trigger film_block_legacy_write before insert or update on public.account_state for each row execute function film_private.block_legacy_write();

create function film_private.job_json(j film_private.jobs) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_object('id',j.id,'kind',j.kind,'profileID',j.profile_id,'payload',j.payload,'result',j.result,'version',j.version,'status',j.status,'expiresAt',j.expires_at,'claimant',j.claimant)
$$;
create function film_private.assert_profile(p_user_id uuid,p_profile_id uuid) returns void
language plpgsql set search_path='' as $$
begin
 if p_profile_id is not null and not exists(select 1 from public.account_state a,jsonb_array_elements(a.state->'profiles')p where a.user_id=p_user_id and lower(p->>'id')=p_profile_id::text)then raise exception 'profile_not_found';end if;
end $$;
create function public.film_create_job(p_user_id uuid,p_token_hash text,p_kind text,p_profile_id uuid,p_payload jsonb,p_operation_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j film_private.jobs;begin
 perform film_private.assert_principal(p_user_id,p_token_hash);
 perform film_private.assert_profile(p_user_id,p_profile_id);
 if p_kind in ('import','taste','review') and p_profile_id is null then raise exception 'invalid_profile';end if;
 if octet_length(p_payload::text)>32000 then raise exception 'invalid_payload';end if;
 insert into film_private.jobs(user_id,kind,profile_id,payload,operation_id)values(p_user_id,p_kind,p_profile_id,p_payload,p_operation_id)on conflict(user_id,operation_id)do nothing;
 select * into j from film_private.jobs where user_id=p_user_id and operation_id=p_operation_id;
 return film_private.job_json(j);
end $$;
create function public.film_list_jobs(p_user_id uuid,p_token_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;begin
 perform film_private.assert_principal(p_user_id,p_token_hash);
 select coalesce(jsonb_agg(film_private.job_json(j)order by j.created_at),'[]')into result from film_private.jobs j where user_id=p_user_id and expires_at>now();return result;
end $$;
create function public.film_transition_job(p_user_id uuid,p_token_hash text,p_id uuid,p_version integer,p_action text,p_claimant text,p_result jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j film_private.jobs;begin
 perform film_private.assert_principal(p_user_id,p_token_hash);
 if p_action in ('claim','complete') and p_token_hash is not null then raise exception 'unauthorized';end if;
 -- Account revision lock serializes profile deletion with accepting a result.
 perform 1 from film_private.account_sync where user_id=p_user_id for update;
 select * into j from film_private.jobs where id=p_id and user_id=p_user_id for update;
 if not found then raise exception 'not_found';end if;
 if j.expires_at<=now()then raise exception 'job_expired';end if;
 perform film_private.assert_profile(p_user_id,j.profile_id);
 if j.version=p_version+1 and j.claimant=p_claimant and ((p_action='claim' and j.status='claimed')or(p_action='complete' and j.status='completed' and j.result=p_result))then return film_private.job_json(j);end if;
 if j.version<>p_version then raise exception 'job_conflict';end if;
 if p_action='claim' and j.status='pending' and length(p_claimant)between 7 and 106 then
  update film_private.jobs set status='claimed',claimant=p_claimant,version=version+1 where id=j.id returning * into j;
 elsif p_action='complete' and j.status='claimed' and j.claimant=p_claimant then
  if octet_length(p_result::text)>64000 then raise exception 'invalid_payload';end if;
  update film_private.jobs set status='completed',result=p_result,version=version+1 where id=j.id returning * into j;
 elsif p_action='cancel' and j.status in ('pending','claimed')then
  update film_private.jobs set status='cancelled',version=version+1 where id=j.id returning * into j;
 else raise exception 'job_conflict';end if;
 return film_private.job_json(j);
end $$;
create function public.film_complete_job(p_user_id uuid,p_token_hash text,p_id uuid,p_version integer,p_claimant text,p_result jsonb,p_expected_revision bigint,p_revision bigint,p_state jsonb,p_metadata jsonb,p_operation_ids uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j jsonb;job film_private.jobs;begin
 if p_token_hash is not null then raise exception 'unauthorized';end if;
 select * into job from film_private.jobs where id=p_id and user_id=p_user_id;
 if not found then raise exception 'not_found';end if;
 if job.profile_id is not null and exists(select 1 from jsonb_array_elements(p_result->'operations')op where lower(op->>'profileID') is distinct from job.profile_id::text)then raise exception 'invalid_job_scope';end if;
 -- All changes occur in this one RPC transaction. A CAS miss rolls the job back too.
 j:=public.film_transition_job(p_user_id,p_token_hash,p_id,p_version,'complete',p_claimant,p_result);
 if not public.film_commit_state(p_user_id,p_token_hash,p_expected_revision,p_revision,p_state,p_metadata,p_operation_ids) then raise exception 'revision_conflict';end if;
 return j||jsonb_build_object('state',p_state,'revision',p_revision);
end $$;
create function public.film_verify_subscription(p_user_id uuid,p_token_hash text,p_receipt jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v film_private.subscriptions;r film_private.account_sync;s jsonb;sub jsonb;env text;original_id text;purchase_at timestamptz;signed_at timestamptz;expires_at timestamptz;begin
 perform film_private.assert_principal(p_user_id,p_token_hash);
 env:=p_receipt->>'environment';original_id:=p_receipt->>'originalTransactionID';sub:=p_receipt->'subscription';
 purchase_at:=(p_receipt->>'purchaseAt')::timestamptz;signed_at:=(p_receipt->>'signedAt')::timestamptz;expires_at:=(p_receipt->>'expiresAt')::timestamptz;
 if env not in ('Sandbox','Production')or original_id!~'^\d{1,40}$'or p_receipt->>'transactionID'!~'^\d{1,40}$'or sub->>'source'<>'appStore'or sub->>'plan' not in ('solo','duo','familie')or signed_at>now()+interval '1 minute' then raise exception 'subscription_invalid';end if;
 if expires_at<=now()then raise exception 'subscription_expired';end if;
 insert into film_private.account_sync(user_id)values(p_user_id)on conflict do nothing;
 select * into r from film_private.account_sync where user_id=p_user_id for update;
 insert into film_private.subscriptions(environment,original_transaction_id,owner_id,transaction_id,purchase_at,signed_at,expires_at,subscription)
 values(env,original_id,p_user_id,p_receipt->>'transactionID',purchase_at,signed_at,expires_at,sub)on conflict do nothing;
 select * into v from film_private.subscriptions where environment=env and original_transaction_id=original_id for update;
 if v.owner_id is distinct from p_user_id then raise exception 'subscription_owner';end if;
 if v.purchase_at>purchase_at or v.signed_at>signed_at then raise exception 'subscription_stale';end if;
 select state into s from public.account_state where user_id=p_user_id for update;
 if s->'account' is null or s->'account'='null'::jsonb then raise exception 'account_not_found';end if;
 update film_private.subscriptions set transaction_id=p_receipt->>'transactionID',purchase_at=(p_receipt->>'purchaseAt')::timestamptz,signed_at=(p_receipt->>'signedAt')::timestamptz,expires_at=(p_receipt->>'expiresAt')::timestamptz,subscription=sub where environment=env and original_transaction_id=original_id;
 if s#>'{account,subscription}' is distinct from sub then
  s:=jsonb_set(s,'{account,subscription}',sub);
  update public.account_state set state=s where user_id=p_user_id;
  update film_private.account_sync set revision=revision+1 where user_id=p_user_id returning * into r;
 end if;
 return jsonb_build_object('state',s,'revision',r.revision);
end $$;
-- A default PUBLIC execute privilege would expose service-only principal arguments.
-- Revoke every new function individually; preserve pre-existing RPC privileges.
do $$ declare f record;begin
 for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where (n.nspname='public' and p.proname like 'film\_%' escape '\')or n.nspname='film_private' loop
  execute format('revoke all on function %s from public, anon, authenticated',f.sig);
  if f.sig::text like 'film_%' or f.sig::text like 'public.film_%' then execute format('grant execute on function %s to service_role',f.sig);end if;
 end loop;
end $$;
commit;
