/* Rendering. Text goes in with textContent only; positions on the time strip are set through the CSS object model. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  var cfg = NP.config;
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    return n;
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }
  function pad2(n) { return String(n).padStart(2, '0'); }

  var fmt = {
    short: function (h) { h = String(h || ''); return h.length > 12 ? h.slice(0, 6) + '…' + h.slice(-4) : h; },
    time: function (ts) { var d = new Date(ts * 1000); return pad2(d.getUTCHours()) + ':' + pad2(d.getUTCMinutes()) + ':' + pad2(d.getUTCSeconds()); },
    date: function (ts) { var d = new Date(ts * 1000); return d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCFullYear(); },
    isoDate: function (iso) { var d = new Date(iso); return isNaN(d) ? '' : fmt.date(d.getTime() / 1000); },
    /* differences of block timestamps; the two chains' clocks differ by about a second, so negatives read 0 */
    sec: function (a, b) { return Math.max(0, Math.round(a - b)); },
    usd: function (n) {
      if (n >= 1e9) return '$' + (n / 1e9).toFixed(1) + 'B';
      if (n >= 1e6) return '$' + (n / 1e6).toFixed(1) + 'M';
      if (n >= 1e3) return '$' + (n / 1e3).toFixed(1) + 'K';
      return '$' + Math.round(n);
    },
    /* BigInt base units to a short decimal string */
    units: function (v, decimals, places) {
      v = BigInt(v);
      var base = 10n ** BigInt(decimals);
      var whole = v / base;
      var frac = (v % base).toString().padStart(decimals, '0').slice(0, places === undefined ? 2 : places).replace(/0+$/, '');
      return whole.toString() + (frac ? '.' + frac : '');
    },
    age: function (seconds) {
      if (seconds < 90) return Math.max(1, Math.round(seconds)) + ' s';
      if (seconds < 5400) return Math.round(seconds / 60) + ' min';
      if (seconds < 129600) return Math.round(seconds / 3600) + ' h';
      var days = Math.floor(seconds / 86400);
      return days + (days === 1 ? ' day' : ' days');
    },
    plural: function (n, one, many) { return n === 1 ? one : many; }
  };

  function txLink(chain, hash, label) {
    var a = el('a', 'hash', fmt.short(hash));
    a.href = cfg.chains[chain].txUrl + hash;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.title = (label ? label + ', ' : '') + 'transaction on ' + cfg.chains[chain].name;
    return a;
  }

  /* "{name}" becomes a text value, "{tx.base.name}" a transaction link. Unknown names print nothing. */
  function fill(template, ctx) {
    var frag = document.createDocumentFragment();
    String(template).split(/(\{[^}]+\})/).forEach(function (part) {
      var m = /^\{([^}]+)\}$/.exec(part);
      if (!m) { if (part) frag.appendChild(document.createTextNode(part)); return; }
      var key = m[1];
      var tx = /^tx\.(base|lasna)\.(\w+)$/.exec(key);
      if (tx) {
        if (ctx[tx[2]]) frag.appendChild(txLink(tx[1], ctx[tx[2]]));
        return;
      }
      var v = ctx[key];
      frag.appendChild(document.createTextNode(v === undefined || v === null ? '' : String(v)));
    });
    return frag;
  }
  function fillText(template, ctx) { return fill(template, ctx).textContent; }

  /* ---------- time strip ---------- */

  function makeStrip() {
    var root = el('div', 'strip');
    var full = el('div', 'axis axis-full');
    full.setAttribute('aria-hidden', 'true');
    ['ax', 'tick t-sched', 'tick t-back', 'tick t-end', 'tick t-now'].forEach(function (c) { full.appendChild(el('span', c)); });
    [['l-sched', 'Change scheduled '], ['l-back', 'Deposit back '], ['l-left', ''], ['l-end', 'Change can take effect ']].forEach(function (p) {
      var s = el('span', 'lab ' + p[0], p[1]);
      s.appendChild(el('b', 'num'));
      if (p[0] === 'l-left') s.appendChild(document.createTextNode(' of notice left'));
      full.appendChild(s);
    });
    root.appendChild(full);
    var zoom = el('div', 'zoom');
    zoom.setAttribute('aria-hidden', 'true');
    zoom.appendChild(el('p', 'zoom-cap'));
    var za = el('div', 'axis axis-zoom');
    ['ax', 'tick t-sched', 'tick t-react', 'tick t-back', 'scale s0 num', 'scale s1 num'].forEach(function (c) { za.appendChild(el('span', c)); });
    zoom.appendChild(za);
    root.appendChild(zoom);
    var recs = el('div', 'records');
    recs.appendChild(makeLedger());
    root.appendChild(recs);
    return root;
  }

  /* model: { t1, t2, t3, execAt, stage (0 to 3 records shown), elapsed (seconds since record 1, while waiting) }
     The second row magnifies the seconds around the exit: from 0 in a "leave now" run, from just before Reactive's
     transaction in a "wait for the deadline" run, where the exit comes about a minute in. */
  function drawStrip(root, m) {
    var period = Math.max(1, (m.execAt || 0) - (m.t1 || 0)) || 180;
    var back = m.t3 ? fmt.sec(m.t3, m.t1) : null;
    var react = m.t2 ? fmt.sec(m.t2, m.t1) : null;
    var stage = m.stage === undefined ? 3 : m.stage;
    root.setAttribute('data-stage', String(stage));
    var q = function (s) { return root.querySelector(s); };
    var pct = function (sec, span) { return Math.max(0, Math.min(100, (sec / span) * 100)).toFixed(3) + '%'; };
    var full = q('.axis-full');
    var waiting = stage >= 1 && stage < 3 && typeof m.elapsed === 'number';
    q('.axis-full .t-now').hidden = !waiting;
    if (waiting) q('.axis-full .t-now').style.setProperty('--pos', pct(Math.min(m.elapsed, period), period));
    if (m.t1) q('.l-sched b').textContent = fmt.time(m.t1) + ' UTC';
    if (m.execAt) q('.l-end b').textContent = fmt.time(m.execAt) + ' UTC';
    if (back !== null) {
      q('.axis-full .t-back').style.setProperty('--pos', pct(back, period));
      full.style.setProperty('--pos', pct(back, period));
      q('.l-back b').textContent = '+' + back + ' s';
      q('.l-left b').textContent = Math.max(0, m.execAt - m.t3) + ' s';
      full.classList.toggle('late', back / period > 0.6);
      full.classList.toggle('mid', back / period > 0.25);
    }
    var known = back !== null ? back : (waiting ? m.elapsed : 2);
    var z0 = react !== null && react > 5 ? react - 2 : 0;
    var span = Math.max(5, Math.ceil((known - z0) * 1.5));
    q('.zoom-cap').textContent = z0 ? 'Seconds ' + z0 + ' to ' + (z0 + span) + ' after the change, magnified' : 'The first ' + span + ' seconds, magnified';
    q('.axis-zoom .s0').textContent = z0 + ' s';
    q('.axis-zoom .s1').textContent = (z0 + span) + ' s';
    q('.axis-zoom').classList.toggle('from-later', z0 > 0);
    if (react !== null) q('.axis-zoom .t-react').style.setProperty('--pos', pct(react - z0, span));
    if (back !== null) q('.axis-zoom .t-back').style.setProperty('--pos', pct(back - z0, span));
  }

  function ledgerRow(cls, what) {
    var tr = el('tr', 'rec rec-' + cls);
    var th = el('th');
    th.scope = 'row';
    var mark = el('span', 'mark');
    mark.setAttribute('aria-hidden', 'true');
    th.appendChild(mark);
    th.appendChild(document.createTextNode(what));
    tr.appendChild(th);
    ['chain', 'num time', 'num sec', 'tx'].forEach(function (c) { tr.appendChild(el('td', c)); });
    return tr;
  }

  function makeLedger() {
    var t = el('table', 'ledger');
    var cap = el('caption', 'vh', 'The three records of this run');
    t.appendChild(cap);
    var head = el('thead', 'vh');
    var hr = el('tr');
    ['Record', 'Chain', 'UTC time', 'After the change', 'Transaction'].forEach(function (h) {
      var th = el('th', null, h);
      th.scope = 'col';
      hr.appendChild(th);
    });
    head.appendChild(hr);
    t.appendChild(head);
    var b = el('tbody');
    b.appendChild(ledgerRow('sched', NP.copy.rec1));
    b.appendChild(ledgerRow('react', NP.copy.rec2));
    b.appendChild(ledgerRow('back', 'Deposit back in the depositor’s wallet'));
    t.appendChild(b);
    return t;
  }

  /* model: { t1, t2, t3, h1, h2, h3, stage, own (the visitor's own run: wording changes), wait2 and wait3 (waiting
     texts of a "wait for the deadline" replay), r2Missing (the exit landed while Reactive Lasna could not be read) } */
  function drawLedger(tbody, m) {
    var rows = tbody.querySelectorAll('tr');
    var stage = m.stage === undefined ? 3 : m.stage;
    var recs = [
      { chain: 'base', ts: m.t1, hash: m.h1, wait: 'waiting' },
      { chain: 'lasna', ts: m.t2, hash: m.h2, wait: m.r2Missing ? NP.copy.rec2Missing : (m.wait2 || NP.copy.rec2Wait) },
      { chain: 'base', ts: m.t3, hash: m.h3, wait: m.wait3 || NP.copy.rec3Wait }
    ];
    recs.forEach(function (r, i) {
      var tr = rows[i];
      if (!tr) return;
      var shown = stage > i && r.ts && r.hash;
      tr.classList.toggle('is-waiting', !shown);
      var cells = tr.querySelectorAll('td');
      cells[0].textContent = cfg.chains[r.chain].name;
      cells[1].textContent = shown ? fmt.time(r.ts) : '';
      cells[2].textContent = shown ? '+' + fmt.sec(r.ts, m.t1) + ' s' : '';
      clear(cells[3]);
      if (shown) cells[3].appendChild(txLink(r.chain, r.hash, tr.querySelector('th').textContent));
      else cells[3].appendChild(el('span', 'quiet', stage >= 1 || i === 0 ? r.wait : ''));
    });
    if (m.own) rows[2].querySelector('th').lastChild.textContent = 'Deposit back in your wallet';
  }

  /* ---------- first screen ---------- */

  function setBusy(node, on) { if (node) node.classList.toggle('sk', !!on); }

  function retryButton(id, label, handler) {
    var old = $(id);
    if (old) old.remove();
    var b = el('button', 'btn btn-quiet', label || 'Try again');
    b.type = 'button';
    b.id = id;
    b.addEventListener('click', function () { b.disabled = true; handler(); });
    return b;
  }

  function problemLoading() {
    setBusy($('problem-src'), true);
    $('problem-src').textContent = 'Reading the live count from Morpho’s public API…';
  }
  function problem(d) {
    var p = $('problem');
    var src = $('problem-src');
    setBusy(src, false);
    var kindWord = { 'cap increase': ['cap increase', 'cap increases'], 'shorter waiting period': ['shorter waiting period', 'shorter waiting periods'],
      'new adapter': ['new adapter', 'new adapters'], 'new allocator': ['new allocator', 'new allocators'], 'other': ['other', 'other'] };
    if (d.n === 0) {
      p.textContent = 'No rule change is waiting in any listed Morpho vault right now.';
    } else {
      var watched = d.k === 0 ? 'None of them is a kind this tool would exit on by default.'
        : d.k + fmt.plural(d.k, ' of them is', ' of them are') + ' a kind this tool would exit on by default.';
      p.textContent = d.n + fmt.plural(d.n, ' rule change is', ' rule changes are') + ' waiting in ' + d.v +
        fmt.plural(d.v, ' Morpho vault', ' Morpho vaults') + ' holding ' + fmt.usd(d.usd) + ' right now. ' + watched;
    }
    var parts = Object.keys(d.byKind).filter(function (k) { return d.byKind[k] > 0; }).map(function (k) {
      return d.byKind[k] + ' ' + (kindWord[k] || [k, k])[d.byKind[k] === 1 ? 0 : 1];
    });
    src.textContent = 'Morpho’s public API, ' + fmt.date(d.at) + ', ' + fmt.time(d.at).slice(0, 5) + ' UTC' +
      (parts.length ? ': ' + parts.join(', ') : '') + '. ' + NP.copy.notMorpho;
  }
  function problemFailed(retry) {
    var s = cfg.morpho.snapshot;
    var src = $('problem-src');
    setBusy(src, false);
    $('problem').textContent = 'On ' + s.date + ': ' + s.changes + ' changes waiting in ' + s.vaults + ' vaults holding ' + fmt.usd(s.usd) +
      '; ' + s.capIncreases + ' cap increases, ' + s.shorter + ' shorter waiting periods. The live count is unavailable right now.';
    src.textContent = 'Morpho’s public API did not answer. ' + NP.copy.notMorpho + ' ';
    src.appendChild(retryButton('problem-retry', 'Try again', retry));
  }

  /* The run on the first screen: the latest "leave now" run, or the run a #run=N address names (linked). */
  function latest(run, state, retry, linked) {
    var cap = $('latest-cap');
    var check = $('latest-check');
    if (run) {
      var ours = !run.owner || run.owner.toLowerCase() === cfg.operator.toLowerCase();
      var where = ours ? 'on our own demo vault' : 'by a visitor on a demo vault';
      var mode = run.mode === 1 ? '“wait for the deadline”' : '“leave now”';
      cap.textContent = (linked ? 'Run #' + run.id + ' on testnet, ' + mode + ' mode, ' + where + ', ' : 'Latest ' + mode + ' run on testnet, ' + where + ', ') +
        fmt.date(run.r1.ts) + ': deposit back ' + fmt.sec(run.r3.ts, run.r1.ts) + ' s after the change was scheduled.';
      drawStrip($('strip-first'), { t1: run.r1.ts, t2: run.r2.ts, t3: run.r3.ts, execAt: run.execAt, stage: 3 });
      drawLedger($('ledger-first'), { t1: run.r1.ts, t2: run.r2.ts, t3: run.r3.ts, h1: run.r1.hash, h2: run.r2.hash, h3: run.r3.hash, stage: 3 });
      $('strip-alt').textContent = 'Run #' + run.id + '. Change scheduled at ' + fmt.time(run.r1.ts) + ' UTC. Deposit back ' +
        fmt.sec(run.r3.ts, run.r1.ts) + ' seconds later. The change could take effect at ' + fmt.time(run.execAt) + ' UTC, ' +
        Math.max(0, run.execAt - run.r3.ts) + ' seconds after the deposit was back.';
    }
    setBusy(check, state === 'loading');
    clear(check);
    if (state === 'loading') check.textContent = 'Recorded copy. ' + NP.copy.checking;
    else if (state === 'ok') check.textContent = 'Re-read from both chains at ' + fmt.time(Date.now() / 1000) + ' UTC: three receipts and their block times.';
    else {
      check.textContent = fillText(NP.copy.checkFail, { date: fmt.isoDate(NP.recorded.readAt) }) + ' ';
      if (retry) check.appendChild(retryButton('latest-retry', 'Try again', retry));
    }
  }

  function proof(d) {
    /* Test traffic is called test traffic, on the same line as the count. */
    var who = '';
    if (d.runs > 0 && d.ours === d.runs) who = d.runs === 1 ? ', our own test' : (d.runs === 2 ? ', both our own tests' : ', all our own tests');
    else if (d.runs > 0 && d.ours + d.visitors === d.runs) who = ': ' + d.visitors + ' by ' + fmt.plural(d.visitors, 'a visitor', 'visitors') + ', ' + d.ours + ' our own ' + fmt.plural(d.ours, 'test', 'tests');
    else if (d.ours > 0) who = ', ' + d.ours + ' of them our own ' + fmt.plural(d.ours, 'test', 'tests');
    var txt = d.runs + fmt.plural(d.runs, ' run so far', ' runs so far') + who + '. ' + d.returned +
      fmt.plural(d.returned, ' deposit returned.', ' deposits returned.');
    if (d.nowTimes.length >= cfg.timing.medianFromRuns) {
      var s = d.nowTimes.slice().sort(function (a, b) { return a - b; });
      var mid = s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
      txt += ' “Leave now” runs: median ' + mid + ' s over ' + s.length + ' runs.';
    } else if (d.nowTimes.length) {
      txt += ' “Leave now” runs: latest ' + d.nowTimes[0] + ' s.';
    }
    if (d.unlisted > 0) txt += ' ' + d.unlisted + fmt.plural(d.unlisted, ' run is', ' runs are') + ' older than this page can list.';
    $('proof').textContent = txt;
  }

  function healthLoading() { setBusy($('health'), true); }
  function health(d, retry) {
    var h = $('health');
    setBusy(h, false);
    clear(h);
    if (!d) {
      h.textContent = 'Could not read the run count and the float right now. ';
      if (retry) h.appendChild(retryButton('health-retry', 'Try again', retry));
      return;
    }
    var txt = 'Live now: ' + d.left + ' of ' + d.cap + ' runs left today. Float ' + d.float + ' lREACT. ';
    if (d.lastAge !== null && d.lastAge <= 26 * 3600) txt += 'Our last \u201cleave now\u201d test run was ' + fmt.age(d.lastAge) + ' ago, deposit back in ' + d.lastSec + ' s.';
    else if (d.lastAge !== null) txt += 'Our latest \u201cleave now\u201d test run was ' + fmt.age(d.lastAge) + ' ago (' + fmt.date(d.lastTs) + '), deposit back in ' + d.lastSec + ' s.';
    else txt += 'No \u201cleave now\u201d test run of ours is on record yet.';
    h.textContent = txt;
  }

  var OUTCOME = { 1: 'Nothing to redeem', 3: 'Vault refused the redeem' };
  var STATUS = { 0: 'not found', 1: 'still on', 2: 'turned off by its owner', 3: 'ended', 4: 'expired' };

  function runRow(r) {
    var tr = el('tr');
    var th = el('th', 'num');
    th.scope = 'row';
    var a = el('a', null, '#' + r.id);
    a.href = '#run=' + r.id;
    th.appendChild(a);
    tr.appendChild(th);
    function td(cls, label, text) { var c = el('td', cls, text); c.setAttribute('data-l', label); tr.appendChild(c); return c; }
    var who = r.owner ? (r.owner.toLowerCase() === cfg.operator.toLowerCase() ? 'Our own test run' : 'Visitor') : '';
    if (!r.r1) {
      td('num', 'When (UTC)', r.armedAt ? fmt.date(r.armedAt) + ' ' + fmt.time(r.armedAt) : '');
      td('', 'Who', who);
      var c = td('quiet', 'Change', 'Watch ' + (STATUS[r.status] || 'unknown') + '. Its transactions are not in this list.');
      c.colSpan = 5;
      return tr;
    }
    td('num', 'When (UTC)', fmt.date(r.r1.ts) + ' ' + fmt.time(r.r1.ts));
    td('', 'Who', who);
    var kind = cfg.kinds.filter(function (k) { return (k.selectors || []).indexOf(r.selector) >= 0; })[0];
    var ch = td('', 'Change', (kind ? kind.short : r.selector) + ' ');
    ch.appendChild(el('span', 'quiet', r.mode === 1 ? '(wait for the deadline)' : '(leave now)'));
    var seen = td('num', 'Reactive transaction', r.r2 ? '+' + fmt.sec(r.r2.ts, r.r1.ts) + ' s' : 'not seen');
    if (r.r2 && r.mode === 1) { seen.appendChild(document.createTextNode(' ')); seen.appendChild(el('span', 'quiet', '(timer)')); }
    var ok = r.r3 && r.r3.outcome === 0;
    td('num back', 'Deposit back', ok ? '+' + fmt.sec(r.r3.ts, r.r1.ts) + ' s' : (r.r3 ? OUTCOME[r.r3.outcome] || 'Not returned' : 'Not delivered'));
    td('num', 'Notice left', ok ? Math.max(0, r.execAt - r.r3.ts) + ' s' : '');
    var tx = td('tx', 'Transactions', '');
    [['base', r.r1, 'change scheduled'], ['lasna', r.r2, 'reactive transaction'], ['base', r.r3, 'withdrawal']].forEach(function (p) {
      if (!p[1]) return;
      tx.appendChild(txLink(p[0], p[1].hash, 'Run ' + r.id + ', ' + p[2]));
      tx.appendChild(document.createTextNode(' '));
    });
    return tr;
  }

  function runs(list, state, retry) {
    var body = $('runs-body');
    var cap = $('runs-cap');
    var date = fmt.isoDate(NP.recorded.readAt);
    setBusy(cap, state === 'loading');
    clear(cap);
    if (state === 'loading') { cap.textContent = 'Recorded list read ' + date + '. Reading the last 27 hours from the chain…'; return; }
    clear(body);
    list.forEach(function (r) { body.appendChild(runRow(r)); });
    if (state === 'ok') cap.textContent = 'Live from the chain, plus the recorded list read ' + date + '.';
    else {
      cap.textContent = 'Recorded list read ' + date + '. Live read failed. ';
      if (retry) cap.appendChild(retryButton('runs-retry', 'Try again', retry));
    }
  }

  /* ---------- guided run ---------- */

  var panelStrip = null;
  var panelLedger = null;
  var handler = function () {};
  var lastAnnounced = '';

  function announce(text) {
    if (!text || text === lastAnnounced) return;
    lastAnnounced = text;
    $('live').textContent = text;
  }

  function rail(step, started) {
    var items = $('rail').querySelectorAll('li');
    for (var i = 0; i < items.length; i++) {
      var n = i + 1;
      items[i].classList.toggle('is-now', step === n);
      items[i].classList.toggle('is-done', started && step !== null && step > n);
      if (step === n) items[i].setAttribute('aria-current', 'step'); else items[i].removeAttribute('aria-current');
      items[i].querySelector('.vh').textContent = step === n ? ' (current step)' : (started && step > n ? ' (done)' : '');
    }
  }

  function actionNode(spec, ctx) {
    var label = fillText(spec.label, ctx);
    var cls = 'btn ' + (spec.primary ? 'btn-primary' : (spec.quiet ? 'btn-quiet' : 'btn-second'));
    if (spec.href) {
      var a = el('a', cls, label);
      var href = spec.href;
      if (href === 'faucets') href = cfg.links.faucets;
      else if (href === 'contracts') href = cfg.links.contracts;
      else if (href === 'self') href = String(window.location.href).split('#')[0];
      else if (href === 'exit') href = cfg.chains.base.addressUrl + cfg.contracts.exit;
      else if (href === 'tx') href = cfg.chains.base.txUrl + (ctx.tx || '');
      a.href = href;
      if (href.charAt(0) !== '#') { a.target = '_blank'; a.rel = 'noopener noreferrer'; }
      return a;
    }
    var b = el('button', cls, label);
    b.type = 'button';
    b.setAttribute('data-a', spec.a);
    if (spec.off) b.disabled = true;
    b.addEventListener('click', function () {
      if (b.disabled) return;
      var all = $('state').querySelectorAll('button');
      for (var i = 0; i < all.length; i++) all[i].disabled = true;
      handler(spec.a, ctx, b);
    });
    return b;
  }

  function linesNode(lines) {
    var ol = el('ol', 'lines');
    var n = lines.filter(function (l) { return l.status !== 'have' && l.status !== 'skip'; }).length;
    var i = 0;
    lines.forEach(function (l) {
      var li = el('li', 'line is-' + l.status);
      var counted = l.status !== 'have' && l.status !== 'skip';
      if (counted) i += 1;
      li.appendChild(el('span', 'num line-n', counted ? i + ' of ' + n : ''));
      li.appendChild(el('span', 'line-what', l.label));
      var st = el('span', 'line-st', NP.copy.lineStatus[l.status] || l.status);
      if (l.status === 'sent' || (l.status === 'done' && l.hash)) {
        st.appendChild(document.createTextNode(' '));
        st.appendChild(txLink('base', l.hash, l.label));
      }
      li.appendChild(st);
      ol.appendChild(li);
    });
    return ol;
  }

  function ruleNode(ctx) {
    var fs = el('fieldset', 'rule');
    fs.appendChild(el('legend', null, NP.copy.ruleHeading));
    cfg.kinds.forEach(function (k) {
      var lab = el('label', 'check');
      var box = el('input');
      box.type = 'checkbox';
      box.checked = (ctx.kinds & k.bit) !== 0;
      box.setAttribute('data-bit', String(k.bit));
      box.addEventListener('change', function () { handler('kinds', { bit: k.bit, on: box.checked }); });
      lab.appendChild(box);
      lab.appendChild(el('span', null, k.label));
      fs.appendChild(lab);
    });
    var p = el('p', 'small', ctx.pendingLine || '');
    p.id = 'pending-line';
    fs.appendChild(p);
    var warn = el('p', 'small warn', '');
    warn.id = 'kinds-warn';
    fs.appendChild(warn);
    return fs;
  }

  function state(id, ctx) {
    var def = NP.states[id];
    var box = $('state');
    var hadFocus = box.contains(document.activeElement);
    ctx = ctx || {};
    clear(box);
    box.setAttribute('data-state', id);
    box.className = 'state kind-' + def.kind;
    $('intro').hidden = !(def.step === 0 || id === 'checking' && !ctx.started);
    rail(def.step === 0 ? null : (def.step || ctx.step || null), !!ctx.started || (def.step || 0) > 0);

    var head = null;
    if (def.h) {
      head = el('h3', 'state-h', fillText(def.h, ctx));
      head.tabIndex = -1;
      box.appendChild(head);
    }
    def.body.forEach(function (line) {
      if (typeof line === 'object') { if (!ctx[line.when]) return; line = line.t; }
      var txt = fillText(line, ctx);
      if (!txt.trim()) return;
      var p = el('p');
      p.appendChild(fill(line, ctx));
      box.appendChild(p);
    });
    if (def.copy && ctx[def.copy]) {
      var cb = el('button', 'btn btn-quiet', 'Copy address');
      cb.type = 'button';
      cb.addEventListener('click', function () { handler('copy-text', { text: ctx[def.copy], button: cb }); });
      box.appendChild(cb);
    }
    if (def.wallets && ctx.wallets) {
      var list = el('div', 'wallets');
      ctx.wallets.forEach(function (w) {
        var b = el('button', 'btn btn-second wallet');
        b.type = 'button';
        if (w.icon) { var im = el('img'); im.src = w.icon; im.alt = ''; im.width = 20; im.height = 20; b.appendChild(im); }
        b.appendChild(el('span', null, w.name));
        b.addEventListener('click', function () { handler('pick-wallet', { id: w.id }); });
        list.appendChild(b);
      });
      box.appendChild(list);
    }
    if (def.lines && ctx.lines) box.appendChild(linesNode(ctx.lines));
    if (ctx.note) box.appendChild(el('p', 'small', ctx.note));
    if (def.rule) box.appendChild(ruleNode(ctx));
    if (def.curator) {
      box.appendChild(el('p', null, NP.copy.curatorIntro));
      box.appendChild(el('p', null, fillText(NP.copy.curatorTimelock, ctx)));
    }
    if (def.cols) {
      var cols = el('div', 'cols');
      def.cols.forEach(function (c) { var d = el('p', 'col'); d.appendChild(fill(c, ctx)); cols.appendChild(d); });
      box.appendChild(cols);
    }
    if (def.strip && ctx.model) {
      if (!panelStrip) { panelStrip = makeStrip(); panelLedger = panelStrip.querySelector('.ledger'); }
      drawStrip(panelStrip, ctx.model);
      drawLedger(panelLedger.querySelector('tbody'), ctx.model);
      box.appendChild(panelStrip);
      if (ctx.refLine) box.appendChild(el('p', 'small', ctx.refLine));
    }
    (def.after || []).forEach(function (line) {
      var unknown = (line.match(/\{(\w+)\}/g) || []).some(function (k) { var v = ctx[k.slice(1, -1)]; return v === undefined || v === null; });
      if (!unknown) box.appendChild(el('p', 'small', fillText(line, ctx)));
    });
    if (def.tech && ctx.name) box.appendChild(el('p', 'small tech', fillText(def.tech, ctx)));
    if (ctx.notice && NP.notices[ctx.notice]) {
      var nt = el('div', 'notice');
      nt.appendChild(el('strong', null, NP.notices[ctx.notice].h + '. '));
      nt.appendChild(document.createTextNode(NP.notices[ctx.notice].body + ' '));
      if (ctx.tx) nt.appendChild(txLink('base', ctx.tx, 'View transaction'));
      box.appendChild(nt);
    }
    var acts = (typeof def.actions === 'function' ? def.actions(ctx) : def.actions).filter(function (s) { return !s.when || ctx[s.when]; });
    if (acts.length) {
      var row = el('div', 'actions');
      acts.forEach(function (s) { row.appendChild(actionNode(s, ctx)); });
      box.appendChild(row);
    }
    if (def.curator) NP.curatorHints(ctx).forEach(function (line) { box.appendChild(el('p', 'small hint', line)); });
    if (def.kind === 'wait' && !def.strip) box.appendChild(el('p', 'small waiting', ctx.waitText || 'Waiting. No button to press right now.'));

    announce(head ? head.textContent : 'Run it yourself');
    if (hadFocus) {
      var target = box.querySelector('.btn-primary:not([disabled])') || head || box;
      try { target.focus({ preventScroll: true }); } catch (e) { target.focus(); }
    }
  }

  /* Updates the strip and ledger of the current state without rebuilding it (the seconds counter). */
  function tickStrip(model) {
    if (!panelStrip) return;
    drawStrip(panelStrip, model);
    drawLedger(panelLedger.querySelector('tbody'), model);
  }
  function setHeadline(text) {
    var h = $('state').querySelector('.state-h');
    if (h) h.textContent = text;
  }
  function setPendingLine(text) { var p = $('pending-line'); if (p) p.textContent = text; }
  function setKindsWarn(text) {
    var p = $('kinds-warn');
    if (p) p.textContent = text;
    var b = $('state').querySelector('[data-a="arm"]');
    if (b) b.disabled = !!text;
  }
  function enableActions() {
    var all = $('state').querySelectorAll('.actions button');
    for (var i = 0; i < all.length; i++) all[i].disabled = false;
  }

  function ctaOrder(noWallet) {
    var box = $('cta');
    var tryB = $('cta-try');
    var rep = $('cta-replay');
    if (noWallet) {
      box.insertBefore(rep, tryB);
      rep.className = 'btn btn-primary';
      tryB.className = 'btn btn-second';
    } else {
      box.insertBefore(tryB, rep);
      tryB.className = 'btn btn-primary';
      rep.className = 'btn btn-second';
    }
  }

  NP.view = {
    $: $, el: el, fmt: fmt, fill: fill, fillText: fillText, txLink: txLink,
    makeStrip: makeStrip, drawStrip: drawStrip, makeLedger: makeLedger, drawLedger: drawLedger,
    problemLoading: problemLoading, problem: problem, problemFailed: problemFailed,
    latest: latest, proof: proof, health: health, healthLoading: healthLoading, runs: runs,
    state: state, tickStrip: tickStrip, setHeadline: setHeadline, setPendingLine: setPendingLine, setKindsWarn: setKindsWarn,
    enableActions: enableActions, announce: announce, ctaOrder: ctaOrder,
    onAction: function (f) { handler = f; },
    STATUS: STATUS
  };
}());
