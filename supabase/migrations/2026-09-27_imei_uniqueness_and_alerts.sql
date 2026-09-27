-- DNCC IT Audit — IMEI uniqueness guard + duplicate-attempt alerts
-- Run once in Supabase SQL Editor.

create extension if not exists "pgcrypto";

-- 1) Employee duplicate-IMEI reports visible to IT Admin.
create table if not exists duplicate_imei_alerts (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  status text not null default 'Open' check (status in ('Open','Acknowledged','Resolved')),
  attempted_imei text not null,
  attempted_field text,
  source text not null default 'Employee form',
  employee_name text,
  employee_id text,
  company_email text,
  personal_email text,
  location text,
  designation text,
  duplicate_device_id uuid,
  duplicate_submission_id uuid,
  existing_device jsonb,
  existing_submission jsonb,
  request_context jsonb,
  message text,
  notified_it_at timestamptz,
  acknowledged_at timestamptz,
  acknowledged_by text,
  resolved_at timestamptz,
  resolved_by text,
  resolution_note text
);

create index if not exists duplicate_imei_alerts_status_created_idx
  on duplicate_imei_alerts(status, created_at desc);
create index if not exists duplicate_imei_alerts_imei_idx
  on duplicate_imei_alerts(attempted_imei);

alter table duplicate_imei_alerts enable row level security;
drop policy if exists "public all duplicate_imei_alerts" on duplicate_imei_alerts;
create policy "public all duplicate_imei_alerts"
  on duplicate_imei_alerts for all to anon using (true) with check (true);
grant select, insert, update, delete on duplicate_imei_alerts to anon, authenticated;

-- 2) Lightweight lookup used by both employee and admin UI.
--    It intentionally returns no photos / large JSON blobs.
create or replace function dncc_find_imei_conflict(
  p_imei text,
  p_exclude_submission_id uuid default null,
  p_exclude_device_id uuid default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_imei text := regexp_replace(coalesce(p_imei,''), '[^0-9]', '', 'g');
  v_device jsonb;
  v_submission jsonb;
  v_device_ids jsonb := '[]'::jsonb;
  v_submission_ids jsonb := '[]'::jsonb;
begin
  if v_imei !~ '^[0-9]{15}$' then
    return jsonb_build_object('exists', false, 'imei', v_imei);
  end if;

  select coalesce(jsonb_agg(d.id), '[]'::jsonb) into v_device_ids
  from devices d
  where (p_exclude_device_id is null or d.id <> p_exclude_device_id)
    and (d.imei1 = v_imei or d.imei2 = v_imei);

  select jsonb_build_object(
      'id', d.id,
      'brand', d.brand,
      'model', d.model,
      'imei1', d.imei1,
      'imei2', d.imei2,
      'status', d.status,
      'assigned_to', d.assigned_to,
      'assigned_employee_id', d.assigned_employee_id,
      'assigned_employee_email', d.assigned_employee_email,
      'last_updated', d.last_updated
    )
    into v_device
  from devices d
  where (p_exclude_device_id is null or d.id <> p_exclude_device_id)
    and (d.imei1 = v_imei or d.imei2 = v_imei)
  order by d.last_updated desc nulls last, d.created_at desc
  limit 1;

  select coalesce(jsonb_agg(s.id), '[]'::jsonb) into v_submission_ids
  from submissions s
  where (p_exclude_submission_id is null or s.id <> p_exclude_submission_id)
    and (
      s.device1->>'imei1' = v_imei or s.device1->>'imei2' = v_imei or
      s.device2->>'imei1' = v_imei or s.device2->>'imei2' = v_imei
    );

  select jsonb_build_object(
      'id', s.id,
      'employee_name', s.employee_name,
      'employee_id', s.employee_id,
      'company_email', s.company_email,
      'personal_email', s.personal_email,
      'location', s.location,
      'created_at', s.created_at,
      'device1', case when (s.device1->>'imei1' = v_imei or s.device1->>'imei2' = v_imei)
                      then jsonb_build_object('brand',s.device1->>'brand','model',s.device1->>'model','imei1',s.device1->>'imei1','imei2',s.device1->>'imei2') end,
      'device2', case when (s.device2->>'imei1' = v_imei or s.device2->>'imei2' = v_imei)
                      then jsonb_build_object('brand',s.device2->>'brand','model',s.device2->>'model','imei1',s.device2->>'imei1','imei2',s.device2->>'imei2') end
    )
    into v_submission
  from submissions s
  where (p_exclude_submission_id is null or s.id <> p_exclude_submission_id)
    and (
      s.device1->>'imei1' = v_imei or s.device1->>'imei2' = v_imei or
      s.device2->>'imei1' = v_imei or s.device2->>'imei2' = v_imei
    )
  order by s.created_at desc
  limit 1;

  return jsonb_build_object(
    'exists', (v_device is not null or v_submission is not null),
    'imei', v_imei,
    'device', v_device,
    'submission', v_submission,
    'device_ids', v_device_ids,
    'submission_ids', v_submission_ids
  );
end;
$$;

grant execute on function dncc_find_imei_conflict(text,uuid,uuid) to anon, authenticated;

-- 3) Deduplicated "Inform IT" endpoint. Repeated clicks/refreshes for the same
--    employee + IMEI reuse the same open alert instead of spamming Admin.
create or replace function dncc_report_duplicate_imei(p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_imei text := regexp_replace(coalesce(p_payload->>'attempted_imei',''), '[^0-9]', '', 'g');
  v_emp_id text := nullif(trim(coalesce(p_payload->>'employee_id','')), '');
  v_email text := lower(nullif(trim(case when coalesce(p_payload->>'company_email','') like '%@%' then p_payload->>'company_email' else coalesce(p_payload->>'personal_email','') end), ''));
begin
  if v_imei !~ '^[0-9]{15}$' then
    raise exception 'A valid 15-digit IMEI is required';
  end if;

  select id into v_id
  from duplicate_imei_alerts
  where attempted_imei = v_imei
    and status in ('Open','Acknowledged')
    and created_at > now() - interval '24 hours'
    and coalesce(employee_id,'') = coalesce(v_emp_id,'')
    and lower(case when coalesce(company_email,'') like '%@%' then company_email else coalesce(personal_email,'') end) = coalesce(v_email,'')
  order by created_at desc
  limit 1;

  if v_id is not null then
    update duplicate_imei_alerts
      set updated_at = now(),
          attempted_field = coalesce(p_payload->>'attempted_field', attempted_field),
          existing_device = coalesce(p_payload->'existing_device', existing_device),
          existing_submission = coalesce(p_payload->'existing_submission', existing_submission),
          request_context = coalesce(p_payload->'request_context', request_context),
          message = coalesce(p_payload->>'message', message)
    where id = v_id;
    return v_id;
  end if;

  insert into duplicate_imei_alerts (
    attempted_imei, attempted_field, source,
    employee_name, employee_id, company_email, personal_email,
    location, designation, duplicate_device_id, duplicate_submission_id,
    existing_device, existing_submission, request_context, message
  ) values (
    v_imei,
    p_payload->>'attempted_field',
    coalesce(nullif(p_payload->>'source',''),'Employee form'),
    p_payload->>'employee_name',
    v_emp_id,
    p_payload->>'company_email',
    p_payload->>'personal_email',
    p_payload->>'location',
    p_payload->>'designation',
    nullif(p_payload->>'duplicate_device_id','')::uuid,
    nullif(p_payload->>'duplicate_submission_id','')::uuid,
    p_payload->'existing_device',
    p_payload->'existing_submission',
    p_payload->'request_context',
    p_payload->>'message'
  ) returning id into v_id;

  return v_id;
end;
$$;

grant execute on function dncc_report_duplicate_imei(jsonb) to anon, authenticated;

-- 4) Hard database guard for the LIVE device inventory.
--    Covers IMEI1-vs-IMEI1, IMEI2-vs-IMEI2 and cross-column collisions.
--    Existing records are left untouched; all future inserts/updates are guarded.
create or replace function dncc_guard_device_imei_uniqueness()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v1 text := nullif(regexp_replace(coalesce(new.imei1,''), '[^0-9]', '', 'g'), '');
  v2 text := nullif(regexp_replace(coalesce(new.imei2,''), '[^0-9]', '', 'g'), '');
  c record;
begin
  if v1 is not null then new.imei1 := v1; end if;
  if v2 is not null then new.imei2 := v2; end if;

  if v1 is not null and v2 is not null and v1 = v2 then
    raise exception using errcode='23505', message='IMEI already exists: IMEI 1 and IMEI 2 cannot be the same number.';
  end if;

  -- Transaction-scoped locks stop two simultaneous writes claiming the same IMEI.
  if v1 is not null then perform pg_advisory_xact_lock(hashtext('dncc-imei-'||v1)); end if;
  if v2 is not null then perform pg_advisory_xact_lock(hashtext('dncc-imei-'||v2)); end if;

  select d.id, d.brand, d.model, d.imei1, d.imei2, d.status, d.assigned_to
    into c
  from devices d
  where d.id <> coalesce(new.id, gen_random_uuid())
    and (
      (v1 is not null and (d.imei1 = v1 or d.imei2 = v1)) or
      (v2 is not null and (d.imei1 = v2 or d.imei2 = v2))
    )
  limit 1;

  if found then
    raise exception using
      errcode='23505',
      message='IMEI already exists in device inventory. Existing device: ' ||
              coalesce(c.brand,'') || ' ' || coalesce(c.model,'') ||
              ' (' || coalesce(c.imei1,'') || ')' ||
              case when c.assigned_to is not null then ' assigned to '||c.assigned_to else '' end;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_dncc_guard_device_imei_uniqueness on devices;
create trigger trg_dncc_guard_device_imei_uniqueness
before insert or update of imei1, imei2 on devices
for each row execute function dncc_guard_device_imei_uniqueness();

-- Optional sanity constraint for future rows. NOT VALID avoids failing migration
-- because of any legacy bad row; new/updated rows are still checked.
alter table devices drop constraint if exists devices_imei_pair_different;
alter table devices add constraint devices_imei_pair_different
  check (imei2 is null or btrim(imei2) = '' or imei1 is null or imei1 <> imei2) not valid;
