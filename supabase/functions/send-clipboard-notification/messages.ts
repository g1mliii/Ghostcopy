// Which devices a clip is pushed to, and what each one is sent. Pure, so the
// routing can be tested without Firebase, WNS or a database
// (messages_test.ts).

import { isWnsChannelUri } from './wns.ts';

export type DeviceRow = {
  id: string;
  device_type: string;
  device_name: string | null;
  fcm_token: string | null;
  wns_channel_uri?: string | null;
};

export type ClipContext = {
  clipboardId: string;
  senderType: string;
  contentType: string;
  title: string;
  body: string;
  isMedia: boolean;
};

const DESKTOP_TYPES = new Set(['windows', 'macos', 'linux']);

/// Devices push may reach. Desktops only while desktop_push_enabled is on:
/// turning the flag off must stop pushes to desktops that registered while
/// it was on, not just stop new ones registering.
export function pushTargets(devices: DeviceRow[], desktopPushEnabled: boolean): DeviceRow[] {
  return devices.filter((device)=>desktopPushEnabled || !DESKTOP_TYPES.has(device.device_type));
}

export function fcmTargets(devices: DeviceRow[]): DeviceRow[] {
  return devices.filter((device)=>typeof device.fcm_token === 'string' && device.fcm_token.length > 0);
}

export function wnsTargets(devices: DeviceRow[]): DeviceRow[] {
  return devices.filter((device)=>device.device_type === 'windows' && isWnsChannelUri(device.wns_channel_uri));
}

/// The FCM message for one device: a silent wake-up for a Mac, a visible
/// notification for a phone.
export function fcmMessageFor(device: DeviceRow, clip: ClipContext) {
  const token = device.fcm_token as string;
  if (device.device_type === 'macos') {
    // A desktop's push is a wake-up, not a notification: the app is running
    // in the tray, fetches the clip itself and shows its own toast. So no
    // alert, no sound, nothing in Notification Center - just the row id.
    // 'background' push type with priority 5 is what Apple requires for
    // content-available.
    return {
      token,
      data: {
        clipboard_id: clip.clipboardId
      },
      apns: {
        headers: {
          'apns-push-type': 'background',
          'apns-priority': '5'
        },
        payload: {
          aps: {
            'content-available': 1
          }
        }
      }
    };
  }
  return {
    token,
    notification: {
      title: clip.title,
      body: clip.body
    },
    data: {
      // Data values MUST be strings in FCM
      clipboard_id: clip.clipboardId,
      device_type: clip.senderType,
      content_type: clip.contentType
    },
    // Tapping routes straight to CopyActivity - a translucent, no-history
    // activity that writes the clipboard and finishes - instead of cold
    // starting the full Flutter app (~2.5s, and visibly "opens GhostCopy").
    //
    // Safe despite CopyActivity being exported="false": the click_action
    // PendingIntent is constructed by the FCM SDK inside this app's own
    // process, and Android permits same-UID callers to start non-exported
    // components. No other app can reach COPY_ACTION.
    //
    // The push still carries no clipboard value - CopyActivity reads the
    // plaintext the background isolate cached on arrival, and falls back to
    // opening the app when that cache misses.
    android: {
      priority: 'high' as const,
      notification: {
        clickAction: 'com.ghostcopy.ghostcopy.COPY_ACTION',
        channelId: 'ghostcopy_notifications'
      }
    },
    // APNs configuration for iOS.
    //
    // No category, because iOS notifications carry no long-press
    // actions: the Copy button needed the clip already staged on the
    // device by a background isolate, and iOS wake-ups are throttled on
    // battery and usage and refused outright for a swiped-away app, so
    // it worked only sometimes. Tapping opens the app and copies, for
    // text and files alike. See AppDelegate.swift.
    //
    // No content-available either, for the same reason - waking the app
    // to prefetch a clip nothing will read is just battery.
    //
    // The alert is overridden here because the shared `notification`
    // above says "Tap to copy", which is true on Android, where the tap
    // routes to CopyActivity and the app never appears. On iOS the tap
    // opens GhostCopy, so promising a bare copy would misdescribe what
    // happens next.
    apns: {
      headers: {
        'apns-priority': '10'
      },
      payload: {
        aps: {
          'mutable-content': 1,
          alert: {
            title: clip.title,
            body: clip.isMedia ? 'Tap to open in GhostCopy' : 'Tap to open and copy'
          }
        }
      }
    }
  };
}
