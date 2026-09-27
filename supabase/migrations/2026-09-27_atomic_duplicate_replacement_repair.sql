-- DNCC: atomic repair for legacy duplicate replacement submissions.
-- Run once in Supabase SQL Editor before using the Repair duplicate replacement button.

create or replace function public.dncc_repair_duplicate_replacement(
  p_request_id uuid,
  p_base_submission_id uuid,
  p_duplicate_submission_id uuid,
  p_admin_username text default 'admin'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  req public.device_requests%rowtype;
  base public.submissions%rowtype;
  dup public.submissions%rowtype;
  old_imei text;
  new_imei text;
  replacement_device jsonb;
  new_device1 jsonb;
  new_device2 jsonb;
  base_count int := 0;
  dup_count int := 0;
  merged_count int := 0;
  deleted_count int := 0;
  cleanup_only boolean := false;
  same_identity boolean := false;
begin
  if p_base_submission_id = p_duplicate_submission_id then
    raise exception 'Base and duplicate submission cannot be the same row.';
  end if;

  select * into req
  from public.device_requests
  where id = p_request_id
  for update;
  if not found then raise exception 'Device request not found.'; end if;
  if coalesce(req.request_type,'') <> 'Replace' or coalesce(req.status,'') <> 'Completed' then
    raise exception 'Only a completed replacement request can be repaired.';
  end if;

  old_imei := coalesce(nullif(trim(req.replace_imei1), ''), nullif(trim(req.replace_device->>'imei1'), ''));
  new_imei := nullif(trim(req.fulfillment_device_snapshot->>'imei1'), '');
  if old_imei is null or new_imei is null then
    raise exception 'Replacement request does not contain both old and new IMEI values.';
  end if;

  select * into base from public.submissions where id = p_base_submission_id for update;
  if not found then raise exception 'Original/merged submission not found.'; end if;
  select * into dup from public.submissions where id = p_duplicate_submission_id for update;
  if not found then raise exception 'Duplicate submission not found.'; end if;

  -- Both rows must belong to the same employee. Prefer employee ID, then e-mail, then name+location.
  same_identity :=
    (nullif(trim(base.employee_id),'') is not null and nullif(trim(dup.employee_id),'') is not null
      and lower(trim(base.employee_id)) = lower(trim(dup.employee_id)))
    or
    (nullif(trim(base.company_email),'') is not null and nullif(trim(dup.company_email),'') is not null
      and lower(trim(base.company_email)) = lower(trim(dup.company_email)))
    or
    (nullif(trim(base.personal_email),'') is not null and nullif(trim(dup.personal_email),'') is not null
      and lower(trim(base.personal_email)) = lower(trim(dup.personal_email)))
    or
    (lower(trim(coalesce(base.employee_name,''))) = lower(trim(coalesce(dup.employee_name,'')))
      and lower(trim(coalesce(base.location,''))) = lower(trim(coalesce(dup.location,''))));
  if not same_identity then
    raise exception 'Safety check failed: the two submissions do not belong to the same employee.';
  end if;

  base_count :=
    (case when base.device1 is not null and coalesce(base.device1->>'imei1','') <> '' then 1 else 0 end) +
    (case when base.device2 is not null and coalesce(base.device2->>'imei1','') <> '' then 1 else 0 end);
  dup_count :=
    (case when dup.device1 is not null and coalesce(dup.device1->>'imei1','') <> '' then 1 else 0 end) +
    (case when dup.device2 is not null and coalesce(dup.device2->>'imei1','') <> '' then 1 else 0 end);

  if dup_count <> 1 then
    raise exception 'Safety check failed: expected the duplicate submission to contain exactly one device.';
  end if;
  if not ((dup.device1->>'imei1') = new_imei or (dup.device2->>'imei1') = new_imei) then
    raise exception 'Safety check failed: duplicate submission does not contain the issued replacement IMEI.';
  end if;

  replacement_device := case
    when dup.device1 is not null and dup.device1->>'imei1' = new_imei then dup.device1
    when dup.device2 is not null and dup.device2->>'imei1' = new_imei then dup.device2
    else req.fulfillment_device_snapshot
  end;
  if replacement_device is null or coalesce(replacement_device->>'imei1','') <> new_imei then
    raise exception 'Replacement device details could not be verified.';
  end if;

  -- Normal repair: original row still has the old device.
  if base.device1 is not null and base.device1->>'imei1' = old_imei then
    new_device1 := replacement_device;
    new_device2 := base.device2;
  elsif base.device2 is not null and base.device2->>'imei1' = old_imei then
    new_device1 := base.device1;
    new_device2 := replacement_device;
  -- Recovery from the old browser-side repair: merge was already saved, duplicate deletion failed.
  elsif base_count >= 2
        and ((base.device1->>'imei1') = new_imei or (base.device2->>'imei1') = new_imei)
        and not ((base.device1->>'imei1') = old_imei or (base.device2->>'imei1') = old_imei) then
    cleanup_only := true;
    new_device1 := base.device1;
    new_device2 := base.device2;
  else
    raise exception 'Safety check failed: original row neither contains the old IMEI nor a verified already-merged replacement.';
  end if;

  merged_count :=
    (case when new_device1 is not null and coalesce(new_device1->>'imei1','') <> '' then 1 else 0 end) +
    (case when new_device2 is not null and coalesce(new_device2->>'imei1','') <> '' then 1 else 0 end);

  if merged_count < 1 then raise exception 'Merged submission would contain no device.'; end if;

  if not cleanup_only then
    update public.submissions
    set
      employee_name = coalesce(nullif(dup.employee_name,''), base.employee_name),
      employee_id = coalesce(nullif(dup.employee_id,''), base.employee_id),
      company_email = coalesce(nullif(dup.company_email,''), base.company_email),
      personal_email = coalesce(nullif(dup.personal_email,''), base.personal_email),
      department = coalesce(nullif(dup.department,''), base.department),
      location = coalesce(nullif(dup.location,''), base.location),
      designation = coalesce(nullif(dup.designation,''), base.designation),
      contact = coalesce(nullif(dup.contact,''), base.contact),
      device_count = merged_count,
      device1 = new_device1,
      device2 = new_device2,
      charger = coalesce(nullif(dup.charger,''), base.charger),
      cable = coalesce(nullif(dup.cable,''), base.cable),
      damage = coalesce(nullif(dup.damage,''), base.damage),
      damage_what = coalesce(nullif(dup.damage_what,''), base.damage_what),
      damage_how = coalesce(nullif(dup.damage_how,''), base.damage_how),
      phone_problem = coalesce(nullif(dup.phone_problem,''), base.phone_problem),
      phone_problem_details = coalesce(nullif(dup.phone_problem_details,''), base.phone_problem_details)
    where id = base.id;
  end if;

  update public.device_requests
  set matched_submission_id = base.id,
      updated_at = now(),
      admin_note = trim(both from concat_ws(E'\n', nullif(admin_note,''),
        case when cleanup_only
          then 'Duplicate replacement cleanup completed atomically on ' || to_char(now(),'YYYY-MM-DD HH24:MI:SS TZ')
          else 'Duplicate replacement repaired atomically on ' || to_char(now(),'YYYY-MM-DD HH24:MI:SS TZ')
        end))
  where id = req.id;

  delete from public.submissions where id = dup.id;
  get diagnostics deleted_count = row_count;
  if deleted_count <> 1 then
    raise exception 'Duplicate delete affected % rows; entire repair has been rolled back.', deleted_count;
  end if;

  insert into public.activity_log(admin_username, action, target_type, target_id, details)
  values (
    coalesce(nullif(trim(p_admin_username),''),'admin'),
    case when cleanup_only then 'Removed leftover replacement duplicate' else 'Repaired duplicate replacement' end,
    'device_request',
    req.id::text,
    'Atomic repair: kept submission ' || base.id::text || ', removed duplicate ' || dup.id::text ||
      ', old IMEI ' || old_imei || ', replacement IMEI ' || new_imei ||
      case when cleanup_only then ' (merge was already saved before this repair).' else '.' end
  );

  return jsonb_build_object(
    'ok', true,
    'mode', case when cleanup_only then 'cleanup_only' else 'merge_and_cleanup' end,
    'submission_id', base.id,
    'deleted_duplicate_id', dup.id,
    'device_count', merged_count,
    'old_imei', old_imei,
    'new_imei', new_imei
  );
end;
$$;

-- The site currently uses the Supabase anon role for admin operations.
-- The function performs strict request/employee/IMEI checks before making changes.
grant execute on function public.dncc_repair_duplicate_replacement(uuid, uuid, uuid, text) to anon, authenticated;
