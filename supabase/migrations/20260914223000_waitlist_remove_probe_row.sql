-- Removes the last row written while verifying the deployed signup endpoint.
--
-- 20260914210000 cleared the earlier probes, but the happy path could only be
-- confirmed *after* that migration applied, so this address was inserted after
-- the cleanup ran. Deleting it here rather than by hand keeps the launch list
-- free of fake signups without anyone having to remember to do it, and leaves a
-- record of why the row existed.
--
-- It cannot be done over the API: anon holds INSERT on this table and nothing
-- else, which is the point.

delete from public.waitlist
 where lower(email) = 'deploy-check@ghostcopy.app';
