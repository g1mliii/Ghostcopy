// deno test supabase/functions/send-clipboard-notification/messages_test.ts
import { assert, assertEquals, assertFalse } from 'jsr:@std/assert@1';
import { type DeviceRow, fcmMessageFor, fcmTargets, pushTargets, recipientDevices, wnsTargets } from './messages.ts';

const row = (device_type: string, extra: Partial<DeviceRow> = {}): DeviceRow => ({
  id: `${device_type}-id`,
  device_type,
  device_name: null,
  fcm_token: null,
  wns_channel_uri: null,
  ...extra
});

const clip = {
  clipboardId: '42',
  senderType: 'windows',
  contentType: 'text',
  title: 'New clipboard item',
  body: 'Tap to copy',
  isMedia: false
};

for (const platform of ['windows', 'macos']) {
  Deno.test(`${platform} pushes reach another machine on the same platform`, () => {
    const sender = row(platform, { id: 'sender', device_name: 'home' });
    const receiver = row(platform, { id: 'receiver', device_name: 'work' });
    const phone = row('ios');
    assertEquals(recipientDevices([sender, receiver, phone], platform, 'home'), [receiver, phone]);
  });
}

Deno.test('phone sender exclusion and unnamed desktop senders remain supported', () => {
  const phone = row('ios');
  const desktop = row('macos', { device_name: 'work' });
  assertEquals(recipientDevices([phone, desktop], 'ios', null), [desktop]);
  assertEquals(recipientDevices([phone, desktop], 'macos', null), [phone, desktop]);
});

Deno.test('desktops are pushed only while the flag is on', () => {
  const devices = [
    row('ios', { fcm_token: 'phone-token' }),
    row('macos', { fcm_token: 'mac-token' }),
    row('windows', { wns_channel_uri: 'https://db5.notify.windows.com/?token=x' })
  ];
  assertEquals(pushTargets(devices, false).map((d)=>d.device_type), ['ios']);
  assertEquals(pushTargets(devices, true).length, 3);
});

Deno.test('a Mac gets a silent wake-up with only the clip id', () => {
  const message = fcmMessageFor(row('macos', { fcm_token: 't' }), clip);
  assertEquals(message.data, { clipboard_id: '42' });
  assertFalse('notification' in message, 'a Mac must not show an alert per clip');
  assertEquals(message.apns.headers['apns-push-type'], 'background');
  assertEquals(message.apns.payload.aps['content-available'], 1);
});

Deno.test('a phone gets a visible notification', () => {
  const message = fcmMessageFor(row('android', { fcm_token: 't' }), clip);
  assert('notification' in message);
  assertEquals(message.data.clipboard_id, '42');
});

Deno.test('only rows with a token are sent to', () => {
  const devices = [
    row('ios', { fcm_token: 'phone-token' }),
    row('android'),
    row('windows', { wns_channel_uri: 'https://db5.notify.windows.com/?token=x' }),
    row('windows', { wns_channel_uri: 'https://evil.example/' })
  ];
  assertEquals(fcmTargets(devices).length, 1);
  assertEquals(wnsTargets(devices).length, 1);
});
