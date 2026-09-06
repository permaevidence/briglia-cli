(function () {
  'use strict';
  var state, selected, pending = null, loginGeneration = '', timer = null, pollErrors = 0, accountBusy = false, requestBusy = false;
  var $ = function (id) { return document.getElementById(id); };
  function node(tag, text) { var e = document.createElement(tag); if (text !== undefined) e.textContent = text; return e; }
  function message(text, error) { $('banner').hidden = false; $('banner').textContent = text; $('banner').className = error ? 'banner error' : 'banner'; }
  function reason(r) { return r.message || (r.error && r.error.message) || r.reason || 'The operation failed. Please retry.'; }
  function api(verb, body) {
    var opts = {method: verb === 'status' ? 'GET' : 'POST', credentials: 'same-origin', headers: {}};
    if (opts.method === 'POST') { opts.headers = {'Content-Type': 'application/json', 'X-Briglia-Quick-Setup': '1'}; opts.body = JSON.stringify(body); }
    return fetch('/api/' + verb, opts).then(function (r) {
      if (r.status === 404) { throw new Error('This settings link expired or was replaced. Run briglia quicksetup for a new link.'); }
      return r.json().then(function (j) { return {status: r.status, data: j}; });
    });
  }
  function invalidate() { document.querySelectorAll('[data-save], #save-provider').forEach(function (e) { e.disabled = true; }); }
  function refresh(keepSelection) {
    return api('status').then(function (r) {
      if (!r.data.ok) throw new Error(reason(r.data));
      state = r.data;
      $('active').textContent = 'Active provider: ' + (state.profiles.find(function (p) { return p.id === state.active; }) || {label: 'None'}).label;
      $('runtime').textContent = state.running ? 'Briglia is running. Saves become available when its current turn and background work finish; no restart is needed.' : 'Briglia is stopped. Saved settings will be used when you start it.';
      if (keepSelection && selected) {
        var current = state.profiles.find(function (p) { return p.id === selected; });
        $('configured').textContent = current.configured ? 'Configured. Leave the API key blank to keep it.' : 'Add this provider by verifying and saving its settings.';
        $('activate').disabled = selected === state.active;
        if (selected === state.active) $('activate').checked = true;
      }
      if (!keepSelection) {
        $('provider').replaceChildren();
        state.profiles.forEach(function (p) { var o = node('option', p.label + (p.configured ? ' · configured' : '')); o.value = p.id; $('provider').appendChild(o); });
        $('provider').value = selected || state.active || 'opencode';
        renderProvider(); renderTools();
      }
    });
  }
  function renderProvider() {
    invalidate(); selected = $('provider').value;
    var p = state.profiles.find(function (x) { return x.id === selected; });
    $('configured').textContent = p.configured ? 'Configured. Leave the API key blank to keep it.' : 'Add this provider by verifying and saving its settings.';
    $('key').value = ''; $('key-row').hidden = selected === 'chatgpt' || selected === 'local';
    $('endpoint-row').hidden = selected !== 'custom' && selected !== 'local'; $('endpoint').value = p.endpoint;
    $('model').value = p.model; $('effort').value = p.effort;
    $('effort-row').hidden = selected === 'local'; $('vision-row').hidden = selected === 'chatgpt'; $('vision').checked = !p.text_only;
    $('activate').checked = selected === state.active || !state.active;
    $('activate').disabled = selected === state.active;
    $('protocol-row').hidden = selected !== 'custom'; $('protocol').value = p.protocol;
    $('media-row').hidden = selected !== 'custom'; $('native-media').checked = p.native_tool_media;
    $('account').hidden = selected !== 'chatgpt'; $('models').replaceChildren();
    if (selected === 'opencode') state.opencode_models.forEach(function (m) { var o = node('option'); o.value = m.id; o.label = m.label; $('models').appendChild(o); });
    if (selected === 'chatgpt') accountStatus();
  }
  function providerRequest() {
    var values = {profile: selected, model: $('model').value.trim(), effort: selected === 'local' ? '' : $('effort').value,
      text_only: !$('vision').checked, activate: $('activate').checked};
    if ($('key').value.trim() && selected !== 'chatgpt' && selected !== 'local') values.api_key = $('key').value.trim();
    if (selected === 'custom' || selected === 'local') values.base_url = $('endpoint').value.trim();
    if (selected === 'custom') { values.protocol = $('protocol').value; values.native_tool_media = $('native-media').checked; }
    if (selected === 'chatgpt') values.generation = loginGeneration;
    return {section: 'provider', values: values};
  }
  function operate(verb, request, saveButton, keyInput) {
    if (requestBusy) { message('Another request is running. Please wait.', true); return; }
    requestBusy = true;
    message(verb === 'verify' ? 'Verifying…' : 'Saving…');
    api(verb, request).then(function (r) {
      if (!r.data.ok) { if (r.data.error !== 'agent_busy') invalidate(); message(reason(r.data), true); return; }
      invalidate();
      if (verb === 'verify') {
        // Input edits while a probe is in flight must not enable a stale Save.
        var current = request.section === 'provider' ? providerRequest() : {section: request.section, values: {api_key: keyInput.value.trim()}};
        if (JSON.stringify(current) !== JSON.stringify(request)) { message('Settings changed during verification. Verify again.', true); return; }
        saveButton.disabled = false;
      } else { if (keyInput && keyInput.value.trim() === (request.values.api_key || '') && (request.section !== 'provider' || request.values.profile === selected)) keyInput.value = ''; refresh(true).catch(failed); }
      message(r.data.message || 'Done.');
    }).catch(failed).finally(function () { requestBusy = false; });
  }
  function renderTools() {
    $('tools').replaceChildren();
    state.tools.forEach(function (tool) {
      var wrap = node('div'), label = node('label', tool.label + (tool.configured ? ' · configured' : ' · not configured')); label.className = 'field';
      var input = node('input'); input.type = 'password'; input.autocomplete = 'off'; input.id = 'tool-' + tool.id; input.placeholder = 'Enter a replacement key'; input.addEventListener('input', invalidate); label.appendChild(input);
      var verify = node('button', 'Verify'), save = node('button', 'Save'); save.dataset.save = tool.id; save.disabled = true;
      function run(verb) { operate(verb, {section: tool.id, values: {api_key: input.value.trim()}}, save, input); }
      verify.addEventListener('click', function () { run('verify'); }); save.addEventListener('click', function () { run('save'); });
      wrap.append(label, verify, document.createTextNode(' '), save); $('tools').appendChild(wrap);
    });
  }
  function failed(e) { message(e.message || 'Connection failed. Retry, or run briglia quicksetup for a new link.', true); }
  function accountControls() { $('login').disabled = !!pending || accountBusy; $('cancel').hidden = !pending; $('logout').disabled = !!pending || accountBusy; $('login-code').hidden = !pending; }
  function schedule(seconds) { clearTimeout(timer); if (pending) timer = setTimeout(poll, Math.max(1, seconds || 5) * 1000); }
  function accountStatus() {
    return api('subscription', {action: 'status'}).then(function (r) {
      if (!r.data.ok) throw new Error(reason(r.data));
      loginGeneration = r.data.generation || '';
      $('account-status').textContent = r.data.state === 'signed_in' ? 'Signed in. Verify and save below to use this account and model.' : 'Sign in to use a ChatGPT subscription.';
      accountControls();
    }).catch(failed);
  }
  function poll() {
    if (!pending) return;
    if (accountBusy || requestBusy) { schedule(2); return; }
    accountBusy = true; accountControls();
    api('subscription', {action: 'poll', pending: pending}).then(function (r) {
      if (!r.data.ok) {
        var retryable = r.status === 409 || (r.data.error && r.data.error.retryable);
        if (retryable && ++pollErrors <= 12) { $('account-status').textContent = 'Waiting for Briglia or the connection. Retrying sign-in…'; schedule(5); return; }
        throw new Error(reason(r.data));
      }
      pollErrors = 0;
      if (r.data.state === 'pending') { schedule(r.data.interval); return; }
      pending = null; invalidate(); accountStatus();
    }).catch(function (e) {
      // A transient network failure keeps the handle, with a bounded retry.
      if (++pollErrors <= 12) { schedule(5); failed(e); }
      else { $('account-status').textContent = 'Automatic retries stopped. Cancel sign-in and try again.'; failed(e); }
    }).finally(function () { accountBusy = false; accountControls(); });
  }
  function accountAction(action) {
    if (accountBusy) return;
    accountBusy = true; accountControls(); invalidate();
    var body = {action: action}; if (action === 'cancel') body.pending = pending;
    api('subscription', body).then(function (r) {
      if (!r.data.ok) throw new Error(reason(r.data));
      if (action === 'start') {
        pending = r.data.pending; pollErrors = 0; $('code').textContent = r.data.code;
        var url = new URL(r.data.url);
        if (url.protocol !== 'https:') throw new Error('Invalid sign-in URL');
        $('login-link').href = url.href; $('account-status').textContent = 'Open the link and approve the code. This page checks automatically.'; schedule(r.data.interval);
      } else { pending = null; loginGeneration = ''; clearTimeout(timer); accountStatus(); }
    }).catch(function (e) { if (action === 'cancel') { pending = null; clearTimeout(timer); } failed(e); })
      .finally(function () { accountBusy = false; accountControls(); });
  }
  $('provider').addEventListener('change', renderProvider);
  ['key','endpoint','model','effort','vision','activate','protocol','native-media'].forEach(function (id) { $(id).addEventListener('input', invalidate); });
  $('verify-provider').addEventListener('click', function () { operate('verify', providerRequest(), $('save-provider'), $('key')); });
  $('save-provider').addEventListener('click', function () { operate('save', providerRequest(), $('save-provider'), $('key')); });
  $('login').addEventListener('click', function () { accountAction('start'); });
  $('cancel').addEventListener('click', function () { accountAction('cancel'); });
  $('logout').addEventListener('click', function () { accountAction('logout'); });
  refresh(false).catch(failed);
}());
