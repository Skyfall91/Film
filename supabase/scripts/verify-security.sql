-- Run after migration in the isolated staging project. Raises on an exposed RPC.
do $$
declare p record;begin
 for p in select pr.oid,pr.proname from pg_proc pr join pg_namespace n on n.oid=pr.pronamespace
  where n.nspname='public' and pr.proname like 'film\_%' escape '\' loop
  if has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')then
   raise exception 'exposed film RPC: %',p.proname;
  end if;
  if not has_function_privilege('service_role',p.oid,'execute')then raise exception 'service RPC inaccessible: %',p.proname;end if;
 end loop;
 if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='film_private' and c.relkind='r' and not c.relrowsecurity)then raise exception 'missing private RLS';end if;
 if has_schema_privilege('anon','film_private','usage') or has_schema_privilege('authenticated','film_private','usage')then raise exception 'exposed private schema';end if;
end $$;
select 'device RPC and private table privileges verified' as result;
