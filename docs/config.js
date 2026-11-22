/* Notice Period page: every address, endpoint, limit and flag in one place.
   Addresses are those of the testnet deployment of 18 Nov 2026 and change with a redeploy. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};

  NP.config = {
    chains: {
      base: {
        key: 'base',
        id: 84532,
        hex: '0x14a34',
        name: 'Base Sepolia',
        currency: 'ETH',
        /* maxRange: the eth_getLogs block range this page asks of each public endpoint. Measured limits: 50,000 on
           the first, 200 on the second (100 keeps a margin). */
        endpoints: [
          { url: 'https://base-sepolia-rpc.publicnode.com', maxRange: 50000 },
          { url: 'https://sepolia.base.org', maxRange: 100 }
        ],
        walletRpc: 'https://sepolia.base.org',
        explorer: 'https://base-sepolia.blockscout.com',
        txUrl: 'https://base-sepolia.blockscout.com/tx/',
        addressUrl: 'https://base-sepolia.blockscout.com/address/'
      },
      lasna: {
        key: 'lasna',
        id: 5318007,
        hex: '0x512577',
        name: 'Reactive Lasna',
        currency: 'lREACT',
        endpoints: [
          { url: 'https://lasna-rpc.rnk.dev/', maxRange: 30000 }
        ],
        explorer: 'https://lasna.reactscan.net',
        txUrl: 'https://lasna.reactscan.net/tx/',
        addressUrl: 'https://lasna.reactscan.net/address/'
      }
    },

    contracts: {
      token: '0x2690DF70a37939c582a800f32FFEE52ec40d150B',
      factory: '0xFFc96A898AF31e2ED652A8A0C0E90584999093CD',
      exit: '0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8',
      callbackProxy: '0x476F44b11F5C942c58f4c8E3d0300E5710743585',
      reactive: '0x00E4996c7255B919B619902E1Ac4b254D3c3f014',
      system: '0x8888888888888888888888888888888888888888'
    },
    /* Our own accounts: runs they sent are labelled "Our own test run". operator is the first (the testnet key);
       the second is the key derived from it for runs that need a second depositor (scripts/loop-system.sh). */
    operators: ['0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4', '0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19'],
    operator: '0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4',

    token: { symbol: 'npUSD', decimals: 6 },
    amounts: {
      deposit: '100000000',            /* 100 npUSD, 6 decimals */
      capIncrease: '1000000000000',    /* the demo cap a "cap increase" schedules */
      minGasWei: '30000000000000',     /* 0.00003 ETH asked before the run starts */
      floatMinWei: '500000000000000000', /* 0.5 lREACT in the reactive contract */
      exitMinWei: '500000000000000'    /* 0.0005 ETH in the exit contract */
    },

    /* Kinds a watch can cover (bit mask, SPEC section 3). DEFAULT = 7. */
    kinds: [
      { bit: 1, on: true, label: 'A new adapter (where the vault may send funds)', short: 'New adapter', a: 'a new adapter' },
      { bit: 2, on: true, label: 'A shorter waiting period', short: 'Shorter waiting period', a: 'a shorter waiting period' },
      { bit: 4, on: true, label: 'A new allocator (who may move funds)', short: 'New allocator', a: 'a new allocator' },
      { bit: 8, on: false, label: 'A cap increase (routine, by far the most common)', short: 'Cap increase', a: 'a cap increase' }
    ],

    /* Seconds. All measured on the recorded runs; see the rule book, section 12. */
    timing: {
      walletDiscoveryMs: 400,
      settleAfterSubscribed: 20,
      subscribeSlow: 60,
      reactiveSlow: 20,
      ignoredAfter: 20,
      missedAfter: 45,
      reactiveTimeout: 90,
      callbackSlow: 90,
      receiptSlow: 30,
      pollMs: 1000,
      medianFromRuns: 5,
      /* A replay whose wait is longer than replayLong seconds is played back in replayPlay seconds, and says so. */
      replayLong: 12,
      replayPlay: 8
    },

    /* How far back the browser can search for runs: three windows of the Lasna log limit (about 27 hours).
       baseVaultWindow: 50,000 Base Sepolia blocks, about 2 h 47 min at 5 blocks a second. An older vault is not reused. */
    scan: { lasnaWindows: 3, baseVaultWindow: 50000, maxRunsListed: 20 },

    flags: {
      /* "Leave only if it is still scheduled near the end" is built in the contracts and switched off on this page. */
      mode1: false,
      /* As the curator, this page schedules every kind the watch can cover. A new adapter, a shorter waiting period,
         a new allocator and (on a watch that covers it) a cap increase have each returned a deposit on the live
         contracts (recorded runs 1, 3, 4 and 7). Off, the page
         offers only a new adapter and, while the watch does not cover it, a cap increase (nothing should move). */
      unprovenKinds: true
    },

    morpho: {
      url: 'https://api.morpho.org/graphql',
      query: '{ vaultV2s(first: 1000, where: {listed: true}) { pageInfo { countTotal } items { address totalAssetsUsd chain { id } pendingConfigs(first: 200) { items { functionName validAt txHash } } } } }',
      kinds: {
        AddAdapter: { label: 'new adapter', watched: true },
        DecreaseTimelock: { label: 'shorter waiting period', watched: true },
        SetIsAllocator: { label: 'new allocator', watched: true },
        IncreaseAbsoluteCap: { label: 'cap increase', watched: false },
        IncreaseRelativeCap: { label: 'cap increase', watched: false }
      },
      /* Shown, with its date, only when the live read fails. */
      snapshot: { date: '21 Nov 2026', changes: 35, vaults: 9, usd: 85909014, capIncreases: 32, shorter: 3 }
    },

    links: {
      repo: 'https://github.com/bongbongcrypto/notice-period',
      ruleBook: 'https://github.com/bongbongcrypto/notice-period/blob/main/SPEC.md',
      contracts: 'https://github.com/bongbongcrypto/notice-period/tree/main/src',
      faucets: 'https://docs.base.org/base-chain/tools/network-faucets'
    }
  };

  /* True for one of our own accounts. */
  NP.config.isOurs = function (address) {
    var a = String(address || '').toLowerCase();
    return NP.config.operators.some(function (o) { return o.toLowerCase() === a; });
  };
}());
