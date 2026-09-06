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
      { id: 'custom_vision', label: 'Custom endpoint can see images', purpose: 'Leave off unless you know the model accepts image input (text-only is the safe default).', checkbox: true }
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

  function api(method, path, body) {
    var opts = { method: method, credentials: 'same-origin', headers: {} };
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
    ['intro', 'rows', 'system', 'poison', 'done'].forEach(function (p) {
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
      btn.addEventListener('click', function (ev) { ev.preventDefault(); state.replace[keptId] = true; renderIntro(); });
      row.appendChild(btn);
      wrap.appendChild(row);
      return wrap;
    }
    if (f.checkbox) {
      var crow = el('div', 'row');
      var cb = el('input'); cb.type = 'checkbox'; cb.id = 'f-' + f.id; cb.checked = !!state.values[f.id];
      cb.addEventListener('change', function () { state.values[f.id] = cb.checked; });
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
    });
    row2.appendChild(input);
    if (!f.plain) {
      var show = el('button', 'tiny', 'show');
      show.type = 'button';
      show.addEventListener('click', function (ev) { ev.preventDefault(); input.type = input.type === 'password' ? 'text' : 'password'; show.textContent = input.type === 'password' ? 'show' : 'hide'; });
      row2.appendChild(show);
    }
    wrap.appendChild(row2);
    return wrap;
  }

  function keptFor(fieldId) {
    var map = { telegram_token: 'telegram', telegram_chat: 'telegram', custom_key: 'custom', custom_base: 'custom', custom_model: 'custom', custom_vision: 'custom' };
    var k = map[fieldId] || fieldId;
    return state.kept.indexOf(k) >= 0 ? k : null;
  }

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
  }

  function buildRequest() {
    var missing = [];
    var req = { name: $('f-name').value.trim() };
    if (!req.name) missing.push('your name');
    function keyField(id, apiName, required) {
      var k = keptFor(id);
      if (k && !state.replace[k]) { req[apiName] = { kept: true }; return; }
      var v = state.values[id] || '';
      if (v) req[apiName] = { value: v };
      else if (required) missing.push(apiName);
    }
    if (usesSubscription()) {
      if (!subscriptionGeneration) missing.push('ChatGPT sign-in');
      req.chatgpt = {model: $('subscription-model').value.trim(), effort: $('subscription-effort').value, generation: subscriptionGeneration};
    } else keyField('opencode', 'opencode', true);
    keyField('openai', 'openai', true);
    keyField('serper', 'serper', true);
    keyField('jina', 'jina', true);
    if (keptFor('telegram_token') && !state.replace.telegram) req.telegram = { kept: true };
    else {
      var t = state.values.telegram_token || '', c = state.values.telegram_chat || '';
      if (!t) missing.push('telegram token');
      if (!c) missing.push('telegram chat ID');
      if (t && c) req.telegram = { token: t, chat_id: c };
    }
    keyField('agentmail', 'agentmail', false);
    keyField('openrouter', 'openrouter', false);
    if (keptFor('custom_key') && !state.replace.custom) req.custom = { kept: true };
    else {
      var ck = state.values.custom_key || '', cb = state.values.custom_base || '', cm = state.values.custom_model || '';
      if (ck || cb || cm) {
        if (ck && cb && cm) req.custom = { api_key: ck, base_url: cb, model: cm, vision: !!state.values.custom_vision };
        else missing.push('custom endpoint (key, base URL and model together)');
      }
    }
    return { request: req, missing: missing };
  }

  $('subscription-url').href = 'https://auth.openai.com/codex/device';
  var subscriptionGeneration = '', subscriptionPending = '', subscriptionTimer = null;
  function subscriptionCall(body) {
    return api('POST', '/api/subscription', body).then(function(r) {
      if (!r.json.ok) {
        var detail = r.json.error;
        var error = new Error((typeof detail === 'string' ? detail : detail && detail.message) || 'ChatGPT login failed; retry.');
        error.retryable = r.status === 409 || r.status >= 500 || !!(detail && detail.retryable);
        throw error;
      }
      return r.json;
    });
  }
  function subscriptionStatus() {
    return subscriptionCall({action: 'status'}).then(function(r) {
      subscriptionGeneration = r.generation || '';
      $('subscription-status').textContent = r.state === 'signed_in' ? 'Signed in. Your selected model will be checked before saving.' : 'Sign in to continue. Enable device login in ChatGPT security settings if needed.';
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
    $('subscription-panel').hidden = !usesSubscription(); renderIntro();
    if (usesSubscription()) subscriptionStatus().catch(subscriptionError);
  });
  $('subscription-start').addEventListener('click', function() {
    $('subscription-start').disabled = true;
    subscriptionGeneration = ''; clearTimeout(subscriptionTimer);
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
    subscriptionPending = ''; subscriptionGeneration = '';
    subscriptionCall(body).then(function() {
      $('subscription-code').textContent = ''; $('subscription-url').hidden = true; $('subscription-cancel').hidden = true;
      return subscriptionStatus();
    }).catch(subscriptionError);
  }
  $('subscription-cancel').addEventListener('click', function() { subscriptionEnd('cancel'); });
  $('subscription-logout').addEventListener('click', function() { subscriptionEnd('logout'); });

  // ---- verify rows ----------------------------------------------------------

  var lastRequest = null;

  function verify() {
    var built = buildRequest();
    if (built.missing.length) { banner('Missing: ' + built.missing.join(', '), true); return; }
    banner(null);
    lastRequest = built.request;
    showPhase('rows');
    $('rows-title').textContent = 'Verifying';
    renderVerifyRows(rowsPending(built.request));
    $('btn-verify').disabled = true;
    api('POST', '/api/verify', built.request).then(function (r) {
      $('btn-verify').disabled = false;
      if (r.status === 409 && r.json.error === 'kept') { banner(r.json.message, true); showPhase('intro'); return; }
      if (r.status !== 200) { banner('Verification failed (' + r.status + ')', true); showPhase('intro'); return; }
      renderVerifyRows(r.json.rows);
      var allOK = r.json.phase === 'verified';
      $('rows-title').textContent = allOK ? 'Everything verified' : 'Some keys need attention';
      $('btn-save').hidden = !allOK;
      $('btn-retry-verify').hidden = allOK;
    }).catch(handleFetchError);
  }

  function rowsPending(req) {
    var out = [];
    ['opencode', 'openai', 'serper', 'jina', 'telegram', 'agentmail', 'openrouter', 'custom'].forEach(function (id) {
      if (req[id]) out.push({ id: id, title: id, state: req[id].kept ? 'ok' : 'running' });
    });
    return out;
  }

  var TITLES = { opencode: 'OpenCode Go key', openai: 'OpenAI key', serper: 'Serper key', jina: 'Jina key', telegram: 'Telegram bot + chat', agentmail: 'AgentMail key', openrouter: 'OpenRouter key', custom: 'Custom endpoint' };

  function renderVerifyRows(rows) {
    var list = $('verify-rows'); clear(list);
    rows.forEach(function (row) {
      var li = el('li', row.state);
      var head = el('div', 'head');
      head.appendChild(el('span', 'mark', row.state === 'ok' ? '✓' : (row.state === 'failed' ? '✗' : '…')));
      head.appendChild(el('span', 'title', row.title || TITLES[row.id] || row.id));
      li.appendChild(head);
      if (row.resolved) li.appendChild(el('div', 'detail', row.resolved));
      if (row.detail) li.appendChild(el('div', 'detail', row.detail));
      if (row.state === 'failed') {
        li.appendChild(el('div', 'reason', row.reason || 'verification failed'));
        li.appendChild(editControls(row.id));
      }
      list.appendChild(li);
    });
  }

  function editControls(id) {
    var wrap = el('div', 'edit');
    function input(fieldId, placeholder, plain) {
      var i = el('input'); i.type = plain ? 'text' : 'password'; i.autocomplete = 'off'; i.placeholder = placeholder;
      i.value = state.values[fieldId] || '';
      i.addEventListener('input', function () { state.values[fieldId] = i.value.trim(); });
      return i;
    }
    if (id === 'telegram') {
      wrap.appendChild(input('telegram_token', 'bot token'));
      wrap.appendChild(input('telegram_chat', 'chat ID', true));
    } else if (id === 'custom') {
      wrap.appendChild(input('custom_key', 'key'));
      wrap.appendChild(input('custom_base', 'base URL', true));
      wrap.appendChild(input('custom_model', 'model', true));
    } else {
      wrap.appendChild(input(id, 'new value'));
    }
    var k = keptFor(id === 'telegram' ? 'telegram_token' : (id === 'custom' ? 'custom_key' : id));
    if (k) state.replace[k] = true;
    var retry = el('button', 'tiny', 'Retry');
    retry.type = 'button';
    retry.addEventListener('click', function () { verify(); });
    wrap.appendChild(retry);
    return wrap;
  }

  function save() {
    if (!lastRequest) return;
    var built = buildRequest();
    if (built.missing.length) { banner('Missing: ' + built.missing.join(', '), true); return; }
    $('btn-save').disabled = true;
    api('POST', '/api/save', built.request).then(function (r) {
      $('btn-save').disabled = false;
      if (r.status === 409) {
        banner('These changed after verification and must be verified again: ' + ((r.json.fields || []).join(', ') || r.json.message || ''), true);
        verify();
        return;
      }
      if (r.status !== 200) { banner((r.json && r.json.message) || ('Save failed (' + r.status + ')'), true); return; }
      // Drop keys from memory now that they are saved.
      state.values = {}; state.replace = {};
      FIELDS.required.concat(FIELDS.agentmail, FIELDS.extra).forEach(function (f) { var i = $('f-' + f.id); if (i) i.value = ''; });
      banner(null);
      refresh();
    }).catch(handleFetchError);
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
          if (state.lastPhase !== 'intro') { renderIntro(); showPhase('intro'); }
          break;
        case 'verifying':
        case 'verified':
          if (state.lastPhase !== st.phase && state.lastPhase !== 'rows') { showPhase('rows'); }
          break;
        case 'saving':
        case 'saved':
          showPhase('rows');
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

  $('btn-verify').addEventListener('click', verify);
  $('btn-retry-verify').addEventListener('click', verify);
  $('btn-save').addEventListener('click', save);
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
