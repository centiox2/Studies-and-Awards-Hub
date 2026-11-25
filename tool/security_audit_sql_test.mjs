import { PGlite } from "npm:@electric-sql/pglite@0.5.16";
import { pgcrypto } from "npm:@electric-sql/pglite@0.5.16/contrib/pgcrypto";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const db = new PGlite({ extensions: { pgcrypto } });
await db.exec(`
create role anon;
create role authenticated;
create role service_role;
create schema extensions;
create extension pgcrypto with schema extensions;
create schema cron;
create schema vault;
create schema net;
create publication supabase_realtime;
create function public.rls_auto_enable() returns event_trigger language plpgsql as $$begin end$$;
create table vault.decrypted_secrets(id uuid primary key default gen_random_uuid(), decrypted_secret text, name text);
create function vault.create_secret(text,text,text default null) returns uuid language sql
 as $$insert into vault.decrypted_secrets(decrypted_secret,name) values($1,$2) returning id$$;
create function net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer)
 returns bigint language sql as $$select 1::bigint$$;
create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;
create table cron.job(jobname text, jobid bigint generated always as identity);
create table cron.job_run_details(jobid bigint, start_time timestamptz, end_time timestamptz, status text);
create function cron.unschedule(text) returns boolean language sql as $$select true$$;
create type extensions.http_response as (status integer, content text);
`);
const schema = readFileSync("supabase/schema.sql", "utf8")
  .replace(/^create extension if not exists (http|pg_cron|pg_net).*;$/gm, "");
await db.exec(schema);

const scalar = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
await db.exec(`
insert into private.app_users(username,full_name,role,hash,must_change,active,pages)
values
 ('owner','Owner','admin',extensions.crypt('password1',extensions.gen_salt('bf',10)),false,true,null),
 ('restricted','Restricted','team',extensions.crypt('password1',extensions.gen_salt('bf',10)),false,true,'{}'),
 ('assigned','Assigned','team',extensions.crypt('password1',extensions.gen_salt('bf',10)),false,true,null),
 ('disabled','Disabled','team',extensions.crypt('password1',extensions.gen_salt('bf',10)),false,false,null);
insert into private.ai_summary_access(user_id)
 select id from private.app_users where username in ('assigned','restricted');
`);
const login = (name, password) =>
  scalar("select public.user_login($1,$2,false)", [name, password]);
const restricted = (await login("restricted", "password1")).token;
const assigned = (await login("assigned", "password1")).token;
const owner = (await login("owner", "password1")).token;
await assert.rejects(
  db.query("select public.admin_diagnostics($1)", [assigned]),
  (error) => error.code === "42501",
);
await assert.rejects(db.query("select public.admin_diagnostics($1)", ["invalid"]));
await db.exec(`
  insert into private.ai_summary_jobs(summary_date,source,status,lease_until,error_code,input_snapshot)
    values(private.today(),'manual','failed',now(),'gemini_quota_exceeded','{"client":"secret client"}'),
          (private.today(),'scheduled','queued',now()-interval '1 minute',null,null);
  update private.airtable_state set last_run_at=now(), last_error='airtable_empty: private server details';
  insert into cron.job(jobname) values ('daily-ai-summary');
  insert into cron.job_run_details(jobid,start_time,end_time,status)
    select jobid,now()-interval '1 second',now(),'succeeded' from cron.job;
`);
const serverDiagnostics = await scalar("select public.admin_diagnostics($1)", [owner]);
assert(serverDiagnostics.some((event) =>
  event.operation === "ai_report" && event.code === "gemini_quota_exceeded"));
assert(serverDiagnostics.some((event) =>
  event.operation === "ai_report" && event.status === "expired"));
assert(serverDiagnostics.some((event) =>
  event.operation === "airtable_sync" && event.code === "airtable_empty"));
assert(serverDiagnostics.some((event) =>
  event.operation === "schedule" && event.elapsed_ms === 1000));
assert(!JSON.stringify(serverDiagnostics).includes("secret client"));
assert(!JSON.stringify(serverDiagnostics).includes("private server details"));
assert.equal(
  await scalar("select public.ai_summary_access($1)", [restricted]),
  false,
);
assert.equal(
  await scalar("select public.ai_summary_access($1)", [assigned]),
  true,
);
for (
  const call of [
    "public.report_start($1)",
    "public.report_list($1,'{}')",
    "public.todo_list($1)",
    "public.todo_sync($1)",
    "public.ai_summary_read($1)",
  ]
) {
  await assert.rejects(
    db.query("select " + call, [restricted]),
    (error) => error.code === "42501",
  );
}
for (
  const [name, password] of [["disabled", "password1"], [
    "disabled",
    "incorrect",
  ], ["missing", "password1"]]
) {
  assert.deepEqual(await login(name, password), { error: "wrong_password" });
}
for (let i = 0; i < 5; i++) {
  assert.deepEqual(await login("assigned", "incorrect"), {
    error: "wrong_password",
  });
}
assert.deepEqual(await login("assigned", "password1"), {
  error: "wrong_password",
});
assert.equal(
  await scalar("select to_regprocedure('public.ai_summary_claim(text,uuid)')"),
  null,
);
assert.equal(
  await scalar(
    "select has_function_privilege('anon','public.report_withdraw(text,bigint)','EXECUTE')",
  ),
  true,
);
// Real upsert path: a fast device cannot pin subsequent edits or rewrite history.
const application = {
  id: 42,
  app_key: "fixture",
  student: "Fixture Client",
  rto: "",
  country: "",
  status: "",
  assignee: "",
  todo: "",
  follow_up: "",
  position: 0,
  updated_at: "2099-01-01T00:00:00",
};
const upsert = (table, row) =>
  db.query("select private.upsert_rows($1,'id',$2::jsonb)", [
    table,
    JSON.stringify([row]),
  ]);
await upsert("applications", application);
assert.equal(
  await scalar(
    "select updated_at::timestamp <= (now() at time zone 'Africa/Nairobi') + interval '5 minutes' from public.applications where id=42",
  ),
  true,
);
const history = {
  id: 9,
  import_id: 1,
  app_key: "fixture",
  student: "Fixture Client",
  field: "status",
  old_value: "New",
  new_value: "Submitted",
  changed_at: "2026-11-25T09:00:00",
};
await upsert("application_changes", history);
await upsert("application_changes", { ...history, new_value: "Other" });
assert.equal(
  await scalar("select new_value from public.application_changes where id=9"),
  "Submitted",
);
assert.equal(
  await scalar(
    "select count(*)::int from private.audit_log where table_name='applications'",
  ),
  1,
);

// The shared list cannot grow past its limit, and failed batches roll back.
const department = await scalar(
  "insert into public.departments(name) values('Fixture') returning id",
);
await db.query(
  "update private.app_users set department_id=$1 where username='assigned'",
  [department],
);
await db.query(
  "insert into public.todo_team_items(department_id,id,title,changed_at) select $1,i,'Fixture',now() from generate_series(1,3000) i",
  [department],
);
await assert.rejects(
  db.query("select public.todo_sync($1,$2::jsonb)", [
    assigned,
    JSON.stringify([{
      id: 3001,
      title: "New item",
      team: true,
      dept: Number(department),
    }]),
  ]),
  (error) => error.code === "22023",
);
assert.equal(
  await scalar(
    "select count(*)::int from public.todo_team_items where id=3001",
  ),
  0,
);
await db.close();
console.log("Security audit SQL checks passed");
