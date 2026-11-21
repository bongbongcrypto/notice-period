# Testing notes for the page

Date of these runs: 2026-11-21, about 14:20 to 14:45 UTC, on the files as they are in this folder. The page is plain
HTML, CSS and JavaScript with no build step. A row is listed only if it was run on this state of the files and its
output was read, unless the row says "not repeated". Nothing here was run with a real wallet.

Two kinds of evidence, kept apart:

- Part 1 can be redone by anyone with this folder, a browser with developer tools, and the public endpoints.
- Part 2 was run with test tooling that is not in this repository: a local server that injects a fake wallet
  (EIP-6963 and EIP-1193) and swaps the page's one network function for a small simulator of the two chains, plus
  scripts that force every state, press every button, compare positions and scan the files.
  It proves the page's own logic and wording. It does not prove a real wallet, real gas estimation or the network.

Browsers used: a Chromium-based browser pane (console, script reads, clicks) at 1280, 1024, 816, 768, 390 and 360
wide, and headless Microsoft Edge with a fresh profile for each capture.

## How to open it

- From a local server: `python -m http.server 8000 --bind 127.0.0.1` in this folder, then `http://127.0.0.1:8000/`.
- By double click on `index.html`. Checked: the page loads its own scripts under its Content-Security-Policy from
  a `file://` address and the live reads work.

## 1. Redoable from this folder: the shipped page against the live public endpoints, no wallet

| What | How | Result |
|---|---|---|
| Console under the shipped policy | Open the page, read the console | No error, no policy violation. Two info lines (`state: idle`, `state: no-wallet`) |
| Hosts contacted by a full load | Network tab, or `performance.getEntriesByType('resource')` | The page's own origin (1 stylesheet, 10 scripts), `api.morpho.org` (1), `base-sepolia-rpc.publicnode.com` (7), `lasna-rpc.rnk.dev` (9). `sepolia.base.org` only as the fallback |
| Recorded runs re-read by receipt | The page does it on load (`readRun` in `run.js`) | Run 1 and run 2: three receipts each, status 1, the `Submit`, `ExitRequested` and `WatchEnded` logs linked by watch id and by the origin transaction hash, the token `Transfer` from the vault to the depositor equal to the redeemed assets. Page line: `Three receipts re-read from both chains at 14:29:21 UTC.` |
| Seconds from live block times | Runs table | Run 1: Reactive +0 s, deposit back +2 s, 178 s of notice left. Run 2: +61 s (timer), +62 s, 118 s |
| `refTx` on the Lasna receipt | `eth_getTransactionReceipt` on `lasna-rpc.rnk.dev` | Not repeated on this state of the files (a fact of the chain, read earlier the same day). Run 1 (leave now): the Base Sepolia transaction, `refChainId` `0x14a34`. Run 2 (deadline): a Lasna transaction, `refChainId` `0x512577`, and the Base Sepolia hash as topic 2 of its `ExitRequested` log |
| Live values | `eth_call` | `nextWatchId` 3 (2 runs), 10 of 10 runs left today, float 4.79 lREACT, both debts 0, `LEAD()` 120 |
| Morpho public API | The query in the README | 33 changes waiting in 8 vaults ($85.2M) at 14:29 UTC: 30 cap increases, 3 shorter waiting periods. The page showed the same |
| The log filters of the guided run, with known answers | `eth_getLogs` with two topics | `ExitRequested` by watch id alone on Lasna: 1 log for run 1 and 1 for run 2, each carrying its origin hash. `WatchEnded` by watch id alone on Base Sepolia: 1 log each |
| The reads of the vault check | `eth_call` | `totalSupply()` and the token balance of a real demo vault (0 and 0), `previewRedeem(100000000)` on it (100000000) |
| Fallback endpoint, in the page's own code | In the console, make `NP.rpc.post` reject for the first Base Sepolia endpoint, then call `NP.rpc.getLogs` and `NP.run.readRun` | A 251-block log read: 1 log, 2 failed tries on the first endpoint, then three 100-block windows on `sepolia.base.org`. A 50,000-block read: reported as unreachable after 2 requests, not 500. Run 1 re-read and checked through the fallback |
| `#run=2` opened directly | Open the address | No scroll. The first screen shows run 2 with the caption `Run #2 on testnet, "wait for the deadline" mode, on our own demo vault`. The panel replays it in about 8 s, says that the 61 s wait is played back faster, and what that mode is |
| The check line of a replay | Open `#run=2`, read the panel | `Reading the three receipts from both chains…` while this replay's own read runs, then `Checked against both chains just now.` |
| `#run=0`, `#run=9` | Open the address | `Run #0 does not exist. Runs are numbered from 1.` and `Run #9 does not exist yet. The latest run is #2.` |
| Run links | Click | Clicking `#2` when the address already says `#run=2` replays it from the start. `Replay another run` moves to run 1 and the address follows (`#run=1`) |
| Double-clicked file copy | Headless Edge, `--dump-dom` on the `file://` address | Scripts ran, state `no-wallet`, the check line, the live Morpho count and the health line were filled |
| A script file that does not load | Headless Edge on `file://` copies of this folder: one with `states.js` deleted, one with a `throw` planted on the first line of `run.js`, one with `guard.js` and `states.js` both deleted | First two: the panel reads `A part of this page did not load, so the guided run and the replay are off. The recorded runs on this page are real and their links work.` with a `Reload the page` link. Third: the panel keeps its plain sentence from the HTML. In all three the recorded run and its three links are on the first screen. The untouched copy shows `No browser wallet found` and no such sentence |
| Reduced motion | Headless Edge with `--force-prefers-reduced-motion` | The replay of run 2 shows its end state at once; without the flag it is still at the first record after 4.5 s |
| Width of the page as loaded | Resize | No sideways scroll at 1280, 1024, 816, 768, 390 and 360 |
| The first-screen buttons | Computed style right after load, and a headless Edge capture | Both are in the HTML, opacity 1, with no animation. Without a wallet `Replay a real run` is the filled one. They keep their places |
| The three-record table | Measure the rows | On the first screen at 1280: one line (37 px) per row, for run 1 and for run 2 (`#run=2`, two-digit seconds). At 1024 and 768, run 1: one line per row. In the run panel at 1280 and 768: one line per row |
| Phone, 390 by 844 | Measure | On the first screen the three records come before the drawing: the first two transaction links end at 696 px and 778 px, inside the first screen; the third ends at 859 px. The two marks of a 2 s run are 11 px apart and of different length (12 px and 20 px). Hash links are 84 by 42 px, run number links 27 by 44 px, the two first-screen buttons 358 by 44 px |
| Type sizes in use | Computed font sizes of every text element | 13, 16, 20, 28 and 44 px at 1280. Not repeated at 768 and 390 (the earlier run the same day: the same five at 768, a 32 px headline at 390) |
| Lone last words | A script that measures the last line of every heading, button, caption, table cell, list item and paragraph, at 1280, 1024, 816, 768, 390 and 360 | None, with one exception at 1280: the `When` cell of the runs table puts the date on one line and the time on the next |
| Print | Headless Edge `--print-to-pdf` | A PDF was produced; it was not looked at |

## 2. With a fake wallet, simulated chains and scan scripts (tooling not in this repository)

| Path | Result |
|---|---|
| Encoder and decoder | 15 of 15: the seven real transaction inputs of the recorded run byte for byte (`create`, `mint`, `approve`, `deposit`, `approve`, `arm`, `submit`), the four real logs, the layouts of `increaseAbsoluteCap`, `decreaseTimelock` and `setIsAllocator`, one error. A deliberately wrong offset in `submit(bytes)` turns it red (14 of 15) |
| Full run by clicks | connect, deposit (4 confirmations), watch (2), new adapter (1), deposit returned: 8 wallet requests, every button clicked twice and sent once |
| The rule chooser and the curator buttons | Four kinds are listed. `A new adapter` is ticked and cannot be unticked, with the line `A new adapter stays on in this demo: it is the change you schedule as the curator in the next step.` With the default watch the curator buttons are `Schedule a new adapter`, `Schedule a cap increase instead` and `Turn the watch off`, each kind with a line saying whether the watch covers it |
| A cap increase first | `Checking for 20 s that nothing moves`, then `The curator scheduled a cap increase. Your watch does not cover that kind.` with three buttons: `Now schedule a new adapter`, `Turn the watch off`, `Withdraw my deposit now`. The new adapter then returned the deposit |
| A watch that does not cover a new adapter | Made by switching `flags.unprovenKinds` on for the watch step only. Back on the default page its curator buttons are `Schedule a new adapter` and `Schedule a cap increase instead`, both marked as not covered. After the new adapter: `Nothing moved, as the rule says`, with `Turn the watch off` and `Withdraw my deposit now`, no button that loops. The withdrawal paid 100 back and the watch went off |
| With `flags.unprovenKinds` switched on | The adapter box can be unticked; a watch for a shorter waiting period and a new allocator offers `Schedule a shorter waiting period`, and that change returned the deposit in the simulator. A new allocator as the scheduled change was not repeated on this state of the files. Neither kind has run against the live contracts, which is why the switch is off |
| A log read fails at "Turn the watch on" | First Base Sepolia endpoint unreachable, or answering with an RPC error, or both endpoints unreachable, each right after a deposit: the watch went on as usual (7 wallet requests). Before this fix the first two ended in `This vault is from an earlier visit` |
| The same failure when the vault's age is not known to the page | As after a reload: `Cannot reach Base Sepolia right now`, with `At the last read your deposit was in your vault`, `Try again` and `Withdraw my deposit now`. `Try again` went on to the watch once the read answered |
| A vault that really is older than the page can search | The read answers and finds no creation record: `This vault is from an earlier visit`; `Withdraw my 100 demo dollars` paid out and led back to step 1 |
| A replay while Reactive Lasna cannot be read | After a load in which both runs were checked, Lasna made unreachable, `Replay another run`: `Reading the three receipts from both chains…`, then `Could not re-check right now; this is the recorded copy from 21 Nov 2026.` |
| A slow Lasna endpoint on first load | Lasna answering 12 s late, `#run=1` opened: `Reading run #1` at once, the replay from the recorded copy 1.4 s later with `Reading the three receipts from both chains…`, and `Checked against both chains just now.` after 26 s |
| Every state on screen | 55 states rendered at 1280, 1024, 768, 390 and 360: no overflow, no unfilled value, no control smaller than 24 px, only native buttons and links. No state headline and no button ends on a lone word at 1280, 1024, 816, 768, 390 and 360 |
| Every button of every state | At 1280 and at 390: 82 buttons, 80 pressed, 2 disabled by design, 0 dead, 0 errors, all reachable by hit test. A planted dead button was reported |
| Nothing moves when data arrives | Positions of 18 blocks recorded before the page's script ran and compared afterwards: 0 moved at 1280 and at 390, with live data, with every read failing, and with a wallet present; at 1280 also after a retry. Inserting a 30 px block makes the same check report all 18 as moved |
| Failure of every read | The first screen keeps the recorded run with its links, says `Could not re-check right now; this is the recorded copy from 21 Nov 2026`, shows the dated Morpho snapshot, and offers `Try again` controls. Pressing them restored the live values |
| Static scan of this folder | Every `0x` literal of 8 or more hex digits is computed from a Solidity signature with a Keccak-256 that is first checked against `transfer(address,uint256)` = `0xa9059cbb`, or was read from the chain. No inline script, style or handler, no `eval`, no `innerHTML`, no browser storage, no cookie. Every outside host named in the files is on a fixed list; a planted unknown host fails the scan |
| Two wallets | Chooser with both names; a name containing markup is shown as text. With a wallet present `Try it with a test wallet` is the filled first-screen button |
| Wrong network | `wrong-network`, switch, continues. With the switch refused: `switch-refused` with the manual values |
| No test ETH | `Not enough test ETH for gas` with the address and the faucet link |
| Limits before the first confirmation | `runs-used-up`, `address-used-up`, `slots-full`, `float-empty`, each after the connection request and before any confirmation |
| A limit reached after the deposit | The day's runs used up by others between the deposit and the watch: the state says `Your 100 demo dollars are still in your vault` and offers `Withdraw my deposit now`, which paid 100 back |
| Rejected confirmation | In the deposit: `confirm-rejected`, then `Continue` went on without a second vault. In the curator step: `You rejected confirmation 1 of 1`, and `Continue` asked for it again |
| Wallet busy, connection rejected | `wallet-busy` and `connect-rejected`, both recover with `Try again` |
| Simulation reverts | `would-fail` with the sentence and the contract error name; no confirmation was asked for |
| Demo dollars sent to a new vault before the deposit | After `create` the page stops with `Someone tampered with this new vault`, one confirmation spent. `Make another vault` made a clean one and the deposit went through (5 confirmations in all, 2 vaults). With every new vault tampered: the second stop says `This is the second vault in a row` and the replay is offered |
| A read endpoint 2.5 s behind | A new vault that has no code there yet, and a deposit that shows no shares yet: the page read again and went on to `100 demo dollars are in your vault` with one vault and no error |
| Reactive Lasna unreachable during the result wait | The exit landed meanwhile: the page still showed `Your deposit came back by itself` with the Base Sepolia records and `not read: Reactive Lasna did not answer` in Reactive's row. Once the endpoint answered, that row was filled in by itself |
| Reactive Lasna unreachable before the curator's change | `Cannot reach Reactive Lasna right now`, with the deposit sentence and `Withdraw my deposit now`; nothing was scheduled |
| Reactive never reacts | `missed` after the first change, a second change, `reactive-timeout`, withdraw by hand, turn the watch off: 189 s from the first click, no error |
| Reactive answers the first change late | After `missed` and a second change, the exit for the first one arrived at 60 s: `returned` with the first change's time, and the line `Reactive reacted to your earlier change` |
| Watch refused, subscription never arrives | `watch-refused` and `subscribe-slow` (after 60 s), both end with the watch off and no dead end |

## 3. Not run

| What | Why | Where it can run |
|---|---|---|
| Any step with a real wallet: connection, the seven confirmations, the real deposit coming back | No wallet was used for these tests | A person with a browser wallet on the deployed page |
| A shorter waiting period or a new allocator as the scheduled change, on the live contracts | Never run as real transactions; the page keeps both off (`flags.unprovenKinds`). Read-only `eth_call`s of both, from a real vault's curator, were accepted earlier the same day and not repeated | A real run for each, then the switch |
| Whether wallet extensions inject their provider under `script-src 'self'` | Needs a real extension | First thing to check in the real-wallet walk |
| The deployed address | The page is not deployed yet | After hosting is switched on |
| Reload in the middle of a real run, two tabs, a second browser engine, private mode | Only the simulator was available; it forgets its state on reload | Real-wallet walk |
| Whether the public endpoints really answer a block behind, and how often their log reads fail | Not measured. The page treats an empty answer as "not known yet" and a failed log read as "try again" either way | Many reads right after a real transaction |
| The page with scripts switched off | Not rendered: the headless capture with scripts blocked came back empty. Read in the source: the recorded runs, their links, the two first-screen buttons and one plain sentence in the panel are in the HTML | Any browser with scripts off |
| A layout-shift score from the browser's own meter | Not measured; the position check in part 2 stands in for it | A visible browser with developer tools |
| Activation with Enter and Space, a screen reader | Not run. Every control is a native button, link or checkbox; one polite live region announces state headlines | A person |
| `callback-slow` and `deposit-short` by their real cause | Rendered and their buttons pressed, but the 90 s wait and the last-moment price move were not driven | Simulator or real run |
| A late exit that lands before the second change is sent | Read in the code only (the result is looked up by watch id when the watch is found ended) | Simulator |
| A table with many runs and with visitor runs | Only two runs exist on chain | After more runs |
| "Wait for the deadline" in the guided run | Switched off on this page (`flags.mode1`); the contracts support it and run 2 used it | Later |
