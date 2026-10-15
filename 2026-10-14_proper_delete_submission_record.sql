-- DNCC: proper, atomic Delete for a submission / employee record.
-- Run once in Supabase SQL Editor (after the 10-05, 10-08, 10-09 and 10-13 migrations).
--
-- Rules (same rules as Return / Takeover, so the lifecycle flow is not broken):
--  * Only an active owner/admin session can delete (staff cannot).
--  * If the employee still has OTHER submissions, only this one submission is
--    removed (its issue tickets / edit audits cascade). Devices and accessories
--    are not touched.
--  * If this is the employee's LAST submission, the whole employee record is closed:
--      mode 'release' (real employee): assigned phones go back to Spare exactly like
--                      Return Device (SIMs stay with the phone), 'Assigned' accessories
--                      go back to Spare, employee is removed from Employee Master.
--                      The Employee ID stays reserved in the ID registry.
--      mode 'purge'   (TEST data): ALL submissions of the employee, their phones, phone
--                      history and accessories are deleted completely, the Employee ID is freed.
--                      (purge never leaves a partly deleted test employee behind)
--  * Everything runs in one transaction: any error rolls back, nothing is half-deleted.
--  * One row in dncc_operation_events + one row in activity_log records the delete.

create or replace function public.dncc_delete_submission_record(
  p_token text,
  p_submission_id uuid,
  p_mode text,
  p_confirm text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user text;
  v_role text;
  s public.submissions%rowtype;
  v_emp text;
  v_mode text := lower(trim(coalesce(p_mode, '')));
  v_remaining int;
  v_sub_imeis text[] := '{}';
  v_imeis text[] := '{}';
  v_dev_n int := 0;
  v_acc_n int := 0;
  v_event text;
  v_full boolean := false;
begin
  -- 1) admin session check (owner/admin only)
  select u.username, u.role into v_user, v_role
  from public.admin_sessions ss
  join public.admin_users u on u.id = ss.admin_user_id
  where ss.token_hash = public.dncc_admin_token_hash(p_token)
    and ss.revoked_at is null and ss.expires_at > now() and u.active
  limit 1;
  if v_user is null or v_role not in ('owner', 'admin') then
    raise exception 'Admin access required to delete records.';
  end if;

  if v_mode not in ('release', 'purge') then
    raise exception 'Mode must be release or purge.';
  end if;

  -- 2) lock the submission
  select * into s from public.submissions where id = p_submission_id for update;
  if not found then raise exception 'Submission not found (already deleted?).'; end if;
  v_emp := upper(trim(coalesce(s.employee_id, '')));

  if v_emp <> '' and upper(trim(coalesce(p_confirm, ''))) <> v_emp then
    raise exception 'Confirmation text does not match the Employee ID.';
  end if;

  -- 3) other submissions of the same employee?
  select count(*) into v_remaining
  from public.submissions
  where id <> s.id and v_emp <> '' and upper(trim(coalesce(employee_id, ''))) = v_emp;

  -- TEST purge removes the whole employee (all their submissions); release only closes the record on the last submission
  v_full := (v_emp <> '' and (v_remaining = 0 or v_mode = 'purge'));

  if v_full then
    -- IMEIs on this submission
    select coalesce(array_agg(x), '{}') into v_sub_imeis
    from (
      select regexp_replace(coalesce(z.device1->>'imei1', ''), '\D', '', 'g') x
      from public.submissions z where upper(trim(coalesce(z.employee_id, ''))) = v_emp
      union all
      select regexp_replace(coalesce(z.device2->>'imei1', ''), '\D', '', 'g')
      from public.submissions z where upper(trim(coalesce(z.employee_id, ''))) = v_emp
    ) q where x <> '';

    -- phones that belong to this employee (or this submission and are not owned by someone else)
    select coalesce(array_agg(d.imei1), '{}') into v_imeis
    from public.devices d
    where (upper(trim(coalesce(d.assigned_employee_id, ''))) = v_emp)
       or (regexp_replace(coalesce(d.imei1, ''), '\D', '', 'g') = any (v_sub_imeis)
           and upper(trim(coalesce(d.assigned_employee_id, ''))) in ('', v_emp));

    if v_mode = 'release' then
      -- same effect as dncc_return_device_op (SIMs stay with the phone)
      with upd as (
        update public.devices d
        set status = 'Spare', assigned_to = null, assigned_employee_id = null,
            assigned_employee_email = null,
            sim_assignment_mode = 'SIM kept with returned phone',
            last_updated = now()
        where d.imei1 = any (v_imeis) and d.status = 'Assigned'
        returning d.imei1
      )
      insert into public.device_history(imei1, action, employee_name, notes)
      select u.imei1, 'Returned to IT - employee record deleted', s.employee_name,
             'Record deleted by ' || v_user || '. Phone moved to Spare.'
      from upd u;
      get diagnostics v_dev_n = row_count;

      -- loose accessories (charger, cable, ...) go back to stock
      if to_regclass('public.accessory_assets') is not null then
        update public.accessory_assets
        set status = 'Spare', assigned_employee_id = null, assigned_employee_name = null,
            assigned_employee_email = null, assignment_mode = null,
            returned_at = now(), manual_override = true, updated_by = v_user, updated_at = now()
        where upper(trim(coalesce(assigned_employee_id, ''))) = v_emp
          and status = 'Assigned';
        get diagnostics v_acc_n = row_count;
      end if;

    else  -- purge (test data)
      if to_regclass('public.accessory_assets') is not null then
        if to_regclass('public.accessory_asset_history') is not null then
          delete from public.accessory_asset_history
          where asset_id in (
            select id from public.accessory_assets
            where upper(trim(coalesce(assigned_employee_id, ''))) = v_emp
               or device_imei = any (v_imeis));
        end if;
        delete from public.accessory_assets
        where upper(trim(coalesce(assigned_employee_id, ''))) = v_emp
           or device_imei = any (v_imeis);
        get diagnostics v_acc_n = row_count;
      end if;
      delete from public.device_history where imei1 = any (v_imeis);
      delete from public.devices where imei1 = any (v_imeis);
      get diagnostics v_dev_n = row_count;
    end if;

    -- employee-level records
    delete from public.device_requests where upper(trim(coalesce(employee_id, ''))) = v_emp;
    delete from public.change_requests where upper(trim(coalesce(employee_id, ''))) = v_emp;
  end if;

  -- 4) the submission itself (tokens first: they have no foreign key)
  if v_full and v_mode = 'purge' then
    delete from public.form_access_tokens
     where submission_id in (select id from public.submissions where upper(trim(coalesce(employee_id, ''))) = v_emp);
    delete from public.submissions where upper(trim(coalesce(employee_id, ''))) = v_emp;
  else
    delete from public.form_access_tokens where submission_id = s.id;
    delete from public.submissions where id = s.id;   -- cascades issue_resolutions, issue reports, edit audits
  end if;

  if v_full then
    if to_regclass('public.employee_it_status') is not null then
      delete from public.employee_it_status where upper(trim(employee_id)) = v_emp;
    end if;
    if to_regclass('public.dncc_employee_master') is not null then
      delete from public.dncc_employee_master where upper(trim(employee_id)) = v_emp;
    end if;
    if v_mode = 'purge' then
      if to_regclass('public.employee_takeovers') is not null then
        delete from public.employee_takeovers where upper(trim(employee_id)) = v_emp;
      end if;
      if to_regclass('public.dncc_employee_id_registry') is not null then
        delete from public.dncc_employee_id_registry where upper(trim(employee_id)) = v_emp;
      end if;
    end if;
  end if;

  -- 5) audit trail
  v_event := 'delete-record:' || p_submission_id::text || ':' || extract(epoch from now())::bigint;
  if to_regclass('public.dncc_operation_events') is not null then
    insert into public.dncc_operation_events(event_key, event_type, employee_id, details, changed_by)
    values (v_event, 'Delete Record', nullif(v_emp, ''),
            jsonb_build_object('mode', v_mode, 'full_cleanup', v_full,
                               'other_submissions_kept', v_remaining,
                               'devices_affected', v_dev_n, 'accessories_affected', v_acc_n,
                               'imeis', to_jsonb(v_imeis)),
            v_user);
  end if;
  insert into public.activity_log(admin_username, action, target_type, target_id, details)
  values (v_user, 'Submission deleted', 'submission', p_submission_id::text,
          coalesce(s.employee_name, '') || ' (' || coalesce(s.employee_id, '-') || ') mode=' || v_mode
          || case when v_full then ', full cleanup' else ', only this submission (employee has ' || v_remaining || ' more)' end
          || ', devices=' || v_dev_n || ', accessories=' || v_acc_n);

  return jsonb_build_object(
    'ok', true, 'mode', v_mode, 'full_cleanup', v_full,
    'employee_id', s.employee_id, 'other_submissions_kept', v_remaining,
    'devices_affected', v_dev_n, 'accessories_affected', v_acc_n);
end;
$$;

revoke all on function public.dncc_delete_submission_record(text, uuid, text, text) from public;
grant execute on function public.dncc_delete_submission_record(text, uuid, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
