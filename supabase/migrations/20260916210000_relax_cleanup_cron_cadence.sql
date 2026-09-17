-- Cleanup cron ran every minute. At current scale that is 2,880 no-op
-- transactions a day and 91% of all database log volume: a three-hour sample
-- on 2026-09-16 showed 332 cleanup runs against a single clipboard insert.
--
-- The every-minute cadence was not wrong - it was sized for scale. Both jobs
-- are bounded (at most 1000 users and 5000 rows per run, resuming from a
-- cursor), so frequent small runs are how they keep up with a large backlog.
-- There is simply no backlog yet.
--
-- WHEN TO PUT THIS BACK
--
-- Do not guess from user count. cleanup_old_clipboard_items_deep() returns
-- deleted_count, and the budget per run is 5000. If it starts returning 5000
-- regularly, every run is ending with its budget exhausted and the backlog is
-- growing faster than cleanup drains it - that is the signal to go back to
-- '* * * * *'. While it returns well under 5000, the schedule has headroom.
--
--   SELECT deleted_count, processed_users
--   FROM public.cleanup_old_clipboard_items_deep();
--
-- For scale: at */5 the drain capacity is still 5000 rows x 288 runs =
-- 1.44M row deletions per day, against 7.2M at every minute. Both are far
-- above current load; the every-minute setting only matters once sustained
-- deletions approach the lower figure.

SELECT cron.unschedule(jobid) FROM cron.job
  WHERE jobname IN ('cleanup-old-clips-bounded', 'cleanup-storage-queue');

SELECT cron.schedule('cleanup-old-clips-bounded', '*/5 * * * *',
  'SELECT * FROM public.cleanup_old_clipboard_items_deep()');

-- Storage cleanup only dispatches queued work, so the same reasoning applies:
-- nothing queues while the clipboard cleanup above finds nothing to delete.
SELECT cron.schedule('cleanup-storage-queue', '*/5 * * * *',
  'SELECT public.dispatch_storage_cleanup()');
