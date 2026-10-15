-- DNCC FORM SUBMISSION: READ-ONLY SUPABASE HEALTH CHECK
-- Paste into Supabase Dashboard > SQL Editor > Run.
-- Does not insert/update/delete data and does not display employee records.
-- Any failed result can explain a form submit error; do not rerun migrations blindly.

select check_name, case when ok then 'PASS' else 'MISSING / CHECK' end as status
from (
  select 'submissions table exists' as check_name,
         to_regclass('public.submissions') is not null as ok
  union all
  select 'submissions.company_email column', exists (
    select 1 from information_schema.columns where table_schema='public' and table_name='submissions' and column_name='company_email'
  )
  union all
  select 'submissions.personal_email column', exists (
    select 1 from information_schema.columns where table_schema='public' and table_name='submissions' and column_name='personal_email'
  )
  union all
  select 'submissions.phone_problem column', exists (
    select 1 from information_schema.columns where table_schema='public' and table_name='submissions' and column_name='phone_problem'
  )
  union all
  select 'employee master table (2026-10-09 migration)',
         to_regclass('public.dncc_employee_master') is not null
  union all
  select 'employee ID registry (2026-10-13 migration)',
         to_regclass('public.dncc_employee_id_registry') is not null
  union all
  select 'claim employee ID RPC (2026-10-13 migration)',
         to_regprocedure('public.dncc_claim_employee_id(text,text,text,text)') is not null
  union all
  select 'preview employee ID RPC (2026-10-13 migration)',
         to_regprocedure('public.dncc_preview_employee_id(text,text,text,text)') is not null
  union all
  select 'anon may execute ID claim RPC',
         coalesce(has_function_privilege('anon',to_regprocedure('public.dncc_claim_employee_id(text,text,text,text)'),'EXECUTE'),false)
  union all
  select 'anon may insert into submissions',
         coalesce(has_table_privilege('anon',to_regclass('public.submissions'),'INSERT'),false)
  union all
  select 'anon may select submission after insert',
         coalesce(has_table_privilege('anon',to_regclass('public.submissions'),'SELECT'),false)
) checks
order by check_name;

-- Also verify public.submissions RLS policies in Dashboard > Database > Policies.
-- A role grant can PASS here while an RLS policy still blocks INSERT or SELECT.
