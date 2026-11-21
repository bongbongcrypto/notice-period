# Testing notes for the page

Date of these runs: 2026-11-21 (UTC). The page is plain HTML, CSS and JavaScript with no build step.
A step is listed as verified only if it was run and its output was read. Nothing here was run with a real wallet.

## How to open it

- From a local server: `python -m http.server 8821 --bind 127.0.0.1` in this folder, then `http://127.0.0.1:8821/`.
- By double click on `index.html`. This was checked: the page loads its own scripts under its Content-Security-Policy
  from a `file://` address and the live reads work (see part 1).

## 1. Verified against the live public endpoints (no wallet)

Run in Microsoft Edge (a browser pane at 1280 and 390 wide, and headless Edge with a fresh profile).

| What | Result |
|---|---|
| Console of the shipped page under the shipped policy | No error, no policy violation. Two info lines (`state: idle`, `state: no-wallet`) |
| Hosts contacted by a full load | The page's own origin, `api.morpho.org`, `base-sepolia-rpc.publicnode.com`, `lasna-rpc.rnk.dev`. `sepolia.base.org` is contacted only as the fallback |
| Recorded runs re-read by receipt | Run 1 and run 2: three receipts each, status 1, the `Submit`, `ExitRequested` and `WatchEnded` logs linked by watch id and by the origin transaction hash, the token `Transfer` from the vault to the depositor equal to the redeemed assets, block times from both chains. Page line: `Checked against both chains just now: three receipts and their block times` |
| Seconds computed from live block times | Run 1: Reactive +0 s, deposit back +2 s, 178 s of notice left. Run 2: +61 s, +62 s, 118 s |
| `refTx` on the Lasna receipt | Run 1 (leave now): equals the Base Sepolia transaction, `refChainId` `0x14a34`. Run 2 (deadline): a Lasna transaction, as expected for a timer tick |
| Live counters | `nextWatchId` 3 (2 runs), 10 of 10 runs left today, float 4.79 lREACT, exit contract reserve 0.004998 ETH, both debts 0, 0 active watches of 8 |
| Search of the last 27 hours on Lasna (three 30,000-block windows) | 0 new runs, which is correct: the last run was three days earlier |
| Morpho public API | Answered cross-origin. 35 changes in 9 vaults ($85.9M) at 11:28 UTC and 33 in 8 vaults ($85.2M) at 11:42 UTC, so the number is live. 3 of a watched kind both times |
| Fallback endpoint | With the first Base Sepolia endpoint made unreachable, the same run was read and checked through `sepolia.base.org` (batch calls included); a 251-block log read went through in 100-block windows; a 50,000-block read was refused for that endpoint and reported as unreachable instead of sending 500 requests |
| `#run=2` | Opens the replay of run 2. `#run=9` shows `Run #9 does not exist yet. The latest run is #2.` Back returns to run 2 |
| Double-clicked file copy (headless Edge, `--dump-dom`) | Scripts ran, state `no-wallet`, the check line and the live Morpho count were filled |
| Layout shift | 0 on load at 1280 and at 390 (observer installed before the document, in the test copy), also 0 when every read fails and is retried |
| Width | No sideways scroll at 1280, 390 and 360. At 390 the must-see cells (deposit back, the three links, the ledger, the addresses) are inside the screen. At 390 with 200% text size: no sideways scroll |
| Text | 0 em dashes, 0 en dashes, 0 middle dots, 0 emoji in every file, every state and every attribute |
| Static checks | Every `0x` literal of 8 or more hex digits in this folder (123) is either computed from a Solidity signature with a Keccak-256 that is first checked against `transfer(address,uint256)` = `0xa9059cbb`, or read from the chain. The policy meta tag equals the specified string. No inline script, style or handler, no `eval`, no `innerHTML`, no browser storage, no cookie |
| Contrast (WCAG formula) | Body text 9.9:1, muted text 6.4:1, orange text 5.7:1, seafoam text 6.1:1 on the page background; white on the navy button 16.5:1. Non-text marks: orange 3.25:1, seafoam 4.96:1, control borders 3.7:1 |
| Failure of every read | Forced in the test copy: the first screen keeps the recorded run with its links, says `Could not re-check right now; this is the recorded copy from 21 Nov 2026`, shows the dated Morpho snapshot, and offers four `Try again` controls. Pressing them restored the live values |

## 2. Run with a fake wallet and simulated chains (not a wallet test)

A test copy served from outside this repository injects a fake EIP-6963 and EIP-1193 provider and replaces the page's one
network function with a small simulator of the two chains. Nothing is forced inside the shipped files.
This proves the page's own logic and copy. It does not prove a real wallet, real gas estimation or the real network.

| Path | Result |
|---|---|
| Encoder and decoder | 13 of 13: the seven real transaction inputs of the recorded run byte for byte (`create`, `mint`, `approve`, `deposit`, `approve`, `arm`, `submit`), the four real logs, the cap-increase layout, one error. A deliberately wrong offset in `submit(bytes)` turns the test red |
| Full run by clicks | connect, deposit (4 confirmations), watch (2), cap increase (ignored after 20 s), new adapter, deposit returned. 9 wallet requests for 18 clicks: every button was clicked twice and sent once |
| Every state on screen | 51 states rendered at 1280 and at 390: no overflow, no unfilled value, no control smaller than 24 px, only native buttons and links |
| Every button of every state | 72 presses, 0 dead buttons, all reachable by hit test. A planted dead button was reported, so the check bites |
| Two wallets | Chooser with both names and icons; a name containing markup is shown as text |
| Wrong network | `wrong-network`, switch, continues. With the switch refused: `switch-refused` with the manual values |
| No test ETH | `no-gas` with the address and the faucet link |
| Limits | `runs-used-up`, `address-used-up`, `slots-full`, `float-empty`, each before the first confirmation |
| Rejected confirmation | `You rejected confirmation 2 of 4`; `Continue from step 2` went on without creating a second vault |
| Wallet busy, connection rejected | `wallet-busy` and `connect-rejected`, both recover with `Try again` |
| Simulation reverts | `would-fail` with the sentence and the contract error name; no wallet request was opened |
| Reactive never reacts | `Slower than usual` at 20 s, `missed` at 45 s, second change, `reactive-timeout` at 90 s, withdraw by hand, turn the watch off |
| Watch refused, subscription never arrives | `watch-refused` and `subscribe-slow`, both end with the watch off and no dead end |

## 3. Not run

| What | Why | Where it can run |
|---|---|---|
| Any step with a real wallet: connection, the seven confirmations, the real deposit coming back | No wallet is used on the machine that built this | A person with a browser wallet on the deployed page; or the anvil job in CI with a forwarding provider |
| Whether wallet extensions inject their provider under `script-src 'self'` | Needs a real extension | First thing to check in the real-wallet walk |
| The deployed address | The page is not deployed yet | After hosting is switched on |
| Reload in the middle of a real run, two tabs, a second browser engine, private mode | Only the simulator was available; it forgets its state on reload | Real-wallet walk |
| Activation with Enter and Space | The automation tool cannot send real key codes. Every control is a native button, link or checkbox | Keyboard walk by a person |
| A screen reader | Not available here. One polite live region announces state headlines | A person |
| `callback-slow` by timeout | Rendered and its buttons pressed, but the 90 s wait was not driven | Simulator or real run |
| Reduced motion | The style rules and the replay branch exist; not exercised | A browser with the setting on |
| Print | A PDF was produced (5 pages); it was not looked at | Print preview by a person |
| A table with many runs and with visitor runs | Only two runs exist on chain | After more runs |
| "Leave only if still scheduled near the end" in the guided run | Switched off on this page (`flags.mode1`); the contracts support it and run 2 used it | Later |
