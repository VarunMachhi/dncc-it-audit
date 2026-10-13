
-- DNCC unique employee ID + unified employee self-service lookup
-- Date: 2026-10-13
-- This migration does NOT rename existing historical employee IDs automatically.
-- It prevents future collisions and exposes historical conflicts through Data Health.

create table if not exists public.dncc_employee_id_registry (
  employee_id text primary key,
  employee_name text,
  location text,
  personal_email text,
  company_email text,
  created_at timestamptz not null default now()
);

alter table public.dncc_employee_id_registry enable row level security;
drop policy if exists "dncc_employee_id_registry_all" on public.dncc_employee_id_registry;
create policy "dncc_employee_id_registry_all"
  on public.dncc_employee_id_registry for all to anon,authenticated
  using (true) with check (true);
grant select,insert,update on public.dncc_employee_id_registry to anon,authenticated;

-- Reserve all current Employee Master IDs so new IDs can never reuse them.
insert into public.dncc_employee_id_registry(employee_id,employee_name,location,personal_email,company_email)
select employee_id,employee_name,location,personal_email,company_email
from public.dncc_employee_master
where coalesce(trim(employee_id),'')<>''
on conflict(employee_id) do nothing;

create or replace function public.dncc_employee_id_base(p_location text,p_employee_name text)
returns text
language plpgsql
immutable
as $$
declare
  v_code text;
  v_first text;
begin
  v_code:=case lower(trim(coalesce(p_location,'')))
    when 'vadodara' then 'VAD'
    when 'surat' then 'SUR'
    when 'anand' then 'ANA'
    when 'ahmedabad' then 'AHM'
    when 'rajkot' then 'RAJ'
    when 'bandra' then 'BAN'
    when 'thane' then 'THA'
    when 'borivali' then 'BOR'
    when 'panjim' then 'PAN'
    else upper(left(regexp_replace(coalesce(p_location,''),'[^A-Za-z0-9]','','g'),3))
  end;
  v_first:=upper(regexp_replace(split_part(trim(coalesce(p_employee_name,'')),' ',1),'[^A-Za-z0-9]','','g'));
  if coalesce(v_code,'')='' or coalesce(v_first,'')='' then return null; end if;
  return v_code||'-'||v_first;
end;
$$;

create or replace function public.dncc_existing_employee_id(
  p_personal_email text,
  p_company_email text
)
returns text
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_id text;
  v_count int;
begin
  -- Personal email is safe enough for reuse when it exactly matches one current employee.
  if coalesce(trim(p_personal_email),'')<>'' and position('@' in p_personal_email)>1 then
    select employee_id into v_id
    from public.dncc_employee_master
    where lower(trim(coalesce(personal_email,'')))=lower(trim(p_personal_email))
    order by updated_at desc
    limit 1;
    if v_id is not null then return v_id; end if;

    -- Also reuse an ID already claimed moments earlier for this same personal email.
    select employee_id into v_id
    from public.dncc_employee_id_registry
    where lower(trim(coalesce(personal_email,'')))=lower(trim(p_personal_email))
    order by created_at desc
    limit 1;
    if v_id is not null then return v_id; end if;
  end if;

  -- Company email may be shared. Reuse it ONLY when exactly one employee owns it.
  if coalesce(trim(p_company_email),'')<>'' and upper(trim(p_company_email))<>'NOT' and position('@' in p_company_email)>1 then
    select count(*),min(employee_id) into v_count,v_id
    from public.dncc_employee_master
    where lower(trim(coalesce(company_email,'')))=lower(trim(p_company_email));
    if v_count=1 then return v_id; end if;
  end if;
  return null;
end;
$$;

create or replace function public.dncc_preview_employee_id(
  p_location text,
  p_employee_name text,
  p_personal_email text default null,
  p_company_email text default null
)
returns text
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_existing text;
  v_base text;
  v_candidate text;
  i int:=1;
begin
  v_existing:=public.dncc_existing_employee_id(p_personal_email,p_company_email);
  if v_existing is not null then return v_existing; end if;

  v_base:=public.dncc_employee_id_base(p_location,p_employee_name);
  if v_base is null then return null; end if;

  loop
    v_candidate:=case when i=1 then v_base else v_base||'-'||lpad(i::text,2,'0') end;
    if not exists(select 1 from public.dncc_employee_id_registry r where upper(trim(r.employee_id))=upper(trim(v_candidate)))
       and not exists(select 1 from public.dncc_employee_master e where upper(trim(e.employee_id))=upper(trim(v_candidate))) then
      return v_candidate;
    end if;
    i:=i+1;
    if i>999 then raise exception 'Could not generate a free Employee ID for base %.',v_base; end if;
  end loop;
end;
$$;

create or replace function public.dncc_claim_employee_id(
  p_location text,
  p_employee_name text,
  p_personal_email text default null,
  p_company_email text default null
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  v_existing text;
  v_base text;
  v_candidate text;
  v_claimed text;
  i int:=1;
begin
  v_existing:=public.dncc_existing_employee_id(p_personal_email,p_company_email);
  if v_existing is not null then return v_existing; end if;

  v_base:=public.dncc_employee_id_base(p_location,p_employee_name);
  if v_base is null then raise exception 'Location and employee name are required to generate Employee ID.'; end if;

  loop
    v_candidate:=case when i=1 then v_base else v_base||'-'||lpad(i::text,2,'0') end;

    if not exists(select 1 from public.dncc_employee_master e where upper(trim(e.employee_id))=upper(trim(v_candidate))) then
      v_claimed:=null;
      insert into public.dncc_employee_id_registry(employee_id,employee_name,location,personal_email,company_email)
      values(v_candidate,trim(p_employee_name),trim(p_location),nullif(trim(p_personal_email),''),nullif(trim(p_company_email),''))
      on conflict(employee_id) do nothing
      returning employee_id into v_claimed;
      if v_claimed is not null then return v_claimed; end if;
    end if;

    i:=i+1;
    if i>999 then raise exception 'Could not claim a free Employee ID for base %.',v_base; end if;
  end loop;
end;
$$;

-- One lookup for both Correction and Device Issue forms.
-- Search supports Employee ID, employee name, personal email, and company email.
drop function if exists public.dncc_self_service_employee_lookup(text,int);

create function public.dncc_self_service_employee_lookup(
  p_search text,
  p_limit int default 20
)
returns table(
  employee_id text,
  employee_name text,
  company_email text,
  personal_email text,
  location text,
  designation text,
  department text,
  employee_status text,
  latest_submission_id uuid,
  current_device_count bigint
)
language sql
stable
security definer
set search_path=public
as $$
  select
    e.employee_id,
    e.employee_name,
    e.company_email,
    e.personal_email,
    e.location,
    e.designation,
    e.department,
    e.status as employee_status,
    ls.id as latest_submission_id,
    coalesce(dc.current_device_count,0) as current_device_count
  from public.dncc_employee_master e
  left join lateral (
    select s.id
    from public.submissions s
    where lower(trim(coalesce(s.employee_id,'')))=lower(trim(e.employee_id))
    order by s.created_at desc
    limit 1
  ) ls on true
  left join lateral (
    select count(*)::bigint current_device_count
    from public.devices d
    where d.status='Assigned'
      and lower(trim(coalesce(d.assigned_employee_id,'')))=lower(trim(e.employee_id))
  ) dc on true
  where coalesce(trim(p_search),'')<>''
    and (
      lower(e.employee_id) like '%'||lower(trim(p_search))||'%'
      or lower(coalesce(e.employee_name,'')) like '%'||lower(trim(p_search))||'%'
      or lower(coalesce(e.company_email,'')) like '%'||lower(trim(p_search))||'%'
      or lower(coalesce(e.personal_email,'')) like '%'||lower(trim(p_search))||'%'
    )
  order by
    case
      when lower(e.employee_id)=lower(trim(p_search)) then 0
      when lower(coalesce(e.personal_email,''))=lower(trim(p_search)) then 1
      when lower(coalesce(e.company_email,''))=lower(trim(p_search)) then 2
      when lower(coalesce(e.employee_name,''))=lower(trim(p_search)) then 3
      else 4
    end,
    e.employee_name,
    e.employee_id
  limit greatest(1,least(coalesce(p_limit,20),50));
$$;

-- Extend passive Data Health with likely historical Employee-ID identity conflicts.
create or replace function public.dncc_system_consistency_health()
returns table(severity text,issue_type text,entity_key text,message text)
language sql
security definer
set search_path=public
as $$
  select 'High','AssignedDeviceMissingEmployee','IMEI:'||coalesce(d.imei1,''),
         'Assigned device '||coalesce(d.imei1,'')||' has no Employee ID.'
  from public.devices d
  where d.status='Assigned' and coalesce(trim(d.assigned_employee_id),'')=''

  union all
  select 'High','AssignedDeviceUnknownEmployee','IMEI:'||coalesce(d.imei1,''),
         'Assigned device '||coalesce(d.imei1,'')||' references Employee ID '||coalesce(d.assigned_employee_id,'')||' which is not in Employee Master.'
  from public.devices d
  where d.status='Assigned' and coalesce(trim(d.assigned_employee_id),'')<>''
    and not exists(select 1 from public.dncc_employee_master e where lower(trim(e.employee_id))=lower(trim(d.assigned_employee_id)))

  union all
  select 'High','ExitedEmployeeOwnsDevice','EMP:'||e.employee_id,
         'Exited employee '||e.employee_id||' still has assigned phone IMEI '||coalesce(d.imei1,'')||'.'
  from public.dncc_employee_master e
  join public.devices d on lower(trim(coalesce(d.assigned_employee_id,'')))=lower(trim(e.employee_id)) and d.status='Assigned'
  where e.status='Exited'

  union all
  select 'High','ExitedEmployeeOwnsAccessory','EMP:'||e.employee_id,
         'Exited employee '||e.employee_id||' still has accessory ACC-'||lpad(a.id::text,6,'0')||'.'
  from public.dncc_employee_master e
  join public.accessory_assets a on lower(trim(coalesce(a.assigned_employee_id,'')))=lower(trim(e.employee_id)) and a.status in ('Assigned','With Device')
  where e.status='Exited'

  union all
  select 'High','DuplicateSIMAcrossDevices','SIM:'||x.sim_no,
         'SIM '||x.sim_no||' appears on more than one device.'
  from (
    select regexp_replace(s.value,'\D','','g') sim_no,count(distinct d.id) n
    from public.devices d
    cross join lateral jsonb_array_elements_text(coalesce(d.sim_numbers,'[]'::jsonb)) s(value)
    where regexp_replace(s.value,'\D','','g') ~ '^\d{10}$'
      and regexp_replace(s.value,'\D','','g')<>'0000000000'
    group by regexp_replace(s.value,'\D','','g')
    having count(distinct d.id)>1
  ) x

  union all
  select 'High','HistoricalEmployeeIdConflict','EMP:'||x.employee_id,
         'Employee ID '||x.employee_id||' appears to belong to more than one historical person. Review manually; it was not auto-renamed.'
  from (
    select min(trim(employee_id)) employee_id
    from public.submissions
    where coalesce(trim(employee_id),'')<>''
    group by lower(trim(employee_id))
    having count(distinct lower(trim(coalesce(personal_email,'')))) filter (where coalesce(trim(personal_email),'')<>'') > 1
       and count(distinct lower(trim(coalesce(employee_name,'')))) filter (where coalesce(trim(employee_name),'')<>'') > 1
  ) x

  union all
  select 'Medium','AccessoryMissingEmployee','ACC:'||a.id,
         'Accessory ACC-'||lpad(a.id::text,6,'0')||' is Assigned but has no Employee ID.'
  from public.accessory_assets a
  where a.status='Assigned' and coalesce(trim(a.assigned_employee_id),'')=''

  union all
  select 'Medium','DeviceLinkedAccessoryMissingPhone','ACC:'||a.id,
         'Accessory ACC-'||lpad(a.id::text,6,'0')||' is With Device but linked phone is missing.'
  from public.accessory_assets a
  where a.status='With Device'
    and coalesce(trim(a.device_imei),'')<>''
    and not exists(
      select 1 from public.devices d
      where regexp_replace(coalesce(d.imei1,''),'\D','','g')=regexp_replace(coalesce(a.device_imei,''),'\D','','g')
    );
$$;

grant execute on function public.dncc_employee_id_base(text,text) to anon,authenticated;
grant execute on function public.dncc_existing_employee_id(text,text) to anon,authenticated;
grant execute on function public.dncc_preview_employee_id(text,text,text,text) to anon,authenticated;
grant execute on function public.dncc_claim_employee_id(text,text,text,text) to anon,authenticated;
grant execute on function public.dncc_self_service_employee_lookup(text,int) to anon,authenticated;
grant execute on function public.dncc_system_consistency_health() to anon,authenticated;

notify pgrst,'reload schema';
