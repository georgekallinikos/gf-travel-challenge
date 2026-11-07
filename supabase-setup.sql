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
  app_cta_clicks integer not null default 0,
  invite_method text,
  guest_invite_contact text,
  host_visitor_id text,
  guest_visitor_id text,
  host_tag text,
  guest_tag text
);

alter table public.travel_matches add column if not exists invite_method text;
alter table public.travel_matches add column if not exists guest_invite_contact text;
alter table public.travel_matches add column if not exists host_visitor_id text;
alter table public.travel_matches add column if not exists guest_visitor_id text;
alter table public.travel_matches add column if not exists host_session_id text;
alter table public.travel_matches add column if not exists guest_session_id text;
alter table public.travel_matches add column if not exists host_tag text;
alter table public.travel_matches add column if not exists guest_tag text;

alter table public.travel_matches enable row level security;
revoke all on public.travel_matches from anon, authenticated;
grant select, delete on public.travel_matches to authenticated;
grant update (host_tag, guest_tag) on public.travel_matches to authenticated;

drop policy if exists "takt staff can read travel matches" on public.travel_matches;
create policy "takt staff can read travel matches"
on public.travel_matches for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');

drop policy if exists "takt staff can delete travel matches" on public.travel_matches;
create policy "takt staff can delete travel matches"
on public.travel_matches for delete to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');

drop policy if exists "takt staff can tag travel matches" on public.travel_matches;
create policy "takt staff can tag travel matches"
on public.travel_matches for update to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr')
with check (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');

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

create or replace function public.tm_save_invite(
  p_token text,
  p_method text,
  p_contact text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_method not in ('share', 'email', 'sms') then
    raise exception 'Invalid invitation method';
  end if;
  update public.travel_matches
     set invite_method = p_method,
         guest_invite_contact = nullif(trim(coalesce(p_contact, '')), ''),
         updated_at = now()
   where invite_token = p_token;
  return found;
end;
$$;

create or replace function public.tm_save_visitor(
  p_token text,
  p_role text,
  p_visitor_id text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_role not in ('host', 'friend') then raise exception 'Invalid player role'; end if;
  if p_visitor_id !~ '^GFV-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid visitor ID'; end if;
  if p_role = 'host' then
    update public.travel_matches set host_visitor_id = p_visitor_id, updated_at = now()
    where invite_token = p_token;
  else
    update public.travel_matches set guest_visitor_id = p_visitor_id, updated_at = now()
    where invite_token = p_token;
  end if;
  return found;
end;
$$;

revoke all on function public.tm_create_match() from public;
revoke all on function public.tm_submit_answers(text,text,smallint[]) from public;
revoke all on function public.tm_status(text) from public;
revoke all on function public.tm_save_email(text,text,text,boolean) from public;
revoke all on function public.tm_track_app_click(text) from public;
revoke all on function public.tm_save_invite(text,text,text) from public;
revoke all on function public.tm_save_visitor(text,text,text) from public;

grant execute on function public.tm_create_match() to anon, authenticated;
grant execute on function public.tm_submit_answers(text,text,smallint[]) to anon, authenticated;
grant execute on function public.tm_status(text) to anon, authenticated;
grant execute on function public.tm_save_email(text,text,text,boolean) to anon, authenticated;
grant execute on function public.tm_track_app_click(text) to anon, authenticated;
grant execute on function public.tm_save_invite(text,text,text) to anon, authenticated;
grant execute on function public.tm_save_visitor(text,text,text) to anon, authenticated;

-- Lightweight Braze-style anonymous visitor profiles and event history.
create table if not exists public.visitor_profiles (
  visitor_id text primary key,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  identified_email text,
  first_source text,
  last_source text,
  first_referrer text,
  last_referrer text,
  first_utm_medium text,
  last_utm_medium text,
  first_utm_campaign text,
  last_utm_campaign text,
  device_type text,
  language text
);

create table if not exists public.visitor_events (
  id bigint generated always as identity primary key,
  visitor_id text not null references public.visitor_profiles(visitor_id) on delete cascade,
  session_id text not null,
  event_name text not null,
  match_token text,
  event_data jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create index if not exists visitor_events_visitor_idx on public.visitor_events(visitor_id, occurred_at desc);
create index if not exists visitor_events_session_idx on public.visitor_events(session_id);
create index if not exists visitor_events_match_idx on public.visitor_events(match_token);

create table if not exists public.visitor_identities (
  visitor_id text not null references public.visitor_profiles(visitor_id) on delete cascade,
  email text not null,
  linked_at timestamptz not null default now(),
  primary key (visitor_id, email)
);

alter table public.visitor_profiles enable row level security;
alter table public.visitor_events enable row level security;
alter table public.visitor_identities enable row level security;
revoke all on public.visitor_profiles, public.visitor_events, public.visitor_identities from anon, authenticated;
grant select, delete on public.visitor_profiles, public.visitor_events, public.visitor_identities to authenticated;

drop policy if exists "takt staff can read visitor profiles" on public.visitor_profiles;
create policy "takt staff can read visitor profiles" on public.visitor_profiles for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');
drop policy if exists "takt staff can read visitor events" on public.visitor_events;
create policy "takt staff can read visitor events" on public.visitor_events for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');
drop policy if exists "takt staff can read visitor identities" on public.visitor_identities;
create policy "takt staff can read visitor identities" on public.visitor_identities for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');
drop policy if exists "takt staff can delete visitor profiles" on public.visitor_profiles;
create policy "takt staff can delete visitor profiles" on public.visitor_profiles for delete to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');
drop policy if exists "takt staff can delete visitor events" on public.visitor_events;
create policy "takt staff can delete visitor events" on public.visitor_events for delete to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');
drop policy if exists "takt staff can delete visitor identities" on public.visitor_identities;
create policy "takt staff can delete visitor identities" on public.visitor_identities for delete to authenticated
using (lower(coalesce(auth.jwt() ->> 'email', '')) like '%@takt.gr');

create or replace function public.tm_track_event(
  p_visitor_id text,
  p_session_id text,
  p_event_name text,
  p_match_token text default null,
  p_event_data jsonb default '{}'::jsonb,
  p_source text default null,
  p_referrer text default null,
  p_utm_medium text default null,
  p_utm_campaign text default null,
  p_device_type text default null,
  p_language text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_visitor_id !~ '^GFV-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid visitor ID'; end if;
  if p_session_id !~ '^GFS-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid session ID'; end if;
  if p_event_name not in ('page_view','match_created','invite_opened','invitation_sent','quiz_started','quiz_completed','coupon_claimed','coupon_skipped','app_clicked') then
    raise exception 'Invalid event';
  end if;

  insert into public.visitor_profiles (
    visitor_id, first_source, last_source, first_referrer, last_referrer,
    first_utm_medium, last_utm_medium, first_utm_campaign, last_utm_campaign,
    device_type, language
  ) values (
    p_visitor_id, left(p_source,120), left(p_source,120), left(p_referrer,180), left(p_referrer,180),
    left(p_utm_medium,120), left(p_utm_medium,120), left(p_utm_campaign,120), left(p_utm_campaign,120),
    left(p_device_type,20), left(p_language,20)
  )
  on conflict (visitor_id) do update set
    last_seen_at = now(),
    last_source = coalesce(left(excluded.last_source,120), visitor_profiles.last_source),
    last_referrer = coalesce(left(excluded.last_referrer,180), visitor_profiles.last_referrer),
    last_utm_medium = coalesce(left(excluded.last_utm_medium,120), visitor_profiles.last_utm_medium),
    last_utm_campaign = coalesce(left(excluded.last_utm_campaign,120), visitor_profiles.last_utm_campaign),
    device_type = coalesce(left(excluded.device_type,20), visitor_profiles.device_type),
    language = coalesce(left(excluded.language,20), visitor_profiles.language);

  insert into public.visitor_events(visitor_id, session_id, event_name, match_token, event_data)
  values (p_visitor_id, p_session_id, p_event_name, nullif(left(coalesce(p_match_token,''),64),''), coalesce(p_event_data,'{}'::jsonb));
  return true;
end;
$$;

create or replace function public.tm_link_identity(
  p_visitor_id text,
  p_email text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_visitor_id !~ '^GFV-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid visitor ID'; end if;
  if p_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email'; end if;
  insert into public.visitor_identities(visitor_id,email) values (p_visitor_id,lower(trim(p_email)))
  on conflict (visitor_id,email) do update set linked_at=now();
  update public.visitor_profiles set identified_email=lower(trim(p_email)),last_seen_at=now() where visitor_id=p_visitor_id;
  return true;
end;
$$;

create or replace function public.tm_save_visitor(
  p_token text,
  p_role text,
  p_visitor_id text,
  p_session_id text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_role not in ('host', 'friend') then raise exception 'Invalid player role'; end if;
  if p_visitor_id !~ '^GFV-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid visitor ID'; end if;
  if p_session_id !~ '^GFS-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid session ID'; end if;
  if p_role = 'host' then
    update public.travel_matches set host_visitor_id=p_visitor_id,host_session_id=p_session_id,updated_at=now() where invite_token=p_token;
  else
    update public.travel_matches set guest_visitor_id=p_visitor_id,guest_session_id=p_session_id,updated_at=now() where invite_token=p_token;
  end if;
  return found;
end;
$$;

revoke all on function public.tm_track_event(text,text,text,text,jsonb,text,text,text,text,text,text) from public;
revoke all on function public.tm_link_identity(text,text) from public;
revoke all on function public.tm_save_visitor(text,text,text,text) from public;
grant execute on function public.tm_track_event(text,text,text,text,jsonb,text,text,text,text,text,text) to anon, authenticated;
grant execute on function public.tm_link_identity(text,text) to anon, authenticated;
grant execute on function public.tm_save_visitor(text,text,text,text) to anon, authenticated;

-- Private dashboard maintenance. Only an authenticated @takt.gr account can run it.
create or replace function public.tm_admin_clear_all_v2()
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
  delete from public.visitor_events where id is not null;
  delete from public.visitor_identities where visitor_id is not null;
  delete from public.visitor_profiles where visitor_id is not null;
  delete from public.travel_matches where id is not null;
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

revoke all on function public.tm_admin_clear_all_v2() from public;
grant execute on function public.tm_admin_clear_all_v2() to authenticated;
