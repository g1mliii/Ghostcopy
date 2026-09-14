// Beta waitlist signup.
//
// Posts straight to PostgREST rather than through an edge function: the table
// has an insert-only policy and no select policy, so the anon key can add a row
// and cannot read one back. That is the whole threat model - the worst an
// attacker does with this key is write junk rows, which a unique index and a
// format check already limit.
//
// Publishable key, public by design. It is the same value that ships inside the
// desktop and mobile apps and in reset-password.html.
(function () {
    'use strict';

    var SUPABASE_URL = 'https://xhbggxftvnlkotvehwmj.supabase.co';
    var SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhoYmdneGZ0dm5sa290dmVod21qIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQxOTk5MTIsImV4cCI6MjA3OTc3NTkxMn0.4xCsBo1ztgnrlGgJM8j78VWHpdp1bAjuHkgVD00HQXA';

    // Deliberately loose. The server has the authoritative check; this only
    // catches the obvious typo before a round trip.
    var EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

    // A human does not land on the page and submit inside two seconds. This is
    // friction for naive bots, not a security control - anything that runs a
    // real browser or posts straight to the API walks past it.
    var MIN_DWELL_MS = 2000;
    var loadedAt = Date.now();

    function setStatus(form, message, tone) {
        var el = form.querySelector('[data-waitlist-status]');
        var idle = form.querySelector('[data-waitlist-idle]');
        if (!el) return;
        el.textContent = message;
        el.className = 'mt-4 text-sm ' + (
            tone === 'error' ? 'text-danger' :
                tone === 'success' ? 'text-success' : 'text-ink-1'
        );
        if (idle) idle.hidden = Boolean(message);
    }

    function submit(form) {
        var input = form.querySelector('input[name="email"]');
        var button = form.querySelector('button[type="submit"]');
        var label = form.querySelector('[data-waitlist-label]');
        var email = (input && input.value || '').trim();

        // Honeypot. Hidden from people and from screen readers; a bot that
        // fills every field trips it. Report success and send nothing, so it
        // has no signal to adapt to.
        var trap = form.querySelector('input[name="company"]');
        if ((trap && trap.value) || Date.now() - loadedAt < MIN_DWELL_MS) {
            form.reset();
            setStatus(form, 'You are on the list. We will email you when builds are ready.', 'success');
            if (button) button.hidden = true;
            return;
        }

        if (!EMAIL.test(email) || email.length > 254) {
            setStatus(form, 'That does not look like an email address.', 'error');
            if (input) input.focus();
            return;
        }

        var platform = null;
        var checked = form.querySelector('input[name="platform"]:checked');
        if (checked) platform = checked.value;

        var original = label ? label.textContent : '';
        if (button) button.disabled = true;
        if (label) label.textContent = 'Sending';
        setStatus(form, '', 'idle');

        fetch(SUPABASE_URL + '/rest/v1/waitlist', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'apikey': SUPABASE_ANON_KEY,
                // return=minimal is required, not cosmetic: the default asks
                // PostgREST to return the inserted row, which needs a SELECT
                // privilege anon does not have and must never have.
                //
                // Deduplication is NOT done with resolution=ignore-duplicates.
                // That compiles to ON CONFLICT, which needs SELECT on the
                // arbiter index to evaluate - so it failed every insert with a
                // 401. A BEFORE INSERT trigger drops repeats instead, and
                // answers 201 either way, so no status code reveals whether an
                // address was already on the list.
                'Prefer': 'return=minimal'
            },
            body: JSON.stringify({
                email: email,
                platform: platform,
                source: form.getAttribute('data-source') || null
            })
        }).then(function (res) {
            // A repeat signup is dropped by the trigger and still answers 201,
            // so both outcomes look identical from here - which is the point.
            // 409 stays handled because the unique index is still there as a
            // backstop, and two simultaneous signups for one address could
            // race past the trigger's existence check.
            if (res.ok || res.status === 409) {
                form.reset();
                setStatus(form, 'You are on the list. We will email you when builds are ready.', 'success');
                if (button) button.hidden = true;
                return;
            }
            throw new Error('http ' + res.status);
        }).catch(function () {
            setStatus(form, 'That did not go through. Try again, or email support@ghostcopy.app.', 'error');
        }).then(function () {
            if (button && !button.hidden) button.disabled = false;
            if (label) label.textContent = original;
        });
    }

    document.addEventListener('submit', function (event) {
        var form = event.target;
        if (!form || !form.hasAttribute || !form.hasAttribute('data-waitlist')) return;
        event.preventDefault();
        submit(form);
    });

    // Offline fallback. Lives here rather than in an inline <script> so the CSP
    // can stay at script-src 'self' with no 'unsafe-inline'.
    if ('serviceWorker' in navigator) {
        window.addEventListener('load', function () {
            navigator.serviceWorker.register('/sw.js').catch(function () { /* non-fatal */ });
        });
    }
})();
