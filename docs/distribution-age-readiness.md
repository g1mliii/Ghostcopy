# Distribution eligibility draft

Recommended initial audience: 16+, not a child-directed or under-16 service.
This PR is a local eligibility and notice gate. It is not identity verification,
a verified parental-consent service, legal clearance, or server-side access control.
Do not market or declare support for children based on these screens.

The gate runs before Dart Sentry/Supabase/auth/device/clipboard setup; headless
send-file startup and background prefetch require a current acknowledgement.
Firebase native auto-init defaults off; messaging is enabled after setup.
A denied age choice persists locally; no birth date is requested. Acknowledge
terms/privacy explicitly, and ask 16–17-year-olds for guardian permission.
That self-declaration must not be represented as verified parental consent.

Before release:
- Legal review of minimum age, teen contractual capacity, consent basis,
  regional age-assurance obligations, notices, and actual data flows.
- Align Play target audience to 16–17 and 18+, App Store declarations, and
  published policies only when the matching build is ready.
- Audit native SDK startup, extensions, CLI entry points, existing sessions and
  backend routes. Client-side preferences cannot enforce server eligibility.
- Define a verified process for reports of child accounts, prompt data removal,
  retention/backups, parent requests, and records of consent/withdrawal.
- Verify notification/clipboard behavior on physical Android and iOS devices.

Under-16 cloud access remains blocked in this draft. The selected provider for
the next integration is Epic Kids Web Services (KWS). Its current documentation
provides Parent Verification, while User Permissions and Family Management are
marked coming soon. Adult verification alone is not purpose-specific consent.
Do not invent API/webhook contracts or enable younger accounts until the real
service configuration and end-to-end authorization are validated.

The remaining implementation requires a reviewed architecture:
neutral age assurance before personal-data collection, verifiable guardian
consent where required, parent access/deletion/revocation controls, minimal
retention, child-compatible SDKs and the Google Play Families declarations.
A terms checkbox, parent email alone, or store age rating is not that system.

Implementation work still required for the requested all-ages flow:
- Neutral jurisdiction selection and country-specific eligibility rules before
  child account registration; collect only necessary information.
- KWS Parent Verification initiation on the server, authenticated callback
  processing, replay protection and correlation to a pending guardian request.
- Separate parental notice and affirmative consent to specified data purposes;
  record notice version, purposes, verification method, time and withdrawal.
- Deny unauthorized child reads/writes in database/storage policies and every
  cloud endpoint, including old clients and CLI/extension upload paths.
- Parent review, revoke and deletion controls; retention and backup treatment.
- A staged migration for existing accounts without assuming they are adults.
- Complete child-related store declarations only once the matching flow ships.

Nothing in this draft is deployed or establishes server-side authorization.

Sources checked 2026-11-12:
- https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions
- https://support.google.com/googleplay/android-developer/answer/9893335
- https://www.priv.gc.ca/en/privacy-topics/privacy-for-businesses/appropriate-handling-of-personal-information/collecting-personal-information-and-consent/consent/gl_omc_201805/
- https://dev.epicgames.com/docs/kids-web-services/kws-get-started
- https://dev.epicgames.com/docs/kids-web-services/user-permissions-family-management
