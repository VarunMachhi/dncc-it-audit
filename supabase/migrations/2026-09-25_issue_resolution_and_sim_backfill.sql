-- DNCC IT Audit — Issue resolution workflow + SIM backfill
-- Run this in Supabase SQL Editor after the device-request migration. Safe to re-run.

create extension if not exists "pgcrypto";

-- Ensure SIM inventory columns exist even if this migration is run independently.
alter table devices add column if not exists sim_slots int default 2;
alter table devices add column if not exists sim_numbers jsonb default '[]'::jsonb;
alter table devices add column if not exists sim_assignment_mode text;

-- 1) Resolution history for physical damage / phone problems reported in submissions.
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
create index if not exists issue_resolutions_updated_idx on issue_resolutions(updated_at desc);

alter table issue_resolutions enable row level security;
drop policy if exists "public all issue_resolutions" on issue_resolutions;
create policy "public all issue_resolutions" on issue_resolutions for all to anon using (true) with check (true);

-- Existing reported damage/problem rows become open issue tickets.
insert into issue_resolutions (submission_id, issue_type, original_issue_summary, status)
select id, 'Physical Damage',
       trim(concat_ws(E'\n',
         case when nullif(trim(damage_what),'') is not null then 'Damage: ' || trim(damage_what) end,
         case when nullif(trim(damage_how),'') is not null then 'Cause: ' || trim(damage_how) end
       )),
       'Open'
from submissions
where damage = 'Yes'
on conflict (submission_id, issue_type) do nothing;

insert into issue_resolutions (submission_id, issue_type, original_issue_summary, status)
select id, 'Phone Problem', coalesce(nullif(trim(phone_problem_details),''),'Phone problem reported'), 'Open'
from submissions
where phone_problem = 'Yes'
on conflict (submission_id, issue_type) do nothing;

-- Keep issue tickets in sync when a form is submitted/edited later.
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
        status = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then 'Open'
          else issue_resolutions.status
        end,
        resolution_notes = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null
          else issue_resolutions.resolution_notes
        end,
        resolved_by = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null
          else issue_resolutions.resolved_by
        end,
        resolved_at = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null
          else issue_resolutions.resolved_at
        end,
        resolution_email_sent_at = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null
          else issue_resolutions.resolution_email_sent_at
        end,
        updated_at = now();
  end if;

  if new.phone_problem = 'Yes' then
    insert into issue_resolutions (submission_id, issue_type, original_issue_summary, status, updated_at)
    values (new.id, 'Phone Problem', problem_summary, 'Open', now())
    on conflict (submission_id, issue_type) do update
    set original_issue_summary = excluded.original_issue_summary,
        status = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then 'Open'
          else issue_resolutions.status
        end,
        resolution_notes = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null
          else issue_resolutions.resolution_notes
        end,
        resolved_by = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null
          else issue_resolutions.resolved_by
        end,
        resolved_at = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null
          else issue_resolutions.resolved_at
        end,
        resolution_email_sent_at = case
          when issue_resolutions.original_issue_summary is distinct from excluded.original_issue_summary then null
          else issue_resolutions.resolution_email_sent_at
        end,
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

-- 2) Backfill SIM numbers for older inventory rows.
-- Older audit forms already stored SIM numbers inside submissions.device1/device2 JSON,
-- but devices.sim_numbers was added later, so those rows can currently appear blank.
with all_device_snapshots as (
  select s.created_at,
         s.device1->>'imei1' as imei1,
         coalesce(s.device1->'simNumbers', '[]'::jsonb) as sims,
         nullif(s.device1->>'simCount','')::int as sim_count
  from submissions s
  where s.device1 is not null and nullif(s.device1->>'imei1','') is not null
  union all
  select s.created_at,
         s.device2->>'imei1' as imei1,
         coalesce(s.device2->'simNumbers', '[]'::jsonb) as sims,
         nullif(s.device2->>'simCount','')::int as sim_count
  from submissions s
  where s.device2 is not null and nullif(s.device2->>'imei1','') is not null
), latest as (
  select distinct on (imei1) imei1, sims, sim_count
  from all_device_snapshots
  order by imei1, created_at desc
)
update devices d
set sim_numbers = latest.sims,
    sim_slots = greatest(coalesce(latest.sim_count,0), coalesce(jsonb_array_length(latest.sims),0), coalesce(d.sim_slots,1), 1),
    sim_assignment_mode = case
      when jsonb_array_length(latest.sims) > 0 then coalesce(nullif(d.sim_assignment_mode,''),'Backfilled from handover form')
      else d.sim_assignment_mode
    end,
    last_updated = coalesce(d.last_updated, now())
from latest
where d.imei1 = latest.imei1
  and jsonb_array_length(latest.sims) > 0
  and (d.sim_numbers is null or d.sim_numbers = '[]'::jsonb);
