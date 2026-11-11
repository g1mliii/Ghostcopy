// deno test supabase/functions/send-clipboard-notification/wns_test.ts
import { assert, assertFalse } from 'jsr:@std/assert@1';
import { isWnsChannelUri } from './wns.ts';

Deno.test('accepts WNS channel URIs', () => {
  assert(isWnsChannelUri('https://db5p.notify.windows.com/?token=AwYAAAB'));
  assert(isWnsChannelUri('https://notify.windows.com/?token=x'));
});

Deno.test('refuses anything a bearer token must not be sent to', () => {
  assertFalse(isWnsChannelUri('http://db5p.notify.windows.com/?token=x'));
  assertFalse(isWnsChannelUri('https://notify.windows.com.evil.example/'));
  assertFalse(isWnsChannelUri('https://evilnotify.windows.com/'));
  assertFalse(isWnsChannelUri('https://example.com/?u=notify.windows.com'));
  assertFalse(isWnsChannelUri('not a url'));
  assertFalse(isWnsChannelUri(null));
  assertFalse(isWnsChannelUri('https://a.notify.windows.com/' + 'x'.repeat(3000)));
});
