-- DNCC safe repair for Assigned device missing Employee ID
-- Run once in Supabase SQL Editor before using "Repair employee link".
-- The function changes ONLY the requested IMEI and only when exactly one active
-- employee can be proven from existing records.

create or replace function public.dncc_repair_missing_device_employee(
  p_imei text,
  p_changed_by text default 'IT Admin'
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_imei text:=regexp_replace(coalesce(p_imei,''),'\D','','g');
  d public.devices%rowtype;
  v_employee_id text;
  v_employee_name text;
  v_employee_email text;
  v_candidate_count int;
  v_candidates text;
begin
  if v_imei='' then
    raise exception 'IMEI is required.';
  end if;

  select * into d
  from public.devices
  where regexp_replace(coalesce(imei1,''),'\D','','g')=v_imei
     or regexp_replace(coalesce(imei2,''),'\D','','g')=v_imei
  limit 1
  for update;

  if not found then
    raise exception 'Device IMEI % was not found in Inventory.',v_imei;
  end if;

  if d.status<>'Assigned' then
    raise exception 'Device IMEI % is %, not Assigned. No repair was applied.',v_imei,d.status;
  end if;

  if coalesce(trim(d.assigned_employee_id),'')<>'' then
    raise exception 'Device IMEI % already has Employee ID %. No repair is needed.',v_imei,d.assigned_employee_id;
  end if;

  -- Candidate evidence comes from historical submissions containing this exact
  -- IMEI. We only accept Employee IDs that exist in Employee Master and are Active.
  with candidates as (
    select distinct trim(s.employee_id) employee_id
    from public.submissions s
    join public.dncc_employee_master e
      on lower(trim(e.employee_id))=lower(trim(s.employee_id))
     and e.status='Active'
    where coalesce(trim(s.employee_id),'')<>''
      and (
        regexp_replace(coalesce(s.device1->>'imei1',''),'\D','','g')=v_imei
        or regexp_replace(coalesce(s.device1->>'imei2',''),'\D','','g')=v_imei
        or regexp_replace(coalesce(s.device2->>'imei1',''),'\D','','g')=v_imei
        or regexp_replace(coalesce(s.device2->>'imei2',''),'\D','','g')=v_imei
      )
  )
  select count(*),string_agg(employee_id,', '),min(employee_id)
  into v_candidate_count,v_candidates,v_employee_id
  from candidates;

  if v_candidate_count=0 then
    raise exception 'No Active employee with matching historical IMEI evidence was found. Review manually.';
  elsif v_candidate_count>1 then
    raise exception 'More than one Employee ID is linked to this IMEI in history: %. Review manually.',v_candidates;
  end if;

  select
    e.employee_name,
    coalesce(nullif(trim(e.company_email),''),nullif(trim(e.personal_email),''))
  into v_employee_name,v_employee_email
  from public.dncc_employee_master e
  where lower(trim(e.employee_id))=lower(trim(v_employee_id))
  limit 1;

  update public.devices
  set assigned_employee_id=v_employee_id,
      assigned_to=coalesce(v_employee_name,d.assigned_to),
      assigned_employee_email=v_employee_email,
      last_updated=now()
  where id=d.id;

  insert into public.device_history(imei1,action,employee_name,notes)
  values(
    d.imei1,
    'Repaired missing Employee ID',
    coalesce(v_employee_name,d.assigned_to,''),
    'Employee ID restored to '||v_employee_id||' from unique historical IMEI evidence · by '||coalesce(p_changed_by,'IT Admin')
  );

  insert into public.dncc_operation_events(
    event_key,event_type,employee_id,old_imei,new_imei,details,changed_by
  )
  values(
    'repair-missing-employee:'||v_imei||':'||extract(epoch from now())::bigint,
    'Repair Missing Device Employee ID',
    v_employee_id,
    d.imei1,
    d.imei1,
    jsonb_build_object('reason','Assigned device was missing employee_id','evidence','unique historical IMEI match'),
    coalesce(p_changed_by,'IT Admin')
  );

  return jsonb_build_object(
    'ok',true,
    'imei',d.imei1,
    'employee_id',v_employee_id,
    'employee_name',v_employee_name
  );
end;
$$;

grant execute on function public.dncc_repair_missing_device_employee(text,text) to anon,authenticated;

notify pgrst,'reload schema';
