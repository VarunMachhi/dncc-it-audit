-- DNCC IT Audit — Device Request workflow migration
-- Run this in Supabase SQL Editor before deploying the updated HTML files. It is safe to re-run.

create extension if not exists "pgcrypto";

-- Keep live inventory rich enough for spare/reassignment decisions and SIM tracking.
alter table devices add column if not exists condition text default 'Good';
alter table devices add column if not exists sim_slots int default 2;
alter table devices add column if not exists sim_numbers jsonb default '[]'::jsonb;
alter table devices add column if not exists sim_assignment_mode text;
alter table devices add column if not exists stock_source text;
alter table devices add column if not exists charger_available text;
alter table devices add column if not exists cable_available text;

-- Address that receives new/replace-device request notifications.
alter table settings add column if not exists it_request_email text;

-- Main employee device request workflow.
create table if not exists device_requests (
  id uuid primary key default gen_random_uuid(),
  request_no bigserial unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  request_type text not null check (request_type in ('New','Replace')),
  employee_kind text not null default 'Existing' check (employee_kind in ('Existing','New')),
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

create index if not exists device_requests_status_idx on device_requests(status);
create index if not exists device_requests_email_idx on device_requests(lower(requester_email));
create index if not exists device_requests_employee_id_idx on device_requests(employee_id);
create index if not exists device_requests_created_idx on device_requests(created_at desc);

-- Temporary employee edit links for an existing submission.
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
create index if not exists form_access_tokens_token_idx on form_access_tokens(token);
create index if not exists form_access_tokens_submission_idx on form_access_tokens(submission_id);

-- This project currently uses the public anon key for both employee and browser-admin operations.
-- Keep policies consistent with the existing architecture so the new workflow works immediately.
alter table device_requests enable row level security;
alter table form_access_tokens enable row level security;

drop policy if exists "public all device_requests" on device_requests;
create policy "public all device_requests" on device_requests for all to anon using (true) with check (true);

drop policy if exists "public all form_access_tokens" on form_access_tokens;
create policy "public all form_access_tokens" on form_access_tokens for all to anon using (true) with check (true);
