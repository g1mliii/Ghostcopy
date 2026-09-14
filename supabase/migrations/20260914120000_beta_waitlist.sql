-- Beta waitlist for the marketing site.
--
-- The site posts straight to PostgREST with the anon key rather than going
-- through an edge function. That is only safe because of the policy shape
-- below: anon may INSERT and nothing else. With RLS on and no SELECT policy,
-- the list cannot be read back through the API by anyone holding the anon key
-- (which is public - it ships in the apps), so the worst an attacker can do is
-- write rows, and the constraints here bound what those rows can be.
--
-- Reading the list is a service-role / dashboard operation, deliberately.

create table if not exists public.waitlist (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  -- Which build they care about. Null is fine - the landing page form does not
  -- ask, only the download page does.
  platform   text,
  -- Which form it came from, so we can tell the landing page from the download
  -- page without another table.
  source     text,
  created_at timestamptz not null default timezone('utc', now()),

  constraint waitlist_email_shape check (
    email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    and length(email) between 6 and 254
  ),
  constraint waitlist_platform_known check (
    platform is null or platform in ('windows', 'macos', 'android', 'ios')
  ),
  constraint waitlist_source_sane check (
    source is null or length(source) <= 64
  )
);

comment on table public.waitlist is
  'Beta signups from the marketing site. Insert-only for anon; read with the service role.';

-- One row per address, case-insensitively. A repeat signup surfaces as a 409,
-- which the site reports to the visitor as "already on the list".
create unique index if not exists waitlist_email_lower_key
  on public.waitlist (lower(email));

create index if not exists waitlist_created_at_idx
  on public.waitlist (created_at desc);

alter table public.waitlist enable row level security;

-- Insert only. No select, update or delete policy exists, so PostgREST refuses
-- all three for anon and authenticated no matter what they ask for.
drop policy if exists "anyone may join the waitlist" on public.waitlist;
create policy "anyone may join the waitlist"
  on public.waitlist
  for insert
  to anon, authenticated
  with check (true);

revoke all on table public.waitlist from anon, authenticated;
grant insert on table public.waitlist to anon, authenticated;
