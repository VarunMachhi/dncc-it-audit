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
