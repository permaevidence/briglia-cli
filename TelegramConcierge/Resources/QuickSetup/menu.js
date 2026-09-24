/* briglia menu — ChatGPT-subscription setup and settings.
   State lives on the server (GET /api/menu/status); every change is one
   POST /api/menu {action, ...} that checks and saves in one go and answers
   with the fresh status. No inline script/style (CSP), no storage. */
(function () {
  'use strict';

  var ORDER = ['name', 'chatgpt', 'telegram', 'serper', 'jina', 'openai', 'email', 'computer', 'tools'];
  var S = null;                 // last status from the server
  var view = { kind: 'loading', step: null };
  var guided = false;
  var local = {};               // per-step UI state (typed values, notices)
  var gone = false;
  var inflight = 0;
  var langPicked = false;       // first run: the language question comes first

  function lang() { return S && S.lang === 'it' ? 'it' : 'en'; }
  function T(en, it) { return lang() === 'it' ? it : en; }
  function setLang(l) { langPicked = true; act('lang', { lang: l }); }

  // ---------- tiny DOM helpers ----------
  function $(id) { return document.getElementById(id); }
  function h(tag, attrs, kids) {
    var e = document.createElement(tag);
    if (attrs) for (var k in attrs) {
      if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
      var v = attrs[k];
      if (v === null || v === undefined || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = String(v);
      else if (k.slice(0, 2) === 'on') e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v === true ? '' : String(v));
    }
    (kids || []).forEach(function (c) {
      if (c === null || c === undefined || c === false) return;
      e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return e;
  }
  function svg(path, opts) {
    var ns = 'http://www.w3.org/2000/svg';
    var s = document.createElementNS(ns, 'svg');
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('fill', 'none');
    s.setAttribute('stroke', (opts && opts.stroke) || '#fff'); s.setAttribute('stroke-width', (opts && opts.width) || '2.6');
    s.setAttribute('stroke-linecap', 'round'); s.setAttribute('stroke-linejoin', 'round');
    var p = document.createElementNS(ns, 'path'); p.setAttribute('d', path); s.appendChild(p);
    return s;
  }
  var CHECK = 'M5 12.5l4.5 4.5L19 7.5';
  function link(url, label) { return h('a', { class: 'pill-link', href: url, target: '_blank', rel: 'noopener noreferrer', text: (label || url.replace(/^https?:\/\//, '')) + ' ↗' }); }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }

  // ---------- server ----------
  function api(method, path, body) {
    var opts = { method: method, credentials: 'same-origin', headers: {} };
    if (method === 'POST') {
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['X-Briglia-Quick-Setup'] = '1';
      opts.body = JSON.stringify(body || {});
    }
    return fetch(path, opts).then(function (r) {
      if (r.status === 404) { gone = true; render(); throw { gone: true }; }
      return r.text().then(function (t) {
        var j = {}; try { j = t ? JSON.parse(t) : {}; } catch (e) { j = {}; }
        return { status: r.status, json: j };
      });
    });
  }
  function refresh() {
    return api('GET', '/api/menu/status').then(function (r) {
      if (r.json && r.json.steps) { S = r.json; if (view.kind === 'loading') start(); render(); }
    }).catch(function () {});
  }
  // `current` (optional): false once the field this action came from has
  // moved on (edited, or a newer submission) — its reply then updates the
  // page state but shows no message and reports `stale`.
  function act(action, extra, step, current) {
    var body = extra || {}; body.action = action;
    inflight++; render();
    return api('POST', '/api/menu', body).then(function (r) {
      inflight--;
      var j = r.json || {};
      if (j.status && j.status.steps) S = j.status;
      // Replaced on the server by a newer change to the same setting.
      if (j.superseded || (current && !current())) { j.stale = true; render(); return j; }
      if (step) {
        local[step] = local[step] || {};
        local[step].notice = j.ok ? (j.message ? { kind: 'ok', text: j.message } : null)
                                  : { kind: 'bad', text: j.message || T('Something went wrong. Try again.', 'Qualcosa è andato storto. Riprova.') };
      }
      render();
      return j;
    }).catch(function (e) { inflight--; if (!e || !e.gone) { if (step) { local[step] = local[step] || {}; local[step].notice = { kind: 'bad', text: T('Briglia stopped answering. Check the terminal window.', 'Briglia non risponde più. Controlla la finestra del terminale.') }; } render(); } return { ok: false }; });
  }

  // ---------- navigation ----------
  function stepInfo(id) { return (S.steps || []).filter(function (s) { return s.id === id; })[0] || { id: id, title: id }; }
  function isDone(id) { return !!stepInfo(id).done; }
  function start() {
    if (S.complete) { view = { kind: 'dashboard' }; return; }
    view = { kind: 'welcome' };
  }
  // Pending auto-checks belong to the screen they were typed on.
  function cancelTimers() {
    for (var k in local) if (Object.prototype.hasOwnProperty.call(local, k) && local[k].timer) { clearTimeout(local[k].timer); local[k].timer = null; }
  }
  function openStep(id, asGuided) {
    cancelTimers();
    if (asGuided !== undefined) guided = asGuided;
    view = { kind: 'step', step: id };
    local[id] = local[id] || {};
    local[id].notice = null;
    render();
    window.scrollTo(0, 0);
  }
  function next(from) {
    if (!guided) { view = { kind: 'dashboard' }; render(); return; }
    var i = ORDER.indexOf(from);
    for (var k = i + 1; k < ORDER.length; k++) { if (!isDone(ORDER[k])) { openStep(ORDER[k]); return; } }
    var missing = (S.steps || []).filter(function (s) { return s.required && !s.done; });
    if (missing.length === 0) { view = { kind: 'finish' }; }
    else { openStep(missing[0].id); return; }
    render();
  }
  function backToDashboard() { cancelTimers(); guided = false; view = { kind: 'dashboard' }; render(); }

  // ---------- chrome ----------
  function renderChrome() {
    var logo = $('logo');
    if (!logo.firstChild) logo.appendChild(svg('M7 5h6a3.5 3.5 0 010 7H7zm0 7h7a3.5 3.5 0 010 7H7z', { width: '2.4' }));
    $('brand-tag').textContent = S && S.complete ? T('Settings', 'Impostazioni') : T('Setup', 'Configurazione');
    var list = $('steps'); clear(list);
    if (!S) return;
    var done = 0, total = 0;
    S.steps.forEach(function (s, idx) {
      if (s.required) { total++; if (s.done) done++; }
      var cls = [s.done ? 'done' : (s.required ? 'todo' : ''), s.required ? '' : 'optional', view.kind === 'step' && view.step === s.id ? 'current' : ''].join(' ');
      var dot = h('span', { class: 'dot' }, [s.done ? svg(CHECK, { width: '3' }) : String(idx + 1)]);
      list.appendChild(h('li', { class: cls }, [h('button', { type: 'button', onclick: function () { openStep(s.id, false); } },
        [dot, h('span', { text: s.title }), s.required ? null : h('span', { class: 'opt', text: T('optional', 'facoltativo') })])]));
    });
    var pct = total ? Math.round(done * 100 / total) : 0;
    $('m-progress').style.width = pct + '%';
    $('m-left').textContent = total - done > 0 ? T((total - done) + ' left', 'ne mancano ' + (total - done)) : T('All set', 'Tutto pronto');
    $('m-step').textContent = view.kind === 'step' ? stepInfo(view.step).title : (S.complete ? T('Settings', 'Impostazioni') : T('Setup', 'Configurazione'));
    $('side-note').textContent = T('Everything you enter is saved right away. Close this page any time and type briglia menu to come back.', 'Tutto quello che inserisci viene salvato subito. Chiudi questa pagina quando vuoi e scrivi briglia menu per tornare.');
    $('footer').textContent = T('This page runs only on this computer. Your keys go straight to each service to be checked, and nowhere else.', 'Questa pagina funziona solo su questo computer. Le tue chiavi vanno direttamente a ciascun servizio per essere controllate, e da nessun’altra parte.');
    document.documentElement.lang = lang();
    var sw = $('lang-switch'); clear(sw);
    sw.appendChild(h('button', { type: 'button', class: 'langbtn' + (lang() === 'en' ? ' on' : ''), 'aria-label': 'English', title: 'English', onclick: function () { if (lang() !== 'en') setLang('en'); } }, [h('span', { class: 'flag', text: '\ud83c\uddec\ud83c\udde7' }), h('span', { text: 'EN' })]));
    sw.appendChild(h('button', { type: 'button', class: 'langbtn' + (lang() === 'it' ? ' on' : ''), 'aria-label': 'Italiano', title: 'Italiano', onclick: function () { if (lang() !== 'it') setLang('it'); } }, [h('span', { class: 'flag', text: '\ud83c\uddee\ud83c\uddf9' }), h('span', { text: 'IT' })]));
  }

  // ---------- views ----------
  function render() {
    // Re-rendering must not steal the caret from a field being typed in.
    var focused = document.activeElement && document.activeElement.id ? document.activeElement.id : null;
    var caret = focused && document.activeElement.selectionStart !== undefined ? document.activeElement.selectionStart : null;
    renderInner();
    if (focused) {
      var again = $(focused);
      if (again && again !== document.activeElement) {
        again.focus();
        if (caret !== null && again.setSelectionRange) { try { again.setSelectionRange(caret, caret); } catch (e) {} }
      }
    }
  }

  function renderInner() {
    var card = $('card'); clear(card);
    if (gone) {
      card.appendChild(h('div', { class: 'gone' }, [h('h1', { text: T('This page has closed', 'Questa pagina è chiusa') }),
        h('p', { class: 'lead', text: T('Type briglia menu in the terminal to open it again.', 'Scrivi briglia menu nel terminale per riaprirla.') })]));
      return;
    }
    if (!S) { card.appendChild(h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), T('Loading…', 'Caricamento…')])); return; }
    renderChrome();
    if (S.closing) { card.appendChild(closingView()); return; }
    if (S.startup) { startupView().forEach(function (n) { if (n) card.appendChild(n); }); return; }
    var v;
    if (view.kind === 'welcome') v = welcomeView();
    else if (view.kind === 'dashboard') v = dashboardView();
    else if (view.kind === 'finish') v = finishView();
    else v = stepView(view.step);
    v.forEach(function (n) { if (n) card.appendChild(n); });
  }

  function notice(step) {
    var n = local[step] && local[step].notice;
    if (!n) return null;
    return h('div', { class: 'notice ' + n.kind }, [n.text]);
  }

  function welcomeView() {
    var fresh = !(S.steps || []).some(function (s) { return s.done && ['computer', 'tools'].indexOf(s.id) < 0; });
    if (fresh && !langPicked) {
      var pick = function (l) { return function () { if (l === lang()) { langPicked = true; render(); } else setLang(l); }; };
      return [
        h('div', { class: 'eyebrow', text: 'Language · Lingua' }),
        h('h1', { text: 'Choose your language' }),
        h('p', { class: 'lead', text: 'Scegli la lingua' }),
        h('div', { class: 'langpick' }, [
          h('button', { class: 'langcard' + (lang() === 'en' ? ' sel' : ''), type: 'button', onclick: pick('en') }, [h('span', { class: 'bigflag', text: '\ud83c\uddec\ud83c\udde7' }), h('span', { class: 'lname', text: 'English' })]),
          h('button', { class: 'langcard' + (lang() === 'it' ? ' sel' : ''), type: 'button', onclick: pick('it') }, [h('span', { class: 'bigflag', text: '\ud83c\uddee\ud83c\uddf9' }), h('span', { class: 'lname', text: 'Italiano' })]),
        ]),
        h('p', { class: 'small', text: 'You can switch any time with the flags at the top. · Puoi cambiarla quando vuoi con le bandiere in alto.' }),
      ];
    }
    var back = (S.steps || []).some(function (s) { return s.done && ['computer', 'tools'].indexOf(s.id) < 0; });
    var left = S.steps.filter(function (s) { return s.required && !s.done; }).length;
    return [
      h('div', { class: 'eyebrow', text: back ? T('Welcome back', 'Bentornato') : T('Welcome', 'Benvenuto') }),
      h('h1', { text: back ? T('Let’s finish setting up Briglia', 'Completiamo la configurazione di Briglia') : T('Let’s set up Briglia', 'Configuriamo Briglia') }),
      h('p', { class: 'lead', text: back ? (left === 1 ? T('1 step left. Everything you entered before is saved.', 'Manca 1 passaggio. Tutto quello che hai inserito è salvato.') : T(left + ' steps left. Everything you entered before is saved.', 'Mancano ' + left + ' passaggi. Tutto quello che hai inserito è salvato.'))
        : T('Briglia is your personal assistant. You talk to it on Telegram and it thinks with your ChatGPT subscription. This takes about 10 minutes, and everything is saved as you go.', 'Briglia è il tuo assistente personale. Gli parli su Telegram e ragiona con il tuo abbonamento ChatGPT. Ci vogliono circa 10 minuti, e tutto viene salvato man mano.') }),
      back ? null : h('p', { class: 'small', text: T('You’ll need:', 'Ti serviranno:') }),
      back ? null : h('ul', { class: 'bullets' }, [
        h('li', { text: T('a ChatGPT account with Plus or Pro', 'un account ChatGPT Plus o Pro') }),
        h('li', { text: T('Telegram on your phone', 'Telegram sul telefono') }),
        h('li', { text: T('free accounts at serper.dev and jina.ai — we’ll show you exactly where to click', 'due account gratuiti su serper.dev e jina.ai: ti mostriamo esattamente dove cliccare') }),
      ]),
      h('div', { class: 'actions' }, [
        h('button', { class: 'btn primary', type: 'button', onclick: function () { guided = true; var first = ORDER.filter(function (id) { return !isDone(id); })[0]; if (first) openStep(first, true); else { view = { kind: 'finish' }; render(); } } }, [back ? T('Continue', 'Continua') : T('Let’s start', 'Iniziamo')]),
        h('button', { class: 'btn ghost', type: 'button', onclick: backToDashboard }, [T('See all settings', 'Vedi tutte le impostazioni')]),
      ]),
    ];
  }

  function dashboardView() {
    var missing = S.steps.filter(function (s) { return s.required && !s.done; });
    var grid = h('div', { class: 'grid' }, S.steps.map(function (s) {
      var badge = s.done ? h('span', { class: 'badge ok', text: T('✓ Done', '✓ Fatto') })
        : s.required ? h('span', { class: 'badge todo', text: T('Needed', 'Da fare') }) : h('span', { class: 'badge opt', text: T('Optional', 'Facoltativo') });
      return h('button', { class: 'tile', type: 'button', onclick: function () { openStep(s.id, false); } },
        [h('div', { class: 'top' }, [h('span', { class: 'ttl', text: s.title }), badge]), h('div', { class: 'val', text: s.summary || '' })]);
    }));
    var startLabel = S.platform === 'linux' ? (S.service_was_running ? T('Save and restart Briglia', 'Salva e riavvia Briglia') : T('Start Briglia', 'Avvia Briglia')) : T('Start Briglia', 'Avvia Briglia');
    return [
      h('div', { class: 'eyebrow', text: T('Settings', 'Impostazioni') }),
      h('h1', { text: missing.length ? T('Almost there', 'Ci siamo quasi') : T('Everything’s ready', 'È tutto pronto') }),
      h('p', { class: 'lead', text: missing.length ? (T('Still needed: ', 'Mancano ancora: ') + missing.map(function (s) { return s.title; }).join(', ') + '.') : T('Click anything to change it. Changes are saved right away.', 'Clicca su qualsiasi voce per modificarla. Le modifiche vengono salvate subito.') }),
      notice('dashboard'),
      grid,
      h('div', { class: 'actions' }, [
        missing.length ? h('button', { class: 'btn primary', type: 'button', onclick: function () { guided = true; openStep(missing[0].id, true); } }, [T('Continue setup', 'Continua la configurazione')])
          : h('button', { class: 'btn primary', type: 'button', onclick: function () { finish('start'); } }, [startLabel]),
        h('span', { class: 'spacer' }),
        h('button', { class: 'btn ghost', type: 'button', onclick: function () { finish('quit'); } }, [S.service_was_running ? T('Close and restart Briglia', 'Chiudi e riavvia Briglia') : T('Close', 'Chiudi')]),
      ]),
    ];
  }

  function finishView() {
    var mac = S.platform !== 'linux';
    return [
      h('div', { class: 'celebrate' }, [svg(CHECK, { width: '3' })]),
      h('h1', { text: T('Everything’s ready!', 'È tutto pronto!') }),
      h('p', { class: 'lead', text: mac
        ? T('Briglia will run in the Terminal window you started this from. Keep that window open (you can minimize it) and talk to Briglia on Telegram.', 'Briglia funzionerà nella finestra del Terminale da cui l’hai avviato. Lasciala aperta (puoi ridurla a icona) e parla con Briglia su Telegram.')
        : T('Briglia will run in the background and start by itself whenever this computer turns on. Talk to it on Telegram.', 'Briglia funzionerà in background e partirà da solo a ogni accensione del computer. Parlagli su Telegram.') }),
      h('p', { class: 'small', text: T('To change anything later, type briglia menu in a terminal.', 'Per cambiare qualcosa in futuro, scrivi briglia menu in un terminale.') }),
      notice('finish'),
      h('div', { class: 'actions' }, [
        h('button', { class: 'btn primary', type: 'button', onclick: function () { finish('start'); } }, [T('Start Briglia', 'Avvia Briglia')]),
        h('button', { class: 'btn ghost', type: 'button', onclick: function () { finish('quit'); } }, [T('Not now', 'Non ora')]),
      ]),
    ];
  }

  function closingView() {
    var start = S.closing === 'start';
    var mac = S.platform !== 'linux';
    return h('div', { class: 'gone' }, [
      h('div', { class: 'celebrate' }, [svg(CHECK, { width: '3' })]),
      h('h1', { text: start ? T('Briglia is starting', 'Briglia si sta avviando') : T('All saved', 'Tutto salvato') }),
      h('p', { class: 'lead', text: start ? (mac ? T('Keep the Terminal window open. Now say hello to your bot on Telegram! You can close this page.', 'Lascia aperta la finestra del Terminale. Ora saluta il tuo bot su Telegram! Puoi chiudere questa pagina.') : T('It runs in the background now. Say hello to your bot on Telegram! You can close this page.', 'Ora funziona in background. Saluta il tuo bot su Telegram! Puoi chiudere questa pagina.'))
        : T('You can close this page. Type briglia menu any time to come back.', 'Puoi chiudere questa pagina. Scrivi briglia menu quando vuoi per tornare qui.') }),
    ]);
  }

  // Linux: the service is started and health-checked while this page stays
  // open; "running" appears only after that check passed.
  function startupView() {
    var u = S.startup;
    if (u.state === 'running') {
      return [h('h1', { text: T('Starting Briglia', 'Avvio Briglia') }),
        h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), u.step || T('One moment…', 'Un momento…')]),
        h('p', { class: 'small', text: T('Keep this page open until it’s done.', 'Lascia aperta questa pagina finché non ha finito.') })];
    }
    return [h('h1', { text: T('Briglia didn’t start', 'Briglia non si è avviato') }),
      h('div', { class: 'notice bad' }, [u.message || T('Something went wrong.', 'Qualcosa è andato storto.')]),
      notice('startup'),
      h('p', { class: 'small', text: T('Your settings are saved. You can try again, or close and look at it later.', 'Le impostazioni sono salvate. Puoi riprovare, oppure chiudere e guardarci più tardi.') }),
      h('div', { class: 'actions' }, [
        h('button', { class: 'btn primary', type: 'button', disabled: inflight > 0, onclick: function () { act('finish', { what: 'start' }, 'startup'); } }, [T('Try again', 'Riprova')]),
        h('span', { class: 'spacer' }),
        h('button', { class: 'btn ghost', type: 'button', disabled: inflight > 0, onclick: function () { act('finish', { what: 'quit' }, 'startup'); } }, [T('Close without starting', 'Chiudi senza avviare')])])];
  }

  function finish(what) {
    act('finish', { what: what }, view.kind === 'finish' ? 'finish' : 'dashboard');
  }

  function stepHeader(id, eyebrow, title, lead) {
    return [h('div', { class: 'eyebrow', text: eyebrow || (stepInfo(id).required ? T('Step ', 'Passo ') + (ORDER.indexOf(id) + 1) : T('Optional', 'Facoltativo')) }),
      h('h1', { text: title }), lead ? h('p', { class: 'lead', text: lead }) : null];
  }

  function navButtons(id, primary) {
    var done = isDone(id);
    var optional = !stepInfo(id).required;
    return h('div', { class: 'actions' }, [
      primary || null,
      (guided && done) ? h('button', { class: 'btn primary', type: 'button', onclick: function () { next(id); } }, [T('Continue →', 'Continua →')]) : null,
      (guided && !done && optional) ? h('button', { class: 'btn secondary', type: 'button', onclick: function () { next(id); } }, [T('Skip for now', 'Salta per ora')]) : null,
      h('span', { class: 'spacer' }),
      h('button', { class: 'btn ghost', type: 'button', onclick: backToDashboard }, [guided ? T('See all settings', 'Vedi tutte le impostazioni') : T('← Back', '← Indietro')]),
    ]);
  }

  // Secret / text field with automatic checking. Its state (value, timer,
  // submission number) lives in local[step], not in the DOM node, so it
  // survives re-renders. A reply counts only for the submission that is
  // still the newest AND whose value is still in the field; a value edited
  // while its check ran is checked next instead of being dropped.
  function field(step, opts) {
    var st = local[step] = local[step] || {};
    var input = h('input', { type: opts.secret && !st.show ? 'password' : 'text', id: 'f-' + step, autocomplete: 'off', spellcheck: 'false',
      placeholder: opts.placeholder || '', 'aria-label': opts.label || 'value' });
    input.value = st.value || '';
    function typed() { return (st.value || '').trim(); }
    function schedule(delay) {
      if (st.timer) clearTimeout(st.timer);
      st.timer = null;
      if (opts.auto !== false && typed().length >= (opts.minAuto || 12)) st.timer = setTimeout(submit, delay);
    }
    function submit() {
      if (st.timer) { clearTimeout(st.timer); st.timer = null; }
      var v = typed();
      if (!v) return;
      if (st.sent === v && (st.checking || st.lastOk)) return;   // already checking / saved this exact value
      var seq = (st.seq || 0) + 1;
      st.seq = seq; st.sent = v; st.checking = true; st.lastOk = false;
      render();
      function current() { return st.seq === seq && typed() === v; }
      opts.onSubmit(v, current).then(function (j) {
        if (st.seq !== seq) return;              // a newer submission owns the field
        st.checking = false;
        if (typed() !== v) {                     // edited while checking: keep the new value, check it
          st.sent = null; st.editing = true;
          render(); schedule(300);
          return;
        }
        st.lastOk = !!(j && j.ok && !j.stale);
        if (st.lastOk) { st.value = ''; st.sent = null; st.editing = false; }
        render();
        var again = $('f-' + step); if (again && !st.lastOk) again.focus();
      });
    }
    input.addEventListener('input', function () {
      st.value = input.value; st.lastOk = false;
      schedule(1200);
    });
    input.addEventListener('paste', function () { if (opts.auto !== false) setTimeout(function () { st.value = input.value; submit(); }, 60); });
    input.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); st.value = input.value; submit(); } });
    var row = h('div', { class: 'input-row' }, [input,
      opts.secret ? h('button', { class: 'btn secondary small', type: 'button', onclick: function () { st.show = !st.show; render(); } }, [st.show ? T('Hide', 'Nascondi') : T('Show', 'Mostra')]) : null,
      opts.button ? h('button', { class: 'btn primary', type: 'button', onclick: submit, disabled: !!st.checking }, [opts.button]) : null]);
    var status = null;
    if (st.checking) status = h('div', { class: 'status work' }, [h('span', { class: 'spinner small' }), opts.checkingText || T('Checking…', 'Controllo…')]);
    setTimeout(function () { var f = $('f-' + step); if (f && document.activeElement === document.body) f.focus(); }, 0);
    return h('div', { class: 'input-wrap' }, [opts.label ? h('label', { for: 'f-' + step, text: opts.label }) : null, row, status]);
  }

  function savedBox(text, sub) {
    return h('div', { class: 'saved' }, [svg(CHECK, { stroke: 'currentColor', width: '3' }), h('span', {}, [text, sub ? h('span', { class: 'sub', text: ' \u00b7 ' + sub }) : null])]);
  }

  function KEYS() { return {
    serper: { title: T('Web search', 'Ricerca web'), lead: T('Serper lets Briglia search Google. The free plan includes 2,500 searches — plenty to start.', 'Serper permette a Briglia di cercare su Google. Il piano gratuito include 2.500 ricerche: più che sufficienti per iniziare.'),
      steps: [[T('Open ', 'Apri '), link('https://serper.dev/signup', 'serper.dev'), T(' and sign up (free, no card needed).', ' e registrati (gratis, senza carta).')], [T('In the dashboard, open ', 'Nella dashboard apri '), h('b', { text: 'API Key' }), T(' and copy it.', ' e copiala.')], [T('Paste it below. It’s checked automatically.', 'Incollala qui sotto. Viene controllata in automatico.')]],
      placeholder: T('Paste your Serper key', 'Incolla la chiave Serper') },
    jina: { title: T('Reading web pages', 'Lettura pagine web'), lead: T('Jina lets Briglia open and read web pages. You can start for free.', 'Jina permette a Briglia di aprire e leggere le pagine web. Puoi iniziare gratis.'),
      steps: [[T('Open ', 'Apri '), link('https://jina.ai/reader', 'jina.ai/reader'), '.'], [T('Copy your API key (it starts with ', 'Copia la tua chiave API (inizia con '), h('b', { text: 'jina_' }), T('). Sign in to keep your free credits.', '). Accedi per conservare i crediti gratuiti.')], [T('Paste it below.', 'Incollala qui sotto.')]],
      placeholder: 'jina_…' },
    openai: { title: T('Voice messages & images', 'Messaggi vocali e immagini'), lead: T('Optional. An OpenAI API key lets Briglia understand your voice messages and create images. Without it, everything else works.', 'Facoltativo. Una chiave API di OpenAI permette a Briglia di capire i tuoi messaggi vocali e di creare immagini. Senza, tutto il resto funziona.'),
      extra: T('This is separate from ChatGPT: OpenAI bills API use per request, so you add a few dollars of credit.', 'È separata da ChatGPT: OpenAI fa pagare l’uso delle API a richiesta, quindi aggiungi qualche dollaro di credito.'),
      steps: [[T('Open ', 'Apri '), link('https://platform.openai.com/api-keys', 'platform.openai.com/api-keys'), T(' and sign in.', ' e accedi.')], [T('Click ', 'Clicca '), h('b', { text: 'Create new secret key' }), T(' and copy it.', ' e copiala.')], [T('Add a little credit under ', 'Aggiungi un po’ di credito in '), h('b', { text: 'Settings → Billing' }), '.'], [T('Paste the key below.', 'Incolla la chiave qui sotto.')]],
      placeholder: 'sk-…' },
    email: { title: 'Email', lead: T('Optional. AgentMail gives Briglia its own email address, so it can receive and send email for you, and a calendar.', 'Facoltativo. AgentMail dà a Briglia un suo indirizzo email, così può ricevere e inviare email per te, e un calendario.'),
      steps: [[T('Sign up at ', 'Registrati su '), link('https://agentmail.to', 'agentmail.to'), T(' (there’s a free plan).', ' (c’è un piano gratuito).')], [T('Create an inbox, then an ', 'Crea una casella, poi una '), h('b', { text: 'API key' }), T(', and copy it.', ' e copiala.')], [T('Paste it below.', 'Incollala qui sotto.')]],
      placeholder: T('Paste your AgentMail key', 'Incolla la chiave AgentMail') },
  }; }

  function stepView(id) {
    var st = local[id] = local[id] || {};
    if (id === 'name') return nameView(st);
    if (id === 'chatgpt') return chatgptView(st);
    if (id === 'telegram') return telegramView(st);
    if (KEYS()[id]) return keyView(id, st);
    if (id === 'computer') return computerView(st);
    if (id === 'tools') return toolsView(st);
    return [h('p', { text: '?' })];
  }

  function nameView(st) {
    var out = stepHeader('name', null, T('What should Bree call you?', 'Come deve chiamarti Bree?'), T('Bree is the name of your assistant. You can change it later by asking Bree.', 'Bree è il nome del tuo assistente. Puoi cambiarlo in seguito chiedendolo a Bree.'));
    out.push(notice('name'));
    if (S.name && !st.editing) {
      out.push(savedBox(S.name));
      out.push(navButtons('name', h('button', { class: 'btn secondary', type: 'button', onclick: function () { st.editing = true; st.value = S.name; render(); } }, [T('Change', 'Cambia')])));
      return out;
    }
    out.push(field('name', { label: T('Your first name', 'Il tuo nome'), placeholder: T('e.g. Sofia', 'es. Sofia'), auto: false, button: T('Save', 'Salva'), onSubmit: function (v, current) {
      return act('name', { name: v }, 'name', current).then(function (j) { if (j.ok && !j.stale && guided) next('name'); return j; });
    } }));
    out.push(navButtons('name'));
    return out;
  }

  function keyView(id, st) {
    var k = KEYS()[id];
    var masked = id === 'email' ? (S.email && S.email.on ? S.keys.agentmail : null) : S.keys[id];
    var out = stepHeader(id, null, k.title, k.lead);
    out.push(notice(id));
    if (masked && !st.editing) {
      if (id === 'email') {
        out.push(savedBox(T('Email is on', 'Email attiva'), S.email.inbox ? T('Briglia’s address: ', 'Indirizzo di Briglia: ') + S.email.inbox : ''));
        if (!S.email.tool_installed) out.push(h('div', { class: 'notice warn' }, [T('The email tool isn’t installed yet.', 'Lo strumento email non è ancora installato.')]));
        if (S.busy === 'email_tool') out.push(h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), T('Installing the email tool…', 'Installo lo strumento email…')]));
      } else out.push(savedBox(T('Key saved', 'Chiave salvata'), masked));
      var btns = [h('button', { class: 'btn secondary', type: 'button', onclick: function () { st.editing = true; st.value = ''; local[id].notice = null; render(); } }, [T('Paste a new key', 'Incolla una nuova chiave')])];
      if (id === 'openai') btns.push(h('button', { class: 'btn danger', type: 'button', onclick: function () { act('key_remove', { kind: 'openai' }, id); } }, [T('Remove', 'Rimuovi')]));
      if (id === 'email') {
        if (!S.email.tool_installed && S.busy !== 'email_tool') btns.push(h('button', { class: 'btn secondary', type: 'button', onclick: function () { act('email_tool', {}, id); } }, [T('Install the email tool', 'Installa lo strumento email')]));
        btns.push(h('button', { class: 'btn danger', type: 'button', onclick: function () { act('email_off', {}, id); } }, [T('Turn email off', 'Disattiva l’email')]));
      }
      out.push(h('div', { class: 'actions' }, btns));
      out.push(navButtons(id));
      return out;
    }
    out.push(h('ol', { class: 'howto' }, k.steps.map(function (parts) { return h('li', {}, parts); })));
    if (k.extra) out.push(h('p', { class: 'small', text: k.extra }));
    if (id === 'email' && S.keys.agentmail && !S.email.on) out.push(h('p', { class: 'small', text: T('Your saved key ' + S.keys.agentmail + ' is kept — paste it again to turn email back on.', 'La chiave salvata ' + S.keys.agentmail + ' resta: incollala di nuovo per riattivare l’email.') }));
    out.push(field(id, { secret: true, placeholder: k.placeholder, label: T('Your key', 'La tua chiave'), checkingText: T('Checking your key…', 'Controllo la chiave…'), onSubmit: function (v, current) {
      return act('key', { kind: id === 'email' ? 'agentmail' : id, key: v }, id, current);
    } }));
    if (st.editing && masked) out.push(h('button', { class: 'btn ghost', type: 'button', onclick: function () { st.editing = false; render(); } }, [T('Cancel', 'Annulla')]));
    out.push(navButtons(id));
    return out;
  }

  function chatgptView(st) {
    var c = S.chatgpt || {};
    var out = stepHeader('chatgpt', null, T('Sign in to ChatGPT', 'Accedi a ChatGPT'), T('Briglia thinks with your ChatGPT subscription (Plus or Pro). You don’t pay per message: it counts toward your normal ChatGPT limits, and Briglia’s web research uses it too.', 'Briglia ragiona con il tuo abbonamento ChatGPT (Plus o Pro). Non paghi a messaggio: conta nei normali limiti di ChatGPT, e anche le ricerche web di Briglia lo usano.'));
    out.push(notice('chatgpt'));
    var login = c.login;
    if (login && login.state === 'error' && login.message) out.push(h('div', { class: 'notice bad' }, [login.message]));
    if (login && (login.state === 'waiting' || login.state === 'finishing')) {
      if (login.state === 'finishing') out.push(h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), T('Signed in — getting Briglia ready…', 'Accesso fatto: preparo Briglia…')]));
      else if (login.code) {
        out.push(h('p', { text: T('On your phone or any computer, open this page and type the code:', 'Sul telefono o su qualsiasi computer, apri questa pagina e scrivi il codice:') }));
        out.push(h('p', {}, [link(login.url)]));
        out.push(h('div', { class: 'code-box' }, [login.code, h('button', { class: 'btn secondary small', type: 'button', onclick: function () { if (navigator.clipboard) navigator.clipboard.writeText(login.code); } }, [T('Copy', 'Copia')])]));
        out.push(h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), T('Waiting for you to enter the code…', 'Aspetto che tu inserisca il codice…')]));
        out.push(h('p', { class: 'small', text: T('Code sign-in needs one setting: in ChatGPT (in the browser) open Settings → Security and Login and turn on “Enable device code authorization for Codex”.', 'L’accesso con codice richiede un’impostazione: in ChatGPT (nel browser) apri Impostazioni → Sicurezza e accesso e attiva “Enable device code authorization for Codex”.') }));
      } else {
        out.push(h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), T('A ChatGPT tab opened — sign in there and approve Briglia.', 'Si è aperta una scheda di ChatGPT: accedi lì e approva Briglia.')]));
        out.push(h('p', { class: 'small' }, [T('Nothing opened? ', 'Non si è aperto nulla? '), h('a', { href: login.url, target: '_blank', rel: 'noopener noreferrer', text: T('Open the sign-in page', 'Apri la pagina di accesso') }), '.']));
      }
      out.push(h('div', { class: 'actions' }, [h('button', { class: 'btn ghost', type: 'button', onclick: function () { act('chatgpt_cancel', {}, 'chatgpt'); } }, [T('Cancel', 'Annulla')])]));
      return out;
    }
    if (c.state === 'signed_in') {
      out.push(savedBox(c.active ? T('Signed in', 'Accesso fatto') : T('Signed in, but not in use', 'Accesso fatto, ma non in uso'), c.active ? T('Briglia thinks with ', 'Briglia ragiona con ') + c.model_label : ''));
      if (!c.active && c.other_provider) {
        out.push(h('p', { text: T('Right now Briglia uses ', 'Adesso Briglia usa ') + c.other_provider + '.' }));
        out.push(h('div', { class: 'actions' }, [h('button', { class: 'btn primary', type: 'button', onclick: function () { act('chatgpt_use', {}, 'chatgpt'); } }, [T('Use ChatGPT for Briglia', 'Usa ChatGPT per Briglia')])]));
      }
      out.push(h('p', { class: 'small', text: T('Model — GPT-6 Sol is recommended. Not every plan includes every model.', 'Modello: consigliato GPT-6 Sol. Non tutti i piani includono tutti i modelli.') }));
      out.push(h('div', { class: 'choices' }, (c.models || []).map(function (m) {
        return h('button', { class: 'choice' + (m.id === c.model ? ' sel' : ''), type: 'button', disabled: inflight > 0,
          onclick: function () { if (m.id !== c.model) act('chatgpt_model', { model: m.id }, 'chatgpt'); } },
          [h('div', { class: 'n', text: m.label }), h('div', { class: 's', text: m.id === c.model ? T('In use', 'In uso') : (m.recommended ? T('Recommended', 'Consigliato') : '') })]);
      })));
      out.push(h('div', { class: 'actions' }, [
        h('button', { class: 'btn secondary', type: 'button', onclick: function () { act('chatgpt_logout', { again: true }, 'chatgpt'); } }, [T('Use a different account', 'Usa un altro account')]),
        h('button', { class: 'btn danger', type: 'button', onclick: function () { act('chatgpt_logout', {}, 'chatgpt'); } }, [T('Sign out', 'Esci')]),
      ]));
      out.push(navButtons('chatgpt'));
      return out;
    }
    if (c.state === 'login_required') out.push(h('div', { class: 'notice warn' }, [T('Your ChatGPT sign-in has expired. Please sign in again.', 'L’accesso a ChatGPT è scaduto. Accedi di nuovo.')]));
    if (c.other_provider) out.push(h('p', { class: 'small', text: T('Right now Briglia uses ' + c.other_provider + '. Signing in switches it to ChatGPT.', 'Adesso Briglia usa ' + c.other_provider + '. Accedendo passerà a ChatGPT.') }));
    var browserBtn = h('button', { class: 'btn dark', type: 'button', disabled: inflight > 0, onclick: function () { act('chatgpt_browser', {}, 'chatgpt'); } }, [T('Sign in with ChatGPT', 'Accedi con ChatGPT')]);
    var codeBtn = h('button', { class: 'btn secondary', type: 'button', disabled: inflight > 0, onclick: function () { act('chatgpt_code', {}, 'chatgpt'); } }, [T('Use a code instead', 'Usa un codice')]);
    out.push(h('div', { class: 'actions' }, S.browser_likely === false ? [codeBtn, browserBtn] : [browserBtn, codeBtn]));
    out.push(h('p', { class: 'small', text: T('“Use a code” works from your phone or another computer.', '“Usa un codice” funziona dal telefono o da un altro computer.') }));
    out.push(navButtons('chatgpt'));
    return out;
  }

  function telegramView(st) {
    var t = S.telegram || {};
    var p = t.pending;
    var out = stepHeader('telegram', null, T('Connect Telegram', 'Collega Telegram'), T('You talk to Briglia on Telegram, through your own private bot. Making one takes a minute.', 'Parli con Briglia su Telegram, tramite un tuo bot privato. Crearlo richiede un minuto.'));
    out.push(notice('telegram'));
    if (!p && t.error) out.push(h('div', { class: 'notice bad' }, [t.error]));
    if (p && p.state === 'found') {
      out.push(h('div', { class: 'found' }, [h('div', { class: 'avatar', text: (p.name || '?').charAt(0).toUpperCase() }),
        h('div', {}, [h('div', { class: 'who', text: p.name }), h('div', { class: 'q', text: T('sent a message to @' + p.bot + '. Is this you?', 'ha scritto a @' + p.bot + '. Sei tu?') })])]));
      out.push(h('div', { class: 'actions' }, [
        h('button', { class: 'btn primary', type: 'button', disabled: inflight > 0, onclick: function () { act('telegram_confirm', { chat_id: p.chat_id }, 'telegram').then(function (j) { if (j.ok && guided) next('telegram'); }); } }, [T('Yes, that’s me', 'Sì, sono io')]),
        h('button', { class: 'btn secondary', type: 'button', onclick: function () { act('telegram_wait', {}, 'telegram'); } }, [T('No', 'No')]),
      ]));
      return out;
    }
    if (p && (p.state === 'waiting' || p.state === 'manual')) {
      out.push(savedBox(T('Your bot: @', 'Il tuo bot: @') + p.bot));
      if (p.state === 'manual') {
        out.push(h('p', { text: T('Type your numeric Telegram ID. To find it, open @userinfobot in Telegram and send it any message: it replies with your ID (a number like 123456789).', 'Scrivi il tuo ID Telegram numerico. Per trovarlo apri @userinfobot su Telegram e mandagli un messaggio qualsiasi: ti risponde con il tuo ID (un numero tipo 123456789).') }));
        out.push(field('telegram-id', { label: T('Your Telegram ID', 'Il tuo ID Telegram'), placeholder: '123456789', auto: false, button: T('Connect', 'Collega'), onSubmit: function (v, current) {
          return act('telegram_confirm', { chat_id: v }, 'telegram', current).then(function (j) { if (j.ok && !j.stale && guided) next('telegram'); return j; });
        } }));
        out.push(h('div', { class: 'actions' }, [h('button', { class: 'btn ghost', type: 'button', onclick: function () { act('telegram_wait', {}, 'telegram'); } }, [T('← Detect it automatically instead', '← Rilevalo in automatico')])]));
        return out;
      }
      out.push(h('p', { class: 'lead', text: T('Last step: open your bot and send it any message, like “hello”.', 'Ultimo passo: apri il tuo bot e mandagli un messaggio qualsiasi, tipo “ciao”.') }));
      out.push(h('div', { class: 'actions' }, [h('a', { class: 'btn primary', href: 'https://t.me/' + p.bot, target: '_blank', rel: 'noopener noreferrer' }, [T('Open @' + p.bot + ' in Telegram ↗', 'Apri @' + p.bot + ' su Telegram ↗')])]));
      out.push(h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), T('Waiting for your message…', 'Aspetto il tuo messaggio…')]));
      out.push(h('p', { class: 'small', text: T('Briglia will answer that message once it’s running.', 'Briglia risponderà a quel messaggio quando sarà in funzione.') }));
      out.push(h('div', { class: 'links' }, [
        h('button', { class: 'btn ghost small', type: 'button', onclick: function () { act('telegram_manual', {}, 'telegram'); } }, [T('Type my Telegram ID instead', 'Scrivo io il mio ID Telegram')]),
        h('button', { class: 'btn ghost small', type: 'button', onclick: function () { act('telegram_reset', {}, 'telegram'); } }, [T('Use another bot', 'Usa un altro bot')])]));
      return out;
    }
    if (t.configured && !st.editing) {
      out.push(savedBox(T('Connected', 'Collegato'), t.bot ? '@' + t.bot : ''));
      out.push(h('p', { class: 'small', text: T('Your Telegram ID: ', 'Il tuo ID Telegram: ') + t.chat_id }));
      out.push(h('div', { class: 'actions' }, [h('button', { class: 'btn secondary', type: 'button', onclick: function () { st.editing = true; render(); } }, [T('Connect a different bot', 'Collega un altro bot')])]));
      out.push(navButtons('telegram'));
      return out;
    }
    out.push(h('ol', { class: 'howto' }, [
      h('li', {}, [T('In Telegram, open ', 'Su Telegram apri '), link('https://t.me/BotFather', '@BotFather'), '.']),
      h('li', {}, [T('Send ', 'Invia '), h('b', { text: '/newbot' }), T(', then pick a name and a username that ends in “bot”.', ', poi scegli un nome e un nome utente che finisca con “bot”.')]),
      h('li', {}, [T('BotFather replies with a ', 'BotFather ti risponde con un '), h('b', { text: 'token' }), T(' — a long code like 123456789:AAE… Copy it and paste it below.', ': un codice lungo tipo 123456789:AAE… Copialo e incollalo qui sotto.')]),
    ]));
    out.push(field('telegram', { secret: true, label: T('Bot token', 'Token del bot'), placeholder: '123456789:AAE…', minAuto: 30, checkingText: T('Checking the token…', 'Controllo il token…'), onSubmit: function (v, current) {
      return act('telegram_token', { token: v }, 'telegram', current);
    } }));
    if (st.editing) out.push(h('button', { class: 'btn ghost', type: 'button', onclick: function () { st.editing = false; render(); } }, [T('Cancel', 'Annulla')]));
    out.push(navButtons('telegram'));
    return out;
  }

  function computerView(st) {
    var c = S.computer || {};
    var mac = S.platform !== 'linux';
    var out = stepHeader('computer', null, T('Prepare this computer', 'Prepara questo computer'), mac ? T('Briglia needs permission to work with your files, and it keeps the Mac awake while it runs.', 'Briglia ha bisogno del permesso per lavorare con i tuoi file, e tiene sveglio il Mac mentre è in funzione.') : T('Briglia runs around the clock, so this computer must not go to sleep by itself.', 'Briglia funziona giorno e notte, quindi questo computer non deve andare in sospensione da solo.'));
    out.push(notice('computer'));
    var items = [];
    if (mac) {
      items.push(h('li', { class: c.fda ? 'ok' : 'bad' }, [h('span', { class: 'ic' }, [c.fda ? svg(CHECK, { width: '3' }) : '!']),
        h('div', {}, [h('div', { class: 't', text: T('Full Disk Access', 'Accesso completo al disco') }), h('div', { class: 'd', text: c.fda ? T('On — Briglia can work with your Documents, Downloads and Desktop.', 'Attivo: Briglia può lavorare con Documenti, Download e Scrivania.') : T('Off — needed so Briglia can work with your files.', 'Disattivo: serve perché Briglia possa lavorare con i tuoi file.') })])]));
    }
    items.push(h('li', { class: c.keep_awake_ok ? 'ok' : 'bad' }, [h('span', { class: 'ic' }, [c.keep_awake_ok ? svg(CHECK, { width: '3' }) : '!']),
      h('div', {}, [h('div', { class: 't', text: T('Stays awake', 'Resta sveglio') }), h('div', { class: 'd', text: c.keep_awake_summary || '' })])]));
    out.push(h('ul', { class: 'checks' }, items));
    if (mac && !c.fda) {
      out.push(h('ol', { class: 'howto' }, [
        h('li', {}, [T('Click ', 'Clicca '), h('b', { text: T('Open System Settings', 'Apri Impostazioni di Sistema') }), T(' below.', ' qui sotto.')]),
        h('li', {}, [T('Turn on ', 'Attiva '), h('b', { text: c.terminal_app || 'Terminal' }), T(' in the list (click + to add it if it’s missing).', ' nell’elenco (clicca + per aggiungerlo se manca).')]),
        h('li', {}, [T('If macOS asks to quit and reopen ' + (c.terminal_app || 'Terminal') + ', do it, then type ', 'Se macOS chiede di chiudere e riaprire ' + (c.terminal_app || 'Terminal') + ', fallo, poi scrivi di nuovo '), h('b', { text: 'briglia menu' }), T(' again. Everything is saved.', '. È tutto salvato.')]),
      ]));
      out.push(h('div', { class: 'actions' }, [h('button', { class: 'btn primary', type: 'button', onclick: function () { act('fda_open', {}, 'computer'); } }, [T('Open System Settings', 'Apri Impostazioni di Sistema')]),
        h('span', { class: 'small', text: T('This page notices by itself when it’s on.', 'Questa pagina se ne accorge da sola quando è attivo.') })]));
    }
    if (!mac && !c.keep_awake_ok) {
      var fixes = [];
      if (c.can_fix_gnome) fixes.push(h('button', { class: 'btn primary', type: 'button', onclick: function () { act('keepawake', { how: 'gnome' }, 'computer'); } }, [T('Turn off automatic suspend', 'Disattiva la sospensione automatica')]));
      if (c.can_mask) fixes.push(h('button', { class: 'btn secondary', type: 'button', onclick: function () { act('keepawake', { how: 'mask' }, 'computer'); } }, [T('Never sleep (asks for your password in the terminal)', 'Mai in sospensione (chiede la password nel terminale)')]));
      fixes.push(h('button', { class: 'btn ghost', type: 'button', onclick: function () { act('recheck', {}, 'computer'); } }, [T('Check again', 'Ricontrolla')]));
      out.push(h('div', { class: 'actions' }, fixes));
    }
    out.push(navButtons('computer'));
    return out;
  }

  function toolsView(st) {
    var t = S.tools || {};
    var mac = S.platform !== 'linux';
    var out = stepHeader('tools', null, T('Document & media tools', 'Strumenti per documenti e media'), T('Briglia uses a few free programs to read and create documents (PDF, Word, Excel, PowerPoint) and to work with audio and video.', 'Briglia usa alcuni programmi gratuiti per leggere e creare documenti (PDF, Word, Excel, PowerPoint) e per lavorare con audio e video.'));
    out.push(notice('tools'));
    if (t.error && !t.installing) out.push(h('div', { class: 'notice bad' }, [t.error]));
    if (t.checking) { out.push(h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), T('Checking what’s installed…', 'Controllo cosa è installato…')])); out.push(navButtons('tools')); return out; }
    if (t.installing) {
      out.push(h('div', { class: 'waiting' }, [h('span', { class: 'spinner' }), t.label || T('Installing…', 'Installazione…')]));
      if (!mac) out.push(h('p', { class: 'small', text: T('If the terminal asks for your password, type it there and press Enter.', 'Se il terminale chiede la password, scrivila lì e premi Invio.') }));
      out.push(h('details', { open: true }, [h('summary', { text: T('Details', 'Dettagli') }), h('div', { class: 'log', text: (t.lines || []).slice(-40).join('\n') })]));
      return out;
    }
    if (t.complete) out.push(savedBox(T('Everything is installed', 'È tutto installato')));
    else {
      out.push(h('ul', { class: 'checks' }, (t.missing || []).map(function (m) {
        return h('li', { class: 'bad' }, [h('span', { class: 'ic', text: '!' }), h('div', {}, [h('div', { class: 't', text: m }), h('div', { class: 'd', text: T('not installed yet', 'non ancora installato') })])]);
      })));
      out.push(h('p', { class: 'small', text: T('Installing takes 10–20 minutes the first time (LibreOffice is large).', 'La prima installazione richiede 10–20 minuti (LibreOffice è grande).') + (mac ? '' : T(' You may be asked for your password in the terminal.', ' Potrebbe esserti chiesta la password nel terminale.')) }));
      if (t.lines && t.lines.length) out.push(h('details', {}, [h('summary', { text: T('Last output', 'Ultimo output') }), h('div', { class: 'log', text: t.lines.slice(-40).join('\n') })]));
      out.push(h('div', { class: 'actions' }, [h('button', { class: 'btn primary', type: 'button', disabled: inflight > 0, onclick: function () { act('tools_install', {}, 'tools'); } }, [T('Install what’s missing', 'Installa ciò che manca')]),
        h('button', { class: 'btn ghost', type: 'button', onclick: function () { act('recheck', {}, 'tools'); } }, [T('Check again', 'Ricontrolla')])]));
    }
    out.push(navButtons('tools'));
    return out;
  }

  // ---------- polling ----------
  function tick() {
    if (gone) return;
    var fast = S && (S.busy || (S.chatgpt && S.chatgpt.login) || (S.telegram && S.telegram.pending && S.telegram.pending.state === 'waiting') ||
      (S.tools && (S.tools.checking || S.tools.installing)) || (view.kind === 'step' && view.step === 'computer'));
    // Don't redraw under the user's typing.
    var typing = document.activeElement && document.activeElement.tagName === 'INPUT';
    if (!typing || fast) refresh();
    setTimeout(tick, fast ? 1500 : 5000);
  }
  refresh().then(function () { setTimeout(tick, 1500); });
})();
