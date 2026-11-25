# Testing notes for the page

The page shows the deployment of 22 Nov 2026 (`deployments/2026-11-22.json`). Its vaults are real Morpho Vault V2s
made by Morpho's factory through our `MorphoVaultMaker`; the maker, the demo dollar and the curator in our runs are
ours. The page is plain HTML, CSS and JavaScript with no build step.

Every row was run on 2026-11-23 on the files as they are now, and its output was read: the scripts of parts 1a and 2
between 06:02 and 06:47 UTC, the browser rows of part 1b between 04:32 and 04:36 UTC (its Morpho row at 07:54 UTC, after that sentence was reworded). No result is carried over from the
earlier notes (21 Nov 2026 for the pair of 18 Nov 2026, 22 Nov 2026 for earlier files of this page); they are in the
history of this file. What was last run then and not since is listed in part 3, without a result. Two page files
changed after these rows, in commit 5333fe9 (23 Nov 2026, 20:11 UTC): `docs/rpc.js` now tries the next endpoint when
one answers with a JSON-RPC error, and a comment in `docs/run.js`. The new offline test `scripts/test-rpc.mjs` is a
step of the `ci` workflow, which passed on the next two commits (517503b, 49bfe4b); the browser rows were not run
again after 5333fe9.

One run used a wallet that signs: the live wallet walk of part 1c (`.github/workflows/page-walk.yml`, which runs
`scripts/page-walk.mjs` on the hosted page), at 06:49 UTC. It came after every other row, so parts 1a, 1b and 2
show the page as it was before it, with 11 watches. No wallet extension was used anywhere.

Three kinds of evidence, kept apart:

- Parts 1a and 1b can be redone by anyone with this repository (this folder and `scripts/`), node 22 or later with
  no packages, a Chromium-based browser with developer tools, and the public endpoints.
- Part 1c is one run of a workflow of this repository that signs with our testnet key. Anyone can read its log and
  check its receipts again; only we can run it.
- Part 2 was run with test tooling that is not in this repository: a static scan of this folder, an encoder test on
  real transaction inputs, a simulator of the two chains with a fake wallet that runs the page's own scripts in node,
  and a read-only replay of the simulator's reads on the live chains.
  It proves the page's own logic and wording. It does not prove a real wallet, real gas estimation or the network.

Browsers used: a Chromium-based browser pane at 1280 by 800 and 390 by 844, and headless Microsoft Edge 157 with a
fresh profile (the dry walk).

## How to open it

- From a local server: `python -m http.server 8000 --bind 127.0.0.1` in this folder, then `http://127.0.0.1:8000/`.
- By double click on `index.html`. Not repeated on these files (part 3).

## 1. From this repository

### 1a. Scripts in `scripts/` (no key)

| What | How | Result |
|---|---|---|
| The rules of the walk's signer | `node scripts/test-page-walk.mjs`. No key, no browser, no network: the chain reads behind a yes are answered by a table in the test, per endpoint | Exit code 0, 157 lines `ok`, last line `signer checks passed (89 transactions, 12 addresses, 7 wallet methods, 10 create receipts, 7 box lists, the signing path)`. Signed: the calls of the guided run on the walk's own vault, for each of the four kinds. Refused, among others: another receiver, another vault the maker lists, the deployment's smoke vault, value attached, another chain, a second `create()`, deposit, arm or submit, a `create()` after the walk's deposit, anything but the one submit after the arm, a change of another kind, an adapter address that holds code on any endpoint, an answer that differs between endpoints, a send when one endpoint gives no transaction count, a vault taken from a create receipt the endpoints do not give alike, a printed transaction hash that only the sending endpoint knows or that sits at another nonce, the signing methods `personal_sign`, `eth_signTypedData_v4` and `eth_sendRawTransaction`, and page addresses other than the hosted page. One line reads `FAIL the page asked for personal_sign`: it is the walk's own message inside the case that checks this refusal |
| Run #1 checked by receipt, outside the page | `node scripts/page-walk.mjs --verify-record records/2026-11-22-1.json`. Read-only, both chains | Result `ok`, 19 of 19 checks. Three receipts with status 1, the two on Base Sepolia read alike from both endpoints. The `Submit` was sent by the curator to the vault and is a new adapter change. `ExitRequested` on Reactive Lasna and `WatchEnded` on Base Sepolia are for watch 1 and each names the `Submit` as its origin. Outcome 0 (redeemed), every share the watch covered, and the demo dollars moved from the vault to the depositor equal the redeemed assets (100000000 units). From block times: the exit 1 s after the `Submit`, 179 s before the change could run; the block time on Reactive Lasna is 1 s before the `Submit` (printed as -1) |
| The guided run up to the first confirmation, in a browser with a stand-in wallet (the dry walk) | `python -m http.server PORT --bind 127.0.0.1` in this folder, then `node scripts/page-walk.mjs --dry --url http://127.0.0.1:PORT/ --browser PATH_TO_EDGE`. The script injects a wallet that has no key, with the deployment's second operator address (0.001966 test ETH on Base Sepolia at that time). Nothing is signed or sent | Result `ok` in 9.5 s, in headless Edge 157 with its sandbox, under the shipped Content-Security-Policy. The page saw the wallet and went `idle`, `checking`, `step-deposit`. Pressing the deposit button (`depositing`) asked the wallet for one transaction, `create()` on the maker, which the signer's rules would sign; it was answered with a rejection (4001) and the page showed `confirm-rejected`, `You rejected confirmation 1 of 3`. Wallet requests: `eth_accounts` 1, `eth_requestAccounts` 1, `eth_chainId` 2, `eth_sendTransaction` 1. The page's token, maker, exit and reactive addresses equal the deployment file's. Console errors, warnings and network errors: none recorded. Flags read from the page: `mode1` false, `unprovenKinds` true |
| The watch step and the curator step for each kind, drawn by the page's own renderer | Part of the same dry walk; no chain behind them, nothing pressed that asks the wallet | For each of the four walk settings the boxes could be set, the button that turns the watch on was enabled and that kind's curator button was there. Kinds value the page built: 7 for a new adapter, 6 for a shorter waiting period, 4 for a new allocator, 15 for a cap increase |

### 1b. In a browser (no wallet)

A Chromium-based browser pane, the page served by `python -m http.server` from this folder on localhost, port 8831,
so the shipped Content-Security-Policy applied. No wallet.

| What | How | Result |
|---|---|---|
| Console under the shipped policy | Open the page, read the console and the list of requests | Only the info lines `state: idle` and `state: no-wallet`. No error and no warning. The page's 13 own files each answered 200 |
| Morpho public API | First screen, 07:54 UTC | `20 rule changes are waiting in 5 Morpho vaults holding $27.6M right now. All are cap increases, the routine kind a watch leaves alone unless you opt in.` Under it: `Morpho’s public API, 23 Nov 2026, 07:54 UTC: 20 cap increases. On 21 Nov 2026, 3 of 35 waiting changes were shorter waiting periods.` At 1280 and at 390 wide the text stays inside its column |
| Recorded run re-read by receipt | First screen | `Run #11` with `Three receipts re-read from both chains at 04:34:04 UTC.` |
| Count of watches | First screen | `11 watches turned on so far, all our own tests: 8 deposits returned, 2 turned off by their owners, 1 still on. “Leave now” runs: median 1 s over 5 runs.` |
| Live limits and float | First screen | `Live now: 47 of 50 runs left today. Float 8.03 lREACT, no debt.` |
| Recent runs table | Read the rows | #11 (leave now, cap increase): Reactive +0 s, deposit back +1 s, 179 s of notice left. #10 and #9 (timer): Reactive +68 s and +61 s, deposit back +70 s and +63 s. #8 `Watch still on. No exit yet.` #7 and #2 `Watch turned off by its owner. No exit.` #6 (timer): Reactive +63 s, deposit back +65 s, 115 s of notice left. #5, #4, #3 and #1 (leave now): Reactive +0 s, deposit back +1 s, +2 s, +1 s and +1 s |
| `#run=11` opened directly | Open the address | `Replay of run #11, 23 Nov 2026`, then `Checked against both chains just now.`; deposit back +1 s, 179 s of notice left |
| `#run=9` opened directly | Open the address | `Replay of run #9, 23 Nov 2026`, the paragraph about its mode (61 s after the change, 117 s of notice left) and `The 61 s of waiting are played back in about 8 s.` Read 5 s after opening, while the receipts were still being re-read |
| `#run=8`, `#run=2` | Open the address | `Run #8 has not fired yet` and `Run #2 ended without an exit` |
| `#run=0` | Open the address | `Run #0 does not exist`, `Runs are numbered from 1. The latest run is #11.` |
| The newer screens, drawn by the page's renderer with made-up values (no chain behind them, nothing pressed), at 1280 and at 390 wide | `NP.run.go(state, values)` in the console | `vault-set-aside` with its one button `Withdraw my 100 demo dollars`; `run-no-return` (`Run #5 ended without a return`, a made-up number); `confirm-rejected` with `Continue` and `Back`; `depositing` with the slow notice and `Check the chain again`; `watch-off` with `No watch is on for this address and vault.`; `rpc-down` with `Tried the one public endpoint that can search that far twice.` At both widths nothing in the box goes past an edge. At 390 the buttons are 324 px wide and 44 px high, one of them 56 on two lines |
| Phone, 390 by 844 | Measure | Document scroll width 390, so no sideways scroll; the only wider element is the visually hidden header row of the table. The first three transaction links of the first screen end at 761, 843 and 925 px |
| 1280 by 800 | Measure | No element past the right edge. The record rows of the first screen are 37 px each |

### 1c. The live wallet walk (GitHub Actions, our testnet key)

`page-walk.yml`, [run 45126645970](https://github.com/bongbongcrypto/notice-period/actions/runs/45126645970), on commit `909bef1`, 23 Nov 2026 at 06:49 UTC. Chrome 157 on the
runner, with its sandbox, opened the hosted page and pressed its buttons; the injected wallet signed with the
second key (`0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19`) under the rules in the header of `scripts/page-walk.mjs`.
Settings: a new adapter, leave now. This row cannot be redone without the key. Its record is
`records/2026-11-22-14.json`, and `node scripts/page-walk.mjs --verify-record records/2026-11-22-14.json` reads its
receipts again without a key (result `ok`, 19 of 19 checks, at 06:56 UTC).

| What | Result |
|---|---|
| The guided run from the hosted page's own buttons | Result `ok` in 56.1 s. States `idle`, `checking`, `step-deposit`, `depositing`, `deposited`, `arming`, `armed-subscribing`, `armed-settling`, `armed`, `scheduling`, `scheduled`, `exit-requested`, `returned`. End screen: `Your deposit came back by itself`, `Deposit back +1 s`, `179 s of notice left`, `Wallet: from 200 to 300 demo dollars. Vault shares: from 100 to 0. Allowance left to the exit contract: 0.` |
| What the wallet signed | Six transactions, nonces 49 to 54, each read back alike from both Base Sepolia endpoints: `create()` on the maker, `approve` on the demo dollar, `deposit` into the new vault `0xB4A34D2b05aD3961a2E3936999A86D6f719beB84`, `approve` on the vault for the exit contract, `arm` on the exit contract (watch 12) and `submit` on the vault. No `mint`: the address already held 200 demo dollars. Nothing was refused. Wallet requests: `eth_accounts` 1, `eth_requestAccounts` 1, `eth_chainId` 7, `eth_sendTransaction` 6 |
| The three transactions the page showed, read by receipt outside the page | 27 of 27 checks. Status 1 on all three, the two on Base Sepolia alike from both endpoints. The `Submit` is the one the walk signed, a new adapter change sent by the curator to the vault. `ExitRequested` on Reactive Lasna and `WatchEnded` on Base Sepolia are for watch 12 and each names the `Submit` as its origin. Outcome 0 (redeemed), every share the watch covered. The exit landed 1 s after the `Submit` and 179 s before the change could run. Afterwards no shares and no watch were left on the vault, the wallet had gained exactly the redeemed assets (200000000 to 300000000 units), and the walk had signed one `create()`, one deposit, one arm and one submit, all on the one vault |
| Console and network | Console errors, warnings and network errors: none recorded |

## 2. With test tooling that is not in this repository

| Path | Result |
|---|---|
| Static scan of this folder | Pass. 16 files, 228 `0x` literals of 8 or more hex digits: each is computed from a Solidity signature (the computed values are compared with a list of expected ones, the well-known `Transfer` topic among them), or is a value of the fixtures, of `deployments/` or of `records/`. The Content-Security-Policy is exactly the specified string. No inline script, style or handler, no `eval`, no `innerHTML`, no browser storage, no cookie. The addresses and operators of `data/deployment.js` equal those of `deployments/2026-11-22.json`. Every outside host named in the files is on a fixed list |
| Encoder | 32 of 32 on the real transaction inputs and logs of both pairs (18 Nov and 22 Nov). With a wrong `submit(bytes)` encoder planted: 27 of 32, caught by all five submit cases: `submit(addAdapter)` on 18 Nov, and on 22 Nov `submit(addAdapter)`, `submit(decreaseTimelock(addAdapter, 60))`, `submit(setIsAllocator(account, true))` and `submit(increaseAbsoluteCap(id data, cap))` |
| Simulator: what it is | The page's own scripts run in node on a small fake page, with a fake wallet and simulated chains; buttons are pressed through their click listeners. 12 scenarios, 12 passed. There is no layout: it judges states, chain reads and wallet requests, not what a screen looks like |
| Simulator: full run | Connect, deposit, watch on, a new adapter scheduled as the curator, deposit returned. States `idle`, `connecting`, `checking`, `step-deposit`, `depositing`, `deposited`, `arming`, `armed-subscribing`, `armed-settling`, `armed`, `scheduling`, `scheduled`, `exit-requested`, `returned`. First deposit line `Make your own Morpho Vault V2 (test network)`; 100 shares after the deposit; waiting period 180 s; 100 back, allowance left 0, 100 in the wallet |
| Simulator: a change the watch does not cover | The default watch, then a cap increase scheduled: `unwatched-wait`, then `ignored`, with the 100 shares kept |
| Simulator: a shorter waiting period | Boxes set so that the watch covers only that kind (kinds 2), then scheduled: `returned`, 100 back |
| Simulator: a new allocator | Boxes set so that the watch covers only that kind (kinds 4), then scheduled: `returned`, 100 back |
| Simulator: Reactive refuses the watch, vault full (code 4) | `watch-refused` with the sentence about 3 watches on one vault. `Withdraw` and start over: `recovering`, then `step-deposit` with a fresh vault to make. Asked again instead: `checking`, then `watch-refused` with `Reactive refused this watch when it was turned on.` |
| Simulator: Reactive refuses the watch, timer mode full (code 5) | `watch-refused` with `The timer mode is full right now.` Turning the watch off: `recovering`, then `watch-off` |
| Simulator: a vault whose shares redeem for half | The page stops at `vault-tampered` with a worth of 50 |
| Simulator: the visitor is not the vault's curator | At the curator step: `would-fail` with `Only the curator of this vault can do that` |
| Simulator: no test ETH, no free slot | `no-gas`, asking for 0.00012 ETH, and `slots-full` (1000 slots), each right after the connection |
| Simulator: every state drawn | 61 states were drawn by the page's renderer without an error. With no layout this says nothing about overflow, sizes or line breaks |
| The simulator's reads replayed on the live chains | Read-only, against the 22 Nov pair, from a random address that never sent anything, with every simulator vault mapped to the vault of run #1. 35 reads answered without an error, among them the daily limits, the slots, the float, the debts, the maker's `TIMELOCK()`, the vault's `previewDeposit` and `previewRedeem`, and `isVaultV2` on Morpho's factory. 4 log filters answered (0 logs each in the last 2,000 blocks). Of the 15 simulated transactions, sent as calls only: `create()`, `mint` and both `approve` pass for a newcomer; `deposit`, `arm`, `submit`, `redeem` and `cancel` revert there, as they need state a newcomer does not have. Result pass |

## 3. Not run

| What | Why | Where it can run |
|---|---|---|
| A wallet extension a person holds: its connection prompt, its confirmations, a rejection by a person | The walk's wallet (part 1c) is injected through developer tools and signs by rule; no extension was used | A person with a browser wallet |
| The live walk with another setting | Only a new adapter, leave now, the second key was walked (part 1c) | `page-walk.yml` with other inputs |
| A dry walk with another setting | Only the default was run (a new adapter, leave now, the second operator address) | `--kind`, `--mode`, `--address` of the same script |
| Whether wallet extensions inject their provider under `script-src 'self'`, outside Edge | Read only, on 2026-11-25 on the hosted page in Edge 158 (Chromium) with six wallet extensions installed: all six announced their providers by EIP-6963 and `window.ethereum` was set; nothing was connected or signed. Other browsers were not tried | A person with a browser wallet in another browser |
| Parts 1a, 1b and 2 on the hosted address | They were run on a local copy of these files. On the hosted page only the walk of part 1c was run | The hosted page, with the same steps |
| The newer screens and buttons by their real cause | `Back` after a rejected confirmation, `Check the chain again` while a transaction has no receipt, the stop screen for a vault that is not watched again, `#run=N` for a run whose exit returned nothing, the sentence `No watch is on for this address and vault`, a switch of account before the run starts, and the wording when only one endpoint can search far enough. Their screens were drawn with made-up values (part 1b); on these files none was reached by the event that causes it | Simulator or real run |
| A cap increase on a watch that covers it, from this page's buttons | One returned a deposit on the 22 Nov pair from our loop workflow (run #11, `records/2026-11-22-13.json`). The page's own button for it was not pressed on the live contracts, and the simulator's only cap increase is on a watch that does not cover it | The walk with `--kind cap` |
| A shorter waiting period or a new allocator scheduled from this page's buttons, on the live contracts | Both returned a deposit on the 22 Nov pair from our loop workflow (runs #3 and #4), not yet from the page's own buttons; only the new adapter button was pressed live (part 1c) | The walk with `--kind timelock` or `--kind allocator` |
| Last run on 21 Nov 2026 on earlier files, not since: the double-clicked `file://` copy, a script file that does not load, reduced motion, the fallback endpoint in the page's own code, the hosts contacted by a full load, the widths 1024, 816, 768 and 360, type sizes, lone last words, the first-screen buttons, print | Not repeated for the 22 Nov deployment | A browser with developer tools |
| Last run on 21 Nov 2026 with the simulator in a browser, not since: every state rendered at five widths, every button of every state pressed, positions before and after data arrives, failure of every read, two wallets, wrong network, the daily limits, a rejected confirmation in the curator step, a busy wallet, a read endpoint that lags, Reactive Lasna unreachable, Reactive never reacting or reacting late, a subscription that never arrives, log reads that fail at "Turn the watch on" | Not repeated for the 22 Nov deployment; the node simulator of part 2 covers 12 scenarios and no layout | The same tooling in a browser |
| Reload in the middle of a real run, two tabs, a second browser engine, private mode | Only the simulator was available; it forgets its state on reload | Real-wallet walk |
| Whether the public endpoints really answer a block behind, and how often their log reads fail | Not measured | Many reads right after a real transaction |
| The page with scripts switched off | Not run on these files | Any browser with scripts off |
| A layout-shift score from the browser's own meter | Not measured | A visible browser with developer tools |
| Activation with Enter and Space, a screen reader | Not run. Read in the HTML only: one polite live region (`aria-live`) | A person |
| `callback-slow`, `deposit-short` and `timer-full` by their real cause | Drawn in the simulator only | Simulator or real run |
| A table with visitor runs | The records hold 12 watches on the 22 Nov pair (`records/`), all our own; none by a visitor | After more runs |
| "Wait for the deadline" in the guided run | Switched off on this page (`flags.mode1`); the contracts support it and runs #6, #9 and #10 used it | Later |
