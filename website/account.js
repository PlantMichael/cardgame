// Site accounts: sign-in, registration, Google sign-in, the signed-in banner,
// the profile page, and the Play page's hand-off of the session to the game.
//
// The website owns the browser session (localStorage key `cardgame_session`, the
// same key and shape the game has always used, so existing sessions resume).
// All account truth comes from the relay; the page only displays it.
//
// Page <-> game messages (version 1, same origin, exact window checks):
//   game -> page  {cg:1,type:'ready'} | {cg:1,type:'account-dirty'} | {cg:1,type:'session-invalid'}
//   page -> game  {cg:1,type:'session',token} | {cg:1,type:'account-changed',pfp_id}
// The token is only ever posted to this page's own origin, to the game iframe's
// window, in answer to that window's 'ready'. It is never put in a URL.
(() => {
  'use strict';

  const SESSION_KEY = 'cardgame_session';
  const relayUrl = document.querySelector('meta[name="cg-relay"]')?.content || '';
  const gameSrc = document.querySelector('[data-game-src]')?.dataset.gameSrc || '';
  const REQUEST_TIMEOUT_MS = 10000;
  const GAME_READY_TIMEOUT_MS = 25000;

  const TIERS = ['Orbital', 'Lunar', 'Planetary', 'Solar', 'Nebular', 'Galactic', 'Cosmic'];
  const SUBS = ['III', 'II', 'I'];
  const LEGEND = ['Superluminal', 'Celestial', 'Universal'];
  const LEGEND_SPAN = 500;
  const LP_PER_BRACKET = 100;
  const RANK_ICONS = ['01-orbital', '02-lunar', '03-planetary', '04-solar', '05-nebular', '06-galactic', '07-cosmic',
    '08-superluminal', '09-celestial', '10-universal'];
  const PORTRAITS = JSON.parse(document.querySelector('script[data-portraits]')?.textContent || '[]');

  const el = (tag, props = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      // ARIA through attributes: the reflected properties are not in every browser.
      if (/^aria[A-Z]/.test(key)) node.setAttribute(`aria-${key.slice(4).toLowerCase()}`, value);
      else node[key] = value;
    }
    for (const child of children) node.append(child);
    return node;
  };
  const fmt = new Intl.NumberFormat('en');

  // ---- visible rank (never the hidden matchmaking rating) ------------------
  function rankOf(a) {
    if (a.rank_in_legend) {
      const idx = Math.min(Math.floor(a.rank_legend_rating / LEGEND_SPAN), LEGEND.length - 1);
      return { name: `${LEGEND[idx]} (${a.rank_legend_rating})`, icon: RANK_ICONS[7 + idx], progress: null };
    }
    const tier = Math.min(Math.floor(a.rank_bracket / SUBS.length), TIERS.length - 1);
    return { name: `${TIERS[tier]} ${SUBS[a.rank_bracket % SUBS.length]}`, icon: RANK_ICONS[tier],
      progress: `${a.rank_lp} / ${LP_PER_BRACKET} LP` };
  }
  const portraitFor = (id) => (PORTRAITS.includes(id) ? `/media/pfps/${id}` : '/media/logo.png');

  // ---- session storage -------------------------------------------------------
  function readSession() {
    try {
      const parsed = JSON.parse(localStorage.getItem(SESSION_KEY) || 'null');
      return parsed && typeof parsed.token === 'string' && parsed.token ? parsed : null;
    } catch { return null; }
  }
  function writeSession(token, username) {
    try { localStorage.setItem(SESSION_KEY, JSON.stringify({ token, username })); } catch { /* private mode */ }
  }
  function clearSession() {
    try { localStorage.removeItem(SESSION_KEY); } catch { /* ignore */ }
  }

  // ---- relay client: one socket, replies matched by type (and request id) ---
  const relay = {
    ws: null, opening: null, pending: [],
    open() {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) return Promise.resolve();
      if (this.opening) return this.opening;
      this.opening = new Promise((resolve, reject) => {
        let ws;
        try { ws = new WebSocket(relayUrl); } catch (e) { this.opening = null; reject(e); return; }
        const timer = setTimeout(() => { try { ws.close(); } catch { /* ignore */ } }, REQUEST_TIMEOUT_MS);
        ws.onopen = () => { clearTimeout(timer); this.ws = ws; this.opening = null; resolve(); };
        ws.onmessage = (event) => this.receive(event.data);
        ws.onclose = () => {
          clearTimeout(timer);
          const wasOpen = this.ws === ws;
          if (wasOpen) this.ws = null;
          if (this.opening) { this.opening = null; reject(new Error('relay unreachable')); }
          for (const p of this.pending.splice(0)) { clearTimeout(p.timer); p.reject(new Error('closed')); }
        };
      });
      return this.opening;
    },
    receive(raw) {
      let message;
      try { message = JSON.parse(raw); } catch { return; }
      const i = this.pending.findIndex((p) => p.type === message.type && (!p.match || p.match(message)));
      if (i < 0) return;
      const [p] = this.pending.splice(i, 1);
      clearTimeout(p.timer);
      p.resolve(message);
    },
    async ask(message, type, match) {
      await this.open();
      return new Promise((resolve, reject) => {
        const entry = { type, match, resolve, reject };
        entry.timer = setTimeout(() => {
          const i = this.pending.indexOf(entry);
          if (i >= 0) this.pending.splice(i, 1);
          reject(new Error('timeout'));
        }, REQUEST_TIMEOUT_MS);
        this.pending.push(entry);
        this.ws.send(JSON.stringify(message));
      });
    },
  };

  // ---- account state ---------------------------------------------------------
  // status: loading | signed-out | signed-in | offline | expired
  const state = { status: 'loading', token: '', account: null, epoch: 0, notice: '' };
  let seq = 0;
  const listeners = new Set();
  const emit = () => listeners.forEach((fn) => fn(state));

  function setIdentity(token) {
    state.epoch += 1;
    state.token = token;
    if (!token) state.account = null;
  }

  async function refresh() {
    if (!state.token) return;
    const epoch = state.epoch;
    const requestId = `${epoch}-${++seq}`;
    if (!state.account) state.status = 'loading';
    emit();
    try {
      const reply = await relay.ask({ type: 'get_account_snapshot', token: state.token, request_id: requestId },
        'account_snapshot_result', (m) => m.request_id === requestId);
      if (epoch !== state.epoch) return; // the account changed while this was in flight
      if (reply.success) { state.account = reply.account; state.status = 'signed-in'; state.notice = ''; }
      else if (reply.unauthorized) { expire('Your session has expired. Please log in again.'); return; }
      else { state.status = state.account ? 'signed-in' : 'offline'; }
    } catch {
      if (epoch !== state.epoch) return;
      state.status = state.account ? 'signed-in' : 'offline';
      if (state.account) state.notice = 'Offline. Showing your last known account details.';
    }
    emit();
  }

  function expire(message) {
    clearSession();
    setIdentity('');
    state.status = 'expired';
    state.notice = message;
    emit();
  }

  async function adoptSession(token, username) {
    writeSession(token, username);
    setIdentity(token);
    state.status = 'loading';
    state.notice = '';
    await refresh();
  }

  async function logout() {
    const token = state.token;
    game.unmount(); // stop and remove the engine before the identity changes
    clearSession();
    setIdentity('');
    state.status = 'signed-out';
    state.notice = '';
    disableGoogleAutoSelect();
    emit();
    if (!token) return;
    try { await relay.ask({ type: 'logout', token }, 'logged_out'); }
    catch {
      state.notice = 'You are signed out on this device, but the server could not be reached to end the session there.';
      emit();
    }
  }

  async function init() {
    const stored = readSession();
    if (!stored) { state.status = 'signed-out'; emit(); return; }
    setIdentity(stored.token);
    await refresh();
  }

  // Another tab signed in, out, or switched account.
  window.addEventListener('storage', (event) => {
    if (event.key !== SESSION_KEY && event.key !== null) return;
    const stored = readSession();
    const token = stored ? stored.token : '';
    if (token === state.token) return;
    game.unmount();
    setIdentity(token);
    state.notice = '';
    if (!token) { state.status = 'signed-out'; emit(); return; }
    state.status = 'loading';
    refresh().then(() => game.mountIfReady());
  });

  // ---- credentials ------------------------------------------------------------
  async function passwordAuth(kind, username, password) {
    const type = kind === 'register' ? 'register' : 'login';
    const reply = await relay.ask({ type, username, password }, `${type}_result`);
    if (!reply.success) return { error: reply.message || 'Something went wrong.' };
    await adoptSession(reply.token, reply.username);
    return {};
  }

  // ---- Google -------------------------------------------------------------------
  const google = { config: null, scriptPromise: null };
  async function googleConfig() {
    if (google.config) return google.config;
    try {
      const reply = await relay.ask({ type: 'google_config' }, 'google_config_result');
      google.config = reply.available ? { clientId: reply.client_id } : { clientId: '' };
    } catch { return { clientId: '' }; }
    return google.config;
  }
  function loadGoogleScript() {
    if (!google.scriptPromise) {
      google.scriptPromise = new Promise((resolve, reject) => {
        const s = el('script', { src: 'https://accounts.google.com/gsi/client', async: true, defer: true });
        s.onload = resolve; s.onerror = () => { google.scriptPromise = null; reject(new Error('Google script blocked')); };
        document.head.append(s);
      });
    }
    return google.scriptPromise;
  }
  function disableGoogleAutoSelect() { try { window.google?.accounts?.id?.disableAutoSelect(); } catch { /* ignore */ } }

  // Renders Google's own button into `slot`. The one-use challenge is bound to
  // the connection and purpose, then to the credential Google signs.
  async function renderGoogleButton(slot, purpose, onResult) {
    slot.replaceChildren();
    const { clientId } = await googleConfig();
    if (!clientId) { slot.append(el('p', { className: 'google-unavailable', textContent: 'Google sign-in is not available right now.' })); return; }
    try {
      await loadGoogleScript();
      const challenge = await relay.ask({ type: 'google_challenge', purpose, token: purpose === 'link' ? state.token : undefined },
        'google_challenge_result');
      if (!challenge.success) throw new Error(challenge.message || 'unavailable');
      window.google.accounts.id.initialize({
        client_id: clientId, nonce: challenge.nonce, auto_select: false, cancel_on_tap_outside: true,
        callback: async (response) => {
          const type = purpose === 'link' ? 'google_link' : 'google_signin';
          try {
            const reply = await relay.ask({ type, credential: response.credential, nonce: challenge.nonce,
              token: purpose === 'link' ? state.token : undefined }, `${type}_result`);
            await onResult(reply);
          } catch { await onResult({ success: false, message: 'Could not reach the server. Try again.' }); }
          renderGoogleButton(slot, purpose, onResult); // a challenge is single use
        },
      });
      window.google.accounts.id.renderButton(slot, { theme: 'filled_black', size: 'large', shape: 'rectangular', text: purpose === 'link' ? 'continue_with' : 'signin_with' });
    } catch {
      slot.replaceChildren(el('p', { className: 'google-unavailable', textContent: 'Google sign-in could not be loaded. You can still use your username and password.' }));
    }
  }

  // ---- dialogs ---------------------------------------------------------------
  let dialog;
  function closeDialog() { if (dialog?.open) dialog.close(); }
  function openDialog(title, build) {
    closeDialog();
    dialog = el('dialog', { className: 'account-dialog', ariaLabel: title });
    const heading = el('h2', { textContent: title });
    const close = el('button', { type: 'button', className: 'dialog-close', textContent: '×', ariaLabel: 'Close' });
    close.addEventListener('click', closeDialog);
    dialog.append(close, heading, build());
    dialog.addEventListener('close', () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();
    return dialog;
  }

  function field(label, name, type, autocomplete) {
    const id = `f-${name}-${Math.random().toString(36).slice(2, 7)}`;
    const input = el('input', { id, name, type, autocomplete, required: true, spellcheck: false });
    return { wrap: el('div', { className: 'field' }, el('label', { htmlFor: id, textContent: label }), input), input };
  }

  function passwordForm(kind, afterSignIn) {
    const isRegister = kind === 'register';
    const user = field('Username', 'username', 'text', 'username');
    const pass = field('Password', 'password', 'password', isRegister ? 'new-password' : 'current-password');
    user.input.minLength = 3; user.input.maxLength = 20; user.input.pattern = '[A-Za-z0-9_]{3,20}';
    user.input.title = '3-20 letters, numbers or underscores';
    pass.input.minLength = 6; pass.input.maxLength = 128;
    const error = el('p', { className: 'form-error', role: 'alert' });
    const submit = el('button', { type: 'submit', className: 'button', textContent: isRegister ? 'Create account' : 'Log in' });
    const form = el('form', { className: 'account-form' }, user.wrap, pass.wrap, error, submit);
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      submit.disabled = true; error.textContent = '';
      try {
        const result = await passwordAuth(kind, user.input.value.trim(), pass.input.value);
        if (result.error) { error.textContent = result.error; submit.disabled = false; return; }
        closeDialog();
        afterSignIn?.();
      } catch { error.textContent = 'Could not reach the server. Try again.'; submit.disabled = false; }
    });
    return form;
  }

  function googleSignInSection(afterSignIn) {
    const slot = el('div', { className: 'google-slot' });
    const holder = el('div', { className: 'google-block' }, el('p', { className: 'divider', textContent: 'or' }), slot);
    renderGoogleButton(slot, 'signin', async (reply) => {
      if (!reply.success) { showGoogleError(holder, reply.message); return; }
      if (reply.needs_username) { openUsernameDialog(reply.setup_token, afterSignIn); return; }
      await adoptSession(reply.token, reply.username);
      closeDialog();
      afterSignIn?.();
    });
    return holder;
  }
  function showGoogleError(holder, message) {
    holder.querySelector('.google-error')?.remove();
    holder.append(el('p', { className: 'form-error google-error', role: 'alert', textContent: message || 'Google sign-in failed.' }));
  }

  function openUsernameDialog(setupToken, afterSignIn) {
    openDialog('Choose your game username', () => {
      const user = field('Game username', 'username', 'text', 'username');
      user.input.minLength = 3; user.input.maxLength = 20; user.input.pattern = '[A-Za-z0-9_]{3,20}';
      const error = el('p', { className: 'form-error', role: 'alert' });
      const submit = el('button', { type: 'submit', className: 'button', textContent: 'Create account' });
      const existing = el('button', { type: 'button', className: 'text-button', textContent: 'I already have a cardgame account' });
      existing.addEventListener('click', () => {
        openDialog('Log in to link Google', () => el('div', {},
          el('p', { textContent: 'Log in with your username and password, then choose Link Google on your profile page. Your progress stays on your existing account.' }),
          passwordForm('login', afterSignIn)));
      });
      const form = el('form', { className: 'account-form' },
        el('p', { textContent: 'This is the name other players see. It is not taken from your Google account.' }),
        user.wrap, error, submit, existing);
      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        submit.disabled = true; error.textContent = '';
        try {
          const reply = await relay.ask({ type: 'google_register', setup_token: setupToken, username: user.input.value.trim() }, 'google_register_result');
          if (!reply.success) {
            error.textContent = reply.message || 'Could not create the account.';
            submit.disabled = reply.code === 'expired' || reply.code === 'google_in_use';
            return;
          }
          await adoptSession(reply.token, reply.username);
          closeDialog();
          afterSignIn?.();
        } catch { error.textContent = 'Could not reach the server. Try again.'; submit.disabled = false; }
      });
      return form;
    });
  }

  function openLogin(kind = 'login', afterSignIn) {
    openDialog(kind === 'register' ? 'Create your account' : 'Log in', () => {
      const switcher = el('button', { type: 'button', className: 'text-button',
        textContent: kind === 'register' ? 'Already have an account? Log in' : 'New here? Create an account' });
      switcher.addEventListener('click', () => openLogin(kind === 'register' ? 'login' : 'register', afterSignIn));
      return el('div', {}, passwordForm(kind, afterSignIn), googleSignInSection(afterSignIn), switcher);
    });
  }

  // ---- banner ------------------------------------------------------------------
  const slot = document.querySelector('[data-account-slot]');
  function renderBanner() {
    if (!slot) return;
    slot.replaceChildren();
    const a = state.account;
    if (state.status === 'loading' && !a) { slot.append(el('span', { className: 'account-loading', role: 'status', textContent: 'Loading account…' })); return; }
    if (state.status === 'offline' && !a) {
      const retry = el('button', { type: 'button', className: 'text-button', textContent: 'Retry' });
      retry.addEventListener('click', refresh);
      slot.append(el('span', { className: 'account-loading', role: 'status', textContent: 'Can’t reach the server. ' }), retry);
      return;
    }
    if (!a) {
      const login = el('button', { type: 'button', className: 'account-link', textContent: 'Log in' });
      const register = el('button', { type: 'button', className: 'account-link strong', textContent: 'Register' });
      login.addEventListener('click', () => openLogin('login', () => game.mountIfReady()));
      register.addEventListener('click', () => openLogin('register', () => game.mountIfReady()));
      slot.append(login, register);
      return;
    }
    const rank = rankOf(a);
    const toProfile = el('a', { className: 'account-profile', href: '/account/', ariaLabel: `Profile for ${a.username}` },
      el('img', { className: 'account-avatar', src: portraitFor(a.pfp_id), alt: '', width: 40, height: 40,
        onerror() { this.src = '/media/logo.png'; } }),
      el('span', { className: 'account-name', textContent: a.username }));
    const rankNode = el('span', { className: 'account-rank', title: `${rank.name}${rank.progress ? ` · ${rank.progress}` : ''}` },
      el('img', { src: `/media/ranks/${rank.icon}.png`, alt: '', width: 28, height: 28 }),
      el('span', { className: 'account-rank-text' }, el('span', { textContent: rank.name }), rank.progress ? el('small', { textContent: rank.progress }) : ''));
    const money = el('span', { className: 'account-balances' },
      el('span', { className: 'balance', title: 'Cyllats' }, el('img', { src: '/media/icons/cyllats.png', alt: 'Cyllats', width: 20, height: 20 }), el('span', { textContent: fmt.format(a.currency) })),
      el('span', { className: 'balance', title: 'Glimmer' }, el('img', { src: '/media/icons/glimmer.png', alt: 'Glimmer', width: 20, height: 20 }), el('span', { textContent: fmt.format(a.dust) })));
    const out = el('button', { type: 'button', className: 'account-link', textContent: 'Log out' });
    out.addEventListener('click', logout);
    slot.append(toProfile, rankNode, money, out);
    if (state.status === 'offline' || state.notice) slot.append(el('span', { className: 'account-notice', role: 'status', textContent: state.notice || 'Offline.' }));
  }

  // ---- profile page -------------------------------------------------------------
  const profileRoot = document.querySelector('[data-profile]');
  function renderProfile() {
    if (!profileRoot) return;
    profileRoot.replaceChildren();
    const a = state.account;
    if (!a) {
      const message = state.status === 'loading' ? 'Loading your account…'
        : state.status === 'offline' ? 'Can’t reach the server right now.' : (state.notice || 'Log in to see your profile.');
      profileRoot.append(el('p', { className: 'profile-message', role: 'status', textContent: message }));
      if (state.status === 'signed-out' || state.status === 'expired') {
        const b = el('button', { type: 'button', className: 'button', textContent: 'Log in' });
        b.addEventListener('click', () => openLogin('login'));
        profileRoot.append(b);
      }
      return;
    }
    const rank = rankOf(a);
    const status = el('p', { className: 'form-status', role: 'status' });
    const picker = el('div', { className: 'portrait-picker', role: 'radiogroup', ariaLabel: 'Profile picture' });
    for (const id of PORTRAITS) {
      const choice = el('button', { type: 'button', className: 'portrait-choice', role: 'radio', ariaChecked: String(id === a.pfp_id), ariaLabel: id.replace(/\.[a-z]+$/i, '').replace(/^pfp_/, '').replace(/_/g, ' ') },
        el('img', { src: `/media/pfps/${id}`, alt: '', width: 96, height: 96 }));
      choice.addEventListener('click', async () => {
        status.textContent = 'Saving…';
        try {
          const reply = await relay.ask({ type: 'set_pfp', token: state.token, pfp_id: id }, 'set_pfp_result');
          if (!reply.success) { status.textContent = reply.message || 'Could not save your picture.'; return; }
          await refresh();
          game.tell({ cg: 1, type: 'account-changed', pfp_id: id });
          // The page re-rendered from the confirmed state; say so on the new copy.
          const saved = profileRoot.querySelector('.form-status');
          if (saved) saved.textContent = 'Picture saved.';
        } catch { status.textContent = 'Could not reach the server. Try again.'; }
      });
      picker.append(choice);
    }
    const stat = (label, value) => el('div', { className: 'stat' }, el('dt', { textContent: label }), el('dd', { textContent: String(value) }));
    const googleBox = el('div', { className: 'google-link-box' });
    if (a.google_linked) {
      googleBox.append(el('p', { textContent: 'Google is linked to this account. You can sign in with Google or your password.' }));
    } else {
      googleBox.append(el('p', { textContent: 'Link Google to sign in with it. Your decks, cards, balances and rank stay on this account.' }));
      const linkSlot = el('div', { className: 'google-slot' });
      googleBox.append(linkSlot);
      renderGoogleButton(linkSlot, 'link', async (reply) => {
        googleBox.querySelector('.google-error')?.remove();
        if (reply.success) { await refresh(); return; }
        googleBox.append(el('p', { className: 'form-error google-error', role: 'alert', textContent: reply.message || 'Could not link Google.' }));
      });
    }
    profileRoot.append(
      el('div', { className: 'profile-head' },
        el('img', { className: 'profile-avatar', src: portraitFor(a.pfp_id), alt: '', width: 96, height: 96 }),
        el('div', {}, el('h1', { textContent: a.username }),
          el('p', { className: 'profile-rank' }, el('img', { src: `/media/ranks/${rank.icon}.png`, alt: '', width: 40, height: 40 }),
            el('span', { textContent: rank.progress ? `${rank.name} · ${rank.progress}` : rank.name })))),
      el('dl', { className: 'stats' },
        stat('Cyllats', fmt.format(a.currency)), stat('Glimmer', fmt.format(a.dust)),
        stat('Ranked wins', a.ranked_wins), stat('Ranked losses', a.ranked_losses), stat('Win streak', a.ranked_win_streak),
        stat('Games won', a.wins), stat('Games lost', a.losses)),
      el('section', {}, el('h2', { textContent: 'Profile picture' }), picker, status),
      el('section', {}, el('h2', { textContent: 'Sign-in methods' }), googleBox));
  }

  // ---- the game on /play/ ------------------------------------------------------------
  const mount = document.querySelector('[data-game-mount]');
  const game = {
    frame: null, readyTimer: 0, handshakeDone: false,
    tell(message) { if (this.frame?.contentWindow && this.handshakeDone) this.frame.contentWindow.postMessage(message, location.origin); },
    unmount() {
      clearTimeout(this.readyTimer);
      if (this.frame) { this.frame.src = 'about:blank'; this.frame.remove(); this.frame = null; }
      this.handshakeDone = false;
    },
    message(text, withRetry) {
      const box = el('div', { className: 'game-message', role: 'status' }, el('p', { textContent: text }));
      if (withRetry) {
        const retry = el('button', { type: 'button', className: 'button', textContent: 'Try again' });
        retry.addEventListener('click', () => { this.unmount(); this.mountIfReady(); });
        box.append(retry);
      }
      mount.replaceChildren(box);
    },
    mountIfReady() {
      if (!mount || this.frame) return;
      if (state.status === 'loading') { this.message('Loading your account…'); return; }
      if (!state.account) {
        if (state.status === 'offline') { this.message('Can’t reach the server to check your account.', true); return; }
        const box = el('div', { className: 'game-message' },
          el('h1', { textContent: 'Log in to play' }),
          el('p', { textContent: state.notice || 'Sign in or create an account to enter the game.' }));
        const login = el('button', { type: 'button', className: 'button', textContent: 'Log in' });
        const register = el('button', { type: 'button', className: 'button secondary', textContent: 'Register' });
        login.addEventListener('click', () => openLogin('login', () => this.mountIfReady()));
        register.addEventListener('click', () => openLogin('register', () => this.mountIfReady()));
        box.append(el('div', { className: 'actions' }, login, register));
        mount.replaceChildren(box);
        return;
      }
      const frame = el('iframe', { id: 'game', className: 'game-window', title: 'cardgame game window', src: gameSrc, allow: 'fullscreen' });
      frame.setAttribute('allowfullscreen', '');
      this.frame = frame;
      this.handshakeDone = false;
      mount.replaceChildren(frame);
      this.readyTimer = setTimeout(() => {
        if (!this.handshakeDone && this.frame === frame) { this.unmount(); this.message('The game did not start. Reload it to try again.', true); }
      }, GAME_READY_TIMEOUT_MS);
    },
  };

  window.addEventListener('message', (event) => {
    if (!game.frame || event.origin !== location.origin || event.source !== game.frame.contentWindow) return;
    const data = event.data;
    if (!data || data.cg !== 1 || typeof data.type !== 'string') return;
    if (data.type === 'ready') {
      if (!state.token) return;
      // Same origin, this exact window, in answer to its own 'ready'.
      game.frame.contentWindow.postMessage({ cg: 1, type: 'session', token: state.token }, location.origin);
      game.handshakeDone = true;
      clearTimeout(game.readyTimer);
    } else if (data.type === 'account-dirty') {
      refresh();
    } else if (data.type === 'session-invalid') {
      game.unmount();
      expire('Your session has expired. Please log in again.');
      game.mountIfReady();
    }
  });

  // ---- wiring ---------------------------------------------------------------------
  listeners.add(renderBanner);
  listeners.add(renderProfile);
  listeners.add(() => { if (mount && !game.frame) game.mountIfReady(); });
  renderBanner();
  init();

  // Small test/debug surface; carries no secrets.
  window.cardgameSite = { state: () => ({ status: state.status, username: state.account?.username || null }), refresh };
})();
