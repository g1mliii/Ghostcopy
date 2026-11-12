# Mobile store reviews

GhostCopy uses `in_app_review` for Apple's StoreKit prompt and Google Play's
In-App Review API. The platform owns the prompt and may silently suppress it.
Finishing the API call does not prove a dialog appeared or a rating was submitted.

Automatic requests are enabled only in release builds on Android/iOS and only
for adults with a current onboarding acknowledgement. Public review entry
points remain unavailable to teen or blocked users while the child/parent
authorization work is incomplete.

A request requires at least seven days since the first successful foreground
send, ten successful sends across three UTC dates, and no review attempt in
the preceding 120 days. Counts and dates remain on the device; clipboard
contents and user sentiment are not collected. No incentives or pre-rating
questions are shown.

After a successful manual send, the screen waits five seconds and checks that
it is still foreground/current, not sending or composing, and the keyboard is
closed. Typing, opening Settings, leaving the app and screen disposal cancel
the pending timer. Platform availability and presentation eligibility are
checked again before requesting the prompt. No automatic store redirect occurs
when the native prompt is unavailable.

The explicit **Rate GhostCopy** Settings row opens the store listing/review
page, using Apple app ID `6811251899` and the current Android package
`com.ghostcopy.ghostcopy`. It does not invoke the quota-limited prompt, so the
button is useful even when the stores decline to show an in-app dialog.

Validation before release:
- Check the Settings link on physical iOS and Android devices.
- Verify the native prompt with an eligible Google Play testing install;
  ordinary sideloads do not establish Play review behavior.
- Test iOS native presentation in a development install. TestFlight suppresses
  the review prompt. Store quotas also control production presentation.
- Revisit review-link access and store declarations before enabling younger
  accounts; this feature does not establish parental authorization.

Primary references checked 2026-11-12:
- https://developer.android.com/guide/playcore/in-app-review
- https://developer.apple.com/documentation/storekit/requesting-app-store-reviews
- https://pub.dev/packages/in_app_review
