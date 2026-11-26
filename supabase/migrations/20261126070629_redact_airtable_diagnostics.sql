begin;

-- Keep provider and database error details on the server.
create or replace function private.airtable_error_code(p_error text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_error is null then null
    when split_part(p_error, ':', 1) in (
      'airtable_token_rejected', 'no_airtable_token', 'airtable_not_found',
      'airtable_limit', 'airtable_budget', 'airtable_empty', 'airtable_too_many_pages'
    ) then split_part(p_error, ':', 1)
    else 'airtable_sync_failed' end;
$$;
revoke all on function private.airtable_error_code(text) from public, anon, authenticated;

-- Older templates may have stored editor names in their status table. Keep
-- headers and data aligned while omitting the column from the response.
create or replace function private.ai_summary_public_blocks(p_blocks jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(
    case when b.block->>'kind' = 'table'
               and jsonb_typeof(b.block->'columns') = 'array'
               and jsonb_typeof(b.block->'rows') = 'array'
               and exists (select 1 from jsonb_array_elements_text(b.block->'columns') title
                           where lower(trim(title)) = 'changed by')
      then b.block || jsonb_build_object(
        'columns', (select coalesce(jsonb_agg(c.title order by c.i), '[]'::jsonb)
                    from jsonb_array_elements_text(b.block->'columns') with ordinality c(title,i)
                    where lower(trim(c.title)) <> 'changed by'),
        'rows', (select coalesce(jsonb_agg(
          case when jsonb_typeof(r.cells) = 'array' then
            (select coalesce(jsonb_agg(v.cell order by v.i), '[]'::jsonb)
             from jsonb_array_elements(r.cells) with ordinality v(cell,i)
             where lower(trim(b.block->'columns'->>((v.i-1)::int))) is distinct from 'changed by')
          else r.cells end order by r.i), '[]'::jsonb)
          from jsonb_array_elements(b.block->'rows') with ordinality r(cells,i)))
      else b.block end order by b.i), '[]'::jsonb)
  from jsonb_array_elements(
    case when jsonb_typeof(p_blocks) = 'array' then p_blocks else '[]'::jsonb end
  ) with ordinality b(block,i);
$$;
revoke all on function private.ai_summary_public_blocks(jsonb) from public, anon, authenticated;

create or replace function private.ai_summary_public_content(p_content jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select case when p_content#>>'{template,version}' = '1' then
    p_content || jsonb_build_object('template', (p_content->'template') || jsonb_build_object(
      'quick', private.ai_summary_public_blocks(p_content#>'{template,quick}'),
      'detailed', private.ai_summary_public_blocks(p_content#>'{template,detailed}')))
  else p_content end;
$$;
revoke all on function private.ai_summary_public_content(jsonb) from public, anon, authenticated;

create or replace function public.airtable_status(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s private.airtable_state;
  b jsonb := private.airtable_budget();
begin
  perform private.token_role(p_token);
  select * into s from private.airtable_state where id = 1;
  return jsonb_build_object(
    'enabled', coalesce((select enabled from private.airtable_config where id = 1), false),
    'last_ok_at', s.last_ok_at,
    'last_full_at', s.last_full_at,
    'last_run_at', s.last_run_at,
    'last_result', (select jsonb_object_agg(k, s.last_result->k)
      from unnest(array['added','changed','removed','total','calls','pages']) as fields(k)
      where jsonb_typeof(s.last_result->k) = 'number'),
    'last_error', private.airtable_error_code(s.last_error),
    'last_error_at', s.last_error_at,
    'calls_this_month', private.airtable_calls_this_month(),
    'limit', (b->>'limit')::int,
    'slow_at', (b->>'slow')::int,
    'stop_at', (b->>'stop_changes')::int,
    'manual_stop_at', (b->>'stop_manual')::int);
end $$;

create or replace function public.airtable_sync_now(p_token text, p_full boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r text := private.token_role(p_token);
  b jsonb := private.airtable_budget();
  result jsonb;
begin
  if r not in ('admin', 'admin_team') or (p_full and r <> 'admin') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if private.airtable_calls_this_month() >= (b->>'stop_manual')::int then
    raise exception 'airtable_budget' using errcode = 'P0001';
  end if;
  if r='admin' and (p_full or exists (
      select 1 from private.airtable_config where id=1
        and not (fields ?& array['status_editor','status_edited_at']))) then
    begin
      perform private.airtable_refresh_status_fields();
    exception when others then
      -- Metadata is optional. A metadata outage must never prevent a sync.
      null;
    end;
  end if;
  result := private.airtable_run(case when p_full then 'full' else 'changes' end,
                                 'Airtable (Sync now)');
  if result ? 'error' then
    return jsonb_build_object('error', private.airtable_error_code(result->>'error'));
  end if;
  return result;
end $$;

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
   (select summary_date,generated_at,cutoff_at,model,private.ai_summary_public_content(content) as content,
    case when content#>>'{template,version}' = '1' then null
    else jsonb_build_object(
      'weekly_tracker', input_snapshot->'weekly_tracker',
      'revenue', input_snapshot->'revenue',
      'applications', input_snapshot->'applications',
      'staff', input_snapshot->'staff'
    ) end as input_snapshot
    from private.ai_summaries
    where status='ready' order by summary_date desc limit 30) s),'[]'::jsonb)) into result from private.ai_summary_config c;
 return result;
end $$;

commit;
