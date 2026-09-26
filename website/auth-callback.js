(function () {
    'use strict';

    // Where Supabase lands after Google sign-in, so the browser has a real page
    // to finish on. Redirecting straight to ghostcopy:// left the tab sitting on
    // an interstitial forever: the OS took the custom scheme and the page was
    // never navigated anywhere.
    //
    // Also where the signup and email-change confirmation emails point, with a
    // token_hash (see supabase/email-templates/confirm-signup.html). Opening
    // this page redeems nothing - which is the point, since mail scanners and
    // link previews open links before the user does. The token goes to the
    // app, or is redeemed here only when the user presses the button.
    //
    // For a sign-in this page only forwards. It does not hold a session, and
    // deliberately does not initialise a Supabase client - the PKCE code is
    // redeemable only by the app process that started the flow and stored the
    // verifier.

    var APP_SCHEME = 'ghostcopy://auth-callback';

    // Public by design, and the same value compiled into the apps
    // (lib/main.dart); security comes from RLS.
    var SUPABASE_URL = 'https://xhbggxftvnlkotvehwmj.supabase.co';
    var SUPABASE_KEY = 'sb_publishable_tTHKyNA1zqQDYC8O_kMvvg_HSaoUYje';

    function show(id) {
        document.querySelectorAll('section[id^="state-"]').forEach(function (s) {
            s.hidden = (s.id !== id);
        });
    }

    function fail(message) {
        document.getElementById('error-detail').textContent = message;
        show('state-error');
    }

    function params() {
        var out = {};
        new URLSearchParams(location.search).forEach(function (v, k) { out[k] = v; });
        // Supabase puts some values in the fragment rather than the query.
        new URLSearchParams(location.hash.replace(/^#/, '')).forEach(function (v, k) { out[k] = v; });
        return out;
    }

    // Take the credential out of the address bar once read, so it is not left
    // in history or in the referrer of anything clicked from here.
    function scrubUrl() {
        try {
            history.replaceState(null, '', location.pathname);
        } catch (e) { /* non-fatal */ }
    }

    var p = params();
    scrubUrl();

    var providerError = p.error_description || p.error;
    if (providerError) {
        fail(providerError);
        return;
    }

    if (p.token_hash) {
        confirmEmail(p.token_hash, p.type);
        return;
    }

    // Only the PKCE code is ever forwarded. access_token/refresh_token name a
    // session chosen by whoever built the URL, and the app refuses them anyway
    // (see lib/utils/auth_callback.dart) - not passing them on keeps this page
    // from being a way to aim one at the app.
    var code = p.code;
    if (!code) {
        fail('The sign-in link was missing its authorization code.');
        return;
    }

    var target = APP_SCHEME + '?code=' + encodeURIComponent(code);

    var retry = document.getElementById('retry');
    if (retry) retry.setAttribute('href', target);

    // Navigating to a custom scheme does not change the page, so the success
    // state is shown on a short delay rather than waiting for an event the
    // browser never fires.
    location.href = target;
    setTimeout(function () { show('state-done'); }, 600);

    // Hand the emailed token to the app, which redeems it and lands signed in.
    // The app may not be on this device, and refuses a token it did not ask
    // for - one from another device's sign-up, or an email change on an
    // account it is already signed in to - without this page ever knowing.
    // So confirming in the browser stays on offer, and the copy does not
    // promise a sign-in.
    function confirmEmail(tokenHash, type) {
        // The confirmation types the emails send. Anything else did not come from us.
        if (type !== 'signup' && type !== 'email_change') {
            fail('This confirmation link is not one GhostCopy sends.');
            return;
        }
        var appLink = APP_SCHEME + '?token_hash=' + encodeURIComponent(tokenHash) +
            '&type=' + encodeURIComponent(type);
        document.getElementById('confirm-open').setAttribute('href', appLink);

        var here = document.getElementById('confirm-here');
        here.addEventListener('click', function () {
            here.disabled = true;
            here.textContent = 'Confirming…';
            verifyHere(tokenHash, type).then(function () {
                show('state-confirmed');
            }, function (err) {
                fail(err.message);
            });
        });

        location.href = appLink;
        setTimeout(function () { show('state-confirm'); }, 600);
    }

    // Redeems the token in this browser. The session that comes back is
    // discarded: the address is confirmed, and signing in belongs to the app.
    function verifyHere(tokenHash, type) {
        return fetch(SUPABASE_URL + '/auth/v1/verify', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'apikey': SUPABASE_KEY },
            body: JSON.stringify({ type: type, token_hash: tokenHash })
        }).then(function (res) {
            return res.json().then(function (body) {
                if (res.ok) return;
                if (body.error_code === 'otp_expired') {
                    throw new Error('This link has already been used or has expired. ' +
                        'If GhostCopy opened a moment ago, you are already signed in there. ' +
                        'Otherwise, try signing in. If GhostCopy says the email is not ' +
                        'confirmed, sign up again with the same address for a new link.');
                }
                throw new Error(body.msg || body.error_description || 'The address could not be confirmed.');
            });
        });
    }
})();
