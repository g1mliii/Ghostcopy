(function () {
    'use strict';

    // Publishable key. Public by design - security comes from RLS, and
    // this same value already ships inside the desktop and mobile apps.
    var SUPABASE_URL = 'https://xhbggxftvnlkotvehwmj.supabase.co';
    var SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhoYmdneGZ0dm5sa290dmVod21qIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQxOTk5MTIsImV4cCI6MjA3OTc3NTkxMn0.4xCsBo1ztgnrlGgJM8j78VWHpdp1bAjuHkgVD00HQXA';

    var MIN_LENGTH = 8;
    var accessToken = null;

    function show(id) {
        ['state-verifying', 'state-form', 'state-done', 'state-error']
            .forEach(function (s) { document.getElementById(s).hidden = (s !== id); });
    }

    function fail(message) {
        document.getElementById('error-detail').textContent = message;
        show('state-error');
    }

    // Take the credential out of the address bar as soon as it is read,
    // so it is not left sitting in history, or in the referrer of any
    // link the user clicks from here.
    function scrubUrl() {
        try {
            history.replaceState(null, '', location.pathname);
        } catch (e) { /* non-fatal */ }
    }

    function params() {
        var out = {};
        new URLSearchParams(location.search).forEach(function (v, k) { out[k] = v; });
        // Supabase puts implicit-flow values in the fragment.
        new URLSearchParams(location.hash.replace(/^#/, '')).forEach(function (v, k) { out[k] = v; });
        return out;
    }

    // Exchange the emailed one-time token for a short-lived session.
    // token_hash is used rather than a PKCE code on purpose: a code can
    // only be redeemed with the verifier held by the app that requested
    // the reset, which this browser does not have.
    function verifyToken(tokenHash, type) {
        return fetch(SUPABASE_URL + '/auth/v1/verify', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'apikey': SUPABASE_ANON_KEY
            },
            body: JSON.stringify({ type: type || 'recovery', token_hash: tokenHash })
        }).then(function (res) {
            return res.json().then(function (body) {
                if (!res.ok || !body.access_token) {
                    throw new Error(body.error_description || body.msg || 'The link is invalid or has expired.');
                }
                return body.access_token;
            });
        });
    }

    function updatePassword(password) {
        return fetch(SUPABASE_URL + '/auth/v1/user', {
            method: 'PUT',
            headers: {
                'Content-Type': 'application/json',
                'apikey': SUPABASE_ANON_KEY,
                'Authorization': 'Bearer ' + accessToken
            },
            body: JSON.stringify({ password: password })
        }).then(function (res) {
            return res.json().then(function (body) {
                if (!res.ok) {
                    throw new Error(body.error_description || body.msg || 'Could not update the password.');
                }
                return body;
            });
        });
    }

    function start() {
        var p = params();

        if (p.error_description || p.error) {
            scrubUrl();
            fail(p.error_description || p.error);
            return;
        }

        // Already a session in the URL (implicit flow) - use it directly.
        if (p.access_token) {
            accessToken = p.access_token;
            scrubUrl();
            show('state-form');
            return;
        }

        if (p.token_hash) {
            var type = p.type || 'recovery';
            verifyToken(p.token_hash, type).then(function (token) {
                accessToken = token;
                scrubUrl();
                show('state-form');
            }).catch(function (e) {
                scrubUrl();
                fail(e.message);
            });
            return;
        }

        if (p.code) {
            // A PKCE code reached the browser. Redeeming it needs the
            // verifier stored by whichever app asked for the reset, so
            // it cannot be completed here. Means the email template is
            // still using {{ .ConfirmationURL }} instead of TokenHash.
            scrubUrl();
            fail('This link has to be opened by the GhostCopy app rather than a browser. Request a new reset link.');
            return;
        }

        fail('The link is missing its reset token. Copy it from the email in full, or request a new one.');
    }

    document.getElementById('password-form').addEventListener('submit', function (event) {
        event.preventDefault();

        var password = document.getElementById('password').value;
        var confirm = document.getElementById('confirm').value;
        var error = document.getElementById('form-error');
        var button = document.getElementById('submit-button');

        if (password.length < MIN_LENGTH) {
            error.textContent = 'Use at least ' + MIN_LENGTH + ' characters.';
            return;
        }
        if (password !== confirm) {
            error.textContent = 'The two passwords do not match.';
            return;
        }

        error.textContent = '';
        button.disabled = true;
        button.textContent = 'Updating...';

        updatePassword(password).then(function () {
            accessToken = null;
            show('state-done');
        }).catch(function (e) {
            error.textContent = e.message;
            button.disabled = false;
            button.textContent = 'Update password';
        });
    });

    start();
})();
