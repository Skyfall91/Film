-- Read-only review before any staging migration. Keep this output private:
-- it contains schema and access rules, never account JSON or secrets.
select version();
select column_name,data_type,is_nullable from information_schema.columns
 where table_schema='public' and table_name='account_state' order by ordinal_position;
select relrowsecurity,relforcerowsecurity from pg_class where oid=to_regclass('public.account_state');
select policyname,roles,cmd,qual,with_check from pg_policies
 where schemaname='public' and tablename='account_state';
select conname,pg_get_constraintdef(oid) from pg_constraint
 where conrelid=to_regclass('public.account_state');
select trigger_name,action_statement from information_schema.triggers
 where event_object_schema='public' and event_object_table='account_state';
select routine_name,security_type from information_schema.routines
 where routine_schema='public' and routine_name='delete_own_account';
select table_schema,table_name,grantee,privilege_type from information_schema.table_privileges
 where table_schema='public' and table_name='account_state';
-- Snapshot format counts only. No email, credential or profile contents are emitted.
select count(*) as households,
 count(*) filter(where jsonb_typeof(state::jsonb->'profiles')='array') as profile_snapshots,
 count(*) filter(where coalesce(state::jsonb#>>'{account,passwordHash}','')<>'') as local_hashes_to_strip,
 count(*) filter(where coalesce(state::jsonb#>>'{account,salt}','')<>'') as local_salts_to_strip
from public.account_state;
