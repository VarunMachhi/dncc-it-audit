-- DNCC performance optimization
-- Purpose: keep large Base64 device photos out of normal list/search queries.
-- Full submission rows remain in public.submissions and are fetched only when needed.

create or replace view public.submission_summaries
with (security_invoker = true)
as
select
  id,
  created_at,
  employee_name,
  employee_id,
  employee_email,
  department,
  location,
  designation,
  contact,
  device_count,
  charger,
  cable,
  damage,
  damage_what,
  damage_how,
  phone_problem,
  phone_problem_details,
  case when device1 is null then null else device1 - 'frontPhoto' - 'backPhoto' end as device1,
  case when device2 is null then null else device2 - 'frontPhoto' - 'backPhoto' end as device2,
  email_sent_at,
  company_email,
  personal_email,
  email_sent_via,
  (
    case when coalesce(device1->>'frontPhoto','') <> '' then 1 else 0 end +
    case when coalesce(device1->>'backPhoto','')  <> '' then 1 else 0 end +
    case when coalesce(device2->>'frontPhoto','') <> '' then 1 else 0 end +
    case when coalesce(device2->>'backPhoto','')  <> '' then 1 else 0 end
  )::int as photo_count
from public.submissions;

grant select on public.submission_summaries to anon, authenticated;
