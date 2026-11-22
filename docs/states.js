/* Every state of the guided run as data: headline, body, actions. One renderer (view.js) draws them all.
   {name} is a live value; {tx.base.name} and {tx.lasna.name} are transaction links.
   step: 0 before, 1 deposit, 2 watch, 3 curator, 4 result. kind: wait (no button needed), stop (needs a decision),
   done (a result), plain. A body line written as { t, when } shows only when that live flag is set.
   actions may be a function of the live values: the curator buttons follow the kinds the watch covers. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};

  var REPLAY = { a: 'replay', label: 'Replay a real run' };
  var REPLAY_INSTEAD = { a: 'replay', label: 'Replay a real run instead' };
  var WITHDRAW_NOW = { a: 'withdraw', label: 'Withdraw my deposit now' };
  var WITHDRAW_IF = { a: 'withdraw', label: 'Withdraw my deposit now', when: 'hasDeposit' };
  var STILL_IN = { t: 'Your 100 demo dollars are still in your vault. You can take them out now.', when: 'hasDeposit' };
  /* The vault source of this deployment (config.js): a Morpho Vault V2 made through our maker, or our demo vault. */
  var V2 = NP.config.deployment.vaultSource === 'maker';
  /* How long a watch that can expire lasts, in words (the deployment's LIFETIME). */
  var LIFE = (function (s) {
    if (s % 86400 === 0) return s === 86400 ? 'one day' : (s / 86400) + ' days';
    return Math.round(s / 3600) + ' hours';
  }(NP.config.deployment.lifetime));

  /* The kinds of change this page schedules as the curator. With flags.unprovenKinds off: a new adapter, and a cap
     increase only while the watch does not cover it (the case where nothing should move). */
  NP.playable = function (kinds) {
    var K = NP.config.kinds;
    if (NP.config.flags.unprovenKinds) return K;
    return K.filter(function (k) { return k.bit === 1 || (k.bit === 8 && (kinds & 8) === 0); });
  };
  /* Those kinds, split by what this watch covers. */
  function split(ctx) {
    var kinds = ctx.kinds || 0;
    var K = NP.playable(kinds);
    return { all: K, covered: K.filter(function (k) { return (kinds & k.bit) !== 0; }), rest: K.filter(function (k) { return (kinds & k.bit) === 0; }) };
  }
  /* Primary: a kind the watch covers. Second: one it does not cover (a cap increase when possible), to show that nothing moves. */
  function curatorPair(ctx) {
    var s = split(ctx);
    var first = s.covered[0] || s.all[0];
    var second = s.rest.filter(function (k) { return k.bit === 8; })[0] || s.rest[0] ||
      s.covered.filter(function (k) { return k !== first; }).slice(-1)[0] || null;
    return [first, second];
  }
  function curatorActions(off) {
    return function (ctx) {
      var pair = curatorPair(ctx);
      var out = [{ a: 'schedule-' + pair[0].bit, label: 'Schedule ' + pair[0].a, primary: true, off: off }];
      if (pair[1]) out.push({ a: 'schedule-' + pair[1].bit, label: 'Schedule ' + pair[1].a + ' instead', off: off });
      if (!off) out.push({ a: 'cancel', label: 'Turn the watch off', quiet: true });
      return out;
    };
  }
  /* One line per curator button: does this watch cover that kind. */
  NP.curatorHints = function (ctx) {
    return curatorPair(ctx).filter(Boolean).map(function (k) {
      return k.short + ': ' + (((ctx.kinds || 0) & k.bit) ? NP.copy.hintCovered : NP.copy.hintIgnored);
    });
  };
  function coveredNext(label) {
    return function (ctx) {
      var first = split(ctx).covered[0];
      var out = [];
      if (first) out.push({ a: 'schedule-' + first.bit, label: label.replace('{kindA}', first.a), primary: true });
      out.push({ a: 'cancel', label: 'Turn the watch off', primary: !first });
      out.push(WITHDRAW_NOW);
      return out;
    };
  }

  NP.states = {
    'idle': {
      step: 0, kind: 'plain', h: '',
      body: [],
      actions: [{ a: 'connect', label: 'Connect a wallet', primary: true }, REPLAY_INSTEAD]
    },
    'no-wallet': {
      step: 0, kind: 'stop', h: 'No browser wallet found',
      body: ['This page talks to a wallet extension such as MetaMask, Rabby or Coinbase Wallet. Without one you can still replay a real run: same contracts, same transactions, read from the chain.'],
      actions: [{ a: 'replay', label: 'Replay a real run', primary: true }, { a: 'recheck-wallet', label: 'Check again' },
        { a: 'unsupported', label: 'My wallet is not an extension', quiet: true }]
    },
    'no-wallet-phone': {
      step: 0, kind: 'stop', h: 'Open this page in a wallet app',
      body: ['On a phone, a wallet works inside its own browser. Copy this link and open it there. Or replay a real run here.'],
      actions: [{ a: 'copy-link', label: 'Copy link', primary: true }, REPLAY]
    },
    'unsupported-wallet': {
      step: 0, kind: 'stop', h: 'That kind of wallet is not supported here',
      body: ['Wallets that connect through WalletConnect or by email need a third-party script, and this page loads none. A browser extension wallet works. So does the replay.'],
      actions: [{ a: 'replay', label: 'Replay a real run', primary: true }]
    },
    'choose-wallet': {
      step: 0, kind: 'stop', h: 'Which wallet?',
      body: [], wallets: true,
      actions: [{ a: 'unsupported', label: 'My wallet is not listed', quiet: true }]
    },
    'connecting': {
      step: 0, kind: 'wait', h: 'Waiting for your wallet',
      body: ['Approve the connection in your wallet. This only shares your address.'],
      actions: []
    },
    'connect-rejected': {
      step: 0, kind: 'stop', h: 'You closed the wallet request',
      body: ['Nothing was sent.'],
      actions: [{ a: 'connect', label: 'Try again', primary: true }, REPLAY_INSTEAD]
    },
    'wallet-busy': {
      step: null, kind: 'stop', h: 'Your wallet already has a request open',
      body: ['Open the wallet and finish or reject it, then come back.'],
      actions: [{ a: 'retry', label: 'Try again', primary: true }]
    },
    'checking': {
      step: null, kind: 'wait', h: 'Reading your wallet’s state from the chain',
      body: ['Network, test ETH, today’s run counts and any deposit this address already has.'],
      actions: []
    },
    'wrong-network': {
      step: null, kind: 'stop', h: 'Your wallet is on another network',
      body: ['The vault is on Base Sepolia, a test network.'],
      actions: [{ a: 'switch', label: 'Switch to Base Sepolia', primary: true }]
    },
    'switch-refused': {
      step: null, kind: 'stop', h: 'Still on the other network',
      body: ['You can switch in the wallet yourself: Base Sepolia, chain ID 84532, RPC https://sepolia.base.org.'],
      actions: [{ a: 'retry', label: 'Check again', primary: true }, REPLAY_INSTEAD]
    },
    'no-gas': {
      step: null, kind: 'stop', h: 'Not enough test ETH for gas',
      body: ['The run needs about {typical} Base Sepolia ETH. This page asks for {need} before the next step, because a wallet checks each transaction against its highest possible fee. It is free from a faucet. This page cannot pay it for you: it has no server and no key.',
        'Your address: {address}'],
      copy: 'address',
      actions: [{ a: 'faucet', label: 'Open Base’s faucet list', href: 'faucets', primary: true },
        { a: 'retry', label: 'I have test ETH now' }, REPLAY_INSTEAD]
    },
    'runs-used-up': {
      step: null, kind: 'stop', h: 'Today’s {cap} live runs are used up',
      body: ['Reactive fees for this demo come from a small float, so it allows {cap} runs a day for everyone. The count resets at 00:00 UTC, in {h} h {m} min.', STILL_IN],
      actions: [{ a: 'replay', label: 'Replay a real run', primary: true }, WITHDRAW_IF]
    },
    'address-used-up': {
      step: null, kind: 'stop', h: 'This address has used its {cap} runs for today',
      body: ['The count resets at 00:00 UTC, in {h} h {m} min. Another address can still run.', STILL_IN],
      actions: [{ a: 'replay', label: 'Replay a real run', primary: true }, WITHDRAW_IF]
    },
    'slots-full': {
      step: null, kind: 'stop', h: 'All {slots} watch slots are taken right now',
      body: ['Every one of the {slots} watch slots is held by an open watch, ours included. A slot frees when a watch fires or is turned off{frees}.', STILL_IN],
      actions: [{ a: 'retry', label: 'Check again', primary: true }, REPLAY, WITHDRAW_IF]
    },
    'timer-full': {
      step: null, kind: 'stop', h: 'The timer mode is full right now',
      body: [{ t: 'Today’s {cap} new timer watches are used up. The count resets at 00:00 UTC, in {h} h {m} min.', when: 'today' },
        { t: 'All {cap} timer places are taken. One frees when a timer watch ends.', when: 'places' },
        'The timer mode is a demonstration and limited on purpose. “Leave now” has none of these limits.', STILL_IN],
      actions: [{ a: 'retry', label: 'Check again', primary: true }, REPLAY, WITHDRAW_IF]
    },
    'float-empty': {
      step: null, kind: 'stop', h: 'The demo is out of fee money',
      body: ['Reactive transactions for this demo are paid from our float, and right now it is too low or in debt (Reactive Lasna {x} lREACT, debt {dL}; exit reserve {y} ETH, debt {dB}). A watch turned on now might not fire. Recorded runs still play.', STILL_IN],
      actions: [{ a: 'replay', label: 'Replay a real run', primary: true }, WITHDRAW_IF]
    },
    'rpc-down': {
      step: null, kind: 'stop', h: 'Cannot reach {chain} right now',
      body: ['Tried {tried} twice. A failed read moves nothing: what is on the chain stays as it is.',
        { t: 'At the last read your deposit was in your vault.', when: 'hasDeposit' },
        { t: 'The recorded runs on this page still open.', when: 'noDeposit' }],
      actions: [{ a: 'retry', label: 'Try again', primary: true }, WITHDRAW_IF, { a: 'replay', label: 'Replay a real run', when: 'noDeposit' }]
    },
    'resume': {
      step: null, kind: 'stop', h: 'Welcome back',
      body: ['Your {what} from {time} is still there. Continue from step {step}.'],
      actions: [{ a: 'continue', label: 'Continue', primary: true }, { a: 'withdraw-restart', label: 'Withdraw my deposit and start over' }]
    },
    'old-vault': {
      step: 1, kind: 'stop', h: 'This vault is from an earlier visit',
      body: ['It was made more than about 3 hours ago, too long ago for this page to list its scheduled changes, so a watch on it could miss one. Take the deposit out and start with a fresh vault.'],
      actions: [{ a: 'withdraw-restart', label: 'Withdraw my 100 demo dollars', primary: true }]
    },
    'step-deposit': {
      step: 1, kind: 'plain', h: 'Step 1. Deposit',
      body: [V2 ? 'One button, {n} wallet confirmations. A Morpho Vault V2 is made for you by Morpho’s own factory, through our maker contract, so you are also its curator.' :
        'One button, {n} wallet confirmations. The vault is created for you, so you are also its curator.'],
      lines: true,
      actions: [{ a: 'deposit', label: 'Deposit 100 demo dollars', primary: true }]
    },
    'depositing': {
      step: 1, kind: 'wait', h: 'Confirm in your wallet ({i} of {n})',
      body: [], lines: true,
      actions: []
    },
    'confirm-rejected': {
      step: null, kind: 'stop', h: 'You rejected confirmation {i} of {n}',
      body: ['Nothing was lost. The steps already done stay done.'],
      lines: true,
      actions: [{ a: 'continue', label: 'Continue', primary: true }]
    },
    'would-fail': {
      step: null, kind: 'stop', h: 'This step would fail right now',
      body: ['{plain}. Nothing was sent.'],
      tech: 'contract error: {name}',
      actions: [{ a: 'continue', label: 'Check again', primary: true }, { a: 'withdraw', label: 'Withdraw my deposit', when: 'hasDeposit' }]
    },
    'wallet-error': {
      step: null, kind: 'stop', h: 'Your wallet reported a problem',
      body: ['{message}', 'Nothing was sent from this page.'],
      actions: [{ a: 'continue', label: 'Try again', primary: true }, REPLAY_INSTEAD]
    },
    'tx-failed': {
      step: null, kind: 'stop', h: 'That transaction failed on Base Sepolia',
      body: ['{plain}. Nothing moved.'],
      tech: 'contract error: {name}',
      actions: [{ a: 'continue', label: 'Try again', primary: true }, { a: 'view-tx', label: 'View transaction', href: 'tx' }]
    },
    'vault-tampered': {
      step: 1, kind: 'stop', h: 'This vault would pay back less than your deposit',
      body: ['Priced by the vault itself, the shares of a 100 demo dollar deposit would redeem for {worth} demo dollars. So nothing was deposited and nothing of yours is in it.',
        'A new vault takes one more confirmation.',
        '{again}'],
      actions: [{ a: 'deposit', label: 'Make another vault', primary: true }, REPLAY_INSTEAD]
    },
    'deposit-short': {
      step: 1, kind: 'stop', h: 'Your deposit is worth less than you put in',
      body: ['Your shares would redeem for {worth} demo dollars, not 100: the vault’s share price moved just before your deposit. These are test tokens with no value.',
        'Take the deposit out and start again with a fresh vault.'],
      actions: [{ a: 'withdraw-restart', label: 'Withdraw and start over', primary: true }]
    },
    'deposited': {
      step: 2, kind: 'plain', h: '100 demo dollars are in your vault',
      body: ['You hold {shares} vault shares.', '{vaultLine}'],
      rule: true,
      actions: [{ a: 'arm', label: 'Turn the watch on', primary: true }]
    },
    'arming': {
      step: 2, kind: 'wait', h: 'Confirm in your wallet ({i} of {n})',
      body: [], lines: true,
      actions: []
    },
    'armed-subscribing': {
      step: 2, kind: 'wait', h: 'Watch #{id} is on. Reactive is subscribing to your vault.',
      body: [],
      cols: ['Base Sepolia: watch on {tx.base.armTx}', 'Reactive Lasna: subscribing…'],
      actions: []
    },
    'armed-settling': {
      step: 3, kind: 'wait', h: 'Reactive is subscribed. Ready in {n} s.',
      body: ['A new subscription needs a moment before it catches events.'],
      curator: true,
      actions: curatorActions(true)
    },
    'armed': {
      step: 3, kind: 'plain', h: 'The watch is on',
      body: ['Base Sepolia: watch #{id} on. Reactive Lasna: subscribed {tx.lasna.subTx}'],
      curator: true,
      actions: curatorActions(false)
    },
    'watch-refused': {
      step: 2, kind: 'stop', h: 'Reactive Lasna refused this watch',
      body: ['{reason}', 'The exit contract on Base Sepolia still shows it as on, but nothing watches your vault. Turn it off before trying again; the next run uses a fresh vault.'],
      cols: ['Base Sepolia: watch #{id} on', 'Reactive Lasna: refused'],
      actions: [{ a: 'cancel', label: 'Turn the watch off', primary: true },
        { a: 'withdraw-restart', label: 'Turn it off, withdraw and start over', when: 'hasDeposit' }]
    },
    'watch-closed': {
      step: 2, kind: 'stop', h: 'Reactive Lasna has closed this watch',
      body: ['Reactive Lasna has ended this watch, but the exit contract on Base Sepolia still shows it as on: the exit did not arrive.', STILL_IN,
        'Turn the watch off before trying again; the next run uses a fresh vault.'],
      cols: ['Base Sepolia: watch #{id} on', 'Reactive Lasna: closed'],
      actions: [{ a: 'cancel', label: 'Turn the watch off', primary: true },
        { a: 'withdraw-restart', label: 'Turn it off, withdraw and start over', when: 'hasDeposit' }]
    },
    'subscribe-slow': {
      step: 2, kind: 'stop', h: 'Reactive has not picked up the watch',
      body: ['This usually takes one second. Our fee float on Reactive Lasna: {x} lREACT, debt {dL}.'],
      actions: [{ a: 'keep-waiting', label: 'Keep waiting', primary: true }, { a: 'cancel-withdraw', label: 'Turn the watch off and withdraw' }]
    },
    'scheduling': {
      step: 3, kind: 'wait', h: 'Confirm in your wallet (1 of 1)',
      body: ['You are scheduling the change as the vault’s curator.'],
      actions: []
    },
    'scheduled': {
      step: 4, kind: 'wait', h: 'Change scheduled. Hands off now.',
      body: [], strip: true, records: true,
      actions: []
    },
    'unwatched-wait': {
      step: 3, kind: 'wait', h: 'Scheduled. Checking for {n} s that nothing moves.',
      body: ['The curator scheduled {kindA} {tx.base.r1}. Your watch does not cover that kind, so Reactive is not told about it and your deposit should stay.'],
      actions: []
    },
    'exit-requested': {
      step: 4, kind: 'wait', h: 'Change scheduled. Hands off now.',
      body: [], strip: true, records: true,
      actions: []
    },
    'returned': {
      step: 4, kind: 'done', h: 'Your deposit came back by itself',
      body: ['{assets} demo dollars are in your wallet again. You clicked nothing after the curator’s change.'],
      strip: true,
      after: ['The change could not take effect for another {t} s.',
        'Your browser saw the withdrawal {w} s after it saw the change.',
        'Wallet: from {a} to {b} demo dollars. Vault shares: from {c} to 0. Allowance left to the exit contract: {z}.'],
      actions: [{ a: 'copy-run', label: 'Copy link to this run', primary: true }, { a: 'again', label: 'Run again' },
        { a: 'contracts', label: 'Read the contracts', href: 'contracts' },
        { a: 'remove-allowance', label: 'Remove the leftover allowance', when: 'hasAllowance' }]
    },
    'ignored': {
      step: 3, kind: 'done', h: 'Nothing moved, as the rule says',
      body: ['The curator scheduled {kindA}. Your watch does not cover that kind. Reactive was not even notified: the subscription names only the kinds you chose. Your {shares} shares are still in the vault and the watch is still on.'],
      actions: coveredNext('Now schedule {kindA}')
    },
    'missed': {
      step: 3, kind: 'stop', h: 'Reactive did not see this change',
      body: ['The subscription may not have been live yet. Your deposit is still in the vault and the watch is still on. A second change will be seen.'],
      actions: coveredNext('Schedule another change')
    },
    'reactive-timeout': {
      step: 4, kind: 'stop', h: 'Reactive has not reacted',
      body: ['Your deposit is still in the vault. The change cannot take effect for another {t} s.'],
      cols: ['Base Sepolia: watch #{id} on, change can run at {time}', 'Reactive Lasna: no exit requested, float {x} lREACT, debt {dL}'],
      actions: [{ a: 'withdraw', label: 'Withdraw my deposit now', primary: true }, { a: 'keep-waiting', label: 'Keep waiting' }]
    },
    'callback-slow': {
      step: 4, kind: 'stop', h: 'Reactive asked for the exit, but it has not arrived on Base Sepolia',
      body: ['This happens when the delivery fails or the exit contract’s fee reserve is empty ({y} ETH, debt {dB}).'],
      cols: ['Reactive Lasna: exit requested {time} {tx.lasna.r2}', 'Base Sepolia: watch #{id} still on, shares still in the vault'],
      actions: [{ a: 'withdraw', label: 'Withdraw my deposit now', primary: true }, { a: 'cancel', label: 'Turn the watch off' },
        { a: 'keep-waiting', label: 'Keep waiting' }]
    },
    'nothing-to-redeem': {
      step: 4, kind: 'done', h: 'The exit ran, but there was nothing to redeem',
      body: ['Your shares or the allowance were already gone when it arrived, for example because you withdrew by hand first.'],
      actions: [{ a: 'again', label: 'Run again', primary: true }]
    },
    'redeem-failed': {
      step: 4, kind: 'stop', h: 'The exit ran, but the vault refused the redeem',
      body: ['The watch has ended and your shares are still yours. The vault’s reason: {reason}.'],
      actions: [{ a: 'withdraw', label: 'Withdraw my deposit now', primary: true }, { a: 'again', label: 'Run again' }]
    },
    'withdrawn-by-hand': {
      step: null, kind: 'done', h: 'You withdrew by hand',
      body: ['{assets} demo dollars are back in your wallet. {watchLine}'],
      actions: [{ a: 'cancel', label: 'Turn the watch off', primary: true, when: 'hasWatch' },
        { a: 'again', label: 'Run again', when: 'noWatch' }]
    },
    'watch-off': {
      step: null, kind: 'done', h: 'The watch is off',
      body: [{ t: 'Reactive drops its subscription when it sees the cancellation. Allowance left to the exit contract: {z}.', when: 'subscribedOff' },
        { t: 'The watch is off on Base Sepolia. Reactive never subscribed to it. Allowance left to the exit contract: {z}.', when: 'refused' }],
      actions: [{ a: 'remove-allowance', label: 'Remove the allowance', primary: true, when: 'hasAllowance' },
        { a: 'withdraw', label: 'Withdraw my deposit', when: 'hasDeposit' }, { a: 'again', label: 'Run again' }]
    },
    'recovering': {
      step: null, kind: 'wait', h: 'Confirm in your wallet ({i} of {n})',
      body: [], lines: true,
      actions: []
    },
    'page-error': {
      step: null, kind: 'stop', h: 'This page hit a problem',
      body: ['{message}', 'This is a fault of the page, not of the chain. What is there is untouched, and the page can read it again.'],
      actions: [{ a: 'retry', label: 'Check again', primary: true }, REPLAY_INSTEAD]
    },
    'account-changed': {
      step: null, kind: 'stop', h: 'Your wallet switched accounts',
      body: ['This run belongs to {address}. Switch back to continue, or start a new run with the new account.'],
      actions: [{ a: 'restart', label: 'Start a new run', primary: true }]
    },
    'framed': {
      step: 0, kind: 'stop', h: 'Open this page directly',
      body: ['Wallet actions are switched off while the page is shown inside another site.'],
      actions: [{ a: 'open-direct', label: 'Open the page in its own tab', href: 'self', primary: true }, REPLAY]
    },
    'run-not-yet': {
      step: null, kind: 'stop', h: 'Run #{id} does not exist{yet}',
      body: ['{numbering}', 'The latest run is #{max}.'],
      actions: [{ a: 'open-latest', label: 'Open run #{max}', primary: true, when: 'hasRuns' }, { a: 'see-runs', label: 'See recent runs', href: '#runs' }]
    },
    'run-too-old': {
      step: null, kind: 'stop', h: 'Run #{id} is older than this page can search',
      body: ['The watch exists on chain (state: {state}), but its transactions are not in the recorded list of {date}.'],
      actions: [{ a: 'open-exit', label: 'Open the exit contract on the explorer', href: 'exit', primary: true },
        { a: 'see-runs', label: 'See recent runs', href: '#runs' }]
    },
    'run-still-on': {
      step: null, kind: 'stop', h: 'Run #{id} has not fired yet',
      body: ['Watch #{id} is still on and has not asked for an exit, so there is nothing to replay yet.'],
      actions: [{ a: 'open-exit', label: 'Open the exit contract on the explorer', href: 'exit', primary: true },
        { a: 'see-runs', label: 'See recent runs', href: '#runs' }]
    },
    'run-no-exit': {
      step: null, kind: 'stop', h: 'Run #{id} ended without an exit',
      body: ['{why} Nothing moved, so there is nothing to replay.'],
      actions: [{ a: 'open-exit', label: 'Open the exit contract on the explorer', href: 'exit', primary: true },
        { a: 'see-runs', label: 'See recent runs', href: '#runs' }]
    },
    'reading-run': {
      step: null, kind: 'wait', h: 'Reading run #{id}',
      body: ['Looking up its three transactions on both chains.'],
      actions: []
    },
    'replay': {
      step: null, kind: 'plain', h: 'Replay of run #{id}, {date}',
      body: ['These are real transactions from that day. Nothing is being sent now.', '{modeLine}', '{fastLine}', '{check}'],
      strip: true,
      actions: [{ a: 'connect', label: 'Try it with a test wallet', primary: true }, { a: 'replay-next', label: 'Replay another run' }]
    }
  };

  /* Notices shown inside another state, never as a state of their own. */
  NP.notices = {
    'reactive-slow': { h: 'Slower than usual', body: 'Earlier runs reached Reactive within a second.' },
    'rpc-hiccup': { h: 'A read failed',
      body: 'A public endpoint did not answer. The page keeps trying every second. Your run does not depend on this page: it goes on by itself.' },
    'tx-slow': { h: 'Still waiting for Base Sepolia',
      body: 'This usually takes under 5 seconds. Your wallet may show the transaction as pending; you can speed it up there.' }
  };

  NP.copy = {
    stepNames: ['Deposit', 'Watch', 'Curator', 'Result'],
    depositLines: [V2 ? 'Make your own Morpho Vault V2 (test network)' : 'Create your own demo vault', 'Get 100 demo dollars (free)', 'Let the vault take them', 'Deposit'],
    armLines: ['Allow the exit contract to redeem exactly your {shares} shares, to your address only', 'Turn the watch on'],
    lineStatus: { todo: 'to do', wallet: 'waiting for your wallet', sent: 'sent', done: 'confirmed', have: 'already in your wallet',
      skip: 'already done' },
    noTokens: 'You have no demo dollars yet. They are free: the confirmation “Get 100 demo dollars” mints 100 to your address.',
    ruleHeading: 'Leave when the curator schedules',
    clockNote: 'The two chains’ clocks differ by about a second, so a record can show a time one second before the change it follows.',
    pendingNone: 'Changes already scheduled on this vault: none.',
    pendingSome: 'Changes already scheduled on this vault: {n}. A watch turned on now will not see them.',
    pendingUnread: 'Changes already scheduled on this vault: could not be read just now.',
    curatorIntro: 'Now play the curator. On a vault that holds real deposits the curator is someone else, not the depositor. Schedule a rule change and see what your deposit does.',
    curatorTimelock: 'This vault waits {sec} seconds before each change offered below can take effect. Vaults that hold real deposits usually wait days.',
    hintCovered: 'your watch covers it, so the deposit should leave.',
    hintIgnored: 'your watch does not cover it, so the deposit should stay.',
    tamperedReuse: 'The empty vault from your earlier visit would now pay back less than a deposit, so this run makes a new one.',
    tamperedAgain: 'This is the second vault in a row. The replay shows the same contracts at work.',
    refused3: 'All watch slots were taken.',
    refused4: 'This vault already has 3 watches, the most our reactive contract serves on one vault. Anyone can deposit into it and turn watches on, so a fresh vault is the way out.',
    refused5: 'The timer mode is full right now.',
    refusedOther: 'Reactive refused it with code {code}.',
    refusedGone: 'Reactive refused this watch when it was turned on.',
    noExitOff: 'Its owner turned the watch off before any exit.',
    noExitExpired: NP.config.deployment.leaveNowExpires ? 'It was ended ' + LIFE + ' after it was turned on, before any exit.' :
      'It was a timer watch, ended ' + LIFE + ' after it was turned on.',
    vaultRefused: 'The vault refused this step. If you just confirmed the step before it, the public endpoint may not show it yet: check again in a few seconds',
    rec1: 'Change scheduled',
    rec2: 'Reactive transaction',
    rec3: 'Withdrawal',
    rec2Wait: 'waiting (usually the same second)',
    rec3Wait: 'waiting (usually a second or two)',
    rec2WaitTimer: 'waiting for the timer (about 2 minutes before the deadline)',
    rec3WaitTimer: 'waiting (follows Reactive within seconds)',
    rec2Missing: 'not read: Reactive Lasna did not answer',
    earlierChange: 'Reactive reacted to your earlier change, the one scheduled at {time} UTC.',
    replayDeadline: 'This run used the other mode, “wait for the deadline”: Reactive stores the change and asks for the exit about 2 minutes before it can take effect, if it is still scheduled then. Here that was {s} s after the change, with {left} s of notice left.',
    replayFast: 'The {s} s of waiting are played back in about {play} s.',
    stillNoWallet: 'Still no wallet found. Checked just now.',
    notMorpho: V2 ? 'The demo below runs on test Morpho Vault V2s made by Morpho’s own factory through our maker contract, holding our demo dollar; these contracts accept no other vault. Not affiliated with Morpho.' :
      'The demo below runs on our own test vault. Not affiliated with Morpho.',
    vaultIsV2: 'Morpho’s own Vault V2 factory lists this vault as one of its vaults.',
    vaultNotV2: 'Morpho’s Vault V2 factory does not list this vault.',
    copyFailed: 'Copying was blocked. Select the text in the box and copy it.',
    refTx: 'Reactive’s receipt names your transaction as its trigger.',
    checkOk: 'Checked against both chains just now.',
    checkFail: 'Could not re-check right now; this is the recorded copy from {date}.',
    checking: 'Reading the three receipts from both chains…',
    watchStillOn: 'The watch is still on.',
    watchNone: 'No watch is on.',
    kindsNone: 'Pick at least one kind of change.',
    kindLocked: 'A new adapter stays on in this demo: it is the change you schedule as the curator in the next step.'
  };
}());
