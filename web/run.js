/* The guided run: a state machine driven by chain reads and wallet answers, never by a guess.
   The step is recomputed from the chain (lastVaultOf, balances, activeWatchOf, watchOf), so a reload resumes.
   The page keeps nothing in browser storage. */
(function () {
  'use strict';
  var NP = window.NP;
  var cfg = NP.config, sig = NP.sig, abi = NP.abi, rpc = NP.rpc, wallet = NP.wallet, view = NP.view, copy = NP.copy;
  var enc = abi.enc, dec = abi.dec, fmt = view.fmt;
  var C = cfg.contracts, T = cfg.timing, EV = sig.ev;
  var BASE = cfg.chains.base;
  var DEP = BigInt(cfg.amounts.deposit);
  var ZERO = '0x' + '0'.repeat(40);

  var S = { epoch: 0, id: 'idle', ctx: {}, me: null, kinds: 7, step: null, started: false, last: null, shared: {}, run: {},
    lines: null, flowState: null, pos: null, timelock: 180, processedHash: null, replayIndex: 0, linked: null };
  var data = { runs: [], next: null, ready: null, baseTs: null, float: null, liveOk: null };
  var framed = false;
  try { framed = window.top !== window.self; } catch (e) { framed = true; }

  cfg.kinds[0].selectors = [sig.fn['addAdapter(address)']];
  cfg.kinds[1].selectors = [sig.fn['decreaseTimelock(bytes4,uint256)']];
  cfg.kinds[2].selectors = [sig.fn['setIsAllocator(address,bool)']];
  cfg.kinds[3].selectors = [sig.fn['increaseAbsoluteCap(bytes,uint256)'], sig.fn['increaseRelativeCap(bytes,uint256)']];

  function topicN(n) { return '0x' + abi.word(n); }
  function topicA(a) { return '0x' + abi.addrWord(a); }
  function same(a, b) { return String(a || '').toLowerCase() === String(b || '').toLowerCase(); }
  function units(v) { return fmt.units(v, cfg.token.decimals, 2); }
  function ether(v, places) { return fmt.units(v, 18, places === undefined ? 4 : places); }
  function now() { return performance.now(); }

  function stop(id, ctx) { var e = new Error(id); e.flow = id; e.ctx = ctx || {}; return e; }
  function rpcFail(e) { return !!(e && (e.rpcDown || e.rpcError)); }
  function rpcCtx(chain) {
    var n = cfg.chains[chain].endpoints.length;
    return { chain: cfg.chains[chain].name, tried: n === 1 ? 'its one public endpoint' : 'both public endpoints' };
  }
  function alive(my) { if (my !== S.epoch) { var e = new Error('cancelled'); e.cancelled = true; throw e; } }

  function go(id, extra) {
    var def = NP.states[id];
    if (def.step) { S.step = def.step; S.started = true; }
    var ctx = Object.assign({ kinds: S.kinds, step: S.step, started: S.started, min: Math.round(S.timelock / 60) }, S.shared, extra || {});
    ctx.noDeposit = !ctx.hasDeposit;
    S.id = id;
    S.ctx = ctx;
    console.info('[notice-period] state:', id);
    view.state(id, ctx);
  }

  function runFlow(fn, remember) {
    var my = ++S.epoch;
    if (remember !== false) S.last = fn;
    return Promise.resolve().then(function () { return fn(my); }).catch(function (e) {
      if (my !== S.epoch || (e && e.cancelled)) return;
      if (e && e.flow) return go(e.flow, e.ctx);
      if (e && e.rpcDown) return go('rpc-down', rpcCtx(e.chain));
      console.error('[notice-period]', e);
      if (e && e.wallet) return go('wallet-error', { message: e.message });
      go('page-error', { message: String((e && e.message) || 'Unexpected error').slice(0, 200) });
    });
  }

  /* ---------- chain reads ---------- */

  function multi(chain, list) {
    return rpc.batch(chain, list.map(function (c) {
      return c.method ? [c.method, c.params] : ['eth_call', [{ to: c.to, data: c.data }, 'latest']];
    })).then(function (res) {
      res.forEach(function (r) {
        if (r && r.error) { var e = new Error(r.error.message || 'RPC error'); e.rpcError = true; throw e; }
      });
      return res;
    });
  }

  function readFloat() {
    return Promise.all([
      multi('lasna', [
        { method: 'eth_getBalance', params: [C.reactive, 'latest'] },
        { to: C.system, data: enc.oneAddr('debt(address)', C.reactive) },
        { to: C.reactive, data: enc.noArg('activeWatches()') },
        { to: C.reactive, data: enc.noArg('MAX_ACTIVE()') }
      ]),
      multi('base', [
        { method: 'eth_getBalance', params: [C.exit, 'latest'] },
        { to: C.callbackProxy, data: enc.oneAddr('debt(address)', C.exit) }
      ])
    ]).then(function (r) {
      var f = { float: BigInt(r[0][0]), debtL: BigInt(r[0][1]), active: Number(BigInt(r[0][2])), maxActive: Number(BigInt(r[0][3])),
        reserve: BigInt(r[1][0]), debtB: BigInt(r[1][1]) };
      data.float = f;
      S.shared.x = ether(f.float, 2);
      S.shared.y = ether(f.reserve, 4);
      /* two debts in two currencies: never added up */
      S.shared.dL = ether(f.debtL, 4) + ' lREACT';
      S.shared.dB = ether(f.debtB, 6) + ' ETH';
      return f;
    });
  }

  /* The caps and the float, read before the first confirmation so nobody signs and is then refused. */
  function capsBlock() {
    var me = S.me;
    return rpc.head('base').then(function (head) {
      var day = Math.floor(head.ts / 86400);
      var left = 86400 - (head.ts % 86400);
      var reset = { h: Math.floor(left / 3600), m: Math.floor((left % 3600) / 60) };
      return Promise.all([
        multi('base', [
          { to: C.exit, data: enc.oneUint('armsOnDay(uint256)', day) },
          { to: C.exit, data: enc.noArg('MAX_ARMS_PER_DAY()') },
          { to: C.exit, data: enc.addrUint('armsByAddressOnDay(address,uint256)', me, day) },
          { to: C.exit, data: enc.noArg('MAX_ARMS_PER_ADDRESS_PER_DAY()') }
        ]),
        readFloat()
      ]).then(function (r) {
        var used = Number(BigInt(r[0][0])), cap = Number(BigInt(r[0][1]));
        var mine = Number(BigInt(r[0][2])), capMine = Number(BigInt(r[0][3]));
        var f = r[1];
        if (used >= cap) return { id: 'runs-used-up', ctx: Object.assign({ cap: cap }, reset) };
        if (mine >= capMine) return { id: 'address-used-up', ctx: Object.assign({ cap: capMine }, reset) };
        if (f.active >= f.maxActive) return { id: 'slots-full', ctx: { n: f.maxActive } };
        if (f.float < BigInt(cfg.amounts.floatMinWei) || f.reserve < BigInt(cfg.amounts.exitMinWei) || f.debtL > 0n || f.debtB > 0n) {
          return { id: 'float-empty', ctx: {} };
        }
        return null;
      });
    });
  }

  /* The demo vault counts every demo dollar it holds, and demo dollars are free to mint to any address. So someone can
     send some to a vault before a visitor deposits and skew the share price. This is the vault's own arithmetic
     (shares = assets * (supply + 1) / (held + 1), redeem = shares * (held + 1) / (supply + 1)): a deposit is fair when
     100 in gives 100 back. An empty vault that already holds demo dollars never is. */
  function fairDeposit(held, supply) {
    if (supply === 0n) return held === 0n;
    var shares = DEP * (supply + 1n) / (held + 1n);
    if (shares === 0n) return false;
    return shares * (held + DEP + 1n) / (supply + shares + 1n) >= DEP;
  }
  async function vaultState(vault) {
    var r = await multi('base', [
      { to: C.token, data: enc.oneAddr('balanceOf(address)', vault) },
      { to: vault, data: enc.noArg('totalSupply()') }
    ]);
    return { held: BigInt(r[0]), supply: BigInt(r[1]) };
  }

  /* Everything the page needs to know about this address, from the chain. */
  async function readPosition() {
    var me = S.me;
    var head = await rpc.head('base');
    var first = await multi('base', [
      { to: C.factory, data: enc.oneAddr('lastVaultOf(address)', me) },
      { to: C.token, data: enc.oneAddr('balanceOf(address)', me) },
      { to: C.factory, data: enc.noArg('TIMELOCK()') },
      { method: 'eth_getBalance', params: [me, 'latest'] }
    ]);
    var pos = { head: head, vault: null, token: BigInt(first[1]), eth: BigInt(first[3]), shares: 0n, tokenAllow: 0n, exitAllow: 0n,
      watchId: 0, base: null, lasna: null, armedAt: 0, fresh: false, created: null, createdTs: null, submits: [] };
    S.timelock = Number(BigInt(first[2])) || 180;
    var vault = dec.addr(first[0]);
    if (same(vault, ZERO)) return pos;
    pos.vault = vault;
    var second = await multi('base', [
      { to: vault, data: enc.oneAddr('balanceOf(address)', me) },
      { to: C.exit, data: enc.twoAddr('activeWatchOf(address,address)', me, vault) },
      { to: C.token, data: enc.twoAddr('allowance(address,address)', me, vault) },
      { to: vault, data: enc.twoAddr('allowance(address,address)', me, C.exit) },
      { to: C.token, data: enc.oneAddr('balanceOf(address)', vault) },
      { to: vault, data: enc.noArg('totalSupply()') }
    ]);
    pos.shares = BigInt(second[0]);
    pos.watchId = Number(BigInt(second[1]));
    pos.tokenAllow = BigInt(second[2]);
    pos.exitAllow = BigInt(second[3]);
    pos.vaultAssets = BigInt(second[4]);
    pos.vaultSupply = BigInt(second[5]);
    pos.tampered = !fairDeposit(pos.vaultAssets, pos.vaultSupply);
    try {
      var from = Math.max(0, head.number - cfg.scan.baseVaultWindow + 1);
      var made = await rpc.getLogs('base', { address: C.factory, topics: [EV['VaultCreated(address,address)'], topicA(vault)] }, from, head.number);
      if (made.length) {
        pos.created = Number(BigInt(made[0].blockNumber));
        pos.fresh = true;
        var logs = await rpc.getLogs('base', { address: vault, topics: [EV['Submit(bytes4,bytes,uint256)']] }, pos.created, head.number);
        pos.submits = logs.map(function (l) {
          var s = dec.submit(l);
          s.hash = l.transactionHash;
          s.block = Number(BigInt(l.blockNumber));
          return s;
        });
      }
    } catch (e) {
      if (!(e && (e.rpcDown || e.rpcError))) throw e;
      pos.fresh = false;
    }
    if (pos.watchId) {
      /* Reactive Lasna has one public endpoint. When it does not answer, the Base Sepolia side is still read, so a
         withdrawal by hand stays possible; lasnaDown means "not known", never "not subscribed". */
      var w = await Promise.all([
        multi('base', [
          { to: C.exit, data: enc.oneUint('watchOf(uint256)', pos.watchId) },
          { to: C.exit, data: enc.oneUint('armedAt(uint256)', pos.watchId) }
        ]),
        rpc.ethCall('lasna', C.reactive, enc.oneUint('watches(uint256)', pos.watchId)).then(function (d) { return dec.lasnaWatch(d); },
          function (e) { if (!rpcFail(e)) throw e; pos.lasnaDown = true; return null; })
      ]);
      pos.base = dec.watchOf(w[0][0]);
      pos.armedAt = Number(BigInt(w[0][1]));
      pos.lasna = w[1];
    }
    S.pos = pos;
    S.shared.address = me;
    S.shared.shares = units(pos.shares);
    S.shared.hasDeposit = pos.shares > 0n;
    S.shared.hasWatch = !!(pos.watchId && pos.base && pos.base.status === 1);
    S.shared.noWatch = !S.shared.hasWatch;
    S.shared.hasAllowance = pos.exitAllow > 0n;
    S.shared.z = units(pos.exitAllow);
    if (S.shared.hasWatch) { S.shared.id = pos.watchId; S.kinds = pos.base.kinds; }
    return pos;
  }

  /* ---------- sending one transaction ---------- */

  function setLine(index, status, hash) {
    if (index === null || !S.lines) return;
    S.lines[index].status = status;
    if (hash) S.lines[index].hash = hash;
    var counted = S.lines.filter(function (l) { return l.status !== 'have' && l.status !== 'skip'; });
    var i = counted.indexOf(S.lines[index]) + 1;
    S.i = i;
    S.n = counted.length;
    go(S.flowState, { i: i, n: counted.length, lines: S.lines, note: S.note, tx: hash || S.ctx.tx });
  }

  function capState(err) {
    if (err.sig === 'DailyCapReached()') return 'runs-used-up';
    if (err.sig === 'DailyCapForAddress()') return 'address-used-up';
    return null;
  }

  async function sendTx(my, index, to, data) {
    var me = S.me;
    if (index === null) { S.i = 1; S.n = 1; } /* a step with one confirmation and no progress lines */
    var cid = await wallet.chainId();
    alive(my);
    if (cid !== BASE.hex) throw stop('wrong-network');
    var sim = await rpc.simulate('base', me, to, data);
    if (!sim.ok) { await rpc.sleep(1200); sim = await rpc.simulate('base', me, to, data); }
    alive(my);
    if (!sim.ok) {
      var err = abi.decodeError(sim.data);
      if (capState(err)) { var blk = await capsBlock(); throw stop(blk ? blk.id : 'would-fail', blk ? blk.ctx : { plain: err.text, name: err.name }); }
      throw stop('would-fail', { plain: err.text, name: err.name });
    }
    setLine(index, 'wallet');
    var hash;
    try {
      hash = await wallet.send(me, to, data);
    } catch (e) {
      alive(my);
      if (e.code === 4001) throw stop('confirm-rejected', { i: S.i || 1, n: S.n || 1, lines: resetLine(index) });
      if (e.code === -32002) throw stop('wallet-busy');
      if (/insufficient funds|not enough (eth|funds)|exceeds balance/i.test(e.message)) throw stop('no-gas', { address: me });
      throw stop('wallet-error', { message: e.message });
    }
    alive(my);
    setLine(index, 'sent', hash);
    var began = now();
    var slow = false;
    var rec = null;
    while (!rec) {
      await rpc.sleep(T.pollMs);
      alive(my);
      try { rec = await rpc.receipt('base', hash); } catch (e) { if (!(e && (e.rpcDown || e.rpcError))) throw e; }
      alive(my);
      if (!rec && !slow && (now() - began) / 1000 > T.receiptSlow) {
        slow = true;
        go(S.flowState, Object.assign({}, S.ctx, { notice: 'tx-slow', tx: hash }));
      }
    }
    if (rec.status !== '0x1') {
      var why = await rpc.simulate('base', me, to, data).catch(function () { return { ok: true }; });
      var d = why.ok ? { text: 'The transaction was mined and reverted', name: '' } : abi.decodeError(why.data);
      throw stop('tx-failed', { plain: d.text, name: d.name, tx: hash });
    }
    setLine(index, 'done', hash);
    return rec;
  }
  function resetLine(index) {
    if (index !== null && S.lines) S.lines[index].status = 'todo';
    return S.lines;
  }

  /* ---------- connect and preflight ---------- */

  function noWalletState() {
    var narrow = window.matchMedia('(max-width: 46em)').matches;
    return narrow && navigator.maxTouchPoints > 0 ? 'no-wallet-phone' : 'no-wallet';
  }

  function connectFlow(id) {
    return async function (my) {
      if (framed) throw stop('framed');
      var list = wallet.list();
      if (!list.length) { list = await wallet.discover(); alive(my); }
      if (!list.length) throw stop(noWalletState());
      if (list.length > 1 && !id) {
        throw stop('choose-wallet', { wallets: list.map(function (w) { return { id: w.id, name: w.name, icon: w.icon }; }) });
      }
      go('connecting');
      try {
        S.me = await wallet.connect(id || list[0].id);
      } catch (e) {
        alive(my);
        if (e.code === 4001) throw stop('connect-rejected');
        if (e.code === -32002) throw stop('wallet-busy');
        throw stop('wallet-error', { message: e.message });
      }
      alive(my);
      S.last = preflight;
      return preflight(my);
    };
  }

  async function preflight(my) {
    if (!S.me) return connectFlow()(my);
    go('checking');
    var cid = await wallet.chainId();
    alive(my);
    if (cid !== BASE.hex) throw stop('wrong-network');
    var pos = await readPosition();
    alive(my);
    if (pos.eth < BigInt(cfg.amounts.minGasWei)) throw stop('no-gas', { address: S.me });
    var active = S.shared.hasWatch;
    if (active || pos.shares > 0n) {
      if (!active && !pos.fresh) throw stop('old-vault');
      var ts = active ? pos.armedAt : null;
      if (!ts && pos.created) ts = await rpc.blockTs('base', rpc.hex(pos.created));
      alive(my);
      var pending = active && watchedPending(pos);
      throw stop('resume', { what: active ? 'watch' : 'deposit', time: ts ? fmt.time(ts) + ' UTC on ' + fmt.date(ts) : 'an earlier visit',
        step: active ? (pending ? 4 : 3) : 2 });
    }
    return showStepDeposit(my, pos);
  }

  function watchedPending(pos) {
    var out = null;
    pos.submits.forEach(function (s) {
      var k = cfg.kinds.filter(function (kd) { return kd.selectors.indexOf(s.selector) >= 0; })[0];
      if (k && (pos.base.kinds & k.bit)) out = s;
    });
    return out;
  }

  /* The WatchEnded log of a watch, by watch id alone. A "leave now" watch ends once, so one log is the whole answer. */
  async function findEnded(watchId, fromBlock) {
    var head = await rpc.head('base');
    var from = fromBlock === undefined || fromBlock === null ? Math.max(0, head.number - 2000) : fromBlock;
    var logs = await rpc.getLogs('base', { address: C.exit,
      topics: [EV['WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)'], topicN(watchId)] }, from, head.number);
    return logs[0] || null;
  }

  async function continueFrom(my) {
    var pos = await readPosition();
    alive(my);
    if (S.shared.hasWatch) {
      if (pos.lasnaDown) throw stop('rpc-down', rpcCtx('lasna'));
      var ls = pos.lasna ? pos.lasna.status : 0;
      var lh = await rpc.head('lasna');
      alive(my);
      var keep = S.run && S.run.r1 ? S.run : null;
      S.run = { watchId: pos.watchId, baseFrom: pos.created || Math.max(0, pos.head.number - 2000),
        lasnaFrom: Math.max(0, lh.number - cfg.chains.lasna.endpoints[0].maxRange + 1), attempt: 1 };
      S.run.lasnaFromSubmit = S.run.lasnaFrom;
      if (ls === 4) throw stop('watch-refused', { reason: copy.refusedGone });
      if (ls === 0) { go('armed-subscribing'); return watchSubscription(my); }
      var pending = watchedPending(pos);
      if (pending) {
        if (keep && same(keep.r1.hash, pending.hash)) {
          S.run = keep;
          S.run.shift = 0;
        } else {
          var ts = await rpc.blockTs('base', rpc.hex(pending.block));
          alive(my);
          Object.assign(S.run, { r1: { hash: pending.hash, block: pending.block, ts: ts }, execAt: pending.executableAt, expectExit: true,
            tokenBefore: null, sharesBefore: pos.shares, seen1: now(), resumed: true, attempt: 2 });
        }
        showWait();
        return watchRecords(my);
      }
      if (ls !== 1) throw stop('watch-refused', { reason: copy.refusedClosed });
      var subs = await rpc.getLogs('lasna', { address: C.reactive,
        topics: [EV['WatchSubscribed(uint256,address,uint8,uint8)'], topicN(pos.watchId)] }, S.run.lasnaFrom, lh.number);
      alive(my);
      if (subs.length) {
        S.shared.subTx = subs[0].transactionHash;
        var subTs = await rpc.blockTs('lasna', subs[0].blockNumber);
        alive(my);
        return settle(my, T.settleAfterSubscribed - Math.max(0, lh.ts - subTs));
      }
      return go('armed');
    }
    /* No watch is on. If this session had one and has not shown its result yet (a read failed while the exit landed,
       or the exit came late), the result is on Base Sepolia: show it instead of starting over at step 1. */
    var had = S.run || {};
    if (had.watchId && !had.r3) {
      var ended = await findEnded(had.watchId, had.baseFrom);
      alive(my);
      if (ended) return finish(my, ended);
    }
    if (pos.shares > 0n) {
      if (!pos.fresh) throw stop('old-vault');
      return showDeposited(pos);
    }
    return showStepDeposit(my, pos);
  }

  /* ---------- step 1: deposit ---------- */

  function planDeposit(pos) {
    var empty = !!(pos.vault && pos.fresh && !pos.submits.length && pos.shares === 0n && !S.shared.hasWatch);
    var reuse = empty && !pos.tampered;
    S.tamperNote = empty && pos.tampered ? copy.tamperedReuse : null;
    var L = copy.depositLines;
    return { reuse: reuse, lines: [
      { label: L[0], status: reuse ? 'skip' : 'todo' },
      { label: L[1], status: pos.token >= DEP ? 'have' : 'todo' },
      { label: L[2], status: reuse && pos.tokenAllow >= DEP ? 'skip' : 'todo' },
      { label: L[3], status: 'todo' }
    ] };
  }
  function countTodo(lines) { return lines.filter(function (l) { return l.status === 'todo'; }).length; }

  async function showStepDeposit(my, pos) {
    var blk = await capsBlock();
    alive(my);
    if (blk) throw stop(blk.id, blk.ctx);
    var plan = planDeposit(pos);
    S.shared.id = undefined;
    S.run = {};
    go('step-deposit', { lines: plan.lines, n: countTodo(plan.lines), note: S.tamperNote || (pos.token >= DEP ? null : copy.noTokens) });
  }

  async function refuseTampered(my, vault) {
    var v = await vaultState(vault);
    alive(my);
    if (fairDeposit(v.held, v.supply)) return;
    S.tampers = (S.tampers || 0) + 1;
    S.lines = null;
    throw stop('vault-tampered', { amount: units(v.held), again: S.tampers > 1 ? copy.tamperedAgain : '' });
  }

  async function doDeposit(my) {
    var pos = await readPosition();
    alive(my);
    if (S.shared.hasWatch || (pos.shares > 0n && pos.fresh)) return continueFrom(my);
    if (pos.eth < BigInt(cfg.amounts.minGasWei)) throw stop('no-gas', { address: S.me });
    var blk = await capsBlock();
    alive(my);
    if (blk) throw stop(blk.id, blk.ctx);
    var plan = planDeposit(pos);
    S.lines = plan.lines;
    S.flowState = 'depositing';
    S.note = pos.token >= DEP ? null : copy.noTokens;
    var vault = plan.reuse ? pos.vault : null;
    go('depositing', { i: 1, n: countTodo(S.lines), lines: S.lines, note: S.note });
    if (S.lines[0].status === 'todo') {
      var rec = await sendTx(my, 0, C.factory, enc.create());
      var made = rec.logs.filter(function (l) { return same(l.address, C.factory) && l.topics[0] === EV['VaultCreated(address,address)']; })[0];
      if (!made) throw stop('tx-failed', { plain: 'The vault was not created', name: '', tx: rec.transactionHash });
      vault = dec.topicAddr(made.topics[1]);
      await refuseTampered(my, vault); /* before the visitor signs anything else for this vault */
    }
    if (S.lines[1].status === 'todo') await sendTx(my, 1, C.token, enc.mint(S.me, DEP));
    S.note = null;
    if (S.lines[2].status === 'todo') await sendTx(my, 2, C.token, enc.approve(vault, DEP));
    await refuseTampered(my, vault); /* again right before the deposit itself */
    await sendTx(my, 3, vault, enc.deposit(DEP, S.me));
    S.lines = null;
    S.tampers = 0;
    var after = await readPosition();
    alive(my);
    /* What the shares would pay out now. Lower than the deposit means the share price moved in the last moment. */
    var worth = BigInt(await rpc.ethCall('base', after.vault, enc.oneUint('previewRedeem(uint256)', after.shares)));
    alive(my);
    if (worth < DEP) throw stop('deposit-short', { worth: units(worth) });
    return showDeposited(after);
  }

  function showDeposited(pos) {
    S.lines = null;
    var line = pos.submits.length ? view.fillText(copy.pendingSome, { n: pos.submits.length }) : copy.pendingNone;
    go('deposited', { pendingLine: pos.fresh ? line : '' });
    view.setKindsWarn(S.kinds ? '' : copy.kindsNone);
  }

  /* ---------- step 2: the watch ---------- */

  async function doArm(my) {
    var pos = await readPosition();
    alive(my);
    if (S.shared.hasWatch || pos.shares === 0n) return continueFrom(my);
    if (!pos.fresh) throw stop('old-vault');
    if (!S.kinds) return showDeposited(pos);
    var blk = await capsBlock();
    alive(my);
    if (blk) throw stop(blk.id, blk.ctx);
    S.lines = [
      { label: view.fillText(copy.armLines[0], { shares: units(pos.shares) }), status: pos.exitAllow === pos.shares ? 'skip' : 'todo' },
      { label: copy.armLines[1], status: 'todo' }
    ];
    S.flowState = 'arming';
    S.note = null;
    var lh = await rpc.head('lasna');
    alive(my);
    S.run = { lasnaFrom: Math.max(0, lh.number - 2), attempt: 0 };
    go('arming', { i: 1, n: countTodo(S.lines), lines: S.lines });
    if (S.lines[0].status === 'todo') await sendTx(my, 0, pos.vault, enc.approve(C.exit, pos.shares));
    var rec = await sendTx(my, 1, C.exit, enc.arm(pos.vault, S.kinds, 0, pos.shares));
    var log = rec.logs.filter(function (l) { return same(l.address, C.exit) && l.topics[0] === EV['WatchArmed(uint256,address,address,uint8,uint8,uint256)']; })[0];
    if (!log) throw stop('tx-failed', { plain: 'The watch was not recorded', name: '', tx: rec.transactionHash });
    S.lines = null;
    S.shared.id = dec.watchArmed(log).watchId;
    S.run.watchId = S.shared.id;
    S.run.baseFrom = Number(BigInt(rec.blockNumber));
    S.shared.armTx = rec.transactionHash;
    S.shared.hasWatch = true;
    S.shared.noWatch = false;
    S.last = continueFrom;
    go('armed-subscribing');
    return watchSubscription(my);
  }

  async function watchSubscription(my) {
    var began = now();
    var idT = topicN(S.shared.id);
    for (;;) {
      alive(my);
      var logs = [];
      try {
        var head = await rpc.head('lasna');
        logs = await rpc.getLogs('lasna', { address: C.reactive,
          topics: [[EV['WatchSubscribed(uint256,address,uint8,uint8)'], EV['WatchRefused(uint256,uint8)']], idT] }, S.run.lasnaFrom, head.number);
      } catch (e) { if (!rpcFail(e)) throw e; /* one failed read is a skipped tick, not the end of the wait */ }
      alive(my);
      if (logs.length) {
        var log = logs[0];
        if (log.topics[0] === EV['WatchRefused(uint256,uint8)']) {
          var code = dec.num(log.data, 0);
          throw stop('watch-refused', { reason: code === 3 ? copy.refused3 : (code === 4 ? copy.refused4 : view.fillText(copy.refusedOther, { code: code })) });
        }
        S.shared.subTx = log.transactionHash;
        var subTs = await rpc.blockTs('lasna', log.blockNumber);
        var latest = await rpc.head('lasna');
        alive(my);
        /* The wait starts from the subscription's block time on Lasna, then runs on the page's monotonic timer. */
        return settle(my, T.settleAfterSubscribed - Math.max(0, latest.ts - subTs));
      }
      if ((now() - began) / 1000 > T.subscribeSlow) { await readFloat(); throw stop('subscribe-slow'); }
      await rpc.sleep(T.pollMs);
    }
  }

  async function settle(my, left) {
    var t0 = now();
    var shown = null;
    for (;;) {
      alive(my);
      var n = Math.ceil(left - (now() - t0) / 1000);
      if (n <= 0) break;
      if (shown === null) go('armed-settling', { n: n });
      else if (n !== shown) view.setHeadline(view.fillText(NP.states['armed-settling'].h, { n: n }));
      shown = n;
      await rpc.sleep(250);
    }
    go('armed');
  }

  /* ---------- step 3: the curator, and the three records ---------- */

  function model() {
    var r = S.run;
    var m = { t1: r.r1 && r.r1.ts, h1: r.r1 && r.r1.hash, execAt: r.execAt, own: true, stage: 1 };
    if (r.r2) { m.t2 = r.r2.ts; m.h2 = r.r2.hash; m.stage = 2; }
    if (r.r3) { m.t3 = r.r3.ts; m.h3 = r.r3.hash; m.stage = 3; m.r2Missing = !r.r2; }
    if (!r.r3 && r.seen1) m.elapsed = Math.floor((now() - r.seen1) / 1000);
    return m;
  }

  function kindOf(bit) { return cfg.kinds.filter(function (k) { return k.bit === bit; })[0]; }
  function rand(n) { return parseInt(abi.randomHex(4).slice(2), 16) % n; }

  /* The call the curator schedules, for one kind. Random arguments each time: the same call data cannot be
     scheduled twice while it is pending. */
  function changeFor(bit) {
    if (bit === 2) {
      /* shorten the waiting period of one curator action; it waits for that action's current period */
      var targets = ['addAdapter(address)', 'setIsAllocator(address,bool)', 'increaseAbsoluteCap(bytes,uint256)', 'increaseRelativeCap(bytes,uint256)'];
      return enc.decreaseTimelock(sig.fn[targets[rand(targets.length)]], 1 + rand(Math.max(1, S.timelock - 1)));
    }
    if (bit === 4) return enc.setIsAllocator(abi.randomHex(20), true);
    if (bit === 8) return enc.increaseAbsoluteCap(abi.randomHex(32), cfg.amounts.capIncrease);
    return enc.addAdapter(abi.randomHex(20));
  }

  function scheduleFlow(bit) {
    return async function (my) {
      var pos = await readPosition();
      alive(my);
      if (!S.shared.hasWatch) return continueFrom(my);
      var kind = kindOf(bit) || kindOf(1);
      var inner = changeFor(kind.bit);
      var lh = await rpc.head('lasna');
      alive(my);
      var prev = S.run || {};
      var from = Math.max(0, lh.number - 2);
      S.run = { watchId: pos.watchId, baseFrom: prev.baseFrom !== undefined ? prev.baseFrom : (pos.created || Math.max(0, pos.head.number - 2000)),
        lasnaFrom: prev.lasnaFrom !== undefined ? prev.lasnaFrom : from, lasnaFromSubmit: from, attempt: (prev.attempt || 0) + 1,
        bit: kind.bit, kindA: kind.a, expectExit: (pos.base.kinds & kind.bit) !== 0, tokenBefore: pos.token, sharesBefore: pos.shares };
      S.lines = null;
      S.flowState = 'scheduling';
      go('scheduling');
      var rec = await sendTx(my, null, pos.vault, enc.submit(inner));
      S.run.seen1 = now();
      var log = rec.logs.filter(function (l) { return same(l.address, pos.vault) && l.topics[0] === EV['Submit(bytes4,bytes,uint256)']; })[0];
      if (!log) throw stop('tx-failed', { plain: 'The change was not scheduled', name: '', tx: rec.transactionHash });
      var ts = await rpc.blockTs('base', rec.blockNumber);
      alive(my);
      S.run.r1 = { hash: rec.transactionHash, block: Number(BigInt(rec.blockNumber)), ts: ts };
      S.run.execAt = dec.submit(log).executableAt;
      S.last = continueFrom; /* from here a retry re-reads the chain; it never schedules a second change by itself */
      showWait();
      return watchRecords(my);
    };
  }

  /* The state of a run that waits for its records, drawn from what is known so far. */
  function showWait(notice) {
    var r = S.run;
    if (r.r2) return go('exit-requested', { model: model(), refLine: r.refLine, notice: notice });
    if (r.expectExit) return go('scheduled', { model: model(), notice: notice });
    go('unwatched-wait', { n: ignoredLeft(), kindA: r.kindA || 'a change', r1: r.r1.hash, notice: notice });
  }
  function ignoredLeft() {
    var r = S.run;
    return Math.max(0, Math.ceil(T.ignoredAfter - ((now() - r.seen1) / 1000 - (r.shift || 0))));
  }

  /* The exit names the Submit it answers. When that is an earlier change of this vault than the one the page was
     waiting for (Reactive delivered the first one late), the run on screen becomes that change. */
  async function adoptOrigin(my, origin) {
    var r = S.run;
    if (r.r1 && same(r.r1.hash, origin)) return;
    var rec = await rpc.receipt('base', origin);
    if (!rec) throw stop('page-error', { message: 'The change this exit answers could not be read from Base Sepolia.' });
    var log = rec.logs.filter(function (l) { return l.topics[0] === EV['Submit(bytes4,bytes,uint256)']; })[0];
    var ts = await rpc.blockTs('base', rec.blockNumber);
    alive(my);
    r.earlier = !!r.r1;
    r.r1 = { hash: rec.transactionHash, block: Number(BigInt(rec.blockNumber)), ts: ts };
    r.execAt = log ? dec.submit(log).executableAt : (r.execAt || ts);
    r.resumed = true; /* the browser's own stopwatch started at another change */
  }

  async function takeRequest(my, log) {
    var r = S.run;
    await adoptOrigin(my, log.topics[2]);
    var both = await Promise.all([rpc.blockTs('lasna', log.blockNumber), rpc.receipt('lasna', log.transactionHash)]);
    alive(my);
    r.r2 = { hash: log.transactionHash, ts: both[0], refTx: both[1] && both[1].refTx };
    r.seen2 = now();
    var parts = [];
    if (r.earlier) parts.push(view.fillText(copy.earlierChange, { time: fmt.time(r.r1.ts) }));
    if (same(r.r2.refTx, r.r1.hash)) parts.push(copy.refTx);
    r.refLine = parts.join(' ') || null;
    r.expectExit = true;
  }

  async function watchRecords(my) {
    var r = S.run;
    var idT = topicN(r.watchId || S.shared.id);
    var lasnaStart = Math.min(r.lasnaFromSubmit, r.lasnaFrom === undefined ? r.lasnaFromSubmit : r.lasnaFrom);
    var noticed = false;
    var fails = 0;
    var hiccup = false;
    var timer = setInterval(function () {
      if (my !== S.epoch || r.r3) { clearInterval(timer); return; }
      if (S.id === 'unwatched-wait') view.setHeadline(view.fillText(NP.states['unwatched-wait'].h, { n: ignoredLeft() }));
      else view.tickStrip(model());
    }, 500);
    try {
      for (;;) {
        alive(my);
        var elapsed = (now() - r.seen1) / 1000 - (r.shift || 0);
        var lasnaOk = true;
        var baseOk = true;
        if (!r.r2) {
          try {
            var lh = await rpc.head('lasna');
            var logs = await rpc.getLogs('lasna', { address: C.reactive,
              topics: [EV['ExitRequested(uint256,uint256,uint8,bytes32)'], idT] }, lasnaStart, lh.number);
            alive(my);
            if (logs.length) {
              await takeRequest(my, logs[0]);
              showWait(hiccup ? 'rpc-hiccup' : undefined);
            }
          } catch (e) { if (!rpcFail(e)) throw e; lasnaOk = false; }
          alive(my);
        }
        if (!r.r2 && lasnaOk) {
          try {
            if (!r.expectExit) {
              if (elapsed >= T.ignoredAfter) {
                var sh = BigInt(await rpc.ethCall('base', S.pos.vault, enc.oneAddr('balanceOf(address)', S.me)));
                alive(my);
                if (sh === r.sharesBefore) throw stop('ignored', { shares: units(sh), kindA: r.kindA || 'a change' });
                r.expectExit = true; /* the shares moved after all: follow it as an exit */
              }
            } else if (elapsed >= T.reactiveTimeout && (r.attempt > 1 || r.shift)) {
              var bh = await rpc.head('base');
              await readFloat();
              throw stop('reactive-timeout', { t: Math.max(0, r.execAt - bh.ts), time: fmt.time(r.execAt) + ' UTC' });
            } else if (elapsed >= T.missedAfter && r.attempt <= 1 && !r.shift) {
              var st = await Promise.all([
                rpc.ethCall('base', C.exit, enc.oneUint('watchOf(uint256)', S.shared.id)),
                rpc.ethCall('lasna', C.reactive, enc.oneUint('watches(uint256)', S.shared.id))
              ]);
              alive(my);
              if (dec.watchOf(st[0]).status === 1 && dec.lasnaWatch(st[1]).status === 1) throw stop('missed');
              r.attempt = 2;
            } else if (elapsed >= T.reactiveSlow && !noticed) {
              noticed = true;
              go('scheduled', { model: model(), notice: 'reactive-slow' });
            }
          } catch (e) { if (!rpcFail(e)) throw e; baseOk = false; }
          alive(my);
        }
        /* The withdrawal is looked for by watch id alone, and also while Reactive Lasna cannot be read: the exit may
           have been asked for and delivered meanwhile. */
        if ((r.r2 || !lasnaOk) && !r.r3) {
          var ended = null;
          try {
            ended = await findEnded(r.watchId || S.shared.id, r.baseFrom !== undefined ? r.baseFrom : (r.r1 && r.r1.block));
          } catch (e) { if (!rpcFail(e)) throw e; baseOk = false; }
          alive(my);
          if (ended) return finish(my, ended);
          if (r.r2 && baseOk && (now() - r.seen2) / 1000 - (r.shift2 || 0) >= T.callbackSlow) {
            await readFloat();
            throw stop('callback-slow', { time: fmt.time(r.r2.ts) + ' UTC', r2: r.r2.hash });
          }
        }
        /* A failed read is a skipped tick, not the end of the run. After two in a row the page says so and keeps going. */
        fails = lasnaOk && baseOk ? 0 : fails + 1;
        if (fails >= 2 && !hiccup) { hiccup = true; showWait('rpc-hiccup'); }
        else if (!fails && hiccup) { hiccup = false; showWait(); }
        await rpc.sleep(T.pollMs);
      }
    } finally { clearInterval(timer); }
  }

  async function finish(my, log) {
    var r = S.run;
    var e = dec.watchEnded(log);
    r.seen3 = now();
    await adoptOrigin(my, e.originTxHash);
    if (!r.r2) {
      /* The exit landed while Reactive's side was not read (or not readable). One more try; the result does not wait for it. */
      try {
        var lh = await rpc.head('lasna');
        var reqs = await rpc.getLogs('lasna', { address: C.reactive,
          topics: [EV['ExitRequested(uint256,uint256,uint8,bytes32)'], topicN(e.watchId)] },
        r.lasnaFrom !== undefined ? r.lasnaFrom : Math.max(0, lh.number - cfg.chains.lasna.endpoints[0].maxRange + 1), lh.number);
        alive(my);
        if (reqs.length) await takeRequest(my, reqs[0]);
      } catch (err) { if (!rpcFail(err)) throw err; }
      alive(my);
    }
    var parts = await Promise.all([
      rpc.blockTs('base', log.blockNumber),
      multi('base', [
        { to: C.token, data: enc.oneAddr('balanceOf(address)', S.me) },
        { to: S.pos.vault, data: enc.oneAddr('balanceOf(address)', S.me) },
        { to: S.pos.vault, data: enc.twoAddr('allowance(address,address)', S.me, C.exit) }
      ]),
      rpc.receipt('base', log.transactionHash)
    ]);
    alive(my);
    r.r3 = { hash: log.transactionHash, ts: parts[0], outcome: e.outcome, assets: e.assets };
    S.shared.id = e.watchId;
    var allow = BigInt(parts[1][2]);
    S.shared.hasWatch = false;
    S.shared.noWatch = true;
    S.shared.hasDeposit = BigInt(parts[1][1]) > 0n;
    S.shared.hasAllowance = allow > 0n;
    S.shared.z = units(allow);
    if (e.outcome === 1) return go('nothing-to-redeem');
    if (e.outcome !== 0) {
      var rv = (parts[2] ? parts[2].logs : []).filter(function (l) { return same(l.address, C.exit) && l.topics[0] === EV['RedeemReverted(uint256,bytes)']; })[0];
      var why = rv ? abi.decodeError(dec.bytesAt(rv.data, 0)) : { text: 'not given' };
      return go('redeem-failed', { reason: why.text + (why.name ? ' (' + why.name + ')' : '') });
    }
    var ctx = {
      model: model(), refLine: r.refLine,
      assets: units(e.assets),
      t: Math.max(0, r.execAt - r.r3.ts),
      w: r.resumed || !r.seen1 ? null : ((r.seen3 - r.seen1) / 1000).toFixed(1),
      a: r.tokenBefore === null || r.tokenBefore === undefined ? null : units(r.tokenBefore),
      b: units(BigInt(parts[1][0])),
      c: r.sharesBefore === null || r.sharesBefore === undefined ? null : units(r.sharesBefore)
    };
    go('returned', ctx);
    writeHash(e.watchId);
    data.ready = loadChain();
    if (!r.r2) fillRequest(my, e.watchId, ctx);
  }

  /* The result was shown without Reactive's record because its chain could not be read. Keep asking, quietly, and
     put the record into the result when it can be read. */
  async function fillRequest(my, watchId, ctx) {
    var r = S.run;
    for (var i = 0; i < 40 && my === S.epoch && S.id === 'returned' && !r.r2; i++) {
      await rpc.sleep(3000);
      if (my !== S.epoch || S.id !== 'returned') return;
      try {
        var lh = await rpc.head('lasna');
        var reqs = await rpc.getLogs('lasna', { address: C.reactive,
          topics: [EV['ExitRequested(uint256,uint256,uint8,bytes32)'], topicN(watchId)] },
        r.lasnaFrom !== undefined ? r.lasnaFrom : Math.max(0, lh.number - cfg.chains.lasna.endpoints[0].maxRange + 1), lh.number);
        if (my !== S.epoch || S.id !== 'returned') return;
        if (reqs.length) {
          await takeRequest(my, reqs[0]);
          go('returned', Object.assign({}, ctx, { model: model(), refLine: r.refLine }));
        }
      } catch (err) { if (!rpcFail(err) && !(err && err.cancelled)) console.warn('[notice-period]', err && err.message); }
    }
  }

  /* ---------- recovery: nothing may trap funds or block a new run ---------- */

  function recoverFlow(kinds, then) {
    return async function (my) {
      var pos = await readPosition();
      alive(my);
      var todo = kinds.filter(function (k) {
        if (k === 'withdraw') return pos.shares > 0n;
        if (k === 'cancel') return S.shared.hasWatch;
        return pos.exitAllow > 0n;
      });
      var labels = { withdraw: 'Withdraw your deposit', cancel: 'Turn the watch off', allowance: 'Remove the allowance' };
      var before = pos.token;
      if (todo.length) {
        S.lines = todo.map(function (k) { return { label: labels[k], status: 'todo', kind: k }; });
        S.flowState = 'recovering';
        S.note = null;
        go('recovering', { i: 1, n: todo.length, lines: S.lines });
        for (var i = 0; i < todo.length; i++) {
          if (todo[i] === 'withdraw') await sendTx(my, i, pos.vault, enc.redeem(pos.shares, S.me, S.me));
          else if (todo[i] === 'cancel') await sendTx(my, i, C.exit, enc.cancel(pos.watchId));
          else await sendTx(my, i, pos.vault, enc.approve(C.exit, 0));
        }
        S.lines = null;
      }
      var after = await readPosition();
      alive(my);
      if (then === 'restart') return showStepDeposit(my, after);
      if (then === 'returned' && S.returnedCtx) {
        return go('returned', Object.assign({}, S.returnedCtx, { z: units(after.exitAllow), hasAllowance: after.exitAllow > 0n }));
      }
      if (kinds[0] === 'withdraw' && kinds.length === 1) {
        return go('withdrawn-by-hand', { assets: units(after.token - before), watchLine: S.shared.hasWatch ? copy.watchStillOn : copy.watchNone });
      }
      return go('watch-off');
    };
  }

  /* ---------- first screen data: no wallet needed ---------- */

  /* Reads one run by its three hashes and checks every link between them. Throws when anything does not fit. */
  async function readRun(id, h1, h2, h3) {
    var res = await Promise.all([
      multi('base', [
        { method: 'eth_getTransactionReceipt', params: [h1] },
        { method: 'eth_getTransactionReceipt', params: [h3] },
        { to: C.exit, data: enc.oneUint('watchOf(uint256)', id) }
      ]),
      rpc.receipt('lasna', h2)
    ]);
    var r1 = res[0][0], r3 = res[0][1], w = dec.watchOf(res[0][2]), r2 = res[1];
    if (!r1 || !r2 || !r3) throw new Error('receipt missing');
    if (r1.status !== '0x1' || r2.status !== '0x1' || r3.status !== '0x1') throw new Error('a transaction failed');
    var idT = topicN(id);
    var sub = r1.logs.filter(function (l) { return same(l.address, w.vault) && l.topics[0] === EV['Submit(bytes4,bytes,uint256)']; })[0];
    var req = r2.logs.filter(function (l) {
      return same(l.address, C.reactive) && l.topics[0] === EV['ExitRequested(uint256,uint256,uint8,bytes32)'] && l.topics[1] === idT && same(l.topics[2], h1);
    })[0];
    var end = r3.logs.filter(function (l) {
      return same(l.address, C.exit) && l.topics[0] === EV['WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)'] && l.topics[1] === idT && same(l.topics[2], h1);
    })[0];
    if (!sub || !req || !end) throw new Error('the three records are not linked');
    var e = dec.watchEnded(end);
    if (e.outcome === 0) {
      var paid = r3.logs.filter(function (l) {
        return same(l.address, C.token) && l.topics[0] === EV['Transfer(address,address,uint256)'] &&
          same(dec.topicAddr(l.topics[1]), w.vault) && same(dec.topicAddr(l.topics[2]), w.owner) && dec.big(l.data, 0) === e.assets;
      })[0];
      if (!paid) throw new Error('the token transfer to the depositor is missing');
    }
    var ts = await Promise.all([
      multi('base', [
        { method: 'eth_getBlockByNumber', params: [r1.blockNumber, false] },
        { method: 'eth_getBlockByNumber', params: [r3.blockNumber, false] }
      ]),
      rpc.blockTs('lasna', r2.blockNumber)
    ]);
    var s = dec.submit(sub);
    return {
      id: id, mode: w.mode, kinds: w.kinds, owner: w.owner, vault: w.vault, selector: s.selector, execAt: s.executableAt, checked: true,
      r1: { hash: h1, block: Number(BigInt(r1.blockNumber)), ts: Number(BigInt(ts[0][0].timestamp)) },
      r2: { hash: h2, ts: ts[1], refTx: r2.refTx, refChainId: r2.refChainId, reason: dec.exitRequested(req).reason },
      r3: { hash: h3, ts: Number(BigInt(ts[0][1].timestamp)), outcome: e.outcome, assets: e.assets.toString() }
    };
  }

  function order(list) {
    return list.slice().sort(function (a, b) {
      var av = a.owner && !same(a.owner, cfg.operator) ? 1 : 0;
      var bv = b.owner && !same(b.owner, cfg.operator) ? 1 : 0;
      if (av !== bv) return bv - av;
      return b.id - a.id;
    });
  }
  function latestNow(list) {
    return list.filter(function (r) { return r.r3 && r.r3.outcome === 0 && r.mode === 0; }).sort(function (a, b) { return b.r1.ts - a.r1.ts; })[0] || null;
  }
  /* A page opened with #run=N shows that run on its first screen, so the address and the screen agree without a scroll. */
  function showHero(list, state, retry) {
    var linked = S.linked === null ? null : list.filter(function (r) { return r.id === S.linked && r.r1 && r.r2 && r.r3; })[0];
    view.latest(linked || latestNow(list), state, retry, !!linked);
  }

  function showProof(list) {
    var withTx = list.filter(function (r) { return r.r1; });
    var returned = withTx.filter(function (r) { return r.r3 && r.r3.outcome === 0; });
    var nowTimes = returned.filter(function (r) { return r.mode === 0; }).sort(function (a, b) { return b.r1.ts - a.r1.ts; })
      .map(function (r) { return fmt.sec(r.r3.ts, r.r1.ts); });
    var total = data.next !== null ? data.next - 1 : withTx.length;
    var unlisted = list.filter(function (r) { return !r.r1 && r.status === 3; }).length + Math.max(0, total - list.length);
    var ours = list.filter(function (r) { return r.owner && same(r.owner, cfg.operator); }).length;
    var visitors = list.filter(function (r) { return r.owner && !same(r.owner, cfg.operator); }).length;
    view.proof({ runs: total, returned: returned.length, nowTimes: nowTimes, unlisted: unlisted, ours: ours, visitors: visitors });
  }

  async function loadChain() {
    var recorded = NP.recorded.runs.slice();
    var list = recorded.slice();
    view.latest(null, 'loading');
    view.runs(null, 'loading');
    view.healthLoading();
    var checked;
    try {
      checked = await Promise.all(recorded.map(function (r) { return readRun(r.id, r.r1.hash, r.r2.hash, r.r3.hash); }));
      list = checked.slice();
      showHero(list, 'ok');
    } catch (e) {
      console.warn('[notice-period] could not re-check the recorded runs:', e && e.message);
      data.runs = order(list);
      data.liveOk = false;
      showHero(list, 'fail', function () { data.ready = loadChain(); });
      view.runs(data.runs, 'fail', function () { data.ready = loadChain(); });
      view.health(null, function () { data.ready = loadChain(); });
      return;
    }
    try {
      var heads = await Promise.all([rpc.head('base'), rpc.head('lasna')]);
      var day = Math.floor(heads[0].ts / 86400);
      data.baseTs = heads[0].ts;
      var live = await Promise.all([
        multi('base', [
          { to: C.exit, data: enc.noArg('nextWatchId()') },
          { to: C.exit, data: enc.noArg('MAX_ARMS_PER_DAY()') },
          { to: C.exit, data: enc.oneUint('armsOnDay(uint256)', day) }
        ]),
        readFloat(),
        rpc.getLogs('lasna', { address: C.reactive, topics: [EV['ExitRequested(uint256,uint256,uint8,bytes32)']] },
          heads[1].number - cfg.scan.lasnaWindows * cfg.chains.lasna.endpoints[0].maxRange + 1, heads[1].number)
      ]);
      data.next = Number(BigInt(live[0][0]));
      var cap = Number(BigInt(live[0][1]));
      var used = Number(BigInt(live[0][2]));
      var have = {};
      list.forEach(function (r) { have[r.id] = true; });
      var fresh = live[2].filter(function (l) { return !have[dec.topicNum(l.topics[1])]; }).slice(-cfg.scan.maxRunsListed);
      for (var i = 0; i < fresh.length; i++) {
        var id = dec.topicNum(fresh[i].topics[1]);
        var h1 = fresh[i].topics[2];
        try {
          var r1 = await rpc.receipt('base', h1);
          var from = Number(BigInt(r1.blockNumber));
          var ended = await rpc.getLogs('base', { address: C.exit,
            topics: [EV['WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)'], topicN(id)] }, from, Math.min(heads[0].number, from + 49999));
          if (ended.length) { list.push(await readRun(id, h1, fresh[i].transactionHash, ended[0].transactionHash)); have[id] = true; }
        } catch (e) { console.warn('[notice-period] run #' + id + ' could not be read:', e && e.message); }
      }
      var missing = [];
      for (var n = data.next - 1; n >= 1 && missing.length < cfg.scan.maxRunsListed; n--) if (!have[n]) missing.push(n);
      if (missing.length) {
        var calls = [];
        missing.forEach(function (m) {
          calls.push({ to: C.exit, data: enc.oneUint('watchOf(uint256)', m) });
          calls.push({ to: C.exit, data: enc.oneUint('armedAt(uint256)', m) });
        });
        var info = await multi('base', calls);
        missing.forEach(function (m, k) {
          var w = dec.watchOf(info[2 * k]);
          list.push({ id: m, owner: w.owner, status: w.status, mode: w.mode, armedAt: Number(BigInt(info[2 * k + 1])) });
        });
      }
      data.runs = order(list);
      data.liveOk = true;
      view.runs(data.runs, 'ok');
      showHero(list, 'ok');
      showProof(list);
      var mine = list.filter(function (r) { return r.r3 && r.r3.outcome === 0 && r.mode === 0 && same(r.owner, cfg.operator); })
        .sort(function (a, b) { return b.r3.ts - a.r3.ts; })[0];
      view.health({ left: Math.max(0, cap - used), cap: cap, float: ether(data.float.float, 2),
        lastAge: mine ? Math.max(0, heads[0].ts - mine.r3.ts) : null, lastTs: mine ? mine.r3.ts : null,
        lastSec: mine ? fmt.sec(mine.r3.ts, mine.r1.ts) : null },
      function () { data.ready = loadChain(); });
    } catch (e) {
      console.warn('[notice-period] live read failed:', e && e.message);
      data.runs = order(list);
      data.liveOk = false;
      view.runs(data.runs, 'fail', function () { data.ready = loadChain(); });
      showProof(list);
      view.health(null, function () { data.ready = loadChain(); });
    }
  }

  async function loadMorpho() {
    view.problemLoading();
    try {
      var j = await rpc.post(cfg.morpho.url, { query: cfg.morpho.query });
      var items = j && j.data && j.data.vaultV2s && j.data.vaultV2s.items;
      if (!Array.isArray(items)) throw new Error('unexpected answer');
      var t = Date.now() / 1000;
      var n = 0, k = 0, usd = 0, vaults = 0, byKind = {};
      items.forEach(function (v) {
        var pend = v && v.pendingConfigs && Array.isArray(v.pendingConfigs.items) ? v.pendingConfigs.items : [];
        var waiting = pend.filter(function (p) { return p && Number(p.validAt) > t; });
        if (!waiting.length) return;
        vaults += 1;
        usd += Number(v.totalAssetsUsd) || 0;
        waiting.forEach(function (p) {
          var kind = cfg.morpho.kinds[p.functionName] || { label: 'other', watched: false };
          n += 1;
          if (kind.watched) k += 1;
          byKind[kind.label] = (byKind[kind.label] || 0) + 1;
        });
      });
      view.problem({ n: n, k: k, v: vaults, usd: usd, byKind: byKind, at: t });
    } catch (e) {
      console.warn('[notice-period] Morpho count unavailable:', e && e.message);
      view.problemFailed(loadMorpho);
    }
  }

  /* ---------- replay and #run=N ---------- */

  function playable() { return data.runs.filter(function (r) { return r.r1 && r.r2 && r.r3; }); }

  function replayFlow(pick) {
    return async function (my) {
      await Promise.race([data.ready, rpc.sleep(1500)]);
      alive(my);
      var list = playable();
      if (!list.length) list = NP.recorded.runs.slice();
      var run = typeof pick === 'number' ? list.filter(function (r) { return r.id === pick; })[0] : null;
      if (pick === 'next') run = list[(S.replayIndex + 1) % list.length];
      if (!run) run = latestNow(list) || list[0];
      S.replayIndex = Math.max(0, list.indexOf(run));
      return replay(my, run);
    };
  }

  async function replay(my, run) {
    var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var deadline = run.mode === 1;
    var m = { t1: run.r1.ts, t2: run.r2.ts, t3: run.r3.ts, execAt: run.execAt, h1: run.r1.hash, h2: run.r2.hash, h3: run.r3.hash, stage: 1 };
    if (deadline) { m.wait2 = copy.rec2WaitTimer; m.wait3 = copy.rec3WaitTimer; }
    var d2 = fmt.sec(run.r2.ts, run.r1.ts), d3 = fmt.sec(run.r3.ts, run.r1.ts);
    /* A long wait is played back faster, and the screen says so. */
    var speed = d3 > T.replayLong ? d3 / T.replayPlay : 1;
    var ctx = { id: run.id, date: fmt.date(run.r1.ts), check: run.checked ? copy.checkOk : copy.checking, model: m,
      modeLine: deadline ? view.fillText(copy.replayDeadline, { s: d2, left: Math.max(0, run.execAt - run.r3.ts) }) : '',
      fastLine: speed > 1 && !reduced ? view.fillText(copy.replayFast, { s: d2, play: T.replayPlay }) : '' };
    S.started = false;
    S.step = null;
    if (reduced) m.stage = 3;
    /* the address never names another run than the one on screen */
    if (parseHash() !== null && parseHash() !== run.id) writeHash(run.id, true);
    go('replay', ctx);
    var t0 = now();
    while (m.stage < 3) {
      await rpc.sleep(200);
      alive(my);
      var el = (now() - t0) / 1000 * speed;
      m.elapsed = Math.floor(el);
      m.stage = el >= d3 + 0.4 * speed ? 3 : (el >= d2 + 0.4 * speed ? 2 : 1);
      view.tickStrip(m);
    }
    var ok = run.checked;
    if (!ok) {
      try { await readRun(run.id, run.r1.hash, run.r2.hash, run.r3.hash); ok = true; } catch (e) { ok = false; }
      alive(my);
    }
    ctx.check = ok ? copy.checkOk : view.fillText(copy.checkFail, { date: fmt.isoDate(NP.recorded.readAt) });
    go('replay', ctx);
  }

  function parseHash() { var m = /^#run=(\d{1,9})$/.exec(window.location.hash); return m ? Number(m[1]) : null; }

  function writeHash(id, force) {
    var h = window.location.hash;
    var mine = '#run=' + id;
    if (!force && h && h !== S.processedHash && parseHash() !== null) return; /* an address from outside that is not processed yet */
    try { window.history.replaceState(null, '', mine); S.processedHash = mine; } catch (e) { /* file pages may refuse */ }
  }

  function openRunFlow(n) {
    return async function (my) {
      S.processedHash = '#run=' + n;
      S.started = false;
      S.step = null;
      go('reading-run', { id: n });
      var find = function () {
        return playable().concat(NP.recorded.runs).filter(function (r) { return r.id === n && r.r1 && r.r2 && r.r3; })[0];
      };
      /* The recorded copy is already in the page: a slow endpoint does not hold the replay back. */
      await Promise.race([data.ready, rpc.sleep(1500)]);
      alive(my);
      var run = find();
      if (!run) { await data.ready; alive(my); run = find(); }
      if (run) {
        S.replayIndex = Math.max(0, playable().map(function (r) { return r.id; }).indexOf(n));
        return replay(my, run);
      }
      if (data.next === null) data.next = Number(BigInt(await rpc.ethCall('base', C.exit, enc.noArg('nextWatchId()'))));
      alive(my);
      if (n < 1 || n >= data.next) throw stop('run-not-yet', { id: n, max: Math.max(0, data.next - 1), hasRuns: data.next > 1 });
      var w = dec.watchOf(await rpc.ethCall('base', C.exit, enc.oneUint('watchOf(uint256)', n)));
      throw stop('run-too-old', { id: n, state: view.STATUS[w.status] || 'unknown', date: fmt.isoDate(NP.recorded.readAt) });
    };
  }

  function midRun() {
    return S.started && ['returned', 'ignored', 'nothing-to-redeem', 'watch-off', 'withdrawn-by-hand', 'step-deposit', 'resume'].indexOf(S.id) < 0;
  }

  /* ---------- actions ---------- */

  function copyText(text, button, done) {
    var finish = function (ok) {
      if (button) { button.disabled = false; if (ok) button.textContent = 'Copied'; }
      view.announce(ok ? 'Copied' : copy.copyFailed);
      if (!ok && button && button.parentNode && !button.parentNode.querySelector('.copy-box')) {
        button.parentNode.appendChild(view.el('p', 'small copy-note', copy.copyFailed));
        var box = view.el('input', 'copy-box');
        box.type = 'text';
        box.readOnly = true;
        box.value = text;
        box.setAttribute('aria-label', 'Text to copy');
        button.parentNode.appendChild(box);
        box.focus();
        box.select();
      }
      if (done) done();
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { finish(true); }, function () { finish(false); });
    else finish(false);
  }

  function pageUrl(hash) { return String(window.location.href).split('#')[0] + (hash || ''); }

  function act(a, ctx, button) {
    switch (a) {
      case 'connect': return runFlow(connectFlow());
      case 'pick-wallet': return runFlow(connectFlow(ctx.id));
      case 'unsupported': return go('unsupported-wallet');
      case 'recheck-wallet':
        return runFlow(async function (my) {
          var list = await wallet.discover();
          alive(my);
          view.ctaOrder(!list.length);
          if (list.length) return go('idle');
          go(noWalletState(), { note: copy.stillNoWallet });
          view.announce(copy.stillNoWallet);
        }, false);
      case 'replay': return runFlow(replayFlow(), false);
      case 'replay-next': return runFlow(replayFlow('next'), false);
      case 'retry': return runFlow(S.last || preflight);
      case 'continue': return runFlow(S.id === 'resume' ? continueFrom : (S.last || preflight), S.id !== 'resume' ? undefined : false);
      case 'switch':
        return runFlow(async function (my) {
          try { await wallet.switchToBase(); } catch (e) {
            alive(my);
            if (e.code === -32002) throw stop('wallet-busy');
            throw stop('switch-refused');
          }
          var cid = await wallet.chainId();
          alive(my);
          if (cid !== BASE.hex) throw stop('switch-refused');
          return preflight(my);
        }, false);
      case 'deposit': return runFlow(doDeposit);
      case 'arm': return runFlow(doArm);
      case 'schedule-1': return runFlow(scheduleFlow(1));
      case 'schedule-2': return runFlow(scheduleFlow(2));
      case 'schedule-4': return runFlow(scheduleFlow(4));
      case 'schedule-8': return runFlow(scheduleFlow(8));
      case 'keep-waiting':
        return runFlow(async function (my) {
          var r = S.run || {};
          /* without the run's own records in memory, re-read the chain instead */
          if (!S.shared.id || (S.id === 'subscribe-slow' ? r.lasnaFrom === undefined : !r.r1)) return continueFrom(my);
          if (S.id === 'subscribe-slow') { go('armed-subscribing'); return watchSubscription(my); }
          if (r.r2) r.shift2 = (now() - r.seen2) / 1000; else r.shift = (now() - r.seen1) / 1000;
          showWait();
          return watchRecords(my);
        }, false);
      case 'withdraw': return runFlow(recoverFlow(['withdraw']));
      case 'withdraw-restart': return runFlow(recoverFlow(['withdraw', 'cancel'], 'restart'));
      case 'cancel': return runFlow(recoverFlow(['cancel']));
      case 'cancel-withdraw': return runFlow(recoverFlow(['cancel', 'withdraw']));
      case 'remove-allowance':
        if (S.id === 'returned') S.returnedCtx = S.ctx;
        return runFlow(recoverFlow(['allowance'], S.id === 'returned' ? 'returned' : null));
      case 'again':
      case 'restart':
        S.me = wallet.account() || S.me;
        S.started = false;
        S.step = null;
        S.shared = {};
        S.run = {};
        S.kinds = 7;
        S.tampers = 0;
        return runFlow(preflight);
      case 'open-latest': window.location.hash = '#run=' + ctx.max; return;
      case 'copy-link': return copyText(pageUrl(), button, function () { view.enableActions(); });
      case 'copy-run': return copyText(pageUrl('#run=' + S.shared.id), button, function () { view.enableActions(); });
      case 'copy-text': return copyText(ctx.text, ctx.button);
      case 'kinds':
        S.kinds = ctx.on ? (S.kinds | ctx.bit) : (S.kinds & ~ctx.bit);
        view.setKindsWarn(S.kinds ? '' : copy.kindsNone);
        return;
      default: view.enableActions();
    }
  }

  /* ---------- boot ---------- */

  function toPanel() {
    var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var target = view.$('try');
    target.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'start' });
    try { view.$('state').focus({ preventScroll: true }); } catch (e) { /* older browsers scroll on focus */ }
  }

  function boot() {
    view.onAction(act);
    view.$('cta-try').addEventListener('click', function (ev) { ev.preventDefault(); toPanel(); if (!midRun()) act('connect'); });
    view.$('cta-replay').addEventListener('click', function (ev) { ev.preventDefault(); toPanel(); if (!midRun()) act('replay'); });
    window.addEventListener('hashchange', function () {
      var n = parseHash();
      if (n === null || midRun()) return;
      toPanel();
      runFlow(openRunFlow(n), false);
    });
    /* A run link whose address is already in the bar changes nothing by itself: replay it on the click. */
    document.addEventListener('click', function (ev) {
      var a = ev.target && ev.target.closest ? ev.target.closest('a[href^="#run="]') : null;
      if (!a || a.getAttribute('href') !== window.location.hash || midRun()) return;
      var n = parseHash();
      if (n === null) return;
      ev.preventDefault();
      toPanel();
      runFlow(openRunFlow(n), false);
    });
    wallet.onAccounts(function (next) {
      if (S.id === 'account-changed') {
        S.me = next;
        if (next && same(next, S.owner)) runFlow(preflight);
        return;
      }
      if (!S.me || same(next, S.me)) return;
      if (!S.started) {
        S.me = next;
        if (next && ['no-gas', 'checking', 'runs-used-up', 'address-used-up', 'resume', 'old-vault'].indexOf(S.id) >= 0) runFlow(preflight);
        return;
      }
      S.epoch += 1;
      S.owner = S.me;
      go('account-changed', { address: S.me });
      S.me = next;
    });
    wallet.onChain(function (id) {
      if (S.id === 'wrong-network' || S.id === 'switch-refused') { if (id === BASE.hex) runFlow(preflight); }
    });

    S.linked = parseHash(); /* before the first read, so the first screen draws the linked run */
    data.ready = loadChain();
    loadMorpho();

    if (framed) {
      view.ctaOrder(true);
      go('framed');
    } else {
      go('idle');
      wallet.discover().then(function (list) {
        view.ctaOrder(!list.length);
        if (!list.length) { if (S.id === 'idle') go(noWalletState()); return; }
        if (list.length !== 1 || S.id !== 'idle') return;
        /* No popup: a wallet that already shares an address with this page lets a reload resume. */
        wallet.silent(list[0].id).then(function (acct) {
          if (!acct || S.id !== 'idle') return;
          S.me = acct;
          runFlow(async function (my) {
            var pos = null;
            try {
              var cid = await wallet.chainId();
              if (cid === BASE.hex) pos = await readPosition();
            } catch (e) { pos = null; }
            alive(my);
            if (pos && (S.shared.hasWatch || pos.shares > 0n)) { S.last = preflight; return preflight(my); }
          }, false);
        });
      });
    }
    /* A run named in the address is replayed in the panel and drawn on the first screen. No scroll on load. */
    if (S.linked !== null) runFlow(openRunFlow(S.linked), false);
  }

  NP.run = { boot: boot, act: act, go: go, state: S, data: data, readRun: readRun, loadChain: loadChain };
  boot();
}());
