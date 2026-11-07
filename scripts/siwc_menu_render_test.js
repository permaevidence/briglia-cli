#!/usr/bin/env node
// Sign in with ChatGPT menu card, rendered (SIWC plan §2.1, §3.10; Codex
// stage-D R6/R7): the production menu.js runs against a tiny DOM shim and an
// in-process fake server, and the test clicks the real handlers.
//   - R6: a flow outcome that arrives by polling (callback refusal, expiry,
//     saved-but-not-switched) is rendered, in English and Italian.
//   - R7: SIWC route → "Choose sign-in method" → legacy → the legacy panel →
//     "Choose sign-in method" → Sign in with ChatGPT, with and without a saved
//     legacy login, and with the SIWC login signed out.
// No network, no browser. Usage: node scripts/siwc_menu_render_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'TelegramConcierge/Resources/QuickSetup/menu.js'), 'utf8');

let failures = 0, total = 0;
function check(label, ok, detail) {
  total++;
  if (!ok) failures++;
  console.log((ok ? '✔ ' : '✖ ') + label + (ok || !detail ? '' : ' — ' + detail));
}

// ---- DOM shim ----
class Node_ {
  constructor(tag) { this.tagName = (tag || '').toUpperCase(); this.children = []; this.attrs = {}; this.listeners = {}; this.style = {}; this._text = ''; this.className = ''; this.parent = null; }
  get id() { return this.attrs.id || ''; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return this.attrs[k]; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  appendChild(c) { c.parent = this; this.children.push(c); return c; }
  removeChild(c) { this.children = this.children.filter(x => x !== c); return c; }
  get firstChild() { return this.children[0] || null; }
  set textContent(v) { this.children = []; this._text = String(v); }
  get textContent() { return this._text + this.children.map(c => c.textContent).join(''); }
  focus() {} setSelectionRange() {}
  click() { (this.listeners.click || []).forEach(f => f({ preventDefault() {}, target: this })); }
}
class Text_ extends Node_ { constructor(t) { super('#text'); this._text = t; } }
const statics = {};
for (const id of ['logo', 'brand-tag', 'steps', 'm-progress', 'm-left', 'm-step', 'side-note', 'footer', 'power', 'lang-switch', 'card']) {
  const n = new Node_('div'); n.attrs.id = id; statics[id] = n;
}
function find(root, pred) {
  if (pred(root)) return root;
  for (const c of root.children) { const r = find(c, pred); if (r) return r; }
  return null;
}
const documentShim = {
  activeElement: null, documentElement: {}, body: {},
  getElementById(id) { return statics[id] || find(statics.card, n => n.id === id) || find(statics.steps, n => n.id === id) || null; },
  createElement: t => new Node_(t), createElementNS: (_, t) => new Node_(t), createTextNode: t => new Text_(t),
  addEventListener() {},
};
const windowShim = { scrollTo() {}, open() { return null; }, location: { replace() {} } };

// ---- fake server ----
function makeServer(state) {
  return async function fetchShim(url, opts) {
    let body = state.status();
    if (opts && opts.method === 'POST') {
      const req = JSON.parse(opts.body || '{}');
      state.posts.push(req);
      body = Object.assign({ ok: true }, state.act(req), { status: state.status() });
    }
    const text = JSON.stringify(body);
    return { status: 200, text: async () => text };
  };
}
function baseStatus(lang, siwc, extra) {
  return Object.assign({
    lang, complete: false, steps: [{ id: 'name', title: 'Name', required: true, done: true }, { id: 'ai', title: 'ChatGPT', required: true, done: true }],
    ai: { lane: 'chatgpt', providers: { chatgpt: { active: siwc.selected, efforts: ['low', 'medium', 'high'], effort: 'high' } } }, browser_likely: true,
    chatgpt: { state: siwc.login === 'signed_in' ? 'signed_in' : 'signed_out', active: siwc.selected, model: 'gpt-6.1-sol', model_label: 'GPT-6.1 Sol', effort: 'high', models: [], siwc },
  }, extra || {});
}

async function settle() { for (let i = 0; i < 20; i++) await new Promise(r => setImmediate(r)); }

async function session(state) {
  for (const k in statics) statics[k].children = [];
  const sandbox = { document: documentShim, window: windowShim, fetch: makeServer(state), setTimeout: () => 0, clearTimeout() {}, navigator: {}, console };
  new Function('document', 'window', 'fetch', 'setTimeout', 'clearTimeout', 'navigator', src)(
    sandbox.document, sandbox.window, sandbox.fetch, sandbox.setTimeout, sandbox.clearTimeout, sandbox.navigator);
  await settle();
  // Open the ChatGPT step from the side list.
  const btn = find(statics.steps, n => n.tagName === 'BUTTON' && n.textContent.includes('ChatGPT'));
  btn.click();
  await settle();
  return {
    el: id => documentShim.getElementById(id),
    text: () => statics.card.textContent,
    click: async id => { const n = documentShim.getElementById(id); if (!n) return false; n.click(); await settle(); return true; },
  };
}

(async () => {
  // ---- R6: polled flow outcomes ----
  const cases = [
    ['en', { state: 'failed', outcome: 'browser_error' }, 'POLICY-REFUSAL-EN'],
    ['it', { state: 'failed', outcome: 'browser_error' }, 'RIFIUTO-IT'],
    ['en', { state: 'failed', outcome: 'expired' }, 'EXPIRED-EN'],
    ['it', { state: 'cancelled', outcome: 'saved' }, 'SALVATO-IT'],
    ['en', { state: 'done', outcome: 'saved' }, 'SAVED-NOT-ACTIVE-EN'],
    ['en', { state: 'done', outcome: 'pending' }, 'PENDING-EN'],
  ];
  for (const [lang, flow, msg] of cases) {
    const siwc = { opted_in: true, route: 'siwc', login: 'signed_out', selected: true, flow, flow_message: msg, manage_usage: 'https://chatgpt.com/settings/usage' };
    const state = { posts: [], status: () => baseStatus(lang, siwc), act: () => ({}) };
    const s = await session(state);
    const n = s.el('siwc-flow-message');
    check(`R6: ${lang} ${flow.state}/${flow.outcome} — the polled outcome is rendered`, !!n && n.textContent.includes(msg), s.text().slice(0, 200));
  }
  {
    const siwc = { opted_in: true, route: 'siwc', login: 'signed_in', selected: true, flow: { state: 'done', outcome: 'signed_in' }, flow_message: 'SIGNED-IN', manage_usage: 'x' };
    const s = await session({ posts: [], status: () => baseStatus('en', siwc), act: () => ({}) });
    check('R6: a plain successful sign-in shows no extra outcome notice', !s.el('siwc-flow-message'));
  }

  // ---- R7: the selector round trip from the SIWC route ----
  for (const lang of ['en', 'it']) {
    for (const [label, login, legacy] of [['signed in, legacy saved', 'signed_in', true], ['signed in, no legacy login', 'signed_in', false], ['SIWC signed out', 'signed_out', false]]) {
      const siwc = { opted_in: true, route: 'siwc', login, selected: true, legacy_login: legacy, flow: { state: 'idle' }, manage_usage: 'x' };
      const state = { posts: [], status: () => baseStatus(lang, siwc), act: () => ({}) };
      const s = await session(state);
      const ok0 = !!s.el('siwc-route');
      await s.click('siwc-choose');
      const ok1 = !!s.el('siwc-pick-legacy') && !!s.el('siwc-pick-siwc');
      await s.click('siwc-pick-legacy');
      const panel = !!s.el('siwc-legacy-route') && (legacy ? !!s.el('siwc-switch-legacy') : !!s.el('siwc-legacy-browser'));
      const posted = state.posts.some(p => p.action === 'siwc_method' && p.route === 'legacy');
      await s.click('siwc-choose');
      const reopened = !!s.el('siwc-pick-siwc') && !s.el('siwc-legacy-route');
      await s.click('siwc-pick-siwc');
      const back = !!s.el('siwc-route') && !s.el('siwc-legacy-route');
      check(`R7: ${lang}, ${label} — SIWC → choose → legacy panel → choose (the selector opens) → Sign in with ChatGPT`,
            ok0 && ok1 && panel && posted && reopened && back, JSON.stringify({ ok0, ok1, panel, posted, reopened, back }));
    }
  }

  console.log(`SIWC menu render test: ${total - failures}/${total}`);
  process.exit(failures ? 1 : 0);
})().catch(e => { console.log('✖ render test crashed — ' + (e && e.stack || e)); process.exit(1); });
