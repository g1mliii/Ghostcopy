# Distribution age readiness

The original 16+ local-only draft has been replaced by server authorization in
this PR. Independent cloud accounts require age 18+. Ages 5–17 require verified,
purpose-specific KWS permission; under-5 cloud accounts stay blocked. No date of
birth is collected. The conservative global under-18 policy is an implementation
choice pending jurisdiction and suitability review, not a claim that every
country has the same legal threshold.

Child activation remains off while Epic access/configuration and live tests are
pending. The app collects no parent contact when the provider is unavailable and
starts no child auth/device/push/clipboard services until permission is confirmed.
Known child accounts require encryption/manual sends and have no optional
crash diagnostics or review entry points. Database and privileged-edge controls
apply beyond local preferences, including older/modified clients after cutover.

See [implementation and activation gates](parental-consent-implementation.md),
[security/retention programme](children-security-and-retention.md), and
[store review behavior](store-reviews.md). Policy changes and audience declarations
must be reviewed against the actual enabled build. A text-heavy clipboard app
must not claim a preschool audience just because its consent code supports age 5.
The Play/App Store listing should remain aligned with the presently available
service until the matching release passes those gates.
