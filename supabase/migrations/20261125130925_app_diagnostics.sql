-- Report only operational metadata from the job tables. Keep raw provider
-- messages, request bodies, account identifiers and report data private.
create or replace function public.admin_diagnostics(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if private.token_role(p_token) is distinct from 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;

  with report_jobs as (
    select summary_date, created_at, status, lease_until, source, error_code, cutoff_at, run_id
    from private.ai_summary_jobs
    where summary_date >= private.today() - 7
    order by summary_date desc, created_at desc
    limit 60
  ), events as (
    select j.created_at as at, 'ai_report' as operation,
      case when j.status in ('queued', 'running') and j.lease_until <= now()
        then 'expired' else j.status end as status,
      j.source as mode,
      case when j.error_code in (
        'admin_required', 'generation_failed', 'gemini_timeout',
        'gemini_incomplete', 'gemini_invalid_report', 'gemini_quota_exceeded',
        'gemini_key_rejected', 'gemini_model_unavailable', 'gemini_request_invalid',
        'gemini_temporarily_unavailable'
      ) then j.error_code when j.error_code is not null then 'other' end as code,
      case when j.cutoff_at is not null and s.generated_at is not null
        then round(extract(epoch from (s.generated_at - j.cutoff_at)) * 1000)::bigint end as elapsed_ms,
      j.cutoff_at as started_at,
      null::jsonb as counts
    from report_jobs j
    left join private.ai_summaries s on s.summary_date = j.summary_date and s.run_id = j.run_id
    union all
    select a.last_run_at, 'airtable_sync',
      case when a.last_error is not null then 'failed'
           when a.last_ok_at >= a.last_run_at then 'succeeded' else 'unknown' end,
      case when a.last_kind in ('changes', 'full') then a.last_kind end,
      case when split_part(a.last_error, ':', 1) in (
        'airtable_token_rejected', 'no_airtable_token', 'airtable_not_found',
        'airtable_limit', 'airtable_budget', 'airtable_empty', 'airtable_too_many_pages'
      ) then split_part(a.last_error, ':', 1) when a.last_error is not null then 'other' end,
      null::bigint, null::timestamptz,
      case when a.last_error is null and a.last_ok_at >= a.last_run_at then
        (select jsonb_object_agg(k, a.last_result->k)
         from unnest(array['added','changed','removed','total','pages']) as fields(k)
         where jsonb_typeof(a.last_result->k) = 'number')
      end
    from private.airtable_state a
    where a.id = 1 and a.last_run_at is not null
    union all
    select r.start_time, 'schedule',
      case when r.status in ('succeeded','failed','running','starting','connecting','sending')
        then r.status else 'unknown' end,
      j.jobname, null::text,
      round(extract(epoch from (r.end_time - r.start_time)) * 1000)::bigint,
      null::timestamptz, null::jsonb
    from cron.job j
    cross join lateral (
      select start_time, end_time, status
      from cron.job_run_details
      where jobid = j.jobid and start_time >= now() - interval '7 days'
      order by start_time desc
      limit 12
    ) r
    where j.jobname in ('daily-ai-summary', 'airtable-changes', 'airtable-nightly', 'airtable-saturday')
  )
  select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc), '[]'::jsonb)
    into result from events e;
  return result;
end;
$$;

revoke all on function public.admin_diagnostics(text) from public, anon, authenticated;
grant execute on function public.admin_diagnostics(text) to anon, authenticated;
