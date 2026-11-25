begin;

-- The database dispatch URL is deployment configuration, stored in Vault.
create or replace function private.ai_summary_dispatch_url() returns text
language plpgsql stable security invoker set search_path = '' as $$
declare endpoint text;
begin
  select decrypted_secret into endpoint
  from vault.decrypted_secrets where name = 'ai_summary_dispatch_url';
  if endpoint is null or endpoint !~ '^https://[A-Za-z0-9.-]+/functions/v1/daily-ai-summary$' then
    raise exception 'job_not_configured';
  end if;
  return endpoint;
end $$;
revoke all on function private.ai_summary_dispatch_url() from public, anon, authenticated;

create or replace function private.ai_summary_dispatch() returns void
language plpgsql security definer set search_path='' as $$
declare secret text;
begin
 if not exists(select 1 from private.ai_summary_config where enabled and key_id is not null) then return; end if;
 select v.decrypted_secret into secret from private.ai_summary_config c join vault.decrypted_secrets v on v.id=c.job_key_id;
 perform net.http_post(url:=private.ai_summary_dispatch_url(),
 headers:=jsonb_build_object('Content-Type','application/json','x-summary-job-token',secret),body:='{}'::jsonb,timeout_milliseconds:=180000);
end $$;

create or replace function public.ai_summary_generate(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.ai_summary_config; job uuid; secret text;
begin
 if private.token_role(p_token) is distinct from 'admin' then raise exception 'admin_required' using errcode='42501'; end if;
 select * into c from private.ai_summary_config for update;
 if c.key_id is null then raise exception 'gemini_key_required'; end if;
 select id into job from private.ai_summary_jobs where status in ('queued','running') and lease_until>now() limit 1;
 if job is not null then return jsonb_build_object('status','running','job_id',job); end if;
 select decrypted_secret into secret from vault.decrypted_secrets where id=c.job_key_id;
 if secret is null then raise exception 'job_not_configured'; end if;
 if not exists(select 1 from vault.decrypted_secrets where id=c.key_id) then raise exception 'gemini_key_required'; end if;
 insert into private.ai_summary_jobs(summary_date,source,requested_by,lease_until,status)
 values(private.today(),'manual',private.token_user(p_token),now()+interval '4 minutes','queued') returning id into job;
 perform net.http_post(url:=private.ai_summary_dispatch_url(),
 headers:=jsonb_build_object('Content-Type','application/json','x-summary-job-token',secret),
 body:=jsonb_build_object('manual_job_id',job),timeout_milliseconds:=180000);
 return jsonb_build_object('status','queued','job_id',job);
end $$;


-- Check the account's current ACL on every protected API call.
create function private.require_page(p_token text, p_page text)
returns void language plpgsql security invoker set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
begin
  if exists (
    select 1 from private.app_users
    where id = me and pages is not null and not (p_page = any(pages))
  ) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
end $$;
revoke all on function private.require_page(text, text) from public, anon, authenticated;

-- Keep the existing signatures, arguments, privileges and implementations.
-- A missing function or an unexpected definition aborts the migration.
do $$
declare
  api record;
  definition text;
  guarded text;
begin
  for api in select * from (values
    ('public.reports_meta(text)', 'dailyReports'),
    ('public.report_start(text)', 'dailyReports'),
    ('public.report_list(text,jsonb)', 'dailyReports'),
    ('public.report_summary(text,date,date,bigint,bigint)', 'dailyReports'),
    ('public.report_save(text,jsonb)', 'dailyReports'),
    ('public.report_delete(text,bigint)', 'dailyReports'),
    ('public.report_history(text,bigint)', 'dailyReports'),
    ('public.report_comments(text,bigint)', 'dailyReports'),
    ('public.report_comment_add(text,bigint,text)', 'dailyReports'),
    ('public.report_comment_delete(text,bigint)', 'dailyReports'),
    ('public.report_withdraw(text,bigint)', 'dailyReports'),
    ('public.report_review(text,bigint,text,text)', 'dailyReports'),
    ('public.report_badge(text)', 'dailyReports'),
    ('public.report_notifications(text)', 'dailyReports'),
    ('public.report_notifications_read(text,bigint[])', 'dailyReports'),
    ('public.todo_list(text)', 'todo'),
    ('public.todo_people(text)', 'todo'),
    ('public.todo_save(text,jsonb)', 'todo'),
    ('public.todo_give(text,bigint,jsonb)', 'todo')
  ) as list(signature, page)
  loop
    definition := pg_get_functiondef(api.signature::regprocedure);
    guarded := regexp_replace(definition, E'\nbegin\\M',
      E'\nbegin\n  perform private.require_page(p_token, ' || quote_literal(api.page) || ');', 'i');
    if guarded = definition then
      raise exception 'Page check could not be installed for %', api.signature;
    end if;
    execute guarded;
  end loop;
end $$;

revoke all on function public.report_withdraw(text, bigint) from public;
grant execute on function public.report_withdraw(text, bigint) to anon, authenticated;


create or replace function public.admin_set_user_pages(
  p_token text, p_user_id bigint, p_pages text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v text[];
begin
  perform private.check_token(p_token);
  if not exists (select 1 from private.app_users where id = p_user_id) then
    raise exception 'unknown_user' using errcode = '22023';
  end if;
  if p_pages is not null then
    select coalesce(array_agg(distinct p order by p), '{}') into v
      from unnest(p_pages) p
      where p in ('home', 'dailyReports', 'week', 'revenue', 'applications',
                  'history', 'staff', 'reports', 'settings', 'todo');
  end if;
  update private.app_users
    set pages = v, updated_at = now()
    where id = p_user_id;
  return private.user_json(p_user_id);
end $$;

-- Locked, inactive and unknown accounts receive the same generic error.
-- Perform one bcrypt operation for every attempt and serialize failed counters.
create or replace function public.user_login(p_username text, p_password text, p_remember boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u private.app_users;
  password_hash text;
  candidate text;
  tries integer;
  eligible boolean;
begin
  select * into u from private.app_users
  where username = lower(trim(left(coalesce(p_username, ''), 256)))
  for update;
  eligible := u.id is not null and u.active and
    (u.locked_until is null or u.locked_until <= now());
  password_hash := case when eligible then u.hash else extensions.gen_salt('bf', 10) end;
  candidate := extensions.crypt(left(coalesce(p_password, ''), 1024), password_hash);
  if not eligible then
    return jsonb_build_object('error', 'wrong_password');
  end if;
  if candidate is distinct from u.hash then
    tries := u.failed_attempts + 1;
    update private.app_users
      set failed_attempts = case when tries >= 5 then 0 else tries end,
          locked_until = case when tries >= 5 then now() + interval '15 minutes' end
      where id = u.id;
    return jsonb_build_object('error', 'wrong_password');
  end if;
  update private.app_users
    set failed_attempts = 0, locked_until = null, last_sign_in = now()
    where id = u.id;
  return jsonb_build_object('token', private.new_user_token(u.id, p_remember),
                            'user', private.user_json(u.id));
end $$;


create or replace function private.upsert_rows(p_table text, p_pk text, p_rows jsonb)
returns void language plpgsql security definer set search_path = '' set timezone = 'Africa/Nairobi' as $$
declare
  sets text;
  newer text := '';
  clock_limit timestamptz := now() + interval '5 minutes';
  stamp text;
begin
  if p_rows is null or jsonb_array_length(p_rows) = 0 then return; end if;
  foreach stamp in array array['updated_at', 'changed_at', 'imported_at'] loop
    select jsonb_agg(case
      when case when pg_input_is_valid(v->>stamp, 'timestamp with time zone')
        then (v->>stamp)::timestamptz > clock_limit else false end
      then jsonb_set(v, array[stamp], to_jsonb(to_char(clock_limit, 'YYYY-MM-DD"T"HH24:MI:SS.US')))
      else v end)
    into p_rows from jsonb_array_elements(p_rows) v;
  end loop;
  if p_table in ('count_changes', 'application_changes', 'revenue_changes') then
    execute format(
      'insert into public.%I select * from jsonb_populate_recordset(null::public.%I, $1) '
      'on conflict (%I) do nothing', p_table, p_table, p_pk) using p_rows;
    return;
  end if;
  select string_agg(format('%I = excluded.%I', column_name, column_name), ', ')
    into sets
    from information_schema.columns
    where table_schema = 'public' and table_name = p_table
      and column_name <> p_pk;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = p_table
               and column_name = 'updated_at') then
    newer := ' where case when pg_input_is_valid(excluded.updated_at, ''timestamp with time zone'') then '
      'not pg_input_is_valid(t.updated_at, ''timestamp with time zone'') or '
      'case when pg_input_is_valid(t.updated_at, ''timestamp with time zone'') then '
      'excluded.updated_at::timestamptz >= t.updated_at::timestamptz '
      'or t.updated_at::timestamptz > now() + interval ''5 minutes'' end else false end';
  end if;
  execute format(
    'insert into public.%I as t select * from jsonb_populate_recordset(null::public.%I, $1) '
    'on conflict (%I) do update set %s%s',
    p_table, p_table, p_pk, sets, newer) using p_rows;
end $$;

create or replace function public.sync_push(p_token text, p_payload jsonb)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  tables text[] := array['staff','weeks','work_days','client_counts',
    'staff_day_off','day_notes','app_settings','count_changes',
    'revenue_entries','revenue_changes',
    'applications','application_imports','application_changes'];
  pks text[] := array['id','id','id','id','id','day_id','key','id','id','id',
    'id','id','id'];
  r text := private.token_role(p_token);
  pg text[] := private.token_pages(p_token);
  i int;
  payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if r not in ('admin', 'admin_team') then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if r = 'admin_team' and (
    exists (
      select 1 from unnest(array['revenue_entries', 'revenue_changes', 'app_settings']) t
      where jsonb_array_length(coalesce(payload->'upserts'->t, '[]')) > 0
         or jsonb_array_length(coalesce(payload->'deletes'->t, '[]')) > 0
    ) or exists (
      select 1 from unnest(array['count_changes', 'application_changes', 'application_imports']) t
      where jsonb_array_length(coalesce(payload->'deletes'->t, '[]')) > 0
    )
  ) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  for i in 1..array_length(tables, 1) loop
    if not private.may_sync(pg, tables[i]) and (
         jsonb_array_length(coalesce(payload->'upserts'->tables[i], '[]')) > 0 or
         jsonb_array_length(coalesce(payload->'deletes'->tables[i], '[]')) > 0) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
  end loop;
  payload := private.canonical_ids(payload);
  for i in reverse array_length(tables, 1)..1 loop
    perform private.delete_rows(tables[i], pks[i], payload->'deletes'->tables[i]);
  end loop;
  for i in 1..array_length(tables, 1) loop
    perform private.upsert_rows(tables[i], pks[i], payload->'upserts'->tables[i]);
  end loop;
  return now();
end $$;

create or replace function public.todo_sync(p_token text, p_items jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me bigint := private.token_user(p_token);
  v_dept bigint;
  n int;
  v_added int;
  v_team_count int;
begin
  perform private.require_page(p_token, 'todo');
  select department_id into v_dept from private.app_users where id = me;
  if p_items is null then p_items := '[]'::jsonb; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items where user_id = me and not deleted;
  select count(*) filter (where not coalesce((i->>'deleted')::boolean, false) and t.id is null)
       - count(*) filter (where coalesce((i->>'deleted')::boolean, false) and t.id is not null)
    into v_added
    from jsonb_array_elements(p_items) i
    left join public.todo_items t
      on t.user_id = me and t.id = (i->>'id')::bigint and not t.deleted
   where not coalesce((i->>'team')::boolean, false);
  if v_added > 0 and n + v_added > 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at, extra)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes'),
         private.todo_extra(i->'extra')
    from jsonb_array_elements(p_items) i
   where not coalesce((i->>'team')::boolean, false)
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at,
        extra = excluded.extra
    where excluded.changed_at >= t.changed_at;

  if v_dept is not null and exists (
    select 1 from jsonb_array_elements(p_items) i
    where coalesce((i->>'team')::boolean, false)
  ) then
    -- Serialize additions within a department, including from different users.
    perform 1 from public.departments where id = v_dept for update;
    select count(*) into v_team_count from public.todo_team_items
      where department_id = v_dept and not deleted;
    insert into public.todo_team_items as t
        (department_id, id, title, done, done_at, deleted, changed_at,
         changed_by, extra)
    select v_dept,
           (i->>'id')::bigint,
           left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
           coalesce((i->>'done')::boolean, false),
           (i->>'done_at')::timestamptz,
           coalesce((i->>'deleted')::boolean, false),
           least(coalesce((i->>'changed_at')::timestamptz, now()),
                 now() + interval '5 minutes'),
           me,
           private.todo_extra(i->'extra')
      from jsonb_array_elements(p_items) i
     where coalesce((i->>'team')::boolean, false)
       and jsonb_typeof(i->'dept') = 'number'
       and (i->>'dept')::bigint = v_dept
    on conflict (department_id, id) do update
      set title = excluded.title,
          done = excluded.done,
          done_at = excluded.done_at,
          deleted = excluded.deleted,
          changed_at = excluded.changed_at,
          changed_by = excluded.changed_by,
          extra = excluded.extra
      where excluded.changed_at >= t.changed_at;
    if (select count(*) from public.todo_team_items
        where department_id = v_dept and not deleted) > greatest(3000, v_team_count) then
      raise exception 'too_many_items' using errcode = '22023';
    end if;
  end if;

  update public.todo_items t
     set done = true,
         done_at = coalesce(t.done_at, now()),
         changed_at = now(),
         extra = t.extra || '{"auto_ticked": true}'::jsonb
    from public.activity_reports r
   where t.user_id = me and not t.done and not t.deleted
     and not (t.extra ? 'auto_ticked')
     and r.id = t.sent_id and r.user_id = me
     and r.status = 'done' and r.review in ('submitted', 'approved');

  delete from public.todo_items
   where user_id = me and (
     (deleted and changed_at < now() - interval '30 days') or
     (done and coalesce((extra->>'archived')::boolean, false)
      and done_at < now() - interval '90 days'));
  if v_dept is not null then
    delete from public.todo_team_items
     where department_id = v_dept and (
       (deleted and changed_at < now() - interval '30 days') or
       (done and done_at < now() - interval '90 days'));
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', t.id, 'title', t.title, 'done', t.done, 'done_at', t.done_at,
          'sent_id', t.sent_id, 'changed_at', t.changed_at, 'extra', t.extra,
          'report_review', r.review, 'report_status', r.status)
        order by t.id)
      from public.todo_items t
      left join public.activity_reports r
        on r.id = t.sent_id and r.user_id = me
      where t.user_id = me and not t.deleted), '[]'::jsonb),
    'team', case when v_dept is null then null else jsonb_build_object(
      'id', v_dept,
      'name', (select d.name from public.departments d where d.id = v_dept),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', t.id, 'title', t.title, 'done', t.done,
            'done_at', t.done_at, 'changed_at', t.changed_at,
            'extra', t.extra, 'team', true, 'dept', v_dept,
            'changed_by_name', u.full_name)
          order by t.id)
        from public.todo_team_items t
        left join private.app_users u on u.id = t.changed_by
        where t.department_id = v_dept and not t.deleted), '[]'::jsonb))
    end);
end $$;

create or replace function public.report_error(p_token text, p_report jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  msg text := left(coalesce(p_report ->> 'message', ''), 2000);
  stk text := left(coalesce(p_report ->> 'stack', ''), 8000);
  ver text := left(coalesce(p_report ->> 'version', ''), 40);
  fp text;
  v_who text := '';

begin
  if msg = '' then return; end if;
  begin
    if p_token is not null then
      perform private.token_role(p_token);
      v_who := coalesce(current_setting('app.actor', true), '');
    end if;
  exception when others then v_who := '';
  end;
  -- Accept shared diagnostics only from authenticated sessions.
  if v_who = '' then return; end if;
  perform pg_advisory_xact_lock(157050401);
  fp := encode(extensions.digest(msg || '|' || left(stk, 600) || '|' || ver, 'sha256'), 'hex');
  update private.error_reports
    set count = error_reports.count + 1, last_seen = now(),
        who = coalesce(nullif(v_who, ''), error_reports.who)
    where fingerprint = fp;
  if found then return; end if;
  if (select count(*) from private.error_reports
      where who <> '' and first_seen > now() - interval '1 day') >= 300 then
    return;
  end if;
  insert into private.error_reports (fingerprint, message, stack, app_version,
                                     platform, who)
  values (fp, msg, stk, ver,
          left(coalesce(p_report ->> 'platform', ''), 40), v_who);
end $$;

create or replace function public.admin_restore_online(p_token text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' set statement_timeout = '30s' as $$
declare
  n_dept int; n_rep int; n_chg int; n_com int; n_todo int; n_team int;
begin
  perform private.check_token(p_token);
  if p_data is null or jsonb_typeof(p_data) <> 'object'
     or pg_column_size(p_data) > 8 * 1024 * 1024 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_data->'departments', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'activity_reports', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'activity_changes', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'report_comments', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'todo_items', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_data->'todo_team_items', '[]')) <> 'array'
     or jsonb_array_length(coalesce(p_data->'departments', '[]')) > 1000
     or jsonb_array_length(coalesce(p_data->'activity_reports', '[]')) > 25000
     or jsonb_array_length(coalesce(p_data->'activity_changes', '[]')) > 100000
     or jsonb_array_length(coalesce(p_data->'report_comments', '[]')) > 25000
     or jsonb_array_length(coalesce(p_data->'todo_items', '[]')) > 25000
     or jsonb_array_length(coalesce(p_data->'todo_team_items', '[]')) > 25000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.departments overriding system value
    select * from jsonb_populate_recordset(null::public.departments,
                                           coalesce(p_data->'departments', '[]'))
    on conflict (id) do nothing;
  get diagnostics n_dept = row_count;

  insert into public.activity_reports overriding system value
    select (jsonb_populate_record(null::public.activity_reports,
             x || jsonb_build_object(
               'assigned_by', private.known_user(x->'assigned_by'),
               'reviewed_by', private.known_user(x->'reviewed_by')))).*
    from jsonb_array_elements(coalesce(p_data->'activity_reports', '[]')) x
    where exists (select 1 from private.app_users u where u.id = (x->>'user_id')::bigint)
      and (x->>'department_id' is null
           or exists (select 1 from public.departments d where d.id = (x->>'department_id')::bigint))
    on conflict (id) do nothing;
  get diagnostics n_rep = row_count;

  -- History rows keep their ids so a restore is faithful; only an admin
  -- can restore, and existing rows are never replaced.
  insert into public.activity_changes overriding system value
    select (jsonb_populate_record(null::public.activity_changes,
             x || jsonb_build_object('changed_by', private.known_user(x->'changed_by')))).*
    from jsonb_array_elements(coalesce(p_data->'activity_changes', '[]')) x
    where exists (select 1 from public.activity_reports r where r.id = (x->>'report_id')::bigint)
    on conflict (id) do nothing;
  get diagnostics n_chg = row_count;

  insert into public.report_comments overriding system value
    select (jsonb_populate_record(null::public.report_comments,
             x || jsonb_build_object('user_id', private.known_user(x->'user_id')))).*
    from jsonb_array_elements(coalesce(p_data->'report_comments', '[]')) x
    where exists (select 1 from public.activity_reports r where r.id = (x->>'report_id')::bigint)
    on conflict (id) do nothing;
  get diagnostics n_com = row_count;

  insert into public.todo_items
    select (jsonb_populate_record(null::public.todo_items,
             x || jsonb_build_object('extra', private.todo_extra(x->'extra')))).*
    from jsonb_array_elements(coalesce(p_data->'todo_items', '[]')) x
    where exists (select 1 from private.app_users u where u.id = (x->>'user_id')::bigint)
    on conflict (user_id, id) do nothing;
  get diagnostics n_todo = row_count;

  insert into public.todo_team_items
    select (jsonb_populate_record(null::public.todo_team_items,
             x || jsonb_build_object(
               'changed_by', private.known_user(x->'changed_by'),
               'extra', private.todo_extra(x->'extra')))).*
    from jsonb_array_elements(coalesce(p_data->'todo_team_items', '[]')) x
    where exists (select 1 from public.departments d where d.id = (x->>'department_id')::bigint)
    on conflict (department_id, id) do nothing;
  get diagnostics n_team = row_count;

  -- The same limit todo_sync keeps.
  if exists (select 1 from public.todo_items group by user_id having count(*) > 3000)
     or exists (select 1 from public.todo_team_items group by department_id
                having count(*) > 3000) then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  perform setval(pg_get_serial_sequence('public.departments', 'id'),
                 greatest(coalesce((select max(id) from public.departments), 0), 1));
  perform setval(pg_get_serial_sequence('public.activity_reports', 'id'),
                 greatest(coalesce((select max(id) from public.activity_reports), 0), 1));
  perform setval(pg_get_serial_sequence('public.activity_changes', 'id'),
                 greatest(coalesce((select max(id) from public.activity_changes), 0), 1));
  perform setval(pg_get_serial_sequence('public.report_comments', 'id'),
                 greatest(coalesce((select max(id) from public.report_comments), 0), 1));
  return jsonb_build_object('departments', n_dept, 'reports', n_rep,
                            'changes', n_chg, 'comments', n_com,
                            'todos', n_todo, 'team_todos', n_team);
end $$;

-- Preserve explicit AI assignments. An additional restricted page list must
-- permit all underlying report sections before the full document is returned.
create or replace function public.ai_summary_access(p_token text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  role text := private.token_role(p_token);
  allowed text[] := private.token_pages(p_token);
begin
  if role = 'admin' then return true; end if;
  if allowed is not null and not (
    role = 'director' and allowed @> array['revenue', 'applications', 'staff', 'dailyReports', 'todo']
    and allowed && array['home', 'week', 'reports', 'history']
  ) then return false; end if;
  return exists (
    select 1 from private.ai_summary_access where user_id = private.token_user(p_token)
  );
end $$;

drop function public.ai_summary_claim(text, uuid);


create or replace function public.ai_summary_read(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; job private.ai_summary_jobs; state text; failure text;
begin
 if not public.ai_summary_access(p_token) then raise exception 'access_denied' using errcode='42501'; end if;
 select * into job from private.ai_summary_jobs where summary_date=private.today()
  or (status in ('queued','running') and lease_until>now())
 order by (status in ('queued','running') and lease_until>now()) desc,created_at desc,id desc limit 1;
 state:=case when job.status in ('queued','running') and job.lease_until<=now() then 'failed' else job.status end;
 if state is null then select status into state from private.ai_summaries where summary_date=private.today(); end if;
 failure:=case
  when job.error_code in ('gemini_http_503','gemini_http_500','gemini_http_502','gemini_http_504','gemini_temporarily_unavailable') then 'Gemini is temporarily busy. Please try generating the report again shortly.'
  when job.error_code in ('gemini_http_429','gemini_quota_exceeded') then 'Gemini quota or rate limit reached. Check your Google AI Studio usage and try again later.'
  when job.error_code in ('gemini_http_401','gemini_http_403','gemini_key_rejected') then 'Gemini rejected access. Admin should check the API key and its project permissions in Settings.'
  when job.error_code in ('gemini_http_404','gemini_model_unavailable') then 'The selected Gemini model is unavailable for this key. Admin can choose an available model in Settings.'
  when job.error_code='gemini_timeout' or (job.status in ('queued','running') and job.lease_until<=now()) then 'The report request timed out. Please try generating it again.'
  when job.error_code='gemini_request_invalid' then 'Gemini could not accept the report request. Check the selected model or contact Admin.'
  when job.error_code in ('gemini_incomplete','gemini_invalid_report') then 'Gemini returned an incomplete report. Please try generating it again.'
  else 'The report could not be generated. Please try again or contact Admin.' end;
 select jsonb_build_object('error_message',case when state='failed' then failure else null end,'enabled',c.enabled,'configured',c.key_id is not null,
  'can_generate',private.token_role(p_token)='admin','today',private.today(),'status',coalesce(state,'waiting'),
  'summaries',coalesce((select jsonb_agg(to_jsonb(s) order by s.summary_date desc) from
   (select summary_date,generated_at,cutoff_at,model,content,
    case when content#>>'{template,version}' = '1' then null
    else jsonb_build_object(
      'weekly_tracker', input_snapshot->'weekly_tracker',
      'revenue', input_snapshot->'revenue',
      'applications', input_snapshot->'applications',
      'daily_reports', input_snapshot->'daily_reports',
      'team_todo', input_snapshot->'team_todo',
      'staff', input_snapshot->'staff'
    ) end as input_snapshot
    from private.ai_summaries
    where status='ready' order by summary_date desc limit 30) s),'[]'::jsonb)) into result from private.ai_summary_config c;
 return result;
end $$;

create or replace function private.audit_clean(p jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select case when p is null then null else (
    select coalesce(jsonb_object_agg(k, v), '{}')
    from jsonb_each(p) as e(k, v)
    where k !~* '(password|hash|secret|token|salt|(^|_)key_id$)'
  ) end;
$$;

create or replace function private.audit_row()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then private.audit_clean(to_jsonb(old)) end;
  n jsonb := case when tg_op <> 'DELETE' then private.audit_clean(to_jsonb(new)) end;
  keys text[];
  pk text;
begin
  if tg_op = 'UPDATE' then
    -- Re-uploads write rows unchanged: nothing to note.
    select array_agg(k order by k) into keys
      from jsonb_object_keys(n) k
      -- Sign-ins and lock-outs aren't edits.
      where k not in ('updated_at', 'last_login', 'last_seen', 'last_sign_in',
                      'failed_logins', 'failed_attempts', 'tries',
                      'locked_until')
        and (o -> k) is distinct from (n -> k);
    if keys is null then return null; end if;
  end if;
  pk := coalesce(n, o) ->> case tg_table_name
    when 'app_settings' then 'key'
    when 'day_notes' then 'day_id'
    when 'ai_summary_access' then 'user_id'
    else 'id' end;
  insert into private.audit_log (actor, actor_id, action, table_name,
                                 record_id, changed, old_row, new_row)
  values (
    coalesce(nullif(current_setting('app.actor', true), ''), 'System'),
    nullif(current_setting('app.actor_id', true), '')::bigint,
    case tg_op when 'INSERT' then 'added' when 'UPDATE' then 'changed'
               else 'deleted' end,
    tg_table_name, pk, coalesce(keys, '{}'), o, n);
  return null;
end $$;

alter table private.ai_summary_config enable row level security;
do $$
declare item record;
begin
  for item in select * from (values
    ('public', 'client_counts'), ('public', 'applications'),
    ('public', 'application_imports'), ('public', 'todo_items'),
    ('public', 'todo_team_items'), ('private', 'ai_summary_config'),
    ('private', 'ai_summary_access')
  ) as audited(schema_name, table_name)
  loop
    execute format('create trigger audit_row after insert or update or delete on %I.%I '
      'for each row execute function private.audit_row()', item.schema_name, item.table_name);
  end loop;
end $$;

commit;
