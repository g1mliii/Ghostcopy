# Desktop push (macOS FCM, Windows WNS)

Lets a desktop in the tray close its Supabase realtime connection and be woken
by the operating system's push service instead, the way phones already are.
The push carries only a clipboard row id; the desktop fetches the clip with
its normal poll. Linux has no OS push service and stays on realtime.

Everything ships switched off. Nothing changes until the steps below are done
and `app_config.desktop_push_enabled` is set to true.

## How it fits together

| Piece | Where |
|---|---|
| Trigger: call the edge function when any targeted device holds a push token | `supabase/migrations/20261111120000_desktop_push.sql` |
| Send a silent FCM push to macOS rows, a WNS raw push to Windows rows | `supabase/functions/send-clipboard-notification/index.ts`, `wns.ts` |
| macOS: Firebase init, APNs/FCM token, silent push to Dart | `lib/services/impl/macos_push_service.dart` |
| Windows: WNS channel URI and raw notifications | `windows/runner/push_channel.cpp`, `lib/services/impl/windows_push_service.dart` |
| When realtime may close | `DesktopPushCoordinator` (`lib/services/desktop_push_service.dart`), `LifecycleController.desktopPushActive` |

Push is trusted only after one has actually arrived on this run. While trusted,
the tray closes realtime and the 5-minute tray health check keeps polling. If
that check finds a clip no push announced in the previous two minutes, trust is
withdrawn and realtime reopens until the next push. A desktop where push cannot
start (no Firebase config, an unpackaged Windows build, refused permission)
never closes realtime.

## macOS setup

1. In the Apple Developer portal, the `com.ghostcopy.ghostcopy` App ID needs
   the Push Notifications capability. Automatic signing under
   `-allowProvisioningUpdates` (what `build-release.sh` uses) should add it and
   regenerate the Developer ID profile; `verify-app.py` refuses a build whose
   profile does not authorize `com.apple.developer.aps-environment`, because
   macOS will not launch that app.
2. Firebase: the Mac app shares the iOS bundle id, so it uses the same Firebase
   iOS app and the APNs auth key already uploaded for iOS. Nothing new to
   register.
3. `build-release.sh` reads `ios/Runner/GoogleService-Info.plist` and passes
   its values as `--dart-define`s. Without that file the build has no push.

## Windows setup

The Store (MSIX) build only: WNS needs package identity.

1. In Partner Center, open the app, then Product management > WNS/MPNS (or
   Product identity) for the **Package SID** (`ms-app://S-1-15-2-...`) and the
   client secret.
2. Set them as edge function secrets:
   `supabase secrets set WNS_PACKAGE_SID=... WNS_CLIENT_SECRET=...`
3. Without them, Windows rows are skipped and the response's `warnings` says
   so (visible in `net._http_response`).

Not yet verified: whether Partner Center still issues these for a new app, or
now routes to an Entra app registration. If it is Entra-only, the client has to
move to the Windows App SDK's `PushNotificationManager` and the server to the
`login.microsoftonline.com` token endpoint; `wns.ts` is the only server file
that changes.

## Turning it on

```sql
update app_config set enabled = true where key = 'desktop_push_enabled';
```

Takes effect on each desktop's next launch.

## Checking it works

- A desktop's row in `devices` gets `fcm_token` (macOS) or `wns_channel_uri`
  (Windows) after launch.
- Send a clip from the phone to an idle desktop: `net._http_response` for the
  call shows `devices_notified` counting the desktop.
- The desktop log shows `[Lifecycle] Desktop push active` after the first push,
  then realtime pausing when the window hides.
