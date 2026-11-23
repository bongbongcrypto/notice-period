/* Reads from the two public test chains through the page's own endpoints, never through the wallet.
   Each endpoint is tried twice before the next one; when all fail the error says which chain.
   scripts/test-rpc.mjs runs this file against endpoints it plays itself (CI). */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  var cfg = NP.config;
  var nextId = 1;
  var lastSent = {};

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  function RpcDown(chain, tried) {
    var e = new Error('Cannot reach ' + cfg.chains[chain].name);
    e.rpcDown = true;
    e.chain = chain;
    e.tried = tried;
    return e;
  }
  function RpcError(err) {
    var e = new Error((err && err.message) || 'RPC error');
    e.rpcError = true;
    e.code = err && err.code;
    e.data = err && err.data;
    return e;
  }

  /* One HTTP POST. Nothing else in the page touches the network for chain data, so a test can swap this one function. */
  function post(url, body) {
    var ctl = new AbortController();
    var timer = setTimeout(function () { ctl.abort(); }, 12000);
    return fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: ctl.signal,
      credentials: 'omit',
      referrerPolicy: 'no-referrer'
    }).then(function (res) {
      clearTimeout(timer);
      if (!res.ok) {
        var e = new Error('HTTP ' + res.status);
        e.http = res.status;
        throw e;
      }
      return res.json();
    }, function (err) { clearTimeout(timer); throw err; });
  }

  /* At least 120 ms between two requests to the same endpoint; polling loops wait a second themselves. */
  function paced(url, body) {
    var now = performance.now();
    var wait = Math.max(0, (lastSent[url] || 0) + 120 - now);
    lastSent[url] = now + wait;
    return (wait ? sleep(wait) : Promise.resolve()).then(function () { return NP.rpc.post(url, body); });
  }

  /* An error the endpoint sent in place of an answer (a rate limit, an overload, a node behind the others) says nothing
     about the chain: the request is treated as failed and the next endpoint is asked. The chain's own refusal, a revert
     or a failed execution, is an answer: it goes back to the caller and is never retried. For a batch, one refused item
     sends the whole batch to the next endpoint. */
  var CHAIN_ANSWER = /revert|out of gas|invalid opcode|vm exception|invalid jump|stack (underflow|overflow)/i;
  function refusal(json) {
    var list = Array.isArray(json) ? json : [json];
    for (var k = 0; k < list.length; k++) {
      var er = list[k] && list[k].error;
      if (er && er.code !== 3 && !CHAIN_ANSWER.test(String(er.message || ''))) return er;
    }
    return null;
  }

  function attempt(chain, body, pick) {
    var eps = cfg.chains[chain].endpoints.filter(pick || function () { return true; });
    var i = 0;
    var tries = 0;
    function next(lastErr) {
      if (i >= eps.length * 2) return Promise.reject(RpcDown(chain, eps.length));
      var ep = eps[Math.floor(i / 2)];
      i += 1;
      tries += 1;
      return paced(ep.url, body).then(function (json) {
        var er = refusal(json);
        if (er) {
          var e = new Error('Refused: ' + (er.message || er.code));
          e.refused = true;
          throw e;
        }
        return { json: json, endpoint: ep };
      }).catch(function (err) {
        if (err && err.rpcError) throw err;
        var backoff = err && err.http === 429 ? 2000 : err && err.refused ? 1000 : 250;
        return sleep(backoff).then(function () { return next(err); });
      });
    }
    return next();
  }

  function call(chain, method, params) {
    var body = { jsonrpc: '2.0', id: nextId++, method: method, params: params || [] };
    return attempt(chain, body).then(function (r) {
      if (r.json && r.json.error) throw RpcError(r.json.error);
      return r.json ? r.json.result : null;
    });
  }

  /* Several calls in one request. Returns results in order; a failed item becomes { error }. */
  function batch(chain, calls) {
    if (!calls.length) return Promise.resolve([]);
    var body = calls.map(function (c) { return { jsonrpc: '2.0', id: nextId++, method: c[0], params: c[1] || [] }; });
    return attempt(chain, body).then(function (r) {
      var arr = Array.isArray(r.json) ? r.json : null;
      if (!arr) throw RpcDown(chain, 1);
      var byId = {};
      arr.forEach(function (x) { byId[x.id] = x; });
      return body.map(function (b) {
        var x = byId[b.id];
        if (!x) return { error: { message: 'missing' } };
        if (x.error) return { error: x.error };
        return x.result;
      });
    });
  }

  function ethCall(chain, to, data, from) {
    var tx = { to: to, data: data };
    if (from) tx.from = from;
    return call(chain, 'eth_call', [tx, 'latest']);
  }

  /* Simulates a write from the visitor's address. Resolves { ok } or { ok: false, data } with the revert data. */
  function simulate(chain, from, to, data) {
    return ethCall(chain, to, data, from).then(function () { return { ok: true }; }, function (err) {
      if (err && err.rpcError) {
        var d = err.data;
        if (d && typeof d === 'object') d = d.data || d.originalError && d.originalError.data;
        return { ok: false, data: typeof d === 'string' ? d : '', message: err.message };
      }
      throw err;
    });
  }

  function hex(n) { return '0x' + BigInt(n).toString(16); }

  /* eth_getLogs over [from, to]. Each endpoint is asked in the windows it accepts: the first one whole if it can,
     the next one only when the first does not answer or answers with an error. An endpoint that would need more
     than 12 windows for the range is not asked at all. When none answers, the error says how many were asked
     (tried) and that it was a log read (logRead), so the page does not claim more endpoints than it tried. */
  function getLogs(chain, filter, from, to) {
    from = Math.max(0, from);
    var span = to - from + 1;
    var eps = cfg.chains[chain].endpoints.filter(function (ep) { return Math.ceil(span / ep.maxRange) <= 12; });
    function down() { var e = RpcDown(chain, eps.length); e.logRead = true; return e; }
    if (!eps.length) return Promise.reject(down());
    var k = 0;
    function windows(ep) {
      var out = [];
      var start = from;
      var only = function (e) { return e === ep; };
      function step() {
        if (start > to) return Promise.resolve(out);
        var end = Math.min(to, start + ep.maxRange - 1);
        var f = { address: filter.address, topics: filter.topics, fromBlock: hex(start), toBlock: hex(end) };
        var body = { jsonrpc: '2.0', id: nextId++, method: 'eth_getLogs', params: [f] };
        return attempt(chain, body, only).then(function (r) {
          if (r.json && r.json.error) throw RpcError(r.json.error);
          out = out.concat(r.json.result || []);
          start = end + 1;
          return step();
        });
      }
      return step();
    }
    function next() {
      if (k >= eps.length) return Promise.reject(down());
      var ep = eps[k++];
      return windows(ep).catch(function (err) {
        if (err && (err.rpcDown || err.rpcError)) return next();
        throw err;
      });
    }
    return next();
  }

  function head(chain) {
    return call(chain, 'eth_getBlockByNumber', ['latest', false]).then(function (b) {
      return { number: Number(BigInt(b.number)), ts: Number(BigInt(b.timestamp)) };
    });
  }
  function blockTs(chain, numberHex) {
    return call(chain, 'eth_getBlockByNumber', [numberHex, false]).then(function (b) {
      return b ? Number(BigInt(b.timestamp)) : null;
    });
  }
  function receipt(chain, hash) { return call(chain, 'eth_getTransactionReceipt', [hash]); }
  function balance(chain, address) {
    return call(chain, 'eth_getBalance', [address, 'latest']).then(function (r) { return BigInt(r); });
  }

  NP.rpc = {
    post: post, call: call, batch: batch, ethCall: ethCall, simulate: simulate, getLogs: getLogs,
    head: head, blockTs: blockTs, receipt: receipt, balance: balance, hex: hex, sleep: sleep
  };
}());
