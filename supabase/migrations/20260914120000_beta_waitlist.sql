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

-- A hard ceiling on the table.
--
-- The anon key is public, so anybody can write rows here; the constraints above
-- bound what a row can contain, but nothing bounds how many. This does. The
-- count is deliberately exact rather than an estimate from pg_class: it makes
-- each insert marginally more expensive as the table grows, which throttles a
-- flood at the same time as it caps one. Legitimate signup volume will never
-- notice.
--
-- security definer because anon has no SELECT on the table - the guard has to
-- read what the caller cannot.
create or replace function public.waitlist_capacity_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  cap constant bigint := 50000;
begin
  if (select count(*) from public.waitlist) >= cap then
    raise exception 'The waitlist is not accepting signups right now.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- Note: EXECUTE is deliberately NOT revoked from anon here. A function whose
-- return type is `trigger` cannot be invoked directly - Postgres refuses with
-- "trigger functions can only be called as trigger triggers" - so leaving the
-- default grant in place exposes nothing, while revoking it risks breaking the
-- very inserts this table exists to accept.

drop trigger if exists waitlist_capacity_guard on public.waitlist;
create trigger waitlist_capacity_guard
  before insert on public.waitlist
  for each row execute function public.waitlist_capacity_guard();
