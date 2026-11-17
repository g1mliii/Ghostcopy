# Parent-managed service: security and retention programme

Status: release preparation, 12 November 2026. Owner: GhostCopy release maintainer.
This records the proposed operating programme and implemented controls, not a
claim of legal certification or an already completed provider assessment.

## Data, purposes and access

Before consent, collect only age in years, country and parent email for direct
notice and verification. No date of birth, child name, clipboard account, device
registration or push token is needed. The edge forwards the email to KWS and
stores an HMAC association rather than plaintext; the device claim is random and
stored only in secure storage, with its hash at the server. Network providers
still see connection metadata. Document their logging before activation.

KWS UP records verified permission for `ghostcopy.cloudSync` and optional
`ghostcopy.fileSync`; adult PV alone is insufficient. Parent-managed content is
encrypted by the client. Supabase sees account/device/delivery metadata and
ciphertext; Cloudflare R2 receives optional encrypted files; Firebase/APNs receive
delivery identifiers and notifications. File names, types, sizes and timing are
metadata and must not be described as end-to-end encrypted. No targeted ads,
optional crash reporting, review requests or automatic sending for these accounts.

Application administrators must use individual accounts, MFA and least privilege.
Service-role, KWS OAuth, webhook and HMAC keys stay in deployment secrets, never
the app, browser bundle, PR screenshots or audit records. Use separate TEST and
production credentials. Record credential owners, processor contracts, permitted
regions and subprocessors before enabling the child service. The current draft
does not attest that these account-level controls have been audited.

## Technical controls and assessment

- RLS adds restrictive authorization and encryption/file-scope checks to existing
  ownership policies, including legacy content and partition entry points.
- Privileged storage, push and QR paths check the same authorization; deleting
  one's data remains possible after authorization is withdrawn.
- Ordinary clients cannot write authorization/evidence or execute internal RPCs.
  A known child account cannot become adult through local preferences/JWT metadata.
- Signed raw-body webhooks are scoped to organization, product and event secret,
  replay checked and deduplicated. Explicit denial wins over stale provider reads.
  Existing child-device file links expire within 60 seconds; requested parent export links within five minutes. Provider refresh uses revision checks and leases; missing webhooks cannot extend
  a child authorization beyond 15 minutes without a successful permission read.
- Parent exports/deletions require a server-verified original parent email and
  approved relationship. Parent unlink/age-out removes management rights. No
  parent-supplied user ID or editable metadata creates a relationship.
- Rate limits constrain public email requests. Content and identity verification
  documents are excluded from consent logs/audits. Raw provider errors are not
  returned to clients. A stolen unlocked device, shared passphrase or forwarded
  verification email remains a risk; communicate this to parents.
- Encryption does not prove an app is suitable for five-year-olds or satisfy all
  country-specific child laws. Review the actual data flow, notices, lawful basis,
  international transfers and Google/Apple audience declarations before launch.

## Retention and deletion schedule

| Data | Purpose and retention | Deletion mechanism |
| --- | --- | --- |
| Unbound consent request and parent association | Complete verification; at most 14 days | 15-minute maintenance job; provider erasure queue |
| Rate buckets | Abuse prevention; up to 2 hours | Maintenance job |
| Webhook deduplication records | Safe retries; 30 days | Maintenance job |
| Active relationship and minimal consent audit | Account management and proof of current purposes | Account/request removal; audit removed after another 30 days |
| Withdrawn parent-managed cloud account | Allow review/export/deletion; at most 30 days since withdrawal | Auth deletion cascades through existing clip/device/file cleanup |
| Unused parent-managed cloud account, including QR synthetic email | At most 90 days without refreshed authorization | Bounded maintenance deletion |
| Ciphertext clips/files on active accounts | Linked-device delivery; newest 20 clips per account, or user deletion sooner | Existing clip cleanup and durable R2 deletion queue |
| KWS subject data | Verification and current permission | Org-level subject erasure queued on request/account deletion; retries on outage |
| Local pasted/downloaded copies | Controlled by device owner | Cloud deletion cannot recall these copies |
| Supabase/R2/Firebase/KWS backups, provider logs and verification vendors | Provider-specific | Confirm actual contractual schedules, deletion propagation and restore suppression before activation |

Do not replace the last row with an invented deadline. Provider approval alone
does not resolve it. Monitor cleanup backlog/oldest age and failed cron calls;
raise an incident if deletion cannot complete within the disclosed schedule.
Keep tombstones/restore procedures so a database recovery does not revive an
account whose deletion happened after the backup. Test that operational procedure
before launch; source-code deletion queues alone do not validate backup recovery.

## Incident response and review

The release maintainer owns the data inventory, access review and incident log.
Review controls at least annually and before changing processors, purposes,
permissions, encryption, age policy or retention. Re-consent is required for a
materially expanded child data purpose. Rotate compromised keys, disable child
activation, revoke affected server authorizations, preserve minimal incident
evidence, investigate processor exposure and follow applicable notification duties.
Do not log clipboard payloads while investigating. Validate controls and restore/
deletion handling using disposable TEST accounts, not real child information.

## References reviewed

- [FTC COPPA FAQ](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions)
- [COPPA final rule, 22 April 2025](https://www.govinfo.gov/content/pkg/FR-2025-04-22/pdf/2025-05904.pdf)
- [Google Play audience requirements](https://support.google.com/googleplay/android-developer/answer/9867159)
- [KWS permission definitions](https://dev.epicgames.com/docs/kids-web-services/user-permissions-family-management/user-permissions/up-definitions-reference)
