/* Notice Period page: every endpoint, limit and flag in one place. The addresses, our own accounts and the
   deployment's rules come from data/deployment.js (window.NP_DEPLOYMENT), which scripts/stamp.py writes from
   deployments/<name>.json; a redeploy changes that file only. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  var D = window.NP_DEPLOYMENT;
  if (!D || !D.contracts || !D.operators || !D.operators.length || !D.values) throw new Error('data/deployment.js did not load');
  var vaultSource = (D.rules && D.rules.vaultSource) || (D.contracts.maker ? 'maker' : 'demo');

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
      token: D.contracts.token,
      /* The vault source: the maker of Morpho Vault V2s (create(), lastVaultOf(address), TIMELOCK(), isVault(address)
         and VaultCreated(vault, curator)), or our demo vault factory on the 18 Nov 2026 deployment (same calls). */
      factory: vaultSource === 'maker' ? D.contracts.maker : D.contracts.factory,
      morphoFactory: D.contracts.morphoFactory || null,
      exit: D.contracts.exit,
      callbackProxy: D.contracts.callbackProxy,
      reactive: D.contracts.reactive,
      system: '0x8888888888888888888888888888888888888888'
    },
    /* Our own accounts: runs they sent are labelled "Our own test run". operator is the first (the testnet key);
       the second is the key derived from it for runs that need a second depositor (scripts/loop-system.sh). */
    operators: D.operators.slice(),
    operator: D.operators[0],
    /* What this deployment's contracts do, for the page's words: the vault source, whether a "leave now" watch ends
       after LIFETIME seconds (the 18 Nov 2026 contracts) or only a timer watch can be ended then (22 Nov 2026), and
       the deployed values (the page reads the live caps from the chain; these are for the words and the fallbacks). */
    deployment: {
      name: D.name,
      vaultSource: vaultSource,
      lifetime: D.values.LIFETIME,
      leaveNowExpires: D.rules ? D.rules.leaveNowExpires !== false : true,
      values: D.values
    },

    token: { symbol: 'npUSD', decimals: 6 },
    amounts: {
      deposit: '100000000',            /* 100 npUSD, 6 decimals */
      capIncrease: '1000000000000',    /* the demo cap a "cap increase" schedules */
      /* Test ETH asked before the run starts. Gas limits of our first loop on these contracts (22 Nov 2026, the seven
         transactions of the guided run): vault create 5,321,160 (the larger of two creates), mint 69,158, approve
         46,497, deposit 134,755, share approve 46,354, arm 235,035, submit 54,598; 5,907,557 in all. A wallet checks
         gas limit times its maximum fee, so the sum is priced at 0.02 gwei, more than three times the 0.006 gwei paid
         then: 5,907,557 x 0.02 gwei = 0.000118 ETH, asked as 0.00012. Without the create, 586,397 x 0.02 gwei =
         0.0000117 ETH, asked as 0.000015. The loop's seven transactions used 5,606,449 gas (5,657,749 with the larger
         create), about 0.000034 ETH at 0.006 gwei: typicalEth below. */
      minGasWei: '120000000000000',
      minGasStepWei: '15000000000000',
      typicalEth: '0.00004',
      floatMinWei: '500000000000000000', /* 0.5 lREACT in the reactive contract */
      exitMinWei: '500000000000000',   /* 0.0005 ETH in the exit contract */
      /* A vault whose shares, priced by its own previewDeposit and previewRedeem, would pay back less than this share
         of the deposit is refused before the deposit and reported after it. One unit of rounding is not a refusal. */
      fairPercent: 99
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
      /* As the curator, this page schedules every kind the watch can cover. Each is one our maker gave its waiting
         period (TIMELOCK, 180 s): a new adapter, a new allocator and a cap increase directly, and a shorter waiting
         period because it waits as long as the action it shortens, which is always one of those (run.js changeFor).
         All four have returned a deposit from our loop on the live contracts (a new adapter, a shorter waiting
         period and a new allocator on the 22 Nov 2026 pair; a cap increase on the 18 Nov 2026 pair). Off, the page
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
