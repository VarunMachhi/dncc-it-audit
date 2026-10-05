-- DNCC IT Admin: server-verified admin sessions, SMTP settings secret lock,
-- and multiple admin/staff users.
-- This migration does not delete production submissions/devices.

create extension if not exists pgcrypto;

create table if not exists public.admin_users (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  password_hash text not null,
  display_name text not null default '',
  role text not null default 'staff' check (role in ('owner','admin','staff')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_login_at timestamptz
);

create unique index if not exists admin_users_username_lower_uidx
  on public.admin_users (lower(username));

create table if not exists public.admin_sessions (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.admin_users(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index if not exists admin_sessions_user_idx on public.admin_sessions(admin_user_id);
create index if not exists admin_sessions_expiry_idx on public.admin_sessions(expires_at);

create table if not exists public.admin_security_config (
  id smallint primary key check (id = 1),
  settings_secret_hash text not null,
  updated_at timestamptz not null default now()
);

-- Only a SHA-256 hash is stored. The actual secret is intentionally not stored in source/database plaintext.
insert into public.admin_security_config(id, settings_secret_hash)
values (1, '5c07ee72a27139f2f3bdec73434cc72332a0cc03434f38855568c4058cd58255')
on conflict (id) do update set settings_secret_hash = excluded.settings_secret_hash, updated_at = now();

-- Migrate the current single admin account into the new multi-user table.
-- The existing password is read inside PostgreSQL and immediately bcrypt-hashed.
insert into public.admin_users(username, password_hash, display_name, role, active)
select
  coalesce(nullif(trim(s.admin_username), ''), 'Admin'),
  crypt(coalesce(s.admin_password, ''), gen_salt('bf', 10)),
  coalesce(nullif(trim(s.admin_username), ''), 'DNCC IT Owner'),
  'owner',
  true
from public.settings s
where s.id = 1
  and coalesce(s.admin_password, '') <> ''
  and not exists (select 1 from public.admin_users);

alter table public.admin_users enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.admin_security_config enable row level security;

revoke all on public.admin_users from anon, authenticated;
revoke all on public.admin_sessions from anon, authenticated;
revoke all on public.admin_security_config from anon, authenticated;

create or replace function public.dncc_admin_token_hash(p_token text)
returns text
language sql
immutable
strict
set search_path = public, extensions
as $$
  select encode(digest(p_token, 'sha256'), 'hex');
$$;

create or replace function public.admin_login_v2(p_username text, p_password text)
returns table(
  session_token text,
  username text,
  display_name text,
  role text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  u public.admin_users%rowtype;
  raw_token text;
  expiry timestamptz := now() + interval '12 hours';
begin
  delete from public.admin_sessions where expires_at < now() or revoked_at is not null;

  select * into u
  from public.admin_users
  where lower(admin_users.username) = lower(trim(p_username))
    and active = true
  limit 1;

  if u.id is null or crypt(coalesce(p_password,''), u.password_hash) <> u.password_hash then
    return;
  end if;

  raw_token := encode(gen_random_bytes(32), 'hex');
  insert into public.admin_sessions(admin_user_id, token_hash, expires_at)
  values (u.id, public.dncc_admin_token_hash(raw_token), expiry);

  update public.admin_users set last_login_at = now(), updated_at = now() where id = u.id;

  return query select raw_token, u.username, u.display_name, u.role, expiry;
end;
$$;

create or replace function public.admin_validate_session(p_token text)
returns table(
  user_id uuid,
  username text,
  display_name text,
  role text,
  expires_at timestamptz
)
language sql
security definer
set search_path = public, extensions
as $$
  select u.id, u.username, u.display_name, u.role, s.expires_at
  from public.admin_sessions s
  join public.admin_users u on u.id = s.admin_user_id
  where s.token_hash = public.dncc_admin_token_hash(p_token)
    and s.revoked_at is null
    and s.expires_at > now()
    and u.active = true
  limit 1;
$$;

create or replace function public.admin_logout_v2(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.admin_sessions
  set revoked_at = now()
  where token_hash = public.dncc_admin_token_hash(p_token)
    and revoked_at is null;
  return true;
end;
$$;

create or replace function public.admin_verify_settings_secret(p_token text, p_secret text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  ok_session boolean;
  expected_hash text;
begin
  select exists(
    select 1
    from public.admin_sessions s
    join public.admin_users u on u.id = s.admin_user_id
    where s.token_hash = public.dncc_admin_token_hash(p_token)
      and s.revoked_at is null and s.expires_at > now() and u.active
      and u.role in ('owner','admin')
  ) into ok_session;
  if not ok_session then return false; end if;

  select settings_secret_hash into expected_hash from public.admin_security_config where id = 1;
  return encode(digest(coalesce(p_secret,''), 'sha256'), 'hex') = expected_hash;
end;
$$;

-- Prevent direct browser updates to sensitive SMTP fields. Only the verified RPC below can change them.
create or replace function public.dncc_guard_sensitive_settings_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (new.smtp2go_api_key is distinct from old.smtp2go_api_key)
     or (new.smtp2go_sender_name is distinct from old.smtp2go_sender_name)
     or (new.smtp2go_sender_email is distinct from old.smtp2go_sender_email)
     or (new.it_request_email is distinct from old.it_request_email) then
    if coalesce(current_setting('dncc.smtp_settings_unlocked', true), '') <> '1' then
      raise exception 'Sensitive SMTP settings are locked';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dncc_guard_sensitive_settings on public.settings;
create trigger trg_dncc_guard_sensitive_settings
before update on public.settings
for each row execute function public.dncc_guard_sensitive_settings_update();

create or replace function public.admin_update_smtp_settings(
  p_token text,
  p_secret text,
  p_api_key text,
  p_sender_name text,
  p_sender_email text,
  p_it_request_email text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.admin_verify_settings_secret(p_token, p_secret) then
    raise exception 'Settings unlock failed';
  end if;

  perform set_config('dncc.smtp_settings_unlocked', '1', true);

  update public.settings
  set smtp2go_api_key = case when nullif(trim(coalesce(p_api_key,'')), '') is null then smtp2go_api_key else trim(p_api_key) end,
      smtp2go_sender_name = trim(coalesce(p_sender_name,'')),
      smtp2go_sender_email = trim(coalesce(p_sender_email,'')),
      it_request_email = trim(coalesce(p_it_request_email,'')),
      updated_at = now()
  where id = 1;

  return true;
end;
$$;

create or replace function public.admin_list_users(p_token text)
returns table(
  id uuid,
  username text,
  display_name text,
  role text,
  active boolean,
  created_at timestamptz,
  last_login_at timestamptz
)
language sql
security definer
set search_path = public, extensions
as $$
  select u.id, u.username, u.display_name, u.role, u.active, u.created_at, u.last_login_at
  from public.admin_users u
  where exists (
    select 1 from public.admin_sessions s
    join public.admin_users me on me.id=s.admin_user_id
    where s.token_hash=public.dncc_admin_token_hash(p_token)
      and s.revoked_at is null and s.expires_at>now() and me.active and me.role='owner'
  )
  order by case when u.role='owner' then 0 else 1 end, lower(u.username);
$$;

create or replace function public.admin_create_user(
  p_token text,
  p_username text,
  p_password text,
  p_display_name text,
  p_role text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  new_id uuid;
begin
  if not exists (
    select 1 from public.admin_sessions s
    join public.admin_users me on me.id=s.admin_user_id
    where s.token_hash=public.dncc_admin_token_hash(p_token)
      and s.revoked_at is null and s.expires_at>now() and me.active and me.role='owner'
  ) then raise exception 'Owner access required'; end if;

  if length(trim(coalesce(p_username,''))) < 3 or length(trim(p_username)) > 40 then
    raise exception 'Username must be 3 to 40 characters';
  end if;
  if p_username !~ '^[A-Za-z0-9._-]+$' then
    raise exception 'Username may contain only letters, numbers, dot, underscore and hyphen';
  end if;
  if length(coalesce(p_password,'')) < 8 then raise exception 'Password must be at least 8 characters'; end if;
  if p_role not in ('admin','staff') then raise exception 'Invalid role'; end if;

  insert into public.admin_users(username,password_hash,display_name,role,active)
  values (trim(p_username), crypt(p_password, gen_salt('bf',10)), trim(coalesce(p_display_name,'')), p_role, true)
  returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.admin_update_user_access(
  p_token text,
  p_user_id uuid,
  p_role text,
  p_active boolean
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  target_role text;
begin
  if not exists (
    select 1 from public.admin_sessions s
    join public.admin_users me on me.id=s.admin_user_id
    where s.token_hash=public.dncc_admin_token_hash(p_token)
      and s.revoked_at is null and s.expires_at>now() and me.active and me.role='owner'
  ) then raise exception 'Owner access required'; end if;

  select role into target_role from public.admin_users where id=p_user_id;
  if target_role='owner' then raise exception 'Owner access cannot be changed here'; end if;
  if p_role not in ('admin','staff') then raise exception 'Invalid role'; end if;

  update public.admin_users set role=p_role, active=p_active, updated_at=now() where id=p_user_id;
  if not p_active then update public.admin_sessions set revoked_at=now() where admin_user_id=p_user_id and revoked_at is null; end if;
  return true;
end;
$$;

create or replace function public.admin_reset_user_password(
  p_token text,
  p_user_id uuid,
  p_new_password text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  target_role text;
begin
  if not exists (
    select 1 from public.admin_sessions s
    join public.admin_users me on me.id=s.admin_user_id
    where s.token_hash=public.dncc_admin_token_hash(p_token)
      and s.revoked_at is null and s.expires_at>now() and me.active and me.role='owner'
  ) then raise exception 'Owner access required'; end if;
  if length(coalesce(p_new_password,'')) < 8 then raise exception 'Password must be at least 8 characters'; end if;
  select role into target_role from public.admin_users where id=p_user_id;
  if target_role='owner' then raise exception 'Owner password cannot be reset from this list'; end if;

  update public.admin_users set password_hash=crypt(p_new_password,gen_salt('bf',10)),updated_at=now() where id=p_user_id;
  update public.admin_sessions set revoked_at=now() where admin_user_id=p_user_id and revoked_at is null;
  return true;
end;
$$;

-- The browser may call only these narrow functions; the backing tables remain unreadable directly.
revoke all on function public.admin_login_v2(text,text) from public;
revoke all on function public.admin_validate_session(text) from public;
revoke all on function public.admin_logout_v2(text) from public;
revoke all on function public.admin_verify_settings_secret(text,text) from public;
revoke all on function public.admin_update_smtp_settings(text,text,text,text,text,text) from public;
revoke all on function public.admin_list_users(text) from public;
revoke all on function public.admin_create_user(text,text,text,text,text) from public;
revoke all on function public.admin_update_user_access(text,uuid,text,boolean) from public;
revoke all on function public.admin_reset_user_password(text,uuid,text) from public;

grant execute on function public.admin_login_v2(text,text) to anon, authenticated;
grant execute on function public.admin_validate_session(text) to anon, authenticated;
grant execute on function public.admin_logout_v2(text) to anon, authenticated;
grant execute on function public.admin_verify_settings_secret(text,text) to anon, authenticated;
grant execute on function public.admin_update_smtp_settings(text,text,text,text,text,text) to anon, authenticated;
grant execute on function public.admin_list_users(text) to anon, authenticated;
grant execute on function public.admin_create_user(text,text,text,text,text) to anon, authenticated;
grant execute on function public.admin_update_user_access(text,uuid,text,boolean) to anon, authenticated;
grant execute on function public.admin_reset_user_password(text,uuid,text) to anon, authenticated;
