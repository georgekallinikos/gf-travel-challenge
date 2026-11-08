-- GoFerry Travel Challenge v0.20
-- One active coupon per normalized email, valid for 30 days.

create table if not exists public.game_coupons (
  id uuid primary key default gen_random_uuid(),
  normalized_email text not null,
  coupon_code text not null unique,
  game_key text not null,
  discount_percent smallint not null check (discount_percent between 1 and 5),
  visitor_id text,
  status text not null default 'active' check (status in ('active','redeemed','expired','cancelled')),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days'),
  redeemed_at timestamptz,
  redeemed_booking_id text
);

create unique index if not exists game_coupons_one_active_per_email
  on public.game_coupons(normalized_email)
  where status = 'active';

create index if not exists game_coupons_visitor_idx
  on public.game_coupons(visitor_id, issued_at desc);

alter table public.game_coupons enable row level security;

create or replace function public.gf_claim_game_coupon(
  p_email text,
  p_discount_percent integer,
  p_visitor_id text,
  p_game_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_email,'')));
  v_existing public.game_coupons%rowtype;
  v_created public.game_coupons%rowtype;
  v_code text;
begin
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Invalid email address';
  end if;
  if p_discount_percent not between 1 and 5 then
    raise exception 'Discount must be between 1 and 5';
  end if;

  update public.game_coupons
     set status = 'expired'
   where normalized_email = v_email
     and status = 'active'
     and expires_at <= now();

  select * into v_existing
    from public.game_coupons
   where normalized_email = v_email
     and status = 'active'
   order by issued_at desc
   limit 1;

  if found then
    return jsonb_build_object(
      'existing', true,
      'coupon_code', v_existing.coupon_code,
      'discount_percent', v_existing.discount_percent,
      'expires_at', v_existing.expires_at,
      'status', v_existing.status
    );
  end if;

  v_code := 'GOFERRY' || p_discount_percent::text || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into public.game_coupons(normalized_email,coupon_code,game_key,discount_percent,visitor_id)
  values(v_email,v_code,left(coalesce(p_game_key,'game'),60),p_discount_percent,left(coalesce(p_visitor_id,''),100))
  returning * into v_created;

  return jsonb_build_object(
    'existing', false,
    'coupon_code', v_created.coupon_code,
    'discount_percent', v_created.discount_percent,
    'expires_at', v_created.expires_at,
    'status', v_created.status
  );
end;
$$;

grant execute on function public.gf_claim_game_coupon(text,integer,text,text) to anon, authenticated;

-- Keep the demo dashboard's Clear all data action complete.
create or replace function public.tm_admin_clear_all_v2()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count bigint := 0;
  affected bigint := 0;
begin
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@takt.gr' then
    raise exception 'Not authorized';
  end if;
  delete from public.game_coupons where id is not null;
  get diagnostics affected = row_count; deleted_count := deleted_count + affected;
  delete from public.travel_matches where id is not null;
  get diagnostics affected = row_count; deleted_count := deleted_count + affected;
  delete from public.visitor_events where id is not null;
  get diagnostics affected = row_count; deleted_count := deleted_count + affected;
  delete from public.visitor_identities where visitor_id is not null;
  get diagnostics affected = row_count; deleted_count := deleted_count + affected;
  delete from public.visitor_profiles where visitor_id is not null;
  get diagnostics affected = row_count; deleted_count := deleted_count + affected;
  delete from public.customer_profiles where customer_id is not null;
  get diagnostics affected = row_count; deleted_count := deleted_count + affected;
  return deleted_count;
end;
$$;

revoke all on function public.tm_admin_clear_all_v2() from public;
grant execute on function public.tm_admin_clear_all_v2() to authenticated;

