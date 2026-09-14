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
                'Prefer': 'return=minimal'
            },
            body: JSON.stringify({
                email: email,
                platform: platform,
                source: form.getAttribute('data-source') || null
            })
        }).then(function (res) {
            // 409 is the unique index doing its job. From the visitor's side
            // "already on the list" and "just added" are the same outcome, and
            // saying so does not leak anything - they typed the address.
            if (res.ok || res.status === 409) {
                form.reset();
                setStatus(form, res.status === 409
                    ? 'You are already on the list. We will be in touch.'
                    : 'You are on the list. We will email you when builds are ready.', 'success');
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
