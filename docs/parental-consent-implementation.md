# Parental cloud authorization implementation

This work extends draft PR #141. The selected integration is KWS User Permissions
with Parent Verification and Family Management. Provider access has been requested;
the signed-in API specification is readable before activation. Test credentials,
production credentials and webhook secrets are separate. No developer credential
belongs in Flutter, a public page or git.

## Conservative initial policy

Cloud accounts require adult acknowledgement or verified parental authorization
for ages 5–17. Use a global under-18 VPC definition until jurisdiction-specific
definitions are reviewed. Collect age in years and country, not a birth date.
Children under 5 remain blocked. No active child account, device registration,
FCM token, diagnostics or clipboard upload starts while consent is pending.

KWS permissions are `ghostcopy.cloudSync` (account, devices and encrypted text
sync) and `ghostcopy.fileSync` (optional encrypted image/file sync). Parent-managed
accounts require end-to-end encryption, manual sending, and no diagnostics or
public store review entry points. The store and published age declarations must
match the eventual enabled build; this is not legal clearance.

## Enforcement boundaries

- Before account creation: a narrowly scoped consent endpoint accepts a parent
  contact address, age and country, rate-limits requests and returns an opaque
  device capability. Store only its hash. Pending requests expire in 14 days.
- KWS initiates direct notice and purpose-specific VPC. A PV adult-verification
  event alone never authorizes an account. Grants also require authoritative
  permission reads showing boolean parent limits/effective values and VPC.
- The app binds an approved request to its authenticated anonymous account.
  Account authorization is immutable from ordinary client writes; a known child
  account cannot become adult by changing local preferences or request bodies.
- Restrictive database policies guard existing cloud tables and legacy/partition
  paths. Edge storage, QR exchange and push paths must check the same server
  authorization, including service-role paths that bypass RLS.
- Signed UP/FM events invalidate authorization; duplicates, stale events,
  wrong organizations/products and invalid signatures must not enable access.
  Authorization leases bound damage from missed revocation events and fail
  closed when a refresh cannot confirm the required permissions.
- Parents use the KWS family portal to change permissions. An app-specific
  authenticated parent portal provides access/export, withdrawal and deletion;
  its relationship checks use the verified original contact address, never a
  child-supplied parent ID or an editable JWT user-metadata claim.
- Account deletion and pending expiry enqueue idempotent provider cleanup;
  Supabase/R2 data removal continues through the existing durable deletion queue.
  Audit records exclude contact addresses, clipboard data and verification IDs
  supplied to KWS's verification vendors.

## Setup and signed-out recovery

Desktop first-run setup shows a normal, focused window before awaiting acceptance;
cloud and clipboard services still start only after setup completes. Ordinary tray
startup is restored afterward. Same-account token refreshes keep the current
composer and attachments mounted; account switches and denied checks remove them.
The diagnostics SDK stays uninitialized until server classification confirms an
opted-in adult. It closes before any interactive account change, sign-out or
deletion and remains off for the rest of that launch; a fresh launch must confirm
adult eligibility again. Early, unclassified startup failures are not collected.
Email signup and confirmation authorize the installed session before registering
its desktop device. Account deletion is unavailable while signed out. Transient
permission-check failures keep push tokens; explicit denials revoke them and a
successful mobile retry re-enables and registers push. Renewed device proofs reuse
the existing bound profile after permission refresh rather than attempting a new
claim-hash binding.

Signing out discards the session and pauses setup. Completing permission setup
again does not create a new guest when the request already belongs to an account.
Instead choose **Link existing device** and obtain a fresh link code and separate
six-digit PIN from **Settings → Link New Device** on another signed-in device
(desktop or mobile). The existing five-minute, single-use exchange and server
permission checks apply. Restore the encryption passphrase separately. If every
device is signed out, contact support with the parent; a retained permission claim
alone cannot restore an authenticated session or decrypt clipboard data.

## Integration facts verified 2026-11-12

- OAuth token: `https://auth.kidswebservices.com/auth/realms/kws/protocol/openid-connect/token`;
  client-credentials grant; UP/consent/FM scopes `settings consent family`.
- Consent: `POST /v1/settings/admin/users/{userId}/products/{productId}/send-consent-email`;
  `age`, `ageProvidedAt` (Unix seconds), `location`, `parentEmail`, `language`,
  `displayName`, `enforceParentalControl`, and the requested `settings`.
- Permissions: `GET /v1/settings/users/{userId}/products/{productId}/values` with
  `namespace=ghostcopy&format=full`; use effective values and the VPC definition.
- Provider erasure: `DELETE /v1/settings/admin/users/{userId}/values`, using an
  organization-scoped developer token. The product-only deletion endpoint removes
  preferences, so it is insufficient for complete subject data erasure.
- Required non-empty User-Agent; server-side developer tokens; regional API host
  comes from the configured UP integration rather than guessing a region.
- `x-kws-signature`: HMAC-SHA256 of timestamp, dot, exact raw request bytes;
  accept any valid active `v1` during rotation and enforce replay tolerance.

References:
- https://dev.epicgames.com/docs/kids-web-services/user-permissions-family-management/user-permissions/up-api-reference
- https://dev.epicgames.com/portal/anchored/kws/api-docs/user-permissions
- https://dev.epicgames.com/docs/kids-web-services/user-permissions-family-management/verify-your-webhook-signature
- https://dev.epicgames.com/docs/kids-web-services/user-permissions-family-management/family-management/fm-webhooks-reference

## Completion gates

Implemented: KWS OAuth/client contracts, raw-body signatures, consent HTTP
endpoints, server-only binding/authorization, RLS and service-role path guards,
parent review/export/file access/withdrawal/deletion, provider cleanup, retention
cron and the Flutter age/country/parent-waiting/encryption flow. Native ratings
are included; actual server classification also suppresses child review access.
Local tests use real PostgreSQL/RLS plus controlled provider HTTP fixtures. They
do not substitute for KWS acceptance tests. Nothing is deployed from this PR.

## Deployment configuration (maintainer reference)

The endpoint is `/functions/v1/cloud-consent`; signed callbacks use
`/functions/v1/cloud-consent/webhook`. Secret-key-only maintenance uses the same
endpoint with `action=maintenance`; the database dispatcher uses existing Vault
`supabase_api_url` and `fcm_service_role_key` settings.

Required edge secrets: `KWS_CLIENT_ID`, `KWS_CLIENT_SECRET`,
`KWS_ORGANIZATION_ID`, `KWS_PRODUCT_ID`, `KWS_API_BASE_URL`,
`KWS_PARENT_PORTAL_URL`, `CONSENT_PARENT_HASH_KEY` (at least 32 random characters),
and `KWS_WEBHOOK_SECRETS`. Use organization-scoped UP credentials so full subject
erasure is authorized. The Parent Verification TEST client is not the UP client.
The pepper is stable; rotating it without migrating associations breaks parent
lookup. Preserve it in controlled secret backup, never in source or logs.

`KWS_WEBHOOK_SECRETS` is a JSON object mapping exact event names to arrays of
active secrets (rotation). Configure separate secrets where the portal provides
separate webhook keys. Supported user events: `consent:changed`,
`consent:deleted`, `settings:effective-values-changed`,
`settings:parent-limits-changed`; family events:
`families:user-added-to-family`, `families:user-removed-from-family`,
`families:guardian-request-expired`, `families:family-group-deleted`.
Configure at least the six events required by the handler's readiness predicate;
lease refresh also fails closed on missing/expired provider permission.
Do not configure a PV-only webhook as proof of purpose consent.

The checked-in permission YAML is a template requiring the actual product ID.
Its boolean restriction, age brackets and dependencies follow KWS documentation;
validate/import in TEST and verify exact returned consent type/timestamps before
production. Parent notice/branding must link to the published matching notices.
Use the actual hosted Family Management portal URL, not a guessed subdomain.
Parent login signup links use the conditional existing confirmation email
(template `Data.parent_portal`); sessions remain in browser memory. This metadata
changes the email destination only and never grants parent privileges.

Migrations initially preserve unknown legacy accounts (`enforce_all_accounts`
false) while protecting all known classifications. Child activation also requires
strict enforcement: `child_consent_enabled` cannot be true unless
`enforce_all_accounts` is true. Ship/review a mandatory update and adult
re-acknowledgement plan before that coordinated cutover. Never infer that unknown
existing accounts are adults. Children stay disabled even with database flags on
when required provider configuration is absent.

A device linked by an authenticated QR session receives a domain-separated,
HMAC-signed pre-auth consent proof for that already-bound child/request. This
reconciles its local receipt before the next launch: its Firebase/Sentry startup
cannot rely on an earlier adult receipt. The proof lives in secure storage,
expires after 366 days, and renews in its last 30 days while authenticated. Every
poll still reads current server/provider permission; the proof is not an auth
session and cannot bind a different user or revive a withdrawn/unlinked request.
Changing its payload case or fields invalidates the MAC. Deleting/replacing the
request invalidates its proofs through the database lookup.

## One client gate, shared server enforcement

The app checks consent at authentication, account changes, foreground resume and
child lease refresh, with one root route guard and a pause/sign-out action. It
does not intercept every database HTTP request. Background prefetch and headless
entry points use the same session check because they run without the UI guard.
RLS calls one shared authorization predicate for sends/receives and device data;
service-role storage, QR and push paths use one shared backend helper. An auth
token alone is not a consent grant and can outlive parental withdrawal.

## Activation gates

Keep this PR draft until approved service access/terms, actual TEST and production
credentials/product IDs, provider definitions and webhooks, real end-to-end
verification/permission/withdrawal/unlink/expiry/deletion tests, and physical
Android/iOS checks are complete. Test missed/duplicate/out-of-order webhooks and
an outage past the 15-minute authorization lease. Review actual processor backup,
log and identity-vendor retention plus restore suppression; confirm the operator’s
legal identity and required public contact details in the parent notice; the security and
retention programme records these unresolved operational checks. Review country
law, child suitability and store audience/data disclosures for the enabled build.
Epic approval alone does not complete those checks. Release build/upload follows
PR review and successful activation testing, as requested.
