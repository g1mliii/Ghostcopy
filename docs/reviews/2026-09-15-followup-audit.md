# Follow-up audit of the pasted Windows and scaling notes

Checked against the current repository and migration history on 2026-09-15.
Earlier fixes in the working tree are preserved. No production changes were
applied, and the pasted claims about this machine's registry history were not
independently reproduced.

## Confirmed issues fixed locally

| Item | Change |
| --- | --- |
| Explorer send results were invisible | Native result dialog for success, missing file, oversized file, missing session, and upload failure; meaningful exit status. File size is checked before reading the file into memory. |
| Registry failures were treated as success | Check `reg.exe` exit status and throw on failure for both context-menu and protocol registration. |
| Uninstall left Explorer/protocol entries | Remove GhostCopy's two HKCU keys during uninstall. |
| Nightly cleanup held one large transaction | Replace the unbounded loop, repeated global ranking and count aggregate with one bounded transaction and a persistent user cursor. Cron runs it each minute. |
| Every deleted file caused HTTP/Vault work inside its DELETE transaction | The trigger now inserts an owner-checked outbox row. Separate workers perform R2 batch deletes, acknowledging successes and retrying failures. |
| Clipboard insert rate limit raced | Atomic conditional `INSERT ... ON CONFLICT DO UPDATE` enforces the limit, including concurrent first inserts. |
| Storage rate limit lived in a per-instance map | Database-backed atomic counters shared by all edge instances. Requests fail closed when the store is unavailable. |
| Expired QR tokens and stale counters accumulated | Scheduled cleanup, bounded to 5,000 rows per table per run. Live QR tokens are retained. |
| Abandoned anonymous accounts accumulated | Hourly cleanup of up to 1,000 empty anonymous accounts inactive for 30 days. Accounts with clips, devices, live links, or recent sessions are retained. |
| Five unused clipboard indexes added write cost | Drop the content-type, encryption-version, target-type, encrypted-flag, and full-text indexes. Application search is local regardless of whether encryption is enabled. Keep indexes supporting ownership, ordering and storage paths. |
| Idle polling repeatedly downloaded/decrypted content | Fetch only one newest ID. Fetch and decrypt its row only after the ID changes, then enforce sender/target checks. History views still fetch the content they display. |
| Client cleanup used an unbounded ID list | Fetch/delete pages of at most 100 IDs, repeating the retained-item offset after each deletion. This also handles histories larger than the PostgREST response cap. |
| Pushes updated `last_active` every time | Only update a device whose last activity is more than one hour old. |

The backend changes are in
[`20260915000000_bound_cleanup_and_rate_limits.sql`](../../supabase/migrations/20260915000000_bound_cleanup_and_rate_limits.sql)
and the existing storage/notification functions. Deploy ordering now applies
migrations before edge functions when both change.

## Claims that need qualification

### Windows 11 menu placement

The existing classic menu registration is valid. Its raw-string command bug
is already fixed in the current source. The README now explains **Show more
options / Shift+F10**. Moving it into the modern menu would be a new native
integration using `IExplorerCommand` and app identity, not a registry-string
repair. That integration was not added. [Microsoft documentation](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)

### Realtime scalability

`broadcast_clipboard_changes()` exists without a trigger, and the clients
currently use Postgres Changes. Broadcast is a valid future scaling direction,
but the notes do not establish a present outage. The common channel name does
not remove the per-subscription `user_id` filter or RLS. The desktop history
view refreshes through the sync callback and one-shot history loads; it does
not also call `watchHistory()`. Mobile uses the repository history stream.

No transport migration was applied. It should be evaluated using subscriber
counts, authorization cost and delivery lag, with private-topic authorization
and client compatibility tested before switching. Supabase recommends
Broadcast for greater scalability. [Supabase guidance](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes)

### Anonymous authentication and billing

Shipping a Supabase anon/publishable key is expected; it is not a leaked
service-role credential. Anonymous signup abuse is a real operational concern,
but this review did not inspect the live project's CAPTCHA or Auth rate-limit
settings. No CAPTCHA setting was changed: enabling it also requires a challenge
flow in the client. [Anonymous sign-in guidance](https://supabase.com/docs/guides/auth/auth-anonymous)

Old unused accounts do not count as active every month merely by existing.
MAU counts distinct users who sign in or refresh during the billing period;
deleting an account does not undo its earlier activity. The new reaper reduces
abandoned database records, not already incurred MAU usage.
[Supabase MAU definition](https://supabase.com/docs/guides/platform/manage-your-usage/monthly-active-users)

### Partitioning and severity

A flat table does not make bloat permanent. PostgreSQL vacuum reclaims dead-row
space for reuse; returning all freed space to the operating system is a
different operation. Partitioning is a workload decision, and dropping time
partitions would not preserve the current "newest 20 per user" retention rule.
No partition migration was applied. [PostgreSQL vacuum documentation](https://www.postgresql.org/docs/current/routine-vacuuming.html)

The transaction and rate-limit defects are confirmed. Calling three items
"P0" or predicting a production outage requires workload and incident evidence
that was not included in the notes.

## Verification limits

The migration is exercised with PostgreSQL/WASM, including retention budgets,
queue leases, account deletion, service-role permissions, expiry and rate-limit
boundaries. Handler tests exercise partial R2 failures and isolated edge
instances against a shared counter. These are local regression tests, not
hosted cron, live R2, or production load verification. See the
[backend instructions](../../supabase/README.md#pending-cleanup-and-rate-limit-migration).
