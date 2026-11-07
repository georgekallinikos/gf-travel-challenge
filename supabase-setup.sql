-- GoFerry Travel Match v0.15 — one-time Supabase setup
-- Run this entire file in the Supabase SQL Editor for project vqkrhqmzmzbkbypnudha.

create extension if not exists pgcrypto;

create table if not exists public.travel_matches (
  id uuid primary key default gen_random_uuid(),
  invite_token text not null unique default encode(gen_random_bytes(16), 'hex'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  host_completed_at timestamptz,
  guest_completed_at timestamptz,
  host_answers smallint[],
  guest_answers smallint[],
  match_score smallint check (match_score between 0 and 100),
  host_email text,
  guest_email text,
  host_marketing boolean not null default false,
  guest_marketing boolean not null default false,
  host_consent_at timestamptz,
  guest_consent_at timestamptz,
  host_coupon_claimed boolean not null default false,
  guest_coupon_claimed boolean not null default false,
  app_cta_clicks integer not null default 0
);

alter table public.travel_matches enable row level security;
revoke all on public.travel_matches from anon, authenticated;
grant select, delete on public.travel_matches to authenticated;

drop policy if exists "takt staff can read travel matches" on public.travel_matches;
create policy "takt staff can read travel matches"
on public.travel_matches for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');

drop policy if exists "takt staff can delete travel matches" on public.travel_matches;
create policy "takt staff can delete travel matches"
on public.travel_matches for delete to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');

create or replace function public.tm_create_match()
returns text
language sql
security definer
set search_path = public
as $$
  insert into public.travel_matches default values returning invite_token;
$$;

create or replace function public.tm_submit_answers(
  p_token text,
  p_role text,
  p_answers smallint[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h smallint[];
  g smallint[];
  calculated_score smallint;
begin
  if p_role not in ('host', 'friend') then
    raise exception 'Invalid player role';
  end if;
  if array_length(p_answers, 1) is distinct from 8
     or exists (select 1 from unnest(p_answers) as x(value) where value < 0 or value > 3) then
    raise exception 'Invalid answers';
  end if;

  perform 1 from public.travel_matches where invite_token = p_token for update;
  if not found then raise exception 'Travel Match not found'; end if;

  if p_role = 'host' then
    update public.travel_matches
       set host_answers = p_answers, host_completed_at = now(), updated_at = now()
     where invite_token = p_token;
  else
    update public.travel_matches
       set guest_answers = p_answers, guest_completed_at = now(), updated_at = now()
     where invite_token = p_token;
  end if;

  select host_answers, guest_answers into h, g
    from public.travel_matches where invite_token = p_token;

  if h is not null and g is not null then
    select round(100.0 * count(*) filter (where h[i] = g[i]) / 8)::smallint
      into calculated_score from generate_subscripts(h, 1) i;
    update public.travel_matches
       set match_score = calculated_score, updated_at = now()
     where invite_token = p_token;
  end if;

  return jsonb_build_object(
    'host_complete', h is not null,
    'guest_complete', g is not null,
    'score', calculated_score
  );
end;
$$;

create or replace function public.tm_status(p_token text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'host_complete', host_answers is not null,
    'guest_complete', guest_answers is not null,
    'score', match_score
  )
  from public.travel_matches
  where invite_token = p_token;
$$;

create or replace function public.tm_save_email(
  p_token text,
  p_role text,
  p_email text,
  p_marketing boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_role not in ('host', 'friend') then raise exception 'Invalid player role'; end if;
  if p_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Invalid email';
  end if;
  if p_role = 'host' then
    update public.travel_matches set
      host_email = lower(trim(p_email)),
      host_marketing = p_marketing,
      host_consent_at = case when p_marketing then now() else null end,
      host_coupon_claimed = true,
      updated_at = now()
    where invite_token = p_token;
  else
    update public.travel_matches set
      guest_email = lower(trim(p_email)),
      guest_marketing = p_marketing,
      guest_consent_at = case when p_marketing then now() else null end,
      guest_coupon_claimed = true,
      updated_at = now()
    where invite_token = p_token;
  end if;
  if not found then raise exception 'Travel Match not found'; end if;
  return true;
end;
$$;

create or replace function public.tm_track_app_click(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.travel_matches
     set app_cta_clicks = app_cta_clicks + 1, updated_at = now()
   where invite_token = p_token;
  return found;
end;
$$;

revoke all on function public.tm_create_match() from public;
revoke all on function public.tm_submit_answers(text,text,smallint[]) from public;
revoke all on function public.tm_status(text) from public;
revoke all on function public.tm_save_email(text,text,text,boolean) from public;
revoke all on function public.tm_track_app_click(text) from public;

grant execute on function public.tm_create_match() to anon, authenticated;
grant execute on function public.tm_submit_answers(text,text,smallint[]) to anon, authenticated;
grant execute on function public.tm_status(text) to anon, authenticated;
grant execute on function public.tm_save_email(text,text,text,boolean) to anon, authenticated;
grant execute on function public.tm_track_app_click(text) to anon, authenticated;

-- Private dashboard maintenance. Only an authenticated @takt.gr account can run it.
create or replace function public.tm_admin_clear_all()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count bigint;
begin
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@takt.gr' then
    raise exception 'Not authorized';
  end if;
  delete from public.travel_matches;
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

revoke all on function public.tm_admin_clear_all() from public;
grant execute on function public.tm_admin_clear_all() to authenticated;
