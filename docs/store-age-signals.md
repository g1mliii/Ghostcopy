# Store age signals

How GhostCopy reads the app stores' age and parental-consent signals and maps
them onto the consent flow from `distribution_onboarding.dart`,
`CloudConsentService` and `consent_service`. Researched 2026-11-17 against
Apple's developer documentation (DocC JSON for the reference pages), the
Age assurance Q&A, Google's Play Age Signals guides and release notes, and the
published `age-signals-0.0.4.aar` itself. Check the sources again before
changing this: both APIs changed several times in 2026.

## Why

Texas SB 2420 has applied to new Apple Accounts in Texas since 4 June 2026,
when a court lifted the injunction. Utah (from 6 May 2026) and Louisiana (from
1 July 2026) have similar laws, and Brazil, Australia and Singapore have their
own age requirements. Apps must read the store's age category, get parental
consent for minors, ask again after a significant change, and honor the store's
withdrawal notices. Google Play ships the same obligations for "applicable US
states" through Play Age Signals.

## Apple

### Declared Age Range

- Framework `DeclaredAgeRange`, iOS / iPadOS / Mac Catalyst / macOS 26.0.
  Apple says to build against the 26.2 SDK (Xcode 26.2) for all age-assurance
  features. `requiredRegulatoryFeatures` needs the 26.4 SDK.
- Entitlement `com.apple.developer.declared-age-range` (Boolean), the
  "Declared Age Range" capability.
- Request: `AgeRangeService.shared.requestAgeRange(ageGates: Int, _: Int?, _: Int?, in: UIViewController)`
  (an `NSWindow` overload exists on macOS; SwiftUI has `@Environment(\.requestAgeRange)`).
  One required gate, up to two more. "The system may override your age gates
  based on the local regulations."
- Response `AgeRangeService.Response`: `.declinedSharing` or
  `.sharing(range: AgeRange)`.
- `AgeRange`: `lowerBound: Int?`, `upperBound: Int?` (inclusive; under the
  lowest gate gives `lowerBound == nil`), `ageRangeDeclaration:
  AgeRangeDeclaration?` (`selfDeclared`, `guardianDeclared`, `confirmed` from
  26.5; the `*Checked` cases are deprecated), `activeParentalControls:
  ParentalControls` (`communicationLimits`).
- Errors `AgeRangeService.Error`: `notAvailable`, `invalidRequest`,
  `declinedOnboarding`, `invalidAccount`, `network`.
- `isEligibleForAgeFeatures: Bool` (26.2) and `requiredRegulatoryFeatures:
  Set<RegulatoryFeature>` (26.4) with `declaredAgeRangeRequired`,
  `significantAppChangeRequiresAdultNotification`,
  `significantAppChangeRequiresParentalConsent`.
- Terms: data is declared by the person or their guardian; the developer is
  responsible for compliance. DPLA 3.3.3(P) limits use to providing an
  age-appropriate experience.

### PermissionKit significant-change consent

- `SignificantAppUpdateTopic(description:)` (iOS / macOS 26.2), asked with
  `AskCenter.shared.ask(PermissionQuestion(significantAppUpdateTopic: topic), in: UIViewController)`
  (26.2; `NSWindow` overload on macOS).
- Answers arrive later through
  `AskCenter.shared.responses(for: SignificantAppUpdateTopic.self)`, an
  `AsyncSequence<PermissionResponse<Topic>, Never>`; `response.choice` is
  `PermissionChoice.approve` or `.decline`.
- `ask` throws `AskError.notAvailable` for adults (sandbox doc).
- `askSignificantChangePermission(for:permissionFlow:in:)` with
  `PermissionFlow` / `PermissionResult` is iOS 27 only; not used.
- Adults may need `AgeRangeService.showSignificantUpdateAcknowledgment(in:updateDescription:)`
  (iOS 26.4, not macOS) where `significantAppChangeRequiresAdultNotification`
  applies. Not wired yet (see Follow-ups).
- Apple: the developer decides what is significant, must block the update's
  functionality until the parent consents, and must handle the answer.

### Consent withdrawal: App Store Server Notifications V2

- `notificationType` `RESCIND_CONSENT`: "the parent or guardian has withdrawn
  consent for a child's app usage". No subtype. Apple also stops the app from
  launching.
- The decoded payload has `appData` (version 2.19) instead of `data`:
  `appAppleId` (absent in Sandbox), `bundleId`, `environment`,
  `signedAppTransactionInfo` (JWS).
- `signedAppTransactionInfo` decodes to `JWSAppTransactionDecodedPayload`:
  `appTransactionId`, `bundleId`, `appAppleId`, `receiptType` (the
  environment), `originalPlatform`, `receiptCreationDate`, ...
- `appTransactionId` is the link to an account. StoreKit's
  `AppTransaction.appTransactionID` (back-deployed to iOS 16) gives the same
  value on the device: one per Apple Account per app, stable across devices
  and reinstalls.
- Signatures: `signedPayload` is a compact JWS, `alg` ES256, `x5c` = leaf,
  Apple WWDR intermediate (extension 1.2.840.113635.100.6.2.1), Apple root.
  The leaf extension 1.2.840.113635.100.6.11.1 and the Apple Root CA - G3 root
  are what Apple's App Store Server Library checks; the reference pages do not
  print them.
- Sandbox: Settings > Developer > Sandbox Apple Account > Manage > Revoke App
  Consent sends a real `RESCIND_CONSENT` with `environment` Sandbox.

## Google Play

### Age Signals API

- `com.google.android.play:age-signals:0.0.4` (July 2026, latest on Google's
  Maven), Android 6.0+.
- Two calls since 0.0.4: `AgeSignalsManagerFactory.create(context)`, then
  `requestAgeSignalsAccess(AgeSignalsAccessRequest.builder().setActivity(a).build())`
  -> `ageSignalsStatus()`: `SHARED`, `NOT_SHARED`, `VERIFICATION_REQUIRED`;
  only after `SHARED`, `checkAgeSignals(AgeSignalsRequest.builder().build())`.
  In regulated US states Play sends the user to the Play Store to verify or
  set up supervision instead of showing a prompt.
- `AgeSignalsResult`: `ageLower()`, `ageUpper()` (Integer, null = unbounded),
  `ageRangeSource()` (`TIER_A` declared, `TIER_B` parent-managed,
  `TIER_C`/`TIER_D` verified, only in regions that require verification),
  `significantChangeStatus()` (`APPROVED`, `PENDING`, `DECLINED`, null),
  `significantChangeApprovalDate()`, `installId()`.
- **`userStatus` and its `VERIFIED` / `SUPERVISED` /
  `SUPERVISED_APPROVAL_PENDING` / `SUPERVISED_APPROVAL_DENIED` values were
  removed in 0.0.4.** Supervision is now `ageRangeSource == TIER_B`, and
  "approval pending / denied" is `significantChangeStatus` `PENDING` /
  `DECLINED`.
- Default bands 0-12, 13-15, 16-17, 18+. Up to three custom minimum ages in
  Play Console (at least 2 years apart, changeable once a year).
- Errors (`AgeSignalsException.getErrorCode()`): `API_NOT_AVAILABLE`,
  `PLAY_STORE_NOT_FOUND`, `NETWORK_ERROR`, `PLAY_SERVICES_NOT_FOUND`,
  `CANNOT_BIND_TO_SERVICE`, `PLAY_STORE_VERSION_OUTDATED`,
  `PLAY_SERVICES_VERSION_OUTDATED`, `CLIENT_TRANSIENT_ERROR`, `APP_NOT_OWNED`
  (not installed from Play; license testers bypass it), `SDK_VERSION_OUTDATED`,
  `INTERNAL_ERROR`.
- Regions: live answers in "applicable US states" on their effective dates
  (Google lists no states or dates). Elsewhere it depends on the user's Play
  age-sharing setting (default "Ask before sharing").
- Terms and policy: use only "to provide age-appropriate content and
  experiences in compliance with laws"; never for advertising, marketing,
  profiling, analytics, or sharing with third parties. No retention rule beyond
  that is published; GhostCopy keeps nothing but the `installId` hash below.

### Significant changes

Declared on Play Console's Age signals page: an "Effective from" date (00:00
UTC, in the future) and an en-US description shown to parents. Up to 3 pending,
up to 90 days ahead, more than 2 days apart; one approval covers all earlier
changes. Play only notifies parents where the law requires it and only for
supervised users, and does not block the app: enforcing a `PENDING` or
`DECLINED` status is the app's job.

### Revocation

**There is no RTDN, Pub/Sub or Developer API notification.** Play Console's
"Revoked app approvals" tab lists revoked `installId` values (CSV, kept 90
days). `installId` is per user per device, only for supervised users, reset by
a factory reset, and may be stored server-side only to match that report.

## What GhostCopy does

### Setup (`distribution_onboarding.dart`)

`StoreAgeSignalService` (`lib/services/store_age_signal_service.dart`) asks the
store when setup starts with no saved age, on iOS and Android only:

| Store answer | Setup |
|---|---|
| adult (`lowerBound >= 18`) | Age question skipped; existing adult path |
| minor (`upperBound < 18`) | Existing KWS parent path; the age list is limited to the band (13-15, 16-17, or "Under 5" and 5-12 for under 13), starting at the lower bound |
| Play `significantChangeStatus` PENDING or DECLINED | "Waiting for a parent" with Check again; no cloud setup |
| anything else | Unchanged self-declared age and KWS flow |

"Anything else" covers older OS versions, macOS, Windows and Linux, a
sideloaded Android build, the user or parent declining to share, a missing
entitlement and every error. The store answer is never persisted, logged or
sent anywhere except the one store reference below. Under 5 is still refused.

KWS remains the verifiable parental consent: the store's age category only
decides which path to take and pre-fills the age. Apple never reports
"supervised but not approved" through Declared Age Range, because it does not
let the app launch without the parent's download approval.

macOS is not wired: GhostCopy for Mac ships as a Developer ID build through
Sparkle, outside the Mac App Store, so the App Store consent obligations and
notifications do not apply, and adding the entitlement to a profile that lacks
it would break the signed build.

### Withdrawal

The parent request (`cloud-consent` action `start`) carries an optional
`storeRef` (`app_store` + `appTransactionId`, or `google_play` + `installId`).
The server stores only `HMAC(CONSENT_PARENT_HASH_KEY, "store-ref:<store>:<id>")`
in `private.store_consent_refs`, deleted with the request.

- Apple: `store-consent-notifications/apple` verifies the outer JWS and the
  inner app transaction against the pinned Apple Root CA - G3
  (`_shared/apple_jws.ts`), checks bundle ID, environment and app Apple ID,
  then calls `store_consent_service('revoke')`, which runs
  `consent_service('revoke')` (the parent-portal withdrawal path) for each
  request bound before the notification's `signedDate`, records
  `store_withdrew_consent`, and withdraws at KWS. The Realtime feed on
  `cloud_authorizations` blocks an open app at once.
- Google: an operator posts the Play Console revoked `installId` list to
  `store-consent-notifications/google-revocations` with a secret key.

A withdrawal signed before the reference was bound is ignored, so an old
notification or a late retry cannot cancel a later consent. Apple identifies
the Apple Account, so one reference covers all of a child's Apple devices.
Play's `installId` is per device: only the device that started setup is bound.

### Significant change

**A significant change is a new parental notice version**
(`private.notice_version()`, `parentalNoticeVersion`,
`IDistributionConsentService.version`, kept equal by `notice_version_test.mjs`).
Bump it whenever what a parent agreed to changes: new data categories, new
recipients or processors, new sharing or communication features, a new purpose,
or longer retention. Copy changes and bug fixes are not significant.

The server already refuses a parent-managed account whose notice version is
not current, which sends the child back to parent setup. On top of that:

- When parent setup completes, the device records the notice version it
  covered (`storeConsentNoticeKey`). A later setup with a different version is
  a significant change.
- iOS: sending the new KWS request also asks
  `AskCenter.ask(SignificantAppUpdateTopic(description:))` where
  `requiredRegulatoryFeatures` contains
  `significantAppChangeRequiresParentalConsent`; the answer from
  `AskCenter.responses` is stored per description (which names the version).
  Setup cannot finish while it is pending or declined, even after KWS approves.
- Android: the release that bumps the version is declared in Play Console with
  its effective date; setup cannot finish while `significantChangeStatus` is
  `PENDING` or `DECLINED`.

## Follow-ups

- Adult significant-update acknowledgement
  (`showSignificantUpdateAcknowledgment`, iOS 26.4) for regions that require it.
- A store signal that contradicts an earlier self-declared adult answer is not
  re-checked after setup.
- Binding Play `installId` for devices linked by QR after setup.
