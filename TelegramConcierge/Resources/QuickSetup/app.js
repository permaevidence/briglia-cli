/* Briglia quick setup — page logic. The page is a VIEW: every transition it
   shows is one the server already made. No inline scripts, no storage APIs,
   every dynamic string goes through textContent. */
(function () {
  'use strict';

  var FIELDS = {
    required: [
      { id: 'opencode', label: 'OpenCode Go key', purpose: 'Runs the main agent (GLM 5.3 Flash by default).', url: 'https://opencode.ai/zen', urlText: 'opencode.ai/zen' },
      { id: 'openai', label: 'OpenAI key', purpose: 'Web research, voice notes, image generation and OCR.', url: 'https://platform.openai.com/api-keys', urlText: 'platform.openai.com' },
      { id: 'serper', label: 'Serper key', purpose: 'Web search.', url: 'https://serper.dev', urlText: 'serper.dev' },
      { id: 'jina', label: 'Jina key', purpose: 'Reading web pages.', url: 'https://jina.ai', urlText: 'jina.ai' },
      { id: 'telegram_token', label: 'Telegram bot token', purpose: 'Create a bot with @BotFather and paste its token.', url: 'https://t.me/BotFather', urlText: '@BotFather' },
      { id: 'telegram_chat', label: 'Telegram chat ID', purpose: 'Your numeric ID (ask @userinfobot). Must be a private chat.', url: 'https://t.me/userinfobot', urlText: '@userinfobot', numeric: true }
    ],
    agentmail: [
      { id: 'agentmail', label: 'AgentMail key', purpose: 'Gives Briglia its own inbox and calendar.', url: 'https://agentmail.to', urlText: 'agentmail.to' }
    ],
    extra: [
      { id: 'openrouter', label: 'OpenRouter key', purpose: 'Alternative provider (saved, not active).', url: 'https://openrouter.ai/keys', urlText: 'openrouter.ai' },
      { id: 'custom_key', label: 'Custom endpoint key', purpose: 'Any OpenAI-compatible server. Needs the base URL and model below.' },
      { id: 'custom_base', label: 'Custom endpoint base URL', purpose: 'e.g. https://my-server.example/v1', plain: true },
      { id: 'custom_model', label: 'Custom endpoint model', purpose: 'The model id the server expects', plain: true },
      { id: 'custom_vision', label: 'Custom endpoint can see images', purpose: 'On by default. Turn off only for a text-only model; images then go through the OCR preprocessor.', checkbox: true, defaultOn: true }
    ]
  };

  var state = { status: null, kept: [], values: {}, replace: {}, jobOffset: 0, lastPhase: null, polling: null, currentOffer: null };

  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  function api(method, path, body, signal) {
    var opts = { method: method, credentials: 'same-origin', headers: {} };
    if (signal) opts.signal = signal;
    if (method === 'POST') {
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['X-Briglia-Quick-Setup'] = '1';
      opts.body = JSON.stringify(body || {});
    }
    return fetch(path, opts).then(function (r) {
      if (r.status === 404) { throw { replaced: true }; }
      return r.text().then(function (t) {
        var json = null;
        try { json = t ? JSON.parse(t) : {}; } catch (e) { json = {}; }
        return { status: r.status, json: json };
      });
    });
  }

  function banner(text, isError) {
    var b = $('banner');
    if (!text) { b.hidden = true; clear(b); return; }
    clear(b);
    b.appendChild(document.createTextNode(text));
    b.className = 'banner' + (isError ? ' error' : '');
    b.hidden = false;
  }

  function showPhase(name) {
    ['intro', 'system', 'poison', 'done'].forEach(function (p) {
      $('phase-' + p).hidden = (p !== name);
    });
  }

  // ---- intro ----------------------------------------------------------------

  function fieldNode(f, index) {
    var wrap = el('label', 'field');
    var label = el('span', 'label', (index !== undefined ? (index + 1) + '. ' : '') + f.label);
    wrap.appendChild(label);
    var purpose = el('span', 'purpose', f.purpose + ' ');
    if (f.url) {
      var a = el('a', null, 'Get it at ' + f.urlText);
      a.href = f.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
      purpose.appendChild(a);
    }
    wrap.appendChild(purpose);
    var keptId = keptFor(f.id);
    if (keptId && !state.replace[keptId]) {
      var row = el('div', 'row');
      row.appendChild(el('span', 'kept', '✓ configured, keeping current'));
      var btn = el('button', 'tiny', 'Replace');
      btn.type = 'button';
      btn.addEventListener('click', function (ev) { ev.preventDefault(); state.replace[keptId] = true; renderIntro(); scheduleVerify(DELAY_CHANGE); });
      row.appendChild(btn);
      wrap.appendChild(row);
      return wrap;
    }
    if (f.checkbox) {
      var crow = el('div', 'row');
      var cb = el('input'); cb.type = 'checkbox'; cb.id = 'f-' + f.id; cb.checked = (f.id in state.values) ? !!state.values[f.id] : !!f.defaultOn;
      cb.addEventListener('change', function () { state.values[f.id] = cb.checked; renderStatuses(); scheduleVerify(DELAY_CHANGE); });
      crow.appendChild(cb);
      wrap.appendChild(crow);
      return wrap;
    }
    var row2 = el('div', 'row');
    var input = el('input');
    input.type = f.plain ? 'text' : 'password';
    input.autocomplete = 'off';
    input.spellcheck = false;
    input.id = 'f-' + f.id;
    input.value = state.values[f.id] || '';
    input.addEventListener('input', function () {
      state.values[f.id] = input.value.trim();
      updateCount();
      if (f.numeric) {
        var bad = input.value.trim() !== '' && !/^-?\d+$/.test(input.value.trim());
        input.style.borderColor = bad ? '#b42318' : '';
        input.title = bad ? 'The chat ID is numeric (letters mean it is a username)' : '';
      }
      // Editing invalidates the row at once; the check itself waits for a
      // pause (or leaving the field) so a half-typed key is not probed.
      renderStatuses();
      scheduleVerify(DELAY_TYPING);
    });
    input.addEventListener('change', function () { scheduleVerify(DELAY_CHANGE); });
    row2.appendChild(input);
    if (!f.plain) {
      var show = el('button', 'tiny', 'show');
      show.type = 'button';
      show.addEventListener('click', function (ev) { ev.preventDefault(); input.type = input.type === 'password' ? 'text' : 'password'; show.textContent = input.type === 'password' ? 'show' : 'hide'; });
      row2.appendChild(show);
    }
    wrap.appendChild(row2);
    var host = STATUS_HOST[f.id];
    if (host) { var vs = el('div', 'vstatus'); vs.id = 'vs-' + host; wrap.appendChild(vs); }
    return wrap;
  }

  // The inline verification line of a server row lives under the field that
  // completes it (Telegram: the chat ID; custom endpoint: the model).
  var STATUS_HOST = { opencode: 'opencode', openai: 'openai', serper: 'serper', jina: 'jina', telegram_chat: 'telegram', agentmail: 'agentmail', openrouter: 'openrouter', custom_model: 'custom' };

  function keptFor(fieldId) {
    var map = { telegram_token: 'telegram', telegram_chat: 'telegram', custom_key: 'custom', custom_base: 'custom', custom_model: 'custom', custom_vision: 'custom' };
    var k = map[fieldId] || fieldId;
    return state.kept.indexOf(k) >= 0 ? k : null;
  }

  function subscriptionEfforts(model) {
    if (/^gpt-6-astra(?:-20.*)?$/.test(model)) return ['low', 'medium', 'high', 'xhigh', 'max'];
    if (/^gpt-6-(?:sol|luna)(?:-20.*)?$/.test(model) || /^gpt-5\.6(?:-luna|-terra|-sol)?(?:-20.*)?$/.test(model)) return ['none', 'low', 'medium', 'high', 'xhigh', 'max'];
    return ['none', 'minimal', 'low', 'medium', 'high', 'xhigh'];
  }
  function renderSubscriptionEfforts() {
    var select = $('subscription-effort'), current = select.value;
    clear(select);
    subscriptionEfforts($('subscription-model').value.trim()).forEach(function (value) {
      var option = el('option', null, value); option.value = value; select.appendChild(option);
    });
    select.value = subscriptionEfforts($('subscription-model').value.trim()).indexOf(current) >= 0 ? current : 'high';
  }
  $('subscription-model-choice').addEventListener('change', function () {
    var custom = this.value === 'custom';
    $('subscription-custom-model-row').hidden = !custom;
    $('subscription-model').value = custom ? '' : this.value;
    renderSubscriptionEfforts();
    renderStatuses(); scheduleVerify(DELAY_CHANGE);
  });
  $('subscription-model').addEventListener('input', function () { renderSubscriptionEfforts(); renderStatuses(); scheduleVerify(DELAY_TYPING); });
  $('subscription-model').addEventListener('change', function () { scheduleVerify(DELAY_CHANGE); });
  $('subscription-effort').addEventListener('change', function () { renderStatuses(); scheduleVerify(DELAY_CHANGE); });
  renderSubscriptionEfforts();

  function usesSubscription() { return $("main-provider").value === "chatgpt"; }

  function updateCount() {
    var n = 0;
    FIELDS.required.forEach(function (f) {
      var k = keptFor(f.id);
      if ((k && !state.replace[k]) || (state.values[f.id] || '').length > 0) n += 1;
    });
    $('req-count').textContent = (usesSubscription() ? Math.max(0, n - ((keptFor('opencode') || state.values.opencode) ? 1 : 0)) : n) + ' of ' + (usesSubscription() ? 5 : 6) + ' filled';
  }

  function renderIntro() {
    var req = $('required-fields'); clear(req);
    FIELDS.required.forEach(function (f, i) { if (!usesSubscription() || f.id !== "opencode") req.appendChild(fieldNode(f, i)); });
    var am = $('agentmail-fields'); clear(am);
    FIELDS.agentmail.forEach(function (f) { am.appendChild(fieldNode(f)); });
    var ex = $('extra-fields'); clear(ex);
    FIELDS.extra.forEach(function (f) { ex.appendChild(fieldNode(f)); });
    if (state.status && state.status.stored_name && !$('f-name').value) $('f-name').value = state.status.stored_name;
    updateCount();
    renderStatuses();
  }

  /* The request as it stands: every field that is complete enough to be
     checked. `missing` lists what a save still needs; `incomplete` explains,
     per server row, why a half-filled group is not sent yet. The verify
     request (partial) and the save request are the same object, so "what was
     verified" and "what is saved" compare by value. */
  function collectRequest() {
    var missing = [], incomplete = {};
    var req = { name: $('f-name').value.trim() };
    if (!req.name) missing.push('your name');
    function keyField(id, apiName, required) {
      var k = keptFor(id);
      if (k && !state.replace[k]) { req[apiName] = { kept: true }; return; }
      var v = state.values[id] || '';
      if (v) req[apiName] = { value: v };
      else if (required) missing.push(TITLES[apiName] || apiName);
    }
    if (usesSubscription()) {
      if (subscriptionGeneration) req.chatgpt = {model: $('subscription-model').value.trim(), effort: $('subscription-effort').value, generation: subscriptionGeneration};
      else missing.push('ChatGPT sign-in');
      if (req.chatgpt && !req.chatgpt.model) { delete req.chatgpt; missing.push('ChatGPT model'); }
    } else keyField('opencode', 'opencode', true);
    keyField('openai', 'openai', true);
    keyField('serper', 'serper', true);
    keyField('jina', 'jina', true);
    if (keptFor('telegram_token') && !state.replace.telegram) req.telegram = { kept: true };
    else {
      var t = state.values.telegram_token || '', c = state.values.telegram_chat || '';
      if (!t) missing.push('Telegram bot token');
      if (!c) missing.push('Telegram chat ID');
      if (t && c && !/^-?\d+$/.test(c)) { missing.push('a numeric Telegram chat ID'); incomplete.telegram = 'The chat ID is numeric (letters mean it is a username).'; }
      else if (t && c) req.telegram = { token: t, chat_id: c };
      else if (t || c) incomplete.telegram = 'Fill in both the bot token and the chat ID.';
    }
    keyField('agentmail', 'agentmail', false);
    keyField('openrouter', 'openrouter', false);
    if (keptFor('custom_key') && !state.replace.custom) req.custom = { kept: true };
    else {
      var ck = state.values.custom_key || '', cb = state.values.custom_base || '', cm = state.values.custom_model || '';
      if (ck || cb || cm) {
        if (ck && cb && cm) req.custom = { api_key: ck, base_url: cb, model: cm, vision: state.values.custom_vision !== false };
        else { missing.push('custom endpoint (key, base URL and model together)'); incomplete.custom = 'Needs the key, the base URL and the model together.'; }
      }
    }
    return { request: req, missing: missing, incomplete: incomplete };
  }
  function buildRequest() { return collectRequest(); }

  $('subscription-url').href = 'https://auth.openai.com/codex/device';
  var subscriptionGeneration = '', subscriptionPending = '', subscriptionTimer = null;
  var subscriptionCalls = 0;
  function subscriptionCall(body, busyTries) {
    // A verify still running on the server makes it answer "busy"; the
    // one-shot actions wait it out (polls already retry on their own).
    subscriptionCalls += 1;
    var tries = busyTries === undefined ? (body.action === 'poll' ? 0 : 20) : busyTries;
    return api('POST', '/api/subscription', body).then(function(r) {
      if (r.status === 409 && r.json.error === 'busy' && tries > 0) {
        subscriptionCalls -= 1;
        return new Promise(function (resolve) { setTimeout(resolve, 500); }).then(function () { return subscriptionCall(body, tries - 1); });
      }
      subscriptionCalls -= 1;
      if (!r.json.ok) {
        var detail = r.json.error;
        var error = new Error((typeof detail === 'string' ? detail : detail && detail.message) || 'ChatGPT login failed; retry.');
        error.retryable = r.status === 409 || r.status >= 500 || !!(detail && detail.retryable);
        throw error;
      }
      return r.json;
    }, function (e) { subscriptionCalls -= 1; throw e; });
  }
  function subscriptionStatus() {
    return subscriptionCall({action: 'status'}).then(function(r) {
      subscriptionGeneration = r.generation || '';
      $('subscription-status').textContent = r.state === 'signed_in' ? 'Signed in. Your selected model is checked automatically.' : 'Sign in to continue. Enable device login in ChatGPT security settings if needed.';
      renderStatuses(); scheduleVerify(DELAY_CHANGE);
    });
  }
  function subscriptionError(e) { $('subscription-status').textContent = e.message || 'Login interrupted; reload and retry.'; }
  function subscriptionPoll() {
    var id = subscriptionPending;
    if (!id) return;
    subscriptionCall({action: 'poll', pending: id}).then(function(r) {
      if (id !== subscriptionPending) return;
      if (r.state === 'signed_in') { subscriptionPending = ''; $('subscription-code').textContent = ''; $('subscription-url').hidden = true; $('subscription-cancel').hidden = true; return subscriptionStatus(); }
      subscriptionTimer = setTimeout(subscriptionPoll, Math.max(1, r.interval || 5) * 1000);
    }).catch(function(e) {
      if (id !== subscriptionPending) return;
      subscriptionError(e);
      // Network failures and busy/transient server replies retain the owned
      // handle. Definitive denial/expiry clears it so sign-in can restart.
      if (e.retryable || e instanceof TypeError) subscriptionTimer = setTimeout(subscriptionPoll, 5000);
      else {
        subscriptionPending = ''; $('subscription-code').textContent = '';
        $('subscription-url').hidden = true; $('subscription-cancel').hidden = true;
      }
    });
  }
  $('main-provider').addEventListener('change', function() {
    $('subscription-panel').hidden = !usesSubscription(); renderIntro(); scheduleVerify(DELAY_CHANGE);
    if (usesSubscription()) subscriptionStatus().catch(subscriptionError);
  });
  $('subscription-start').addEventListener('click', function() {
    $('subscription-start').disabled = true;
    subscriptionGeneration = ''; clearTimeout(subscriptionTimer); renderStatuses();
    subscriptionCall({action: 'start'}).then(function(r) {
      subscriptionPending = r.pending; $('subscription-code').textContent = 'Enter code: ' + r.code;
      // The URL is a compiled fixed endpoint, not an arbitrary provider redirect.
      $('subscription-url').hidden = false; $('subscription-cancel').hidden = false;
      $('subscription-status').textContent = 'Waiting for sign-in (15 minutes maximum).';
      subscriptionTimer = setTimeout(subscriptionPoll, Math.max(1, r.interval || 5) * 1000);
    }).catch(subscriptionError).then(function() { $('subscription-start').disabled = false; });
  });
  function subscriptionEnd(action) {
    clearTimeout(subscriptionTimer);
    var body = {action: action}; if (action === 'cancel') body.pending = subscriptionPending;
    subscriptionPending = ''; subscriptionGeneration = ''; renderStatuses();
    subscriptionCall(body).then(function() {
      $('subscription-code').textContent = ''; $('subscription-url').hidden = true; $('subscription-cancel').hidden = true;
      return subscriptionStatus();
    }).catch(subscriptionError);
  }
  $('subscription-cancel').addEventListener('click', function() { subscriptionEnd('cancel'); });
  $('subscription-logout').addEventListener('click', function() { subscriptionEnd('logout'); });

  // ---- automatic verification --------------------------------------------
  //
  // Every field is checked with its provider as soon as it is complete: after
  // a pause in typing (DELAY_TYPING) or at once when the field is left
  // (DELAY_CHANGE). One /api/verify carries every complete field (partial:
  // true); the server re-probes only fields whose value changed, so a new
  // key costs one probe. A newer check aborts the older request and its
  // answer is ignored by sequence number (the server bumps its own request
  // generation and discards the older probes). Save is enabled only when the
  // last answer said "verified" for exactly the values now on the page.

  var DELAY_TYPING = 1200, DELAY_CHANGE = 150;
  var auto = { seq: 0, ctl: null, inflight: false, timer: null, sentKey: null, sentSig: {}, rows: {}, sig: {}, phase: null, verifiedKey: null, saving: false };
  var TITLES = { opencode: 'OpenCode Go key', chatgpt: 'ChatGPT subscription', openai: 'OpenAI key', serper: 'Serper key', jina: 'Jina key', telegram: 'Telegram bot + chat', agentmail: 'AgentMail key', openrouter: 'OpenRouter key', custom: 'Custom endpoint' };
  var ROW_IDS = ['opencode', 'chatgpt', 'openai', 'serper', 'jina', 'telegram', 'agentmail', 'openrouter', 'custom'];

  function sigOf(value) { return value === undefined ? null : JSON.stringify(value); }
  function hasAnyField(req) { return ROW_IDS.some(function (id) { return req[id] !== undefined; }); }

  function scheduleVerify(delay) {
    if (auto.saving) return;
    clearTimeout(auto.timer);
    auto.timer = setTimeout(runVerify, delay);
  }

  function runVerify() {
    auto.timer = null;
    if (auto.saving || $('phase-intro').hidden) return;
    // Sign-in calls are refused by the server while a verify runs; wait.
    if (subscriptionCalls > 0) { scheduleVerify(500); return; }
    var built = collectRequest(), req = built.request;
    if (!hasAnyField(req)) {
      if (auto.ctl) auto.ctl.abort();
      auto.ctl = null; auto.inflight = false; auto.sentKey = null; auto.rows = {}; auto.sig = {}; auto.phase = null; auto.verifiedKey = null;
      renderStatuses(); return;
    }
    var key = sigOf(req);
    if (key === auto.sentKey) return;   // this exact request is in flight or answered
    if (auto.ctl) auto.ctl.abort();
    var ctl = typeof AbortController === 'function' ? new AbortController() : null;
    var my = ++auto.seq;
    auto.ctl = ctl; auto.inflight = true; auto.sentKey = key; auto.verifiedKey = null;
    auto.sentSig = {};
    ROW_IDS.forEach(function (id) { auto.sentSig[id] = sigOf(req[id]); });
    renderStatuses();
    var body = { partial: true };
    Object.keys(req).forEach(function (k) { body[k] = req[k]; });
    api('POST', '/api/verify', body, ctl ? ctl.signal : undefined).then(function (r) {
      if (my !== auto.seq) return;          // superseded by a newer check
      auto.inflight = false; auto.ctl = null;
      if (r.status === 200) {
        banner(null);
        auto.rows = {}; auto.sig = {};
        (r.json.rows || []).forEach(function (row) { auto.rows[row.id] = row; auto.sig[row.id] = auto.sentSig[row.id]; });
        auto.phase = r.json.phase;
        auto.verifiedKey = r.json.phase === 'verified' ? key : null;
      } else {
        auto.sentKey = null;   // let the next edit (or "Check again") retry
        if (r.status === 409 && r.json.error === 'kept') banner(r.json.message, true);
        else if (r.status === 409 && r.json.error === 'phase') { /* saving or past it: the status loop takes over */ }
        else banner((r.json && r.json.message) || ('Could not check the keys (' + r.status + ')'), true);
      }
      renderStatuses();
    }).catch(function (e) {
      if (my !== auto.seq) return;          // aborted or superseded: ignore
      auto.inflight = false; auto.ctl = null; auto.sentKey = null;
      renderStatuses();
      handleFetchError(e);
    });
  }

  function checkAgain() { auto.sentKey = null; scheduleVerify(0); }

  // What to show for one server row, given the values now on the page.
  function rowView(id, built) {
    var current = sigOf(built.request[id]);
    if (current === null) return built.incomplete[id] ? { state: 'pending', text: built.incomplete[id] } : null;
    if (built.request[id] && built.request[id].kept) return null;
    var row = auto.rows[id];
    if (auto.inflight && auto.sentSig[id] === current && !(row && auto.sig[id] === current && row.state === 'ok')) return { state: 'running', text: 'Checking…' };
    if (row && auto.sig[id] === current) {
      if (row.state === 'ok') return { state: 'ok', text: 'Verified', detail: row.resolved || row.detail };
      if (row.state === 'failed') return { state: 'failed', text: row.reason || 'verification failed', retry: true };
      if (row.state === 'running') return { state: 'running', text: 'Checking…' };
    }
    return { state: 'pending', text: 'Will be checked when you pause or leave the field.' };
  }

  function renderStatuses() {
    var built = collectRequest(), failed = 0, pending = 0;
    ROW_IDS.forEach(function (id) {
      var view = rowView(id, built);
      if (view && view.state === 'failed') failed += 1;
      if (view && (view.state === 'pending' || view.state === 'running')) pending += 1;
      var box = $('vs-' + id);
      if (!box) return;
      clear(box);
      box.className = 'vstatus' + (view ? ' ' + view.state : '');
      box.setAttribute('data-state', view ? view.state : '');
      if (!view) return;
      box.appendChild(el('span', 'mark', view.state === 'ok' ? '✓' : (view.state === 'failed' ? '✗' : (view.state === 'running' ? '…' : '·'))));
      box.appendChild(el('span', 'text', view.text));
      if (view.detail) box.appendChild(el('span', 'detail', view.detail));
      if (view.retry) {
        var b = el('button', 'tiny', 'Check again'); b.type = 'button';
        b.addEventListener('click', function (ev) { ev.preventDefault(); checkAgain(); });
        box.appendChild(b);
      }
    });
    var ready = canSave(built);
    var btn = $('btn-save');
    btn.disabled = !ready || auto.saving;
    btn.textContent = auto.saving ? 'Saving…' : 'Save and continue';
    var hint = auto.saving ? '' : ready ? 'Everything is verified.'
      : built.missing.length ? 'Still needed: ' + built.missing.join(', ') + '.'
      : failed ? 'Fix the entries marked ✗ (they are checked again automatically).'
      : 'Checking your keys…';
    $('save-hint').textContent = hint;
  }

  function canSave(built) {
    return !built.missing.length && !auto.inflight && auto.phase === 'verified' && auto.verifiedKey !== null && auto.verifiedKey === sigOf(built.request);
  }

  function save() {
    var built = collectRequest();
    if (!canSave(built)) { renderStatuses(); return; }
    auto.saving = true; clearTimeout(auto.timer);
    renderStatuses();
    api('POST', '/api/save', built.request).then(function (r) {
      auto.saving = false;
      if (r.status === 409 && r.json.error === 'phase' && INTRO_PHASES.indexOf(r.json.phase) < 0) { refresh(); return; }
      if (r.status === 409 && (r.json.error === 'not_verified' || r.json.error === 'phase')) {
        // The server no longer holds a verification matching these values
        // (edited, or dropped by an earlier refused save): check again.
        banner('Some entries changed after they were verified and are being checked again' + ((r.json.fields || []).length ? ': ' + r.json.fields.join(', ') : '') + '. Press Save again when they are verified.', true);
        auto.verifiedKey = null; auto.phase = null; auto.sentKey = null; auto.rows = {}; auto.sig = {};
        renderStatuses(); scheduleVerify(0);
        return;
      }
      if (r.status !== 200) { banner((r.json && (r.json.message || (r.json.error && r.json.error.message))) || ('Save failed (' + r.status + ')'), true); renderStatuses(); return; }
      // Drop keys from memory now that they are saved.
      state.values = {}; state.replace = {};
      auto.rows = {}; auto.sig = {}; auto.verifiedKey = null; auto.sentKey = null;
      FIELDS.required.concat(FIELDS.agentmail, FIELDS.extra).forEach(function (f) { var i = $('f-' + f.id); if (i) i.value = ''; });
      banner(null);
      refresh();
    }).catch(function (e) { auto.saving = false; renderStatuses(); handleFetchError(e); });
  }

  // ---- system phase ---------------------------------------------------------

  function renderSystem(st) {
    var list = $('system-rows'); clear(list);
    var next = null, running = false;
    (st.system_rows || []).forEach(function (row) {
      var li = el('li', row.state);
      var head = el('div', 'head');
      head.appendChild(el('span', 'mark', row.state === 'ok' ? '✓' : (row.state === 'failed' ? '✗' : (row.state === 'running' ? '…' : '·'))));
      head.appendChild(el('span', 'title', row.title));
      li.appendChild(head);
      if (row.detail) li.appendChild(el('div', 'detail', row.detail));
      if (row.state === 'failed') li.appendChild(el('div', 'reason', row.reason || 'failed'));
      if (row.state === 'failed' && row.output && row.output.length) li.appendChild(el('pre', 'output', row.output.join('\n')));
      if (row.id === 'toolchain' && row.state !== 'ok') li.appendChild(el('div', 'detail', 'Downloads about 1.5 GB and can take up to 40 minutes on a slow connection; LibreOffice is most of it.'));
      if (row.id === 'keepawake' && st.platform === 'macos' && row.state !== 'ok') li.appendChild(el('div', 'detail', 'Briglia prevents idle system sleep while it runs. A closed lid or a manual sleep still stops it.'));
      if (row.id === 'fda' && row.state !== 'ok') li.appendChild(el('div', 'detail', 'In System Settings → Privacy & Security → Full Disk Access, click “+”, add ' + (st.terminal_app || 'your terminal app') + ' (or turn it on), and choose “Quit & Reopen” if asked. Then run `briglia quicksetup` again — it continues from here.'));
      list.appendChild(li);
      if (row.state === 'running') running = true;
      if (!next && row.state !== 'ok') next = row;
    });
    state.currentOffer = next && next.state === 'failed' ? next.offer : null;
    $('btn-system-retry').hidden = !(next && next.state === 'failed');
    $('btn-open-settings').hidden = !(next && next.id === 'fda' && next.state !== 'ok');
    $('btn-mask').hidden = !(next && next.id === 'keepawake' && next.state === 'failed' && next.offer === 'mask');
    $('btn-finish').hidden = !(st.phase === 'system-complete' || st.phase === 'systemComplete');
    $('job-log').hidden = !(running || st.current_job);
    // Auto-start the next pending row.
    if (next && next.state === 'pending' && !running && !st.current_job) runRow(next.id, null);
    // FDA: auto-retry when the permission flips on.
    if (next && next.id === 'fda' && next.state === 'failed' && st.fda_granted) runRow('fda', null);
  }

  function runRow(id, option) {
    var body = { row: id };
    if (option) body.option = option;
    api('POST', '/api/system/run', body).then(function (r) {
      if (r.status === 409 && r.json.error === 'poisoned') { refresh(); return; }
      if (r.status !== 202 && r.status !== 409) banner('Could not start the step (' + r.status + ')', true);
      setTimeout(refresh, 400);
    }).catch(handleFetchError);
  }

  function renderFinish(st) {
    var steps = st.finish_steps || [];
    $('finish-title').hidden = steps.length === 0;
    var list = $('finish-rows'); clear(list);
    var failed = false;
    steps.forEach(function (s) {
      var li = el('li', s.state);
      var head = el('div', 'head');
      head.appendChild(el('span', 'mark', s.state === 'ok' ? '✓' : (s.state === 'failed' ? '✗' : (s.state === 'running' ? '…' : '·'))));
      head.appendChild(el('span', 'title', s.title));
      li.appendChild(head);
      if (s.detail) li.appendChild(el('div', 'detail', s.detail));
      if (s.state === 'failed') { failed = true; li.appendChild(el('div', 'reason', s.reason || 'failed')); }
      list.appendChild(li);
    });
    $('btn-finish-retry').hidden = !failed;
  }

  function pollJob() {
    api('POST', '/api/job', { offset: state.jobOffset }).then(function (r) {
      if (r.status !== 200) return;
      var log = $('job-log');
      (r.json.lines || []).forEach(function (line) { log.appendChild(document.createTextNode(line + '\n')); });
      if ((r.json.lines || []).length) log.scrollTop = log.scrollHeight;
      state.jobOffset = r.json.next || state.jobOffset;
    }).catch(function () {});
  }

  function renderPoison(st) {
    var p = st.poisoned;
    var list = $('poison-list'); clear(list);
    if (p.unreadable_journal) list.appendChild(el('li', 'failed', p.unreadable_journal));
    (p.survivors || []).forEach(function (s) {
      list.appendChild(el('li', 'failed', 'pid ' + s.pid + (s.note ? ' — ' + s.note : '') + ' (step: ' + p.row + ')'));
    });
    if (p.enumeration_failed) list.appendChild(el('li', 'failed', 'the process table could not be read'));
  }

  // ---- status loop ------------------------------------------------------------

  var failedFetches = 0;
  var INTRO_PHASES = ['intro', 'verifying', 'verified', 'saving', 'saved'];

  function handleFetchError(e) {
    if (e && e.replaced) { banner('This session was replaced; use the new link from the terminal.', true); stopPolling(); return; }
    failedFetches += 1;
    if (failedFetches >= 3) {
      banner('The terminal was restarted. Run `briglia quicksetup` again — it continues from here.', true);
      stopPolling();
    }
  }

  function stopPolling() { if (state.polling) { clearInterval(state.polling); state.polling = null; } }

  function refresh() {
    return api('GET', '/api/status').then(function (r) {
      failedFetches = 0;
      if (r.status !== 200) return;
      var st = r.json;
      state.status = st;
      state.kept = st.kept || [];
      if (st.poisoned) { renderPoison(st); showPhase('poison'); return; }
      if (st.wizard_requested) { banner('Continue in the terminal.'); showPhase('done'); $('done-text').textContent = 'The step-by-step wizard is running in the terminal. You can close this tab.'; stopPolling(); return; }
      switch (st.phase) {
        case 'intro':
        case 'verifying':
        case 'verified':
        case 'saving':
        case 'saved':
          // The form stays in place through automatic checks and the save.
          if (INTRO_PHASES.indexOf(state.lastPhase) < 0) { renderIntro(); showPhase('intro'); }
          // Something else dropped the server back to intro (a save refused
          // for changed values): what the page thinks is verified is stale.
          if (st.phase === 'intro' && auto.phase === 'verified' && !auto.inflight && !auto.saving) {
            auto.phase = null; auto.verifiedKey = null; auto.sentKey = null; renderStatuses(); scheduleVerify(0);
          }
          break;
        case 'system':
        case 'systemComplete':
        case 'system-complete':
        case 'finishing':
          showPhase('system');
          renderSystem(st);
          renderFinish(st);
          if (st.current_job || st.phase === 'finishing') pollJob();
          break;
        case 'done':
          showPhase('done');
          stopPolling();
          break;
      }
      state.lastPhase = st.phase;
    }).catch(handleFetchError);
  }

  // ---- wiring ----------------------------------------------------------------

  $('btn-save').addEventListener('click', save);
  $('f-name').addEventListener('input', function () { renderStatuses(); scheduleVerify(DELAY_TYPING); });
  $('f-name').addEventListener('change', function () { scheduleVerify(DELAY_CHANGE); });
  $('btn-wizard').addEventListener('click', function () {
    api('POST', '/api/stepbystep', {}).then(function (r) {
      if (r.status === 200) { $('done-text').textContent = 'Continue in the terminal.'; showPhase('done'); stopPolling(); }
      else banner('Cannot switch now (' + r.status + ')', true);
    }).catch(handleFetchError);
  });
  $('btn-system-retry').addEventListener('click', function () {
    var st = state.status; if (!st) return;
    var next = (st.system_rows || []).filter(function (r) { return r.state !== 'ok'; })[0];
    if (next) runRow(next.id, null);
  });
  $('btn-open-settings').addEventListener('click', function () { api('POST', '/api/system/open-settings', {}).catch(handleFetchError); });
  $('btn-mask').addEventListener('click', function () { banner('Look at the terminal: sudo is asking for your password.'); runRow('keepawake', 'mask'); });
  $('btn-finish').addEventListener('click', function () {
    api('POST', '/api/finish', {}).then(function () { refresh(); }).catch(handleFetchError);
  });
  $('btn-finish-retry').addEventListener('click', function () {
    api('POST', '/api/finish', {}).then(function () { refresh(); }).catch(handleFetchError);
  });
  $('btn-recheck').addEventListener('click', function () {
    api('POST', '/api/recover/recheck', {}).then(function () { refresh(); }).catch(handleFetchError);
  });

  refresh();
  state.polling = setInterval(refresh, 2000);
})();
