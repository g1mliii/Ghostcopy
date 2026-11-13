// Parent identity comes from a server-verified email session, never local metadata.
(() => {
  'use strict';
  const base = 'https://xhbggxftvnlkotvehwmj.supabase.co';
  const key = 'sb_publishable_tTHKyNA1zqQDYC8O_kMvvg_HSaoUYje';
  const el = (id) => document.getElementById(id);
  let token = null;
  let busy = false;
  const parameters = new URLSearchParams(location.search);
  const confirmation = parameters.get('type') === 'signup' ? parameters.get('token_hash') : null;
  history.replaceState(null, '', location.pathname);
  function message(value) { el('status').textContent = value; }
  async function request(path, body, authenticated = false) {
    const response = await fetch(base + path, {
      method: 'POST', cache: 'no-store', credentials: 'omit', redirect: 'error',
      headers: { 'apikey': key, 'Content-Type': 'application/json',
        ...(authenticated && token ? { Authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(body), signal: AbortSignal.timeout(20000),
    });
    const result = await response.json();
    if (!response.ok) throw new Error('Request failed. Check your details or try again.');
    return result;
  }
  const consent = (action, data = {}) => request('/functions/v1/cloud-consent', { action, ...data }, true);
  async function run(task) {
    if (busy) return;
    busy = true;
    document.querySelectorAll('button').forEach((button) => { button.disabled = true; });
    try { await task(); }
    catch { message('Could not complete the request. Check your connection and verified email, or contact support@ghostcopy.app.'); }
    finally { busy = false; document.querySelectorAll('button').forEach((button) => { button.disabled = false; }); }
  }
  function button(label, task) {
    const node = document.createElement('button');
    node.type = 'button'; node.textContent = label;
    node.className = 'rounded-lg border border-line-strong px-4 py-3';
    node.addEventListener('click', () => run(task));
    return node;
  }
  function download(value, filename) {
    const url = URL.createObjectURL(new Blob([JSON.stringify(value, null, 2)], { type: 'application/json' }));
    const link = document.createElement('a');
    link.href = url; link.download = filename; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  async function render() {
    const result = await consent('parent-list');
    const children = el('children'); children.replaceChildren();
    if (!Array.isArray(result.children)) throw new Error('Invalid response');
    if (!result.children.length) children.textContent = 'No verified child account is associated with this email.';
    for (const child of result.children) {
      const card = document.createElement('article'); card.className = 'rounded-xl border border-line-strong p-5 space-y-4';
      const heading = document.createElement('h3'); heading.className = 'text-xl'; heading.textContent = child.accountLabel;
      const details = document.createElement('p'); details.textContent = `Status: ${child.status}. Cloud sync: ${child.cloudSync ? 'allowed' : 'off'}. File sync: ${child.fileSync ? 'allowed' : 'off'}.`;
      const actions = document.createElement('div'); actions.className = 'flex flex-wrap gap-3';
      actions.append(button('Export saved data', async () => {
        const pages = []; let offset = 0;
        do {
          const page = await consent('parent-export', { id: child.id, offset });
          pages.push(page); offset = page.data?.nextOffset ?? null;
        } while (offset !== null);
        download({ pages }, `ghostcopy-${child.id}-export.json`);
        const paths = [...new Set(pages.flatMap((page) => page.data?.clips ?? []).map((clip) => clip.storage_path).filter(Boolean))];
        for (const path of paths) {
          actions.append(button('Get encrypted file', async () => {
            const file = await consent('parent-file', { id: child.id, path });
            const url = new URL(file.downloadUrl);
            if (url.protocol !== 'https:' || !url.hostname.endsWith('.r2.cloudflarestorage.com')) throw new Error('Invalid file URL');
            const link = document.createElement('a'); link.href = url.href; link.rel = 'noopener noreferrer'; link.target = '_blank';
            link.textContent = `Download ${path.split('/').pop()}`; actions.append(link);
          }));
        }
        message('Export downloaded. Clips and files remain encrypted; their passphrase is needed to read them. File links expire after five minutes.');
      }), button('Stop cloud sync', async () => {
        if (!window.confirm('Stop future cloud collection for this account? Saved data remains available for export or deletion for up to 30 days.')) return;
        await consent('parent-revoke', { id: child.id, confirm: true }); await render(); message('Cloud access has been withdrawn.');
      }), button('Delete account and data', async () => {
        if (!window.confirm('Permanently delete this child account and its saved cloud data? This cannot be undone.')) return;
        await consent('parent-delete', { id: child.id, confirm: true }); await render(); message('Account deleted. Stored files and provider records are queued for removal.');
      }));
      card.append(heading, details, actions); children.append(card);
    }
    el('login').hidden = true; el('accounts').hidden = false;
    const config = await consent('configuration');
    if (config.parentPortalUrl) {
      const url = new URL(config.parentPortalUrl);
      if (url.protocol === 'https:' && url.hostname.endsWith('.kidswebservices.com')) {
        el('family-portal').href = url.href; el('family-portal').hidden = false;
      }
    }
  }
  el('login-form').addEventListener('submit', (event) => {
    event.preventDefault();
    run(async () => {
      const session = await request('/auth/v1/token?grant_type=password', { email: el('email').value.trim(), password: el('password').value });
      el('password').value = ''; token = session.access_token;
      if (!token) throw new Error('Session unavailable');
      await render(); message('Signed in.');
    });
  });
  el('create').addEventListener('click', () => {
    if (!el('login-form').reportValidity()) return;
    run(async () => {
      await request('/auth/v1/signup', { email: el('email').value.trim(), password: el('password').value, data: { parent_portal: true } });
      el('password').value = '';
      message('Check your email and confirm your parent portal login. Then sign in here. An existing GhostCopy account can use its usual password.');
    });
  });
  el('signout').addEventListener('click', () => run(async () => {
    try { await request('/auth/v1/logout', {}, true); }
    finally { token = null; el('children').replaceChildren(); el('accounts').hidden = true; el('login').hidden = false; message('Signed out.'); }
  }));
  if (confirmation) {
    el('confirm').hidden = false;
    el('confirm-email').addEventListener('click', () => run(async () => {
      // Deliberate click: email security scanners cannot redeem the credential.
      await request('/auth/v1/verify', { type: 'signup', token_hash: confirmation });
      el('confirm').hidden = true; message('Email confirmed. You can now sign in.');
    }));
  }
})();
