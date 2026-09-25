-- DNCC IT Audit — Step 1 database migration
-- Run this in Supabase SQL Editor BEFORE deploying the updated HTML files.

-- New employee-reported phone problem fields.
alter table submissions add column if not exists phone_problem text;
alter table submissions add column if not exists phone_problem_details text;

-- Ensure the inventory email field exists.
alter table devices add column if not exists assigned_employee_email text;

-- Backfill assigned device email from the latest matching employee submission.
-- Prefer company email when it looks valid; otherwise use personal email.
with latest_by_employee_id as (
  select distinct on (employee_id)
    employee_id,
    case
      when company_email is not null and company_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then company_email
      when personal_email is not null and personal_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then personal_email
      else null
    end as preferred_email
  from submissions
  where employee_id is not null and btrim(employee_id) <> ''
  order by employee_id, created_at desc
)
update devices d
set assigned_employee_email = s.preferred_email
from latest_by_employee_id s
where d.status = 'Assigned'
  and d.assigned_employee_id = s.employee_id
  and s.preferred_email is not null
  and (
    d.assigned_employee_email is null
    or btrim(d.assigned_employee_email) = ''
    or d.assigned_employee_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  );

-- Fallback for old rows where employee ID was not saved: match by assigned employee name.
with latest_by_employee_name as (
  select distinct on (employee_name)
    employee_name,
    case
      when company_email is not null and company_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then company_email
      when personal_email is not null and personal_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then personal_email
      else null
    end as preferred_email
  from submissions
  where employee_name is not null and btrim(employee_name) <> ''
  order by employee_name, created_at desc
)
update devices d
set assigned_employee_email = s.preferred_email
from latest_by_employee_name s
where d.status = 'Assigned'
  and (d.assigned_employee_id is null or btrim(d.assigned_employee_id) = '')
  and d.assigned_to = s.employee_name
  and s.preferred_email is not null
  and (
    d.assigned_employee_email is null
    or btrim(d.assigned_employee_email) = ''
    or d.assigned_employee_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
  );

-- Keep new problem values consistent at database level while allowing old rows to remain NULL.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'submissions_phone_problem_value_chk'
      and conrelid = 'submissions'::regclass
  ) then
    alter table submissions
      add constraint submissions_phone_problem_value_chk
      check (phone_problem is null or phone_problem in ('Yes','No'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'submissions_phone_problem_details_chk'
      and conrelid = 'submissions'::regclass
  ) then
    alter table submissions
      add constraint submissions_phone_problem_details_chk
      check (phone_problem is distinct from 'Yes' or nullif(btrim(phone_problem_details), '') is not null);
  end if;
end $$;
