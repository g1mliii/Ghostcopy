-- A repeat signup that names a platform now moves the existing row to it.
--
-- The guard dropped every repeat whole. That was fine for a single beta list,
-- but the site now asks for TestFlight invites (platform 'ios') and for
-- Windows and Android notices separately - and anyone already on the list
-- from the beta days who asked for an invite was dropped with it, so the
-- request never reached anyone. The latest platform asked for wins; a repeat
-- that names none is still dropped untouched.
--
-- Still answers the same way either way: the trigger returns NULL for every
-- repeat, so no HTTP status tells a caller the address was already there.
-- What it lets a stranger do is move someone else's row to another platform,
-- which is noise in a list we read by hand, not a disclosure.

create or replace function private.waitlist_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  cap constant bigint := 50000;
begin
  -- Hard ceiling; see 20260914210000_waitlist_guard_hardening.sql.
  if (select count(*) from public.waitlist) >= cap then
    raise exception 'The waitlist is not accepting signups right now.'
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1 from public.waitlist w where lower(w.email) = lower(new.email)
  ) then
    if new.platform is not null then
      update public.waitlist w
         set platform = new.platform,
             source = coalesce(new.source, w.source)
       where lower(w.email) = lower(new.email);
    end if;
    return null;
  end if;

  return new;
end;
$$;

comment on function private.waitlist_guard() is
  'BEFORE INSERT guard for public.waitlist: caps the table, and answers a repeat signup by moving the existing row to the platform it names (if any) rather than inserting, so no HTTP status distinguishes a new signup from a repeat one.';
