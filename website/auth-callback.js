(function () {
    'use strict';

    // Where Supabase lands after Google sign-in, so the browser has a real page
    // to finish on. Redirecting straight to ghostcopy:// left the tab sitting on
    // an interstitial forever: the OS took the custom scheme and the page was
    // never navigated anywhere.
    //
    // This page only forwards. It does not hold a session, and deliberately
    // does not initialise a Supabase client - the PKCE code is redeemable only
    // by the app process that started the flow and stored the verifier.

    var APP_SCHEME = 'ghostcopy://auth-callback';

    function show(id) {
        ['state-working', 'state-done', 'state-error'].forEach(function (s) {
            document.getElementById(s).hidden = (s !== id);
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
})();
