/* Every state of the guided run as data: headline, body, actions. One renderer (view.js) draws them all.
   {name} is a live value; {tx.base.name} and {tx.lasna.name} are transaction links.
   step: 0 before, 1 deposit, 2 watch, 3 curator, 4 result. kind: wait (no button needed), stop (needs a decision),
   done (a result), plain. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};

  var REPLAY = { a: 'replay', label: 'Replay a real run' };
  var REPLAY_INSTEAD = { a: 'replay', label: 'Replay a real run instead' };
  var WITHDRAW_NOW = { a: 'withdraw', label: 'Withdraw my deposit now' };

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
      body: ['The demo vault is on Base Sepolia, a test network.'],
      actions: [{ a: 'switch', label: 'Switch to Base Sepolia', primary: true }]
    },
    'switch-refused': {
      step: null, kind: 'stop', h: 'Still on the other network',
      body: ['You can switch in the wallet yourself: Base Sepolia, chain ID 84532, RPC https://sepolia.base.org.'],
      actions: [{ a: 'retry', label: 'Check again', primary: true }, REPLAY_INSTEAD]
    },
    'no-gas': {
      step: null, kind: 'stop', h: 'Your wallet has no test ETH for gas',
      body: ['The run needs about 0.00002 Base Sepolia ETH, which is free from a faucet. This page cannot pay it for you: it has no server and no key.',
        'Your address: {address}'],
      copy: 'address',
      actions: [{ a: 'faucet', label: 'Open Base’s faucet list', href: 'faucets', primary: true },
        { a: 'retry', label: 'I have test ETH now' }, REPLAY_INSTEAD]
    },
    'runs-used-up': {
      step: null, kind: 'stop', h: 'Today’s {cap} live runs are used up',
      body: ['Reactive fees for this demo come from a small float, so it allows {cap} runs a day for everyone. The count resets at 00:00 UTC, in {h} h {m} min.'],
      actions: [{ a: 'replay', label: 'Replay a real run', primary: true }]
    },
    'address-used-up': {
      step: null, kind: 'stop', h: 'This address has used its {cap} runs for today',
      body: ['The count resets at 00:00 UTC, in {h} h {m} min. Another address can still run.'],
      actions: [{ a: 'replay', label: 'Replay a real run', primary: true }]
    },
    'slots-full': {
      step: null, kind: 'stop', h: 'All {n} watch slots are taken right now',
      body: ['Other visitors have watches open. A slot frees when a watch ends, or one day after it was turned on.'],
      actions: [{ a: 'retry', label: 'Check again', primary: true }, REPLAY]
    },
    'float-empty': {
      step: null, kind: 'stop', h: 'The demo is out of fee money',
      body: ['Reactive transactions for this demo are paid from our float, and it is too low right now ({x} lREACT, {y} ETH). A watch turned on now might not fire. Recorded runs still play.'],
      actions: [{ a: 'replay', label: 'Replay a real run', primary: true }]
    },
    'rpc-down': {
      step: null, kind: 'stop', h: 'Cannot reach {chain} right now',
      body: ['Tried {n} public endpoints. The runs below were recorded on {date}.'],
      actions: [{ a: 'retry', label: 'Try again', primary: true }]
    },
    'resume': {
      step: null, kind: 'stop', h: 'Welcome back',
      body: ['Your {what} from {time} is still there. Continue from step {step}.'],
      actions: [{ a: 'continue', label: 'Continue', primary: true }, { a: 'withdraw-restart', label: 'Withdraw my deposit and start over' }]
    },
    'old-vault': {
      step: 1, kind: 'stop', h: 'This vault is from an earlier visit',
      body: ['Its scheduled changes can no longer be listed from here, so a watch on it could miss one. Take the deposit out and start with a fresh vault.'],
      actions: [{ a: 'withdraw-restart', label: 'Withdraw my 100 demo dollars', primary: true }]
    },
    'step-deposit': {
      step: 1, kind: 'plain', h: 'Step 1. Deposit',
      body: ['One button, {n} wallet confirmations. The vault is created for you, so you are also its curator.'],
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
      actions: [{ a: 'continue', label: 'Continue from step {i}', primary: true }]
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
    'deposited': {
      step: 2, kind: 'plain', h: '100 demo dollars are in your vault',
      body: ['You hold {shares} vault shares.'],
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
      actions: [{ a: 'schedule-adapter', label: 'Schedule a new adapter', primary: true, off: true },
        { a: 'schedule-cap', label: 'Schedule a cap increase instead', off: true }]
    },
    'armed': {
      step: 3, kind: 'plain', h: 'The watch is on',
      body: ['Base Sepolia: watch #{id} on. Reactive Lasna: subscribed {tx.lasna.subTx}'],
      curator: true,
      actions: [{ a: 'schedule-adapter', label: 'Schedule a new adapter', primary: true },
        { a: 'schedule-cap', label: 'Schedule a cap increase instead' },
        { a: 'cancel', label: 'Turn the watch off', quiet: true }]
    },
    'watch-refused': {
      step: 2, kind: 'stop', h: 'Reactive did not take this watch',
      body: ['{reason}', 'Base Sepolia still shows it as on, so turn it off before trying again.'],
      actions: [{ a: 'cancel', label: 'Turn the watch off', primary: true }, { a: 'withdraw', label: 'Withdraw my deposit' }]
    },
    'subscribe-slow': {
      step: 2, kind: 'stop', h: 'Reactive has not picked up the watch',
      body: ['This usually takes one second. Float {x} lREACT, debt {d}.'],
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
        'Wallet: from {a} to {b} npUSD. Vault shares: from {c} to 0. Allowance left to the exit contract: {z}.'],
      actions: [{ a: 'copy-run', label: 'Copy link to this run', primary: true }, { a: 'again', label: 'Run again' },
        { a: 'contracts', label: 'Read the contracts', href: 'contracts' },
        { a: 'remove-allowance', label: 'Remove the leftover allowance', when: 'hasAllowance' }]
    },
    'ignored': {
      step: 3, kind: 'done', h: 'Nothing moved, as the rule says',
      body: ['The curator scheduled a cap increase. Your watch does not cover that kind. Reactive was not even notified: the subscription names only the kinds you chose. Your {shares} shares are still in the vault and the watch is still on.'],
      actions: [{ a: 'schedule-adapter', label: 'Now schedule a new adapter', primary: true }]
    },
    'missed': {
      step: 3, kind: 'stop', h: 'Reactive did not see this change',
      body: ['The subscription may not have been live yet. Your deposit is still in the vault and the watch is still on. A second change will be seen.'],
      actions: [{ a: 'schedule-adapter', label: 'Schedule another change', primary: true }, WITHDRAW_NOW]
    },
    'reactive-timeout': {
      step: 4, kind: 'stop', h: 'Reactive has not reacted',
      body: ['Your deposit is still in the vault. The change cannot take effect for another {t} s.'],
      cols: ['Base Sepolia: watch #{id} on, change can run at {time}', 'Reactive Lasna: no exit requested, float {x} lREACT, debt {d}'],
      actions: [{ a: 'withdraw', label: 'Withdraw my deposit now', primary: true }, { a: 'keep-waiting', label: 'Keep waiting' }]
    },
    'callback-slow': {
      step: 4, kind: 'stop', h: 'Reactive asked for the exit, but it has not arrived on Base Sepolia',
      body: ['This happens when the delivery fails or the exit contract’s fee reserve is empty ({y} ETH, debt {d}).'],
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
      body: ['Reactive drops its subscription when it sees the cancellation. Allowance left to the exit contract: {z}.'],
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
      body: ['{message}', 'Nothing was sent. What is on the chain is untouched, and the page can read it again.'],
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
      step: null, kind: 'stop', h: 'Run #{id} does not exist yet',
      body: ['The latest run is #{max}.'],
      actions: [{ a: 'open-latest', label: 'Open run #{max}', primary: true, when: 'hasRuns' }, { a: 'see-runs', label: 'See recent runs', href: '#runs' }]
    },
    'run-too-old': {
      step: null, kind: 'stop', h: 'Run #{id} is older than this page can search',
      body: ['The watch exists on chain (state: {state}), but its transactions are not in the recorded list of {date}.'],
      actions: [{ a: 'open-exit', label: 'Open the exit contract on the explorer', href: 'exit', primary: true },
        { a: 'see-runs', label: 'See recent runs', href: '#runs' }]
    },
    'replay': {
      step: null, kind: 'plain', h: 'Replay of run #{id}, {date}',
      body: ['These are real transactions from that day. Nothing is being sent now.', '{check}'],
      strip: true,
      actions: [{ a: 'connect', label: 'Try it with a test wallet', primary: true }, { a: 'replay-next', label: 'Replay another run' }]
    }
  };

  /* Notices shown inside another state, never as a state of their own. */
  NP.notices = {
    'reactive-slow': { h: 'Slower than usual', body: 'Earlier runs reached Reactive within a second.' },
    'tx-slow': { h: 'Still waiting for Base Sepolia',
      body: 'This usually takes under 5 seconds. Your wallet may show the transaction as pending; you can speed it up there.' }
  };

  NP.copy = {
    stepNames: ['Deposit', 'Watch', 'Curator', 'Result'],
    depositLines: ['Create your own demo vault', 'Get 100 demo dollars (free)', 'Let the vault take them', 'Deposit'],
    armLines: ['Allow the exit contract to redeem exactly your {shares} shares, to your address only', 'Turn the watch on'],
    lineStatus: { todo: 'to do', wallet: 'waiting for your wallet', sent: 'sent', done: 'confirmed', have: 'already in your wallet',
      skip: 'already done' },
    noTokens: 'You have no demo dollars yet. They are free: the next confirmation mints 100 to your address.',
    ruleHeading: 'Leave when the curator schedules',
    pendingNone: 'Changes already scheduled on this vault: none.',
    pendingSome: 'Changes already scheduled on this vault: {n}. A watch turned on now will not see them.',
    curatorIntro: 'Now play the curator. On a real vault this is the operator, not you. Schedule a rule change and see what your deposit does.',
    curatorTimelock: 'This vault’s waiting period is {min} minutes. Real vaults use days.',
    capIgnored: 'Your watch ignores cap increases, so the deposit should stay.',
    capCovered: 'Your watch covers cap increases too, so this will also make the deposit leave.',
    refused3: 'All watch slots were taken.',
    refused4: 'This vault already has 3 watches.',
    refusedOther: 'Reactive refused it with code {code}.',
    refusedGone: 'Reactive refused this watch when it was turned on.',
    refusedClosed: 'Reactive has already closed this watch.',
    rec1: 'Change scheduled',
    rec2: 'Reactive transaction',
    rec3: 'Withdrawal',
    rec2Wait: 'waiting (usually the same second)',
    rec3Wait: 'waiting (usually 2 seconds)',
    refTx: 'Reactive’s receipt names your transaction as its trigger.',
    checkOk: 'Checked against both chains just now.',
    checkFail: 'Could not re-check right now; this is the recorded copy from {date}.',
    checking: 'Reading the three receipts from both chains…',
    watchStillOn: 'The watch is still on.',
    watchNone: 'No watch is on.',
    kindsNone: 'Pick at least one kind of change.'
  };
}());
