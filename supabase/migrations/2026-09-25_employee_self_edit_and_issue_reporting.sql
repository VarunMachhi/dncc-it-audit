-- DNCC employee self-edit audit trail + post-handover device issue reporting
-- Run this file ONCE in Supabase SQL Editor for the existing live project.

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
drop policy if exists "public all employee_edit_audits" on employee_edit_audits;
create policy "public all employee_edit_audits" on employee_edit_audits for all to anon using (true) with check (true);

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
drop policy if exists "public all employee_issue_reports" on employee_issue_reports;
create policy "public all employee_issue_reports" on employee_issue_reports for all to anon using (true) with check (true);
