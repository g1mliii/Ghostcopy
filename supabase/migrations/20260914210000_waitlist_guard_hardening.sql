-- Fixes a broken signup path and three database linter findings against the
-- waitlist table added earlier today in 20260914120000_beta_waitlist.sql.
--
-- THE BUG
-- The site sent `Prefer: resolution=ignore-duplicates` so that a repeat signup
-- would answer 201 instead of 409 - a 409 tells anyone holding the public anon
-- key whether a given address is already on the list. That turned out to be
-- incompatible with the whole point of the table: PostgREST turns that header
-- into ON CONFLICT DO NOTHING, and Postgres needs SELECT privilege on the
-- arbiter index's columns to evaluate a conflict target. anon deliberately has
-- no SELECT, so every signup failed with 42501 (surfaced as HTTP 401).
-- Confirmed against production: a plain insert returned 201, the same insert
-- with that header returned 401.
--
-- Keeping "anon cannot read the list" is non-negotiable, so the deduplication
-- moves into the trigger instead. A BEFORE INSERT trigger that returns NULL
-- cancels the row silently, and with `Prefer: return=minimal` PostgREST answers
-- 201 whether or not a row was written. Same 201 either way, so there is no
-- status code left to enumerate with - and it no longer needs ON CONFLICT.
--
-- THE LINTER FINDINGS
-- 0028/0029, SECURITY DEFINER function executable by anon/authenticated: the
-- guard lived in `public`, which PostgREST exposes, so it was reachable at
-- /rest/v1/rpc/waitlist_capacity_guard. It moves to a `private` schema that
-- PostgREST does not serve, which removes the RPC surface entirely. Trigger
-- firing is unaffected: Postgres resolves the function to an OID at CREATE
-- TRIGGER and checks EXECUTE then, not on each insert.
--
-- 0024, RLS policy always true: WITH CHECK (true) was doing no work. It now
-- restates the table's constraints at the policy layer. That is duplication on
-- purpose - the constraint is the integrity rule, the policy is the access
-- rule, and a future ALTER that relaxes one should not silently relax both.

-- A schema PostgREST does not expose. Nothing in it is reachable over the API.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

comment on schema private is
  'Internal helpers that must never be reachable through PostgREST. Not in the exposed schema list.';

create or replace function private.waitlist_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  cap constant bigint := 50000;
begin
  -- Hard ceiling. The anon key is public, so anybody can write here; the
  -- column constraints bound what a row contains and this bounds how many
  -- there are. The count is exact rather than estimated on purpose: it makes
  -- each insert slightly dearer as the table fills, so it throttles a flood as
  -- well as capping one. Real signup volume will never notice.
  if (select count(*) from public.waitlist) >= cap then
    raise exception 'The waitlist is not accepting signups right now.'
      using errcode = 'check_violation';
  end if;

  -- Silently drop a repeat signup. Returning NULL from a BEFORE INSERT trigger
  -- cancels the row without raising, so the caller cannot tell this address was
  -- already present. security definer is what makes this readable at all - anon
  -- has no SELECT on the table.
  if exists (
    select 1 from public.waitlist w where lower(w.email) = lower(new.email)
  ) then
    return null;
  end if;

  return new;
end;
$$;

comment on function private.waitlist_guard() is
  'BEFORE INSERT guard for public.waitlist: caps the table and silently drops duplicates so no HTTP status distinguishes a new signup from a repeat one.';

-- Swap the trigger over, then drop the old public-schema function that the
-- linter flagged. Order matters - the trigger depends on it.
drop trigger if exists waitlist_capacity_guard on public.waitlist;
drop function if exists public.waitlist_capacity_guard();

drop trigger if exists waitlist_guard on public.waitlist;
create trigger waitlist_guard
  before insert on public.waitlist
  for each row execute function private.waitlist_guard();

-- Give the policy actual work to do.
drop policy if exists "anyone may join the waitlist" on public.waitlist;
create policy "anyone may join the waitlist"
  on public.waitlist
  for insert
  to anon, authenticated
  with check (
    email is not null
    and char_length(email) between 6 and 254
    and (platform is null or platform in ('windows', 'macos', 'android', 'ios'))
    and (source is null or char_length(source) <= 64)
  );

-- Remove the rows written while verifying the deployed endpoint.
delete from public.waitlist
 where lower(email) in (
   'probe1@example.com',
   'deploy-check@ghostcopy.app',
   'deploy-check2@ghostcopy.app'
 );
