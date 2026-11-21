/* Hand-written ABI encoding and decoding for the few calls and events this page uses.
   Selectors and topics come from sig.js. Everything is hex strings and BigInt. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  var sig = NP.sig;

  function strip(h) { return (h || '').replace(/^0x/, ''); }
  function word(n) { return BigInt(n).toString(16).padStart(64, '0'); }
  function addrWord(a) {
    var h = strip(a).toLowerCase();
    if (!/^[0-9a-f]{40}$/.test(h)) throw new Error('bad address');
    return h.padStart(64, '0');
  }
  function bytesTail(hex) {
    var h = strip(hex);
    var len = h.length / 2;
    var padded = h + '0'.repeat((64 - (h.length % 64)) % 64);
    return word(len) + padded;
  }
  function fn(name) {
    var s = sig.fn[name];
    if (!s) throw new Error('unknown function ' + name);
    return s;
  }

  var enc = {
    create: function () { return fn('create()'); },
    mint: function (to, amount) { return fn('mint(address,uint256)') + addrWord(to) + word(amount); },
    approve: function (spender, amount) { return fn('approve(address,uint256)') + addrWord(spender) + word(amount); },
    deposit: function (assets, receiver) { return fn('deposit(uint256,address)') + word(assets) + addrWord(receiver); },
    arm: function (vault, kinds, mode, maxShares) {
      return fn('arm(address,uint8,uint8,uint256)') + addrWord(vault) + word(kinds) + word(mode) + word(maxShares);
    },
    /* submit(bytes): selector, offset 0x20, length, data padded to 32 bytes */
    submit: function (inner) { return fn('submit(bytes)') + word(32) + bytesTail(inner); },
    executableAt: function (inner) { return fn('executableAt(bytes)') + word(32) + bytesTail(inner); },
    addAdapter: function (account) { return fn('addAdapter(address)') + addrWord(account); },
    /* increaseAbsoluteCap(bytes idData, uint256 cap): offset 0x40, cap, then the bytes */
    increaseAbsoluteCap: function (idData, cap) {
      return fn('increaseAbsoluteCap(bytes,uint256)') + word(64) + word(cap) + bytesTail(idData);
    },
    redeem: function (shares, receiver, owner) {
      return fn('redeem(uint256,address,address)') + word(shares) + addrWord(receiver) + addrWord(owner);
    },
    cancel: function (id) { return fn('cancel(uint256)') + word(id); },
    /* reads */
    noArg: function (name) { return fn(name); },
    oneAddr: function (name, a) { return fn(name) + addrWord(a); },
    oneUint: function (name, n) { return fn(name) + word(n); },
    twoAddr: function (name, a, b) { return fn(name) + addrWord(a) + addrWord(b); },
    addrUint: function (name, a, n) { return fn(name) + addrWord(a) + word(n); }
  };

  function wordAt(data, i) {
    var h = strip(data);
    var w = h.slice(64 * i, 64 * i + 64);
    if (w.length !== 64) throw new Error('short data');
    return w;
  }
  function big(data, i) { return BigInt('0x' + wordAt(data, i || 0)); }
  function num(data, i) { return Number(big(data, i)); }
  function addr(data, i) { return '0x' + wordAt(data, i || 0).slice(24); }
  function topicAddr(t) { return '0x' + strip(t).slice(24); }
  function topicNum(t) { return Number(BigInt(t)); }
  function bytesAt(data, i) {
    var h = strip(data);
    var off = Number(big(data, i)) * 2;
    var len = Number(BigInt('0x' + h.slice(off, off + 64)));
    return '0x' + h.slice(off + 64, off + 64 + len * 2);
  }

  var dec = {
    big: big, num: num, addr: addr, topicAddr: topicAddr, topicNum: topicNum, bytesAt: bytesAt,
    /* WatchArmed(uint256 indexed watchId, address indexed owner, address indexed vault, uint8 kinds, uint8 mode, uint256 maxShares) */
    watchArmed: function (log) {
      return { watchId: topicNum(log.topics[1]), owner: topicAddr(log.topics[2]), vault: topicAddr(log.topics[3]),
        kinds: num(log.data, 0), mode: num(log.data, 1), maxShares: big(log.data, 2) };
    },
    /* Submit(bytes4 indexed selector, bytes data, uint256 executableAt) */
    submit: function (log) {
      return { selector: log.topics[1].slice(0, 10), data: bytesAt(log.data, 0), executableAt: num(log.data, 1) };
    },
    /* ExitRequested(uint256 indexed watchId, uint256 indexed originTxHash, uint8 reason, bytes32 dataHash) */
    exitRequested: function (log) {
      return { watchId: topicNum(log.topics[1]), originTxHash: log.topics[2], reason: num(log.data, 0),
        dataHash: '0x' + wordAt(log.data, 1) };
    },
    /* WatchEnded(uint256 indexed watchId, uint256 indexed originTxHash, uint8 outcome, uint8 reason, uint256 shares, uint256 assets) */
    watchEnded: function (log) {
      return { watchId: topicNum(log.topics[1]), originTxHash: log.topics[2], outcome: num(log.data, 0),
        reason: num(log.data, 1), shares: big(log.data, 2), assets: big(log.data, 3) };
    },
    /* watchOf(uint256): owner, kinds, mode, status, vault, maxShares */
    watchOf: function (data) {
      return { owner: addr(data, 0), kinds: num(data, 1), mode: num(data, 2), status: num(data, 3),
        vault: addr(data, 4), maxShares: big(data, 5) };
    },
    /* NoticeReactive.watches(uint256): vault, kinds, mode, status, pendingCount, reactions */
    lasnaWatch: function (data) {
      return { vault: addr(data, 0), kinds: num(data, 1), mode: num(data, 2), status: num(data, 3) };
    }
  };

  /* Contract errors turned into sentences. The name is shown small, after the sentence. */
  var ERR_TEXT = {
    'DailyCapReached()': "Today's live runs are used up",
    'DailyCapForAddress()': 'This address has used its runs for today',
    'AlreadyWatching(uint256)': 'This address already has a watch on this vault',
    'NoShares()': 'This address holds no shares of the vault',
    'NoAllowance()': 'The exit contract is not allowed to redeem any shares yet',
    'UnknownVault(address)': 'The exit contract does not know this vault',
    'WatchNotActive(uint256)': 'This watch is not on any more',
    'NotWatchOwner()': 'This watch belongs to another address',
    'DataAlreadyPending()': 'The same change is already scheduled',
    'Unauthorized()': 'Only the curator of this vault can do that',
    'InsufficientBalance()': 'The balance is too low for this step',
    'InsufficientAllowance()': 'The allowance is too low for this step',
    'ZeroShares()': 'The deposit would mint no shares',
    'ZeroAssets()': 'There is nothing to pay out',
    'MintTooLarge(uint256,uint256)': 'The demo token mints at most 1,000 per call',
    'NoKinds()': 'No kind of change is selected',
    'Reentrancy()': 'The contract is busy with another call',
    'TransferFailed()': 'The token transfer failed',
    'ZeroAddress()': 'The receiver address is empty'
  };

  function decodeError(data) {
    var h = strip(data);
    if (h.length < 8) return { name: '', text: 'The call reverted without a reason' };
    var s = '0x' + h.slice(0, 8).toLowerCase();
    var name = '';
    Object.keys(sig.err).forEach(function (k) { if (sig.err[k] === s) name = k; });
    if (name === 'Error(string)') {
      try {
        var hexStr = strip(bytesAt('0x' + h.slice(8), 0));
        var out = '';
        for (var i = 0; i < hexStr.length; i += 2) out += String.fromCharCode(parseInt(hexStr.slice(i, i + 2), 16));
        return { name: 'Error', text: out.replace(/[^\x20-\x7e]/g, '?') };
      } catch (e) { return { name: 'Error', text: 'The call reverted' }; }
    }
    if (name === 'Panic(uint256)') return { name: 'Panic', text: 'The contract hit an internal check' };
    if (!name) return { name: s, text: 'The call reverted' };
    return { name: name.replace(/\(.*$/, ''), sig: name, text: ERR_TEXT[name] || 'The contract refused the call' };
  }

  function randomHex(bytes) {
    var a = new Uint8Array(bytes);
    window.crypto.getRandomValues(a);
    var s = '';
    for (var i = 0; i < a.length; i++) s += a[i].toString(16).padStart(2, '0');
    return '0x' + s;
  }

  NP.abi = { enc: enc, dec: dec, decodeError: decodeError, word: word, addrWord: addrWord, randomHex: randomHex, strip: strip };
}());
