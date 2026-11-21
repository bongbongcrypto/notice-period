# Notice Period

When the curator of a vault you deposited in schedules a change you did not accept, your deposit leaves by itself
before the change can take effect.

Built for the Reactive Network Omni buildathon, track "Set It and Forget It". Testnets only: Base Sepolia (the vault
side) and Reactive Lasna (the reactive contract). No server, no key that can send the funds elsewhere: the exit
happens only because the vault emitted its own `Submit` event, the network delivered the callback, and the redeem
pays the depositor and nobody else.

The rule book is [SPEC.md](SPEC.md). The page is in [`docs/`](docs): plain HTML, CSS and JavaScript, no build step and
no third-party script. Open `docs/index.html`, or serve the folder (`python -m http.server 8000 --bind 127.0.0.1`
inside `docs/`).

## Who it is for

A depositor in a curated vault (Morpho Vault V2 is the model). The curator can change the rules: add an adapter,
shorten a waiting period, add an allocator, raise a cap. The vault makes each change wait, usually days, and
announces it with an event. That waiting period is the depositor's notice, and it only helps someone who is
watching. Notice Period watches for the depositor and, for the kinds of change the depositor picked, redeems the
deposit to the depositor's own address while the change is still waiting.

How many changes are waiting right now, read from Morpho's public API (no key needed):

```
curl -s https://api.morpho.org/graphql -H "content-type: application/json" --data "{\"query\":\"{ vaultV2s(first: 1000, where: {listed: true}) { items { address totalAssetsUsd pendingConfigs(first: 200) { items { functionName validAt } } } } }\"}"
```

A change is waiting when its `validAt` (unix seconds) is later than now. On 21 Nov 2026 that was 35 changes in
9 vaults holding $85.9M: 32 cap increases and 3 shorter waiting periods. The number moves, so the page reads it
live. Cap increases are routine, which is why the default rule covers the three rarer kinds and leaves cap
increases off.

## Contracts of the 18 Nov 2026 testnet deployment

| Contract | Chain | Address |
|---|---|---|
| `NoticeExit` | Base Sepolia (84532) | [`0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8`](https://base-sepolia.blockscout.com/address/0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8) |
| `NoticeReactive` | Reactive Lasna (5318007) | [`0x00E4996c7255B919B619902E1Ac4b254D3c3f014`](https://lasna.reactscan.net/address/0x00E4996c7255B919B619902E1Ac4b254D3c3f014) |
| `DemoVaultFactory` | Base Sepolia | [`0xFFc96A898AF31e2ED652A8A0C0E90584999093CD`](https://base-sepolia.blockscout.com/address/0xFFc96A898AF31e2ED652A8A0C0E90584999093CD) |
| `DemoToken` (demo dollar, 6 decimals) | Base Sepolia | [`0x2690DF70a37939c582a800f32FFEE52ec40d150B`](https://base-sepolia.blockscout.com/address/0x2690DF70a37939c582a800f32FFEE52ec40d150B) |

Reactive's own contracts used here: the callback proxy on Base Sepolia `0x476F44b11F5C942c58f4c8E3d0300E5710743585`
and the system contract on Lasna `0x8888888888888888888888888888888888888888`.

## Two full loops on chain

Both were sent by our own test account (`0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4`) on 18 Nov 2026, each on a
demo vault of its own. Seconds are differences of block times.

| | Run 1, "leave now" | Run 2, "wait for the deadline" |
|---|---|---|
| Change scheduled (Base Sepolia) | [`0xdd4ce73f…4891`](https://base-sepolia.blockscout.com/tx/0xdd4ce73f5073de51dc3ec51c0e75fc50f01b5753c74f16ca374eb255b3544891) 01:04:46 UTC | [`0x19353d51…a378`](https://base-sepolia.blockscout.com/tx/0x19353d516295390f7ff762d3e3bdfce296fadf95b9d9dffffa435977a6b5a378) 01:06:48 UTC |
| Reactive transaction (Lasna) | [`0x1a6b032a…aa3e`](https://lasna.reactscan.net/tx/0x1a6b032aa7afc9f89e25fdef852bebbffad4ee1b750ba4fd4cc5bb6a5f84aa3e) +0 s | [`0x98b822a5…c530`](https://lasna.reactscan.net/tx/0x98b822a593a99bf8ab4d085d94f7d77a0986830755a3f15223e3c47023efc530) +61 s, on the timer |
| Deposit back in the depositor's wallet (Base Sepolia) | [`0x7f6456d9…7b04`](https://base-sepolia.blockscout.com/tx/0x7f6456d9b7938e6a205c87a86d0e95ae5e347ec160a39c1e7a7251caebc67b04) +2 s | [`0x681bd1f9…0b47`](https://base-sepolia.blockscout.com/tx/0x681bd1f976e0b708c29ffe7639d9a987701bf2f8fc89480ae97e8ace77470b47) +62 s |
| Notice left when the deposit was back | 178 s of 180 | 118 s of 180 |

In run 2 the reactive contract stored the change and asked for the exit on the first timer tick with 120 s or
less left (`LEAD` in this deployment). That is what the mode is for: the deposit stays if the curator cancels first.

## Check every claim in ten minutes

1. **The three records belong together.** Open the three links of a run. In run 1 Reactive's transaction names
   the Base Sepolia transaction as its origin. In run 2 the origin is the timer tick, and the Base Sepolia hash is a
   topic of the `ExitRequested` log. In both, the withdrawal's `WatchEnded` log carries the same hash.
2. **The deposit went to its owner.** In the withdrawal the demo dollars move from the vault to the depositor.
   In [`src/NoticeExit.sol`](src/NoticeExit.sol) the receiver is read from the watch in storage (`_end`), never
   from the callback's arguments.
3. **A cap increase never reaches Reactive by default.** [`src/NoticeReactive.sol`](src/NoticeReactive.sol)
   subscribes one filter per chosen selector (`_filter`). On the page, schedule a cap increase as the curator:
   nothing moves.
4. **Only our reactive contract can ask.** `NoticeExit.exit` accepts a call only from Reactive's callback proxy
   and only when the network says our reactive contract requested it (`onlyServiceProvider` and
   `onlyCallbackSender`, from Reactive's `AbstractCallback`).
5. **The contracts refuse what the rule book says.** See "Checks" below.

Not checkable on an explorer yet: the four contracts are not source-verified there. The source is this repository.

## What each Reactive feature does here

| Feature | What it does here | What breaks without it | Where |
|---|---|---|---|
| Event subscription with topic filters | The trigger: the vault's address, the `Submit` topic and the selector of each kind the depositor chose | A server that polls the chain and holds a hot key. With a wildcard filter, any stranger's contract could bill ours into debt and switch the exit off | `NoticeReactive._onArmed`, `_filter` |
| Subscribe and unsubscribe at runtime | One subscription per watch, added when it is turned on and removed when it ends | One hard-coded vault, and fees for watches nobody holds | `NoticeReactive._filter` (reference-counted) |
| A timer that runs only while a change is waiting | The second mode: store the change, ask for the exit `LEAD` seconds before it can run, stay if the curator revokes | Only "leave now". Left on all the time, the timer would spend the float while idle | `NoticeReactive._cronFilter`, `_onTick` |
| Callback through the callback proxy | The redeem on the vault's chain | Nothing moves the deposit. With a weaker check anyone could force an exit; the funds would still go only to their owner | `NoticeReactive._fire`, `NoticeExit.exit` |
| Blocks about one second apart | In run 1 Reactive's transaction carries the same second as the vault's event, and the deposit was back 2 s later | The exit would still beat a waiting period of days. It counts when the notice is short, as in the 3-minute demo | the run table above |

## Prior art, and why an exit

- Steakhouse's Supervisor v2 gives depositors a veto over a curator's change during the waiting period, through a
  DAO of depositors ([announcement](https://kitchen.steakhouse.financial/p/launching-supervisor-v2-and-migration)).
  A veto needs enough other depositors to act in time. An exit needs only yourself.
- Morpho Vault V2 has a Sentinel role that can revoke pending changes
  ([docs](https://docs.morpho.org/curate/tutorials-v2/sentinel/)). It is appointed by the vault's owner, not by the
  depositor.
- Monitoring services alert on pending changes. An alert still needs the depositor to be awake and to act.
- Reactive's own demos cover stop orders and liquidation protection, which trigger on price. This one triggers on a
  governance event and acts for the depositor, not for the protocol.

None of these withdraws for a depositor. Whether another tool does was searched for and not found; it was not an
exhaustive search.

## Limits, said plainly

- The demo vault and the demo dollar are ours and have no value. The vault copies the timelock and the events of
  Morpho Vault V2; it is not Morpho's vault, and this project is not affiliated with Morpho.
- A watch lasts one day in this deployment, and the demo allows 10 watches a day for everyone, 2 per address and
  8 at a time, because Reactive fees are paid from our float.
- A change with no waiting period leaves no time to exit.
- Both recorded runs exited on a new adapter. A shorter waiting period and a new allocator are kinds the contracts
  cover (SPEC.md section 3), but no testnet run has shown an exit on them yet, so the page's curator step schedules
  only a new adapter (the deposit leaves) and a cap increase (it stays).
- The demo vault counts every demo dollar it holds, and demo dollars are free to mint. So someone can send demo
  dollars to a visitor's fresh vault and skew its share price. The page refuses to deposit into such a vault; the
  contract itself does not prevent it (SPEC.md section 11).
- Everything else: [SPEC.md](SPEC.md) section 11.

## Built during the event

Everything in this repository was written from 17 Nov 2026 on, for this event: the two contracts, the demo vault,
the tests and the mutation check, the deploy and loop scripts, the page.

Choices worth knowing:

- No library on the page: ABI encoding, wallet access (EIP-6963 and EIP-1193) and RPC reads are written here, so
  the page loads nothing from anywhere else and its Content-Security-Policy can say so.
- The page keeps nothing in browser storage. Its step is recomputed from the chain, so a reload resumes.
- The toolchain is pinned by checksum and the libraries by commit; deployments run only by hand in CI, with the
  testnet key in an environment secret and nowhere else.

## Layout

| Path | What |
|---|---|
| `src/NoticeExit.sol` | Base Sepolia. Keeps the watches, redeems a depositor's shares to that depositor on the network's callback |
| `src/NoticeReactive.sol` | Lasna. Subscribes to the watched vaults' `Submit` (and `Revoke` in mode 1) and to the CRON tick while a change waits; asks for the exit |
| `src/demo/` | Our own demo token and ERC-4626 demo vault with a Morpho Vault V2 style timelock (`Submit`, `Revoke`, `Accept`). Test only, not Morpho's vault |
| `src/hello/` | The smallest full loop: an event on Base Sepolia, a reactive transaction on Lasna, a callback on Base Sepolia |
| `test/` | Unit, attack, fuzz, invariant and real-log fixture tests, with a mock system contract and callback proxy |
| `scripts/` | CI toolchain setup, the mutation check, deploy and loop scripts, the local dry run |
| `docs/` | The page: a guided run with a browser wallet, a replay of the recorded runs, live reads from both chains. Testing notes in `docs/TESTING.md` |

## Checks

Everything builds and runs in GitHub Actions (`.github/workflows/ci.yml`) on every push that touches the contracts,
tests or scripts (pushes that change only the page or prose are skipped):

- `forge test`: unit and attack tests (each refusal test sits next to a sibling call that succeeds and checks the
  exact error), fuzz tests, invariants over random visitor, curator, clock and attacker actions, and fixture
  tests that feed real logs read from Base and Lasna;
- mutation check: `scripts/mutations.py` removes one refusal rule at a time and the named test must fail;
- dry run: the same deploy and loop scripts the testnet workflows use, run against two local anvil chains with
  the mock network contracts at the real addresses and a relay script playing the network.

Toolchain: Foundry v1.9.0 and solc 0.8.30, both checked against sha256 digests; the sponsor library
`reactive-lib-omni` and `forge-std` are fetched at pinned commits in CI and never committed. EVM target `cancun`.

## Testnet workflows (manual)

`deploy-hello`, `deploy-system` and `loop` run only by hand, inside the `testnet` environment (main branch only),
with the key in that environment's `TESTNET_KEY` secret. Each stops before sending anything when a balance is
zero, unknown or too small, and prints addresses and transaction hashes. `loop` fires the origin event and waits
for the reactive transaction and the callback, then prints the three hashes and the seconds between them.

## Licence

MIT, see [LICENSE](LICENSE). The sponsor library fetched in CI has its own terms.

Built by Bongbong ([@bongbongcrypto](https://x.com/bongbongcrypto)).
