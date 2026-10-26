-- Mahmotna: allow one active browser/device session per account.
-- Run this whole file in Supabase Dashboard -> SQL Editor -> New query.
create table if not exists public.device_sessions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  device_token text not null,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.device_sessions enable row level security;
revoke all on public.device_sessions from anon, authenticated;

create or replace function public.claim_device_session(p_device_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected integer;
begin
  if auth.uid() is null or p_device_token is null or length(p_device_token) < 16 then
    return false;
  end if;

  insert into public.device_sessions(user_id, device_token, last_seen_at, created_at)
  values (auth.uid(), p_device_token, now(), now())
  on conflict (user_id) do update
    set device_token = excluded.device_token,
        last_seen_at = now(),
        created_at = case
          when public.device_sessions.device_token = excluded.device_token
            then public.device_sessions.created_at
          else now()
        end
    where public.device_sessions.device_token = excluded.device_token
       or public.device_sessions.last_seen_at < now() - interval '90 seconds';

  get diagnostics affected = row_count;
  return affected > 0;
end;
$$;

create or replace function public.heartbeat_device_session(p_device_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected integer;
begin
  if auth.uid() is null or p_device_token is null then
    return false;
  end if;

  update public.device_sessions
     set last_seen_at = now()
   where user_id = auth.uid()
     and device_token = p_device_token;

  get diagnostics affected = row_count;
  return affected > 0;
end;
$$;

revoke all on function public.claim_device_session(text) from public, anon;
revoke all on function public.heartbeat_device_session(text) from public, anon;
grant execute on function public.claim_device_session(text) to authenticated;
grant execute on function public.heartbeat_device_session(text) to authenticated;
