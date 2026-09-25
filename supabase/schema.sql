-- ── DNCC IT Mobile Audit — Supabase schema ─────────────────────────────
-- Run this once in Supabase: Dashboard → SQL Editor → New query → paste → Run.

create extension if not exists "pgcrypto";

-- 1. Every form submission
create table if not exists submissions (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  employee_name text,
  employee_id text,
  employee_email text,
  department text,
  location text,
  designation text,
  contact text,
  device_count int,
  charger text,
  cable text,
  damage text,
  damage_what text,
  damage_how text,
  phone_problem text,
  phone_problem_details text,
  device1 jsonb,
  device2 jsonb,
  email_sent_at timestamptz
);

-- 2. Live device inventory (auto-populated from submissions, editable by admin)
create table if not exists devices (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  last_updated timestamptz default now(),
  brand text,
  model text,
  ram text,
  storage text,
  imei1 text unique,
  imei2 text,
  status text default 'Assigned',        -- Assigned / Spare / Retired / Damaged
  assigned_to text,
  assigned_employee_id text,
  assigned_employee_email text,
  notes text
);

-- 3b. Editable email formats for each type of device action.
--     Edit these live from Admin → Settings → Email templates.
--     Placeholders you can use inside subject/body:
--     {{employee_name}} {{employee_id}} {{device_brand}} {{device_model}}
--     {{imei1}} {{imei2}} {{location}} {{designation}} {{action_date}} {{company_name}}
create table if not exists email_templates (
  action text primary key,     -- handover / reassign / takeover / retire
  subject text,
  body text
);
insert into email_templates (action, subject, body) values
('handover', 'Your Mobile Device Handover Confirmation — {{company_name}}',
 '<p>Hi {{employee_name}},</p><p>This confirms your mobile device handover with {{company_name}} IT Department.</p><p><b>Device:</b> {{device_brand}} {{device_model}}<br/><b>IMEI:</b> {{imei1}}<br/><b>Date:</b> {{action_date}}</p><p>Your handover PDF is attached for your records. Please keep it safe.</p>'),
('reassign', 'Device Reassignment Confirmation — {{company_name}}',
 '<p>Hi {{employee_name}},</p><p>A mobile device has been reassigned to you by {{company_name}} IT Department.</p><p><b>Device:</b> {{device_brand}} {{device_model}}<br/><b>IMEI:</b> {{imei1}}<br/><b>Date:</b> {{action_date}}</p><p>A confirmation PDF is attached for your records.</p>'),
('takeover', 'Device Return / Takeover Confirmation — {{company_name}}',
 '<p>Hi {{employee_name}},</p><p>This confirms {{company_name}} IT Department has taken back the following device from you.</p><p><b>Device:</b> {{device_brand}} {{device_model}}<br/><b>IMEI:</b> {{imei1}}<br/><b>Date:</b> {{action_date}}</p><p>A confirmation PDF is attached for your records.</p>'),
('retire', 'Device Retirement Notice — {{company_name}}',
 '<p>Hi {{employee_name}},</p><p>This confirms the following device previously assigned to you has been retired from active use by {{company_name}} IT Department.</p><p><b>Device:</b> {{device_brand}} {{device_model}}<br/><b>IMEI:</b> {{imei1}}<br/><b>Date:</b> {{action_date}}</p>')
on conflict (action) do nothing;

-- 3. Audit trail of assign / reassign / spare / retire / edit actions
create table if not exists device_history (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  imei1 text,
  action text,
  employee_name text,
  notes text
);

-- 4. Single-row settings table: SMTP config + admin login credentials.
--    Editable from the Admin Portal's Settings tab — no redeploy needed.
create table if not exists settings (
  id int primary key default 1,
  smtp_host text,
  smtp_port text default '587',
  smtp_username text,
  smtp_password text,
  smtp_from_name text default 'DNCC IT Department',
  smtp_from_email text,
  admin_username text default 'Varunit',
  admin_password text default 'Shinchan@1121',
  updated_at timestamptz default now()
);
insert into settings (id) values (1) on conflict (id) do nothing;

-- Safe to re-run: adds new columns if you already set this up before.
alter table devices add column if not exists assigned_employee_email text;
alter table submissions add column if not exists employee_email text;
alter table submissions add column if not exists email_sent_at timestamptz;
alter table submissions add column if not exists phone_problem text;
alter table submissions add column if not exists phone_problem_details text;

-- ── Row Level Security ──────────────────────────────────────────────
-- This app has no custom backend server for its data layer, so the browser
-- talks to Supabase directly using the public "anon" key. These policies
-- allow that key to read/write freely, INCLUDING the settings table (which
-- holds your SMTP password and admin login). That is what makes it possible
-- to edit these from the Admin Portal without redeploying anything.
--
-- Trade-off: anyone who obtains your site's config.js (Supabase URL + anon
-- key) could theoretically read this data too. Treat that file as
-- internal/private, keep your GitHub repo private, and don't reuse this
-- SMTP account's password anywhere sensitive. This is an appropriate
-- trade-off for a small internal clinic tool — for stronger protection
-- later, the settings table can be locked to service-role-only access.

alter table submissions enable row level security;
alter table devices enable row level security;
alter table device_history enable row level security;
alter table settings enable row level security;
alter table email_templates enable row level security;

create policy "public insert submissions" on submissions for insert to anon with check (true);
create policy "public read submissions" on submissions for select to anon using (true);
create policy "public update submissions" on submissions for update to anon using (true);
create policy "public delete submissions" on submissions for delete to anon using (true);

create policy "public all devices" on devices for all to anon using (true) with check (true);
create policy "public all device_history" on device_history for all to anon using (true) with check (true);
create policy "public all settings" on settings for all to anon using (true) with check (true);
create policy "public all email_templates" on email_templates for all to anon using (true) with check (true);


-- ── Current application compatibility (keeps schema.sql aligned with the UI) ──
alter table submissions add column if not exists company_email text;
alter table submissions add column if not exists personal_email text;
alter table submissions add column if not exists email_sent_via text;
alter table email_templates add column if not exists closing text;
alter table settings add column if not exists smtp2go_api_key text;
alter table settings add column if not exists smtp2go_sender_name text;
alter table settings add column if not exists smtp2go_sender_email text;

create table if not exists change_requests (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  submission_id uuid,
  employee_name text,
  employee_id text,
  employee_email text,
  request_details text not null,
  status text not null default 'Pending',
  resolved_at timestamptz
);

create table if not exists activity_log (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  admin_username text,
  action text,
  target_type text,
  target_id text,
  details text
);

alter table change_requests enable row level security;
alter table activity_log enable row level security;
create policy "public all change_requests" on change_requests for all to anon using (true) with check (true);
create policy "public all activity_log" on activity_log for all to anon using (true) with check (true);

-- ── Device Request workflow additions ───────────────────────────────
alter table devices add column if not exists condition text default 'Good';
alter table devices add column if not exists sim_slots int default 2;
alter table devices add column if not exists sim_numbers jsonb default '[]'::jsonb;
alter table devices add column if not exists sim_assignment_mode text;
alter table devices add column if not exists stock_source text;
alter table devices add column if not exists charger_available text;
alter table devices add column if not exists cable_available text;
alter table settings add column if not exists it_request_email text;

create table if not exists device_requests (
  id uuid primary key default gen_random_uuid(),
  request_no bigserial unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  request_type text not null,
  employee_kind text not null default 'Existing',
  requester_email text not null,
  company_email text,
  personal_email text,
  employee_name text,
  employee_id text,
  location text,
  designation text,
  department text,
  matched_submission_id uuid,
  current_devices jsonb not null default '[]'::jsonb,
  request_choice text,
  replace_imei1 text,
  replace_device jsonb,
  request_reason text not null,
  intended_use text,
  needed_by date,
  status text not null default 'Pending Review',
  admin_note text,
  expected_timeline text,
  decision_at timestamptz,
  fulfillment_source text,
  fulfillment_device_id uuid,
  fulfillment_device_snapshot jsonb,
  previous_assignee jsonb,
  sim_plan text,
  fulfillment_sim_numbers jsonb not null default '[]'::jsonb,
  assigned_at timestamptz,
  form_token uuid,
  form_token_expires_at timestamptz,
  form_completed_at timestamptz,
  employee_notified_at timestamptz,
  it_notified_at timestamptz
);

create table if not exists form_access_tokens (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  submission_id uuid not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  active boolean not null default true,
  created_by text,
  purpose text default 'Employee correction/edit'
);

alter table device_requests enable row level security;
alter table form_access_tokens enable row level security;
create policy "public all device_requests" on device_requests for all to anon using (true) with check (true);
create policy "public all form_access_tokens" on form_access_tokens for all to anon using (true) with check (true);

-- ── Issue / damage resolution workflow ─────────────────────────────
create table if not exists issue_resolutions (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references submissions(id) on delete cascade,
  issue_type text not null check (issue_type in ('Physical Damage','Phone Problem')),
  original_issue_summary text,
  status text not null default 'Open' check (status in ('Open','Resolved')),
  resolution_notes text,
  resolved_by text,
  resolved_at timestamptz,
  resolution_email_sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (submission_id, issue_type)
);
create index if not exists issue_resolutions_status_idx on issue_resolutions(status);
create index if not exists issue_resolutions_submission_idx on issue_resolutions(submission_id);
alter table issue_resolutions enable row level security;
create policy "public all issue_resolutions" on issue_resolutions for all to anon using (true) with check (true);

create or replace function dncc_sync_issue_resolution_tickets()
returns trigger
language plpgsql
as $$
declare
  damage_summary text;
  problem_summary text;
begin
  damage_summary := trim(concat_ws(E'\n',
    case when nullif(trim(new.damage_what),'') is not null then 'Damage: ' || trim(new.damage_what) end,
    case when nullif(trim(new.damage_how),'') is not null then 'Cause: ' || trim(new.damage_how) end
  ));
  problem_summary := coalesce(nullif(trim(new.phone_problem_details),''),'Phone problem reported');

  if new.damage = 'Yes' then
    insert into issue_resolutions (submission_id, issue_type, original_issue_summary, status, updated_at)
    values (new.id, 'Physical Damage', damage_summary, 'Open', now())
    on conflict (submission_id, issue_type) do update
    set original_issue_summary = excluded.original_issue_summary,
        status = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then 'Open' else issue_resolutions.status end,
        resolution_notes = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null else issue_resolutions.resolution_notes end,
        resolved_by = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null else issue_resolutions.resolved_by end,
        resolved_at = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null else issue_resolutions.resolved_at end,
        resolution_email_sent_at = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null else issue_resolutions.resolution_email_sent_at end,
        updated_at = now();
  end if;

  if new.phone_problem = 'Yes' then
    insert into issue_resolutions (submission_id, issue_type, original_issue_summary, status, updated_at)
    values (new.id, 'Phone Problem', problem_summary, 'Open', now())
    on conflict (submission_id, issue_type) do update
    set original_issue_summary = excluded.original_issue_summary,
        status = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then 'Open' else issue_resolutions.status end,
        resolution_notes = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null else issue_resolutions.resolution_notes end,
        resolved_by = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null else issue_resolutions.resolved_by end,
        resolved_at = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null else issue_resolutions.resolved_at end,
        resolution_email_sent_at = case when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null else issue_resolutions.resolution_email_sent_at end,
        updated_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dncc_sync_issue_resolution_tickets on submissions;
create trigger trg_dncc_sync_issue_resolution_tickets
after insert or update of damage, damage_what, damage_how, phone_problem, phone_problem_details
on submissions
for each row execute function dncc_sync_issue_resolution_tickets();

-- ── Employee temporary self-edit audit trail ────────────────────────
create table if not exists employee_edit_audits (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  submission_id uuid not null references submissions(id) on delete cascade,
  access_token_id uuid references form_access_tokens(id) on delete set null,
  employee_name text,
  employee_id text,
  employee_email text,
  changed_fields jsonb not null default '[]'::jsonb,
  before_snapshot jsonb,
  after_snapshot jsonb,
  admin_notification_sent_at timestamptz
);
create index if not exists employee_edit_audits_submission_idx on employee_edit_audits(submission_id);
create index if not exists employee_edit_audits_created_idx on employee_edit_audits(created_at desc);
alter table employee_edit_audits enable row level security;
create policy "public all employee_edit_audits" on employee_edit_audits for all to anon using (true) with check (true);

-- ── Employee-reported post-handover damage / phone issues ──────────
create table if not exists employee_issue_reports (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submission_id uuid not null references submissions(id) on delete cascade,
  employee_name text,
  employee_id text,
  employee_email text,
  location text,
  device_imei1 text not null,
  device_snapshot jsonb not null default '{}'::jsonb,
  issue_type text not null check (issue_type in ('Physical Damage','Phone Problem')),
  issue_details text not null,
  damage_cause text,
  status text not null default 'Open' check (status in ('Open','Resolved')),
  resolution_notes text,
  resolved_by text,
  resolved_at timestamptz,
  employee_ack_sent_at timestamptz,
  it_notification_sent_at timestamptz,
  resolution_email_sent_at timestamptz,
  language text default 'en'
);
create index if not exists employee_issue_reports_submission_idx on employee_issue_reports(submission_id);
create index if not exists employee_issue_reports_status_idx on employee_issue_reports(status);
create index if not exists employee_issue_reports_imei_idx on employee_issue_reports(device_imei1);
create index if not exists employee_issue_reports_created_idx on employee_issue_reports(created_at desc);
alter table employee_issue_reports enable row level security;
create policy "public all employee_issue_reports" on employee_issue_reports for all to anon using (true) with check (true);
