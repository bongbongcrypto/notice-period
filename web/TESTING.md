# Testing notes for the page

Date of these runs: 2026-11-21 (UTC), after the review fixes of that day. The page is plain HTML, CSS and JavaScript
with no build step. A row is listed only if it was run on this state of the files and its output was read.
Nothing here was run with a real wallet.

Two kinds of evidence, kept apart:

- Part 1 can be redone by anyone from this repository and the public endpoints.
- Part 2 was run with test tooling that is not in this repository: a local server that injects a fake wallet
  (EIP-6963 and EIP-1193) and swaps the page's one network function for a small simulator of the two chains.
  It proves the page's own logic and wording. It does not prove a real wallet, real gas estimation or the network.

Browsers used: a Chromium-based browser pane (console, script reads, clicks) at 1280, 1024, 768, 390 and 360 wide, and
headless Microsoft Edge with a fresh profile for each capture.

## How to open it

- From a local server: `python -m http.server 8000 --bind 127.0.0.1` in this folder, then `http://127.0.0.1:8000/`.
- By double click on `index.html`. Checked: the page loads its own scripts under its Content-Security-Policy from
  a `file://` address and the live reads work.

## 1. Against the live public endpoints, no wallet

| What | Result |
|---|---|
| Console of the shipped page under the shipped policy | No error, no policy violation. Two info lines (`state: idle`, `state: no-wallet`) |
| Hosts contacted by a full load (resource entries) | The page's own origin (1 stylesheet, 9 scripts), `api.morpho.org` (1), `base-sepolia-rpc.publicnode.com` (7), `lasna-rpc.rnk.dev` (9). `sepolia.base.org` is contacted only as the fallback |
| Recorded runs re-read by receipt | Run 1 and run 2: three receipts each, status 1, the `Submit`, `ExitRequested` and `WatchEnded` logs linked by watch id and by the origin transaction hash, the token `Transfer` from the vault to the depositor equal to the redeemed assets, block times from both chains. Page line: `Three receipts re-read from both chains at 13:25:19 UTC.` |
| Seconds from live block times | Run 1: Reactive +0 s, deposit back +2 s, 178 s of notice left. Run 2: +61 s (timer), +62 s, 118 s |
| `refTx` on the Lasna receipt | Run 1 (leave now): the Base Sepolia transaction, `refChainId` `0x14a34`. Run 2 (deadline): a Lasna transaction, `refChainId` `0x512577`, and the Base Sepolia hash as topic 2 of its `ExitRequested` log |
| Live values | `nextWatchId` 3 (2 runs), 10 of 10 runs left today, float 4.79 lREACT, both debts 0, `LEAD()` 120 |
| Morpho public API | 33 changes waiting in 8 vaults ($85.2M) at 13:05 UTC: 30 cap increases, 3 shorter waiting periods. The query in the README returns the same count |
| The log filters the guided run uses, sent to the real endpoints with known answers | `ExitRequested` by watch id alone on Lasna: 1 log for run 1 and 1 for run 2, each carrying its origin hash. `WatchEnded` by watch id alone on Base Sepolia: 1 log each, through both endpoints |
| The reads added for the vault check | `totalSupply()` and the token balance of a real demo vault (0 and 0), `previewRedeem(100000000)` on it (100000000), also as a batch through the fallback endpoint |
| The two new curator calls, as a read-only call against a real demo vault | `submit(decreaseTimelock(addAdapter selector, 77))` and `submit(setIsAllocator(address, true))`: accepted from the vault's curator, refused from a stranger with `Unauthorized` (`0x82b42900`). No transaction was sent |
| `#run=2` opened directly | No scroll. The first screen shows run 2 with the caption `Run #2 on testnet, "wait for the deadline" mode, on our own demo vault`. The panel replays it in about 8 s and says that the 61 s wait is played back faster, and what that mode is |
| Run links | Clicking `#2` when the address already says `#run=2` replays it. `Replay another run` moves to run 1 and the address follows (`#run=1`) |
| A slow Lasna endpoint (its requests made to hang 12 s) | `Reading run #1` at once, the replay from the recorded copy 1.5 s later |
| Double-clicked file copy (headless Edge, `--dump-dom`) | Scripts ran, state `no-wallet`, the check line, the live Morpho count and the health line were filled |
| Nothing moves when data arrives | Positions of 18 blocks recorded before the page's script ran and compared afterwards: 0 moved at 1280 and at 390, with live data, with every read failing, after a retry, and with a wallet present. Inserting a 30 px block makes the same check report all 18 as moved |
| Width | No sideways scroll at 1280, 1024, 768, 390 and 360, in each of the 55 states. No heading, table heading or button ends on a lone word at those five widths |
| The three-record table | One line per record (37 px) in the run panel and on the first screen at 1280 and at 768 |
| Phone, 390 wide | The two marks of a 2 s run are 8 px apart and of different length. Hash links are 84 by 42 px or more, run number links 27 by 44 px |
| Type sizes in use | 13, 16, 20, 28 and 44 px (32 for the headline on a phone) |
| Reduced motion (headless Edge with `--force-prefers-reduced-motion`) | The replay of run 2 shows its end state at once; without the flag it is still at the first record after 4.5 s |
| Failure of every read | Forced in the test copy: the first screen keeps the recorded run with its links, says `Could not re-check right now; this is the recorded copy from 21 Nov 2026`, shows the dated Morpho snapshot, and offers `Try again` controls. Pressing them restored the live values |
| Static checks | Every `0x` literal of 8 or more hex digits in this folder is computed from a Solidity signature with a Keccak-256 that is first checked against `transfer(address,uint256)` = `0xa9059cbb`, or was read from the chain. No inline script, style or handler, no `eval`, no `innerHTML`, no browser storage, no cookie. Every outside host named in the files is on a fixed list; a planted unknown host fails the check |
| Print | A PDF was produced; it was not looked at |

## 2. With a fake wallet and simulated chains (tooling not in this repository)

| Path | Result |
|---|---|
| Encoder and decoder | 15 of 15: the seven real transaction inputs of the recorded run byte for byte (`create`, `mint`, `approve`, `deposit`, `approve`, `arm`, `submit`), the four real logs, the layouts of `increaseAbsoluteCap`, `decreaseTimelock` and `setIsAllocator`, one error. A deliberately wrong offset in `submit(bytes)` turns it red (14 of 15) |
| Full run by clicks | connect, deposit (4 confirmations), watch (2), new adapter (1), deposit returned: 8 wallet requests, every button clicked twice and sent once |
| A watch without "new adapter" | Buttons offered: `Schedule a shorter waiting period`, `Schedule a cap increase instead`, each with a line saying whether the watch covers it. The cap increase: `Checking for 20 s that nothing moves`, then `The curator scheduled a cap increase. Your watch does not cover that kind.` with three buttons: the covered change, `Turn the watch off`, `Withdraw my deposit now`. The covered change then returned the deposit |
| A watch for cap increases only | Primary button `Schedule a cap increase`. The other button schedules a new adapter: `The curator scheduled a new adapter. Your watch does not cover that kind.` Then the cap increase returned the deposit |
| A watch for a new allocator only | `Schedule a new allocator` returned the deposit |
| Every state on screen | 55 states rendered at 1280 and at 390: no overflow, no unfilled value, no control smaller than 24 px, only native buttons and links |
| Every button of every state | 82 buttons: 80 pressed, 2 disabled by design, 0 dead, 0 errors, all reachable by hit test. A planted dead button was reported |
| Two wallets | Chooser with both names and icons; a name containing markup is shown as text |
| Wrong network | `wrong-network`, switch, continues. With the switch refused: `switch-refused` with the manual values |
| No test ETH | `Not enough test ETH for gas` with the address and the faucet link |
| Limits before the first confirmation | `runs-used-up`, `address-used-up`, `slots-full`, `float-empty`, each with 0 wallet requests |
| A limit reached after the deposit | The day's runs used up by others between the deposit and the watch: the state says `Your 100 demo dollars are still in your vault` and offers `Withdraw my deposit now`, which paid 100 back |
| Rejected confirmation | In the deposit: `You rejected confirmation 2 of 4`, `Continue` went on without a second vault. In the curator step: `You rejected confirmation 1 of 1` |
| Wallet busy, connection rejected | `wallet-busy` and `connect-rejected`, both recover with `Try again` |
| Simulation reverts | `would-fail` with the sentence and the contract error name; no wallet request was opened |
| Demo dollars sent to a new vault before the deposit | After `create` the page stops with `Someone tampered with this new vault` and 1 wallet request spent. `Make another vault` made a clean one and the deposit went through (5 requests in all). With every new vault tampered: the second stop says so and the replay is offered |
| Reactive Lasna unreachable during the result wait | The exit landed meanwhile: the page still showed `Your deposit came back by itself` with the Base Sepolia records and `not read: Reactive Lasna did not answer` in Reactive's row. Once the endpoint answered, that row was filled in by itself |
| Reactive Lasna unreachable before the curator's change | `Cannot reach Reactive Lasna right now`, with the deposit sentence and `Withdraw my deposit now`; nothing was scheduled |
| Reactive never reacts | `Slower than usual` at 21 s, `missed` at 46 s, second change, `reactive-timeout` 93 s later, withdraw by hand, turn the watch off |
| Reactive answers the first change late | After `missed` and a second change, the exit for the first one arrived at 60 s: `returned` with the first change's hash and time, and the line `Reactive reacted to your earlier change` |
| Watch refused, subscription never arrives | `watch-refused` and `subscribe-slow` (after 60 s), both end with the watch off and no dead end |

## 3. Not run

| What | Why | Where it can run |
|---|---|---|
| Any step with a real wallet: connection, the seven confirmations, the real deposit coming back, the two new curator calls as real transactions | No wallet was used for these tests | A person with a browser wallet on the deployed page |
| Whether wallet extensions inject their provider under `script-src 'self'` | Needs a real extension | First thing to check in the real-wallet walk |
| The deployed address | The page is not deployed yet | After hosting is switched on |
| Reload in the middle of a real run, two tabs, a second browser engine, private mode | Only the simulator was available; it forgets its state on reload | Real-wallet walk |
| The page with scripts switched off | Not rendered. Read in the source: the recorded runs and their links are in the HTML, and the health line is plain text until the script runs | Any browser with scripts off |
| A layout-shift score from the browser's own meter | Not measured; the position check in part 1 stands in for it | A visible browser with developer tools |
| Activation with Enter and Space, a screen reader | Not run. Every control is a native button, link or checkbox; one polite live region announces state headlines | A person |
| `callback-slow` and `deposit-short` by their real cause | Rendered and their buttons pressed, but the 90 s wait and the last-moment price move were not driven | Simulator or real run |
| A late exit that lands before the second change is sent | Read in the code only (the result is looked up by watch id when the watch is found ended) | Simulator |
| A table with many runs and with visitor runs | Only two runs exist on chain | After more runs |
| "Wait for the deadline" in the guided run | Switched off on this page (`flags.mode1`); the contracts support it and run 2 used it | Later |
