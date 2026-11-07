-- GoFerry unified visitor/customer profile layer.
-- Safe to run after supabase-setup.sql. Existing Travel Match data remains intact.

create extension if not exists pgcrypto;

create table if not exists public.customer_profiles (
  customer_id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_identities (
  id bigint generated always as identity primary key,
  customer_id uuid not null references public.customer_profiles(customer_id) on delete cascade,
  identity_type text not null check (identity_type in ('email','phone')),
  normalized_value text not null,
  source text not null default 'unknown',
  verified boolean not null default false,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique(identity_type, normalized_value)
);

create table if not exists public.visitor_customer_links (
  visitor_id text primary key references public.visitor_profiles(visitor_id) on delete cascade,
  customer_id uuid not null references public.customer_profiles(customer_id) on delete cascade,
  source text not null default 'unknown',
  linked_at timestamptz not null default now()
);

create table if not exists public.visitor_traits (
  id bigint generated always as identity primary key,
  visitor_id text not null references public.visitor_profiles(visitor_id) on delete cascade,
  customer_id uuid references public.customer_profiles(customer_id) on delete set null,
  game_key text not null,
  channel text not null default 'web',
  trait_key text not null,
  trait_value text not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique(visitor_id, game_key, trait_key)
);

create table if not exists public.consent_records (
  id bigint generated always as identity primary key,
  visitor_id text not null references public.visitor_profiles(visitor_id) on delete cascade,
  customer_id uuid references public.customer_profiles(customer_id) on delete set null,
  identity_type text check (identity_type in ('email','phone')),
  normalized_value text,
  purpose text not null,
  granted boolean not null,
  wording_version text not null,
  source text not null,
  recorded_at timestamptz not null default now()
);

create index if not exists customer_identities_customer_idx on public.customer_identities(customer_id);
create index if not exists visitor_customer_links_customer_idx on public.visitor_customer_links(customer_id);
create index if not exists visitor_traits_customer_idx on public.visitor_traits(customer_id, last_seen_at desc);
create index if not exists visitor_traits_lookup_idx on public.visitor_traits(trait_key, trait_value);
create index if not exists consent_records_customer_idx on public.consent_records(customer_id, recorded_at desc);

alter table public.visitor_profiles add column if not exists identified_phone text;

alter table public.customer_profiles enable row level security;
alter table public.customer_identities enable row level security;
alter table public.visitor_customer_links enable row level security;
alter table public.visitor_traits enable row level security;
alter table public.consent_records enable row level security;

revoke all on public.customer_profiles, public.customer_identities, public.visitor_customer_links, public.visitor_traits, public.consent_records from anon, authenticated;
grant select, delete on public.customer_profiles, public.customer_identities, public.visitor_customer_links, public.visitor_traits, public.consent_records to authenticated;

drop policy if exists "takt staff read customer profiles" on public.customer_profiles;
create policy "takt staff read customer profiles" on public.customer_profiles for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr');
drop policy if exists "takt staff read customer identities" on public.customer_identities;
create policy "takt staff read customer identities" on public.customer_identities for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr');
drop policy if exists "takt staff read visitor links" on public.visitor_customer_links;
create policy "takt staff read visitor links" on public.visitor_customer_links for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr');
drop policy if exists "takt staff read visitor traits" on public.visitor_traits;
create policy "takt staff read visitor traits" on public.visitor_traits for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr');
drop policy if exists "takt staff read consent records" on public.consent_records;
create policy "takt staff read consent records" on public.consent_records for select to authenticated
using (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr');

create or replace function public.gf_identify_visitor(
  p_visitor_id text,
  p_identity_type text,
  p_identity_value text,
  p_source text default 'unknown',
  p_verified boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_value text;
  v_customer uuid;
begin
  if p_visitor_id !~ '^GFV-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid visitor ID'; end if;
  if p_identity_type not in ('email','phone') then raise exception 'Invalid identity type'; end if;

  if p_identity_type='email' then
    v_value=lower(trim(p_identity_value));
    if v_value !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email'; end if;
  else
    v_value=regexp_replace(trim(p_identity_value),'[^0-9+]','','g');
    if v_value !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Phone must use E.164 format'; end if;
  end if;

  select customer_id into v_customer from public.customer_identities
  where identity_type=p_identity_type and normalized_value=v_value;

  if v_customer is null then
    select customer_id into v_customer from public.visitor_customer_links where visitor_id=p_visitor_id;
  end if;
  if v_customer is null then
    insert into public.customer_profiles default values returning customer_id into v_customer;
  end if;

  insert into public.customer_identities(customer_id,identity_type,normalized_value,source,verified)
  values(v_customer,p_identity_type,v_value,left(coalesce(p_source,'unknown'),80),coalesce(p_verified,false))
  on conflict(identity_type,normalized_value) do update set
    last_seen_at=now(), verified=customer_identities.verified or excluded.verified;

  insert into public.visitor_customer_links(visitor_id,customer_id,source)
  values(p_visitor_id,v_customer,left(coalesce(p_source,'unknown'),80))
  on conflict(visitor_id) do update set customer_id=excluded.customer_id,source=excluded.source,linked_at=now();

  update public.visitor_traits set customer_id=v_customer where visitor_id=p_visitor_id;
  update public.consent_records set customer_id=v_customer where visitor_id=p_visitor_id;
  update public.customer_profiles set updated_at=now() where customer_id=v_customer;
  if p_identity_type='email' then
    update public.visitor_profiles set identified_email=v_value,last_seen_at=now() where visitor_id=p_visitor_id;
  else
    update public.visitor_profiles set identified_phone=v_value,last_seen_at=now() where visitor_id=p_visitor_id;
  end if;
  return v_customer;
end;
$$;

create or replace function public.gf_save_traits(
  p_visitor_id text,
  p_game_key text,
  p_channel text,
  p_traits jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer uuid;
  v_item record;
begin
  if p_visitor_id !~ '^GFV-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid visitor ID'; end if;
  if p_game_key !~ '^[a-z0-9_-]{2,60}$' then raise exception 'Invalid game key'; end if;
  if jsonb_typeof(p_traits) <> 'object' then raise exception 'Traits must be a JSON object'; end if;
  select customer_id into v_customer from public.visitor_customer_links where visitor_id=p_visitor_id;
  for v_item in select key,value #>> '{}' as value from jsonb_each(p_traits)
  loop
    if length(v_item.key) between 2 and 80 and length(v_item.value) between 1 and 300 then
      insert into public.visitor_traits(visitor_id,customer_id,game_key,channel,trait_key,trait_value)
      values(p_visitor_id,v_customer,p_game_key,left(coalesce(p_channel,'web'),40),v_item.key,v_item.value)
      on conflict(visitor_id,game_key,trait_key) do update set
        customer_id=coalesce(excluded.customer_id,visitor_traits.customer_id),
        channel=excluded.channel,trait_value=excluded.trait_value,last_seen_at=now();
    end if;
  end loop;
  return true;
end;
$$;

create or replace function public.gf_record_consent(
  p_visitor_id text,
  p_identity_type text,
  p_identity_value text,
  p_purpose text,
  p_granted boolean,
  p_wording_version text,
  p_source text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer uuid;
  v_value text;
begin
  if p_visitor_id !~ '^GFV-[A-Za-z0-9-]{12,64}$' then raise exception 'Invalid visitor ID'; end if;
  if p_identity_type not in ('email','phone') then raise exception 'Invalid identity type'; end if;
  v_value=case when p_identity_type='email' then lower(trim(p_identity_value)) else regexp_replace(trim(p_identity_value),'[^0-9+]','','g') end;
  select customer_id into v_customer from public.visitor_customer_links where visitor_id=p_visitor_id;
  insert into public.consent_records(visitor_id,customer_id,identity_type,normalized_value,purpose,granted,wording_version,source)
  values(p_visitor_id,v_customer,p_identity_type,v_value,left(p_purpose,80),coalesce(p_granted,false),left(p_wording_version,40),left(p_source,80));
  return true;
end;
$$;

grant execute on function public.gf_identify_visitor(text,text,text,text,boolean) to anon, authenticated;
grant execute on function public.gf_save_traits(text,text,text,jsonb) to anon, authenticated;
grant execute on function public.gf_record_consent(text,text,text,text,boolean,text,text) to anon, authenticated;

-- Keep the existing Travel Match email call compatible while also creating a unified profile.
create or replace function public.tm_link_identity(p_visitor_id text,p_email text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.gf_identify_visitor(p_visitor_id,'email',p_email,'travel_match_coupon',false);
  insert into public.visitor_identities(visitor_id,email) values(p_visitor_id,lower(trim(p_email)))
  on conflict(visitor_id,email) do update set linked_at=now();
  return true;
end;
$$;

grant execute on function public.tm_link_identity(text,text) to anon, authenticated;

-- Extend the existing demo reset so the dashboard still clears every layer in one click.
create or replace function public.tm_admin_clear_all_v2()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count bigint;
begin
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@takt.gr' then raise exception 'Not authorized'; end if;
  delete from public.travel_matches where id is not null;
  delete from public.visitor_events where id is not null;
  delete from public.visitor_identities where visitor_id is not null;
  delete from public.visitor_profiles where visitor_id is not null;
  delete from public.customer_profiles where customer_id is not null;
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

revoke all on function public.tm_admin_clear_all_v2() from public;
grant execute on function public.tm_admin_clear_all_v2() to authenticated;

