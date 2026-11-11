-- GoFerry dashboard profile tags v0.21
-- Adds one editable internal tag to browser-level and unified customer profiles.

alter table public.visitor_profiles
  add column if not exists admin_tag text;

alter table public.customer_profiles
  add column if not exists admin_tag text;

grant update (admin_tag) on public.visitor_profiles to authenticated;
grant update (admin_tag) on public.customer_profiles to authenticated;

drop policy if exists "takt staff update visitor profile tags" on public.visitor_profiles;
create policy "takt staff update visitor profile tags"
on public.visitor_profiles
for update
to authenticated
using (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr')
with check (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr');

drop policy if exists "takt staff update customer profile tags" on public.customer_profiles;
create policy "takt staff update customer profile tags"
on public.customer_profiles
for update
to authenticated
using (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr')
with check (lower(coalesce(auth.jwt() ->> 'email','')) like '%@takt.gr');
