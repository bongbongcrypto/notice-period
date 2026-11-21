/* Browser wallet access, hand-written: EIP-6963 discovery with window.ethereum as the fallback, EIP-1193 requests.
   Nothing is requested on load except a silent eth_accounts. No message signing, no typed data. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  var cfg = NP.config;
  var providers = [];
  var active = null;
  var account = null;
  var listeners = { accounts: [], chain: [] };

  function onAnnounce(ev) {
    var d = ev && ev.detail;
    if (!d || !d.provider || !d.info) return;
    var id = String(d.info.uuid || d.info.rdns || d.info.name || providers.length);
    if (providers.some(function (p) { return p.id === id || p.provider === d.provider; })) return;
    var icon = typeof d.info.icon === 'string' && /^data:image\//.test(d.info.icon) ? d.info.icon : '';
    providers.push({ id: id, name: String(d.info.name || 'Wallet').slice(0, 40), icon: icon, provider: d.provider });
  }

  /* Resolves the list of wallets after the discovery window. Safe to call again ("Check again"). */
  function discover() {
    window.removeEventListener('eip6963:announceProvider', onAnnounce);
    window.addEventListener('eip6963:announceProvider', onAnnounce);
    try { window.dispatchEvent(new Event('eip6963:requestProvider')); } catch (e) { /* old browser */ }
    return new Promise(function (resolve) {
      setTimeout(function () {
        if (!providers.length && window.ethereum && typeof window.ethereum.request === 'function') {
          providers.push({ id: 'injected', name: 'Browser wallet', icon: '', provider: window.ethereum });
        }
        resolve(providers.slice());
      }, cfg.timing.walletDiscoveryMs);
    });
  }

  function norm(err) {
    var e = new Error(String((err && err.message) || 'Wallet error').slice(0, 300));
    e.wallet = true;
    e.code = err && typeof err.code === 'number' ? err.code : (err && err.code ? Number(err.code) : 0);
    if (err && err.data && err.data.originalError && err.data.originalError.code) e.inner = err.data.originalError.code;
    return e;
  }

  function request(method, params) {
    if (!active) return Promise.reject(norm({ message: 'No wallet connected' }));
    try {
      return Promise.resolve(active.provider.request({ method: method, params: params || [] })).catch(function (err) {
        throw norm(err);
      });
    } catch (err) { return Promise.reject(norm(err)); }
  }

  function bind(p) {
    if (p.bound || typeof p.provider.on !== 'function') return;
    p.bound = true;
    p.provider.on('accountsChanged', function (list) {
      if (active !== p) return;
      var next = list && list[0] ? String(list[0]).toLowerCase() : null;
      var prev = account;
      account = next;
      listeners.accounts.forEach(function (f) { f(next, prev); });
    });
    p.provider.on('chainChanged', function (id) {
      if (active !== p) return;
      listeners.chain.forEach(function (f) { f(String(id).toLowerCase()); });
    });
    p.provider.on('disconnect', function () {
      if (active !== p) return;
      var prev = account;
      account = null;
      listeners.accounts.forEach(function (f) { f(null, prev); });
    });
  }

  function use(id) {
    active = providers.filter(function (p) { return p.id === id; })[0] || null;
    if (active) bind(active);
    return active;
  }

  /* Opens the wallet's connection request. Shares only the address. */
  function connect(id) {
    if (!use(id)) return Promise.reject(norm({ message: 'Wallet not found' }));
    return request('eth_requestAccounts').then(function (list) {
      if (!list || !list[0]) throw norm({ message: 'The wallet returned no account' });
      account = String(list[0]).toLowerCase();
      return account;
    });
  }

  /* No popup: asks an already connected wallet which account it shares with this page. */
  function silent(id) {
    if (!use(id)) return Promise.resolve(null);
    return request('eth_accounts').then(function (list) {
      account = list && list[0] ? String(list[0]).toLowerCase() : null;
      return account;
    }, function () { return null; });
  }

  function chainId() {
    return request('eth_chainId').then(function (id) { return String(id).toLowerCase(); });
  }

  function switchToBase() {
    var c = cfg.chains.base;
    return request('wallet_switchEthereumChain', [{ chainId: c.hex }]).catch(function (err) {
      if (err.code === 4902 || err.inner === 4902 || /unrecognized|not been added|unknown chain/i.test(err.message)) {
        return request('wallet_addEthereumChain', [{
          chainId: c.hex,
          chainName: c.name,
          nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
          rpcUrls: [c.walletRpc],
          blockExplorerUrls: [c.explorer]
        }]);
      }
      throw err;
    });
  }

  function send(from, to, data) {
    return request('eth_sendTransaction', [{ from: from, to: to, data: data, value: '0x0' }]);
  }

  NP.wallet = {
    discover: discover, connect: connect, silent: silent, chainId: chainId, switchToBase: switchToBase, send: send,
    list: function () { return providers.slice(); },
    account: function () { return account; },
    hasActive: function () { return !!active; },
    onAccounts: function (f) { listeners.accounts.push(f); },
    onChain: function (f) { listeners.chain.push(f); }
  };
}());
