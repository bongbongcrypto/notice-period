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

## Contracts of the 22 Nov 2026 testnet deployment: real Morpho Vault V2s

These contracts watch vaults made by Morpho's own `VaultV2Factory` on Base Sepolia
(`0xE3a2CEbca662d99D0F279aF13a6bb8c9825D2ea0`), so the vault in a run is Morpho's Vault V2 code, not our copy.
`MorphoVaultMaker` makes one for the caller, with the demo dollar as its asset and a 180 s waiting period, and
hands it over: the caller is its curator and owner. The callback gas limit is 1,000,000 (the 18 Nov pair: 600,000),
and a "leave now" watch has no end date (SPEC.md section 11). Deployed by the `deploy-system` workflow, run
45007627595, from commit 3f47b8c ([`deployments/2026-11-22.json`](deployments/2026-11-22.json)). All four match their
source exactly on Sourcify, and our `verify` workflow found the code on chain equal to the build of that commit
([`status/bytecode-2026-11-22.json`](status/bytecode-2026-11-22.json)).

| Contract | Chain | Address |
|---|---|---|
| `NoticeExit` | Base Sepolia (84532) | [`0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca`](https://base-sepolia.blockscout.com/address/0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca) |
| `NoticeReactive` | Reactive Lasna (5318007) | [`0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32`](https://lasna.reactscan.net/address/0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32) |
| `MorphoVaultMaker` | Base Sepolia | [`0x373628f4D8edA26E5ced03a4ec76Fa38162f6cC5`](https://base-sepolia.blockscout.com/address/0x373628f4D8edA26E5ced03a4ec76Fa38162f6cC5) |
| `DemoToken` (demo dollar, 6 decimals) | Base Sepolia | [`0xA73cD0eCA5bda9c98EFdEc8bbc7c32684d36A5D7`](https://base-sepolia.blockscout.com/address/0xA73cD0eCA5bda9c98EFdEc8bbc7c32684d36A5D7) |

Run 1 on these contracts, 22 Nov 2026, with a depositor that is not the curator. The second key deposited 100 demo
dollars in a vault made through `MorphoVaultMaker`
([`0x43b0CED4…8C23`](https://base-sepolia.blockscout.com/address/0x43b0CED4AF6180eF0251C50454D16EF389D08C23)) and turned a watch on at 09:30:20 UTC.
The curator (`0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4`) scheduled a new adapter at 09:30:39 UTC
([`0xc9741124…e783`](https://base-sepolia.blockscout.com/tx/0xc974112485f9350817cb58a35418cc309b7d27b536dfa3da3e4a08eeba9ce783)),
Reactive answered (Lasna's block time is 1 s earlier)
([`0xf9d98a07…88a9`](https://lasna.reactscan.net/tx/0xf9d98a074ebb38114108434a8704e50e659929c25ab510c0644e35602b4b88a9)),
and the deposit was back 1 s later
([`0x85724300…f549`](https://base-sepolia.blockscout.com/tx/0x85724300cdc2c5a21cf1f56c58133094f6f07e694644fa1d692368d296e1f549)),
179 s before the change could run. That callback's transaction had a gas limit of 1,000,000 and used 174428.

Runs 2 to 8 on these contracts followed the same day and runs 9 to 12 on 23 Nov 2026, each on a new vault made
through `MorphoVaultMaker`. A run
number here is the watch id, as on the page. The first key is the curator in runs 1 to 11; the second key is the
depositor in runs 1, 5, 7, 8 and 10, and both depositor and curator in run 12. Seconds are differences of block
times.

So far on these contracts: twelve watches, all our own tests. Nine ended in an exit (six "leave now",
three "wait for the deadline"), two were turned off by their owners (run 2, and run 7 after its change was
revoked) and one is still on (run 8).

| | Run 3, a shorter waiting period | Run 4, a new allocator | Run 5, a new adapter after an ignored cap increase | Run 6, "wait for the deadline" |
|---|---|---|---|---|
| Change scheduled (Base Sepolia) | [`0x4fa10231…16ce`](https://base-sepolia.blockscout.com/tx/0x4fa102311a96226837e5f07850028f40edc472d33d89a6b7d25f727e174616ce) 09:43:16 UTC | [`0xb2f3b820…affb`](https://base-sepolia.blockscout.com/tx/0xb2f3b82017938a457a5dd5957cef1e4e54c5a92c400fbba2f6853964a8fbaffb) 09:44:17 UTC | [`0x6e0edc92…a633`](https://base-sepolia.blockscout.com/tx/0x6e0edc92588549cdc8854ce32501f4602eb0654bcc384432a66841794497a633) 09:46:22 UTC | [`0x9b56fa04…2bfb`](https://base-sepolia.blockscout.com/tx/0x9b56fa046d73aaccb548b72993f443d6e248928c136f4b0d0c9e32cd10d52bfb) 09:47:33 UTC |
| Reactive transaction (Lasna) | [`0x06f32120…cc82`](https://lasna.reactscan.net/tx/0x06f32120122d36b696c2d80d9ebaef67b36de0dad0e88cfbf00846465742cc82) +0 s (block time 1 s earlier) | [`0xf418f45b…9fea`](https://lasna.reactscan.net/tx/0xf418f45b402d158c4253c0fc01c581fc851664947a4833159acd6abb3f669fea) +0 s | [`0x0dd6304d…a4b1`](https://lasna.reactscan.net/tx/0x0dd6304d6a037393516f8cb1c7d4bd52e6d2c6ba008c8068be5b3dc274c3a4b1) +0 s (block time 1 s earlier) | [`0x14235447…f975`](https://lasna.reactscan.net/tx/0x14235447a26e0eb8da3bd05412d0055e9cf64797b6874e9344f342e70cf0f975) +63 s, on the timer |
| Deposit back in the depositor's wallet (Base Sepolia) | [`0xd221d597…8e48`](https://base-sepolia.blockscout.com/tx/0xd221d597fa2de2284414b979375a4d1c0dfb3865f8c8251fa4e5e58fc0c68e48) +1 s | [`0xde051159…3521`](https://base-sepolia.blockscout.com/tx/0xde051159cc4782505f1834624cd1ff4c783c0e4d4348d535d0896bf625773521) +2 s | [`0xdea82586…2a93`](https://base-sepolia.blockscout.com/tx/0xdea82586747b2f21766e4e5831a5acd4b7a0247bea6c448d4234ae231f752a93) +1 s | [`0x5b28027a…a4eb`](https://base-sepolia.blockscout.com/tx/0x5b28027a2cf02ae7d5b0aca870acd092925e7596e3c30dea46bc05909120a4eb) +65 s |
| Notice left when the deposit was back | 179 s of 180 | 178 s of 180 | 179 s of 180 | 115 s of 180 |

- Run 2: a watch turned on and turned off again by its owner
  ([`0xe4ff116d…17ba`](https://base-sepolia.blockscout.com/tx/0xe4ff116db1fd22e3310211bb15e9668c27b6a62ee1a2b544bc839d9377b217ba), 09:40:30 UTC).
- Run 5: before the new adapter, the curator scheduled a cap increase, a kind that watch does not cover
  ([`0x0a691b4e…58f6`](https://base-sepolia.blockscout.com/tx/0x0a691b4e3ab06c6bd92559359aa779d044601b7e60e7becd31ec8458183358f6), 09:45:28 UTC).
  In Lasna blocks 8964872 to 8964915 our reactive contract logged nothing for the watch, and its stray and unknown
  counters stayed at 0.
- Run 7 is the one where the deposit must stay. On a "wait for the deadline" watch the curator scheduled a new
  adapter at 09:49:34 UTC
  ([`0x64cac9a2…4e43`](https://base-sepolia.blockscout.com/tx/0x64cac9a2abb471391fb2a19b74ca3b159b8b90a3570da191d9a1f301fc214e43))
  and revoked it 22 s later
  ([`0xe5379a15…dc92`](https://base-sepolia.blockscout.com/tx/0xe5379a158e5aaed53e7af9922e8b6ddf5188558bd7c10527df8fe0c3d279dc92));
  Reactive recorded the revoke in the same second
  ([`0x3f0a508f…903b`](https://lasna.reactscan.net/tx/0x3f0a508f5c14511c05a5e1454fd023915a58be59492790190b7a5268bca5903b)).
  No exit was asked in Lasna blocks 8965083 to 8965300, which run 30 s past the time the change could have run
  (09:52:34 UTC), and all the depositor's shares stayed in the vault until the depositor turned the watch off
  ([`0xe860137f…a96e`](https://base-sepolia.blockscout.com/tx/0xe860137fb6983df4a09fac39d4342304be2ede400c959321c8c88284f0e6a96e)).
- Run 8 is a watch left on. A "leave now" watch has no end date on these contracts; a change will be scheduled on
  its vault later, to show a watch that waited days.
- Runs 9 to 11, on 23 Nov 2026, cover the kinds the timer mode had not been run on, and the opt-in kind. Run 9,
  "wait for the deadline" on a shorter waiting period: the deposit was back 63 s after the curator's transaction,
  117 s before the change could run ([`0xb28dd039…e089`](https://base-sepolia.blockscout.com/tx/0xb28dd039c4677ebbf82ab16db773dbc0beb417bd355efc6e40db31dcb21ae089), [`0x3283ace2…546a`](https://lasna.reactscan.net/tx/0x3283ace2058d53ad2f8c00008a17e9ecb8fe3b52f01155f6a49fdc024fbb546a), [`0x87553a4a…078f`](https://base-sepolia.blockscout.com/tx/0x87553a4a5428ed035d68f8981e7f4945057eb2efc3848ab8fe025ad7c67b078f)).
  Run 10, the same mode on a new allocator, with the second key as depositor: 70 s after, 110 s before
  ([`0x23273662…527d`](https://base-sepolia.blockscout.com/tx/0x23273662123154ee91789ba32336500da3a19d87fa9b6be5d0b7dfb3d0a2527d), [`0x5c58356b…92a0`](https://lasna.reactscan.net/tx/0x5c58356b74abedcb3c1b4063b7c8b27f5241c913b45ca0d08b4118cbefb192a0), [`0xd5fb0d55…5aac`](https://base-sepolia.blockscout.com/tx/0xd5fb0d552aceccc3fd867c112cd279f2abbb1d5780e2b50d17885446f5f95aac)).
  Run 11, a cap increase on a "leave now" watch that opted in: 1 s after, 179 s before
  ([`0xa6a05292…d4f2`](https://base-sepolia.blockscout.com/tx/0xa6a052929d70b601b4545a2e9a69d1e71fd4e3f74c0b88eb381d7085c9d1d4f2), [`0x5e04016f…34cb`](https://lasna.reactscan.net/tx/0x5e04016fd5c3605adc92e24fa88d3ee5315bc56247db96ea5d0d2fc9d7a134cb), [`0x67d48fde…37a5`](https://base-sepolia.blockscout.com/tx/0x67d48fdeb74b26619f44f839e067b57d73d8f7aa3c9bcfb30665fdece41a37a5)).
- Run 12, on 23 Nov 2026, is the hosted page's own guided run, pressed button by button by the `page-walk`
  workflow ([run 45126645970](https://github.com/bongbongcrypto/notice-period/actions/runs/45126645970)): Chrome on the runner opened the page, and an injected wallet signed with
  the second key, which made its own vault and was both its depositor and its curator. The curator's button
  scheduled a new adapter at 06:49:58 UTC; the deposit was back 1 s after, 179 s before the change could run
  ([`0xac9323f8…7317`](https://base-sepolia.blockscout.com/tx/0xac9323f8b520e2464a8a0861919dc64131076e78f635656d6d5b05eff3b67317), [`0xbd66f4a1…37e8`](https://lasna.reactscan.net/tx/0xbd66f4a1bedfc2d2e3025c299c6a996c6a143bc3f15491c3a49f53000f8037e8), [`0xee2b1a90…9065`](https://base-sepolia.blockscout.com/tx/0xee2b1a90f07f6a0041a5accdc3048b750854b1d32f06b504154b6270f5649065)).
  The walk then read the three transactions by receipt, outside the page: 27 of 27 checks
  ([`docs/TESTING.md`](docs/TESTING.md), part 1c).
- The burst test: on run 1's vault, after its watch had ended, the curator scheduled three new adapters in one
  `multicall`
  ([`0x6d92a52c…bb8f`](https://base-sepolia.blockscout.com/tx/0x6d92a52c571396ca88227c30a7300399307649653a33389b642b58fcb23cbb8f), 09:41:08 UTC).
  In Lasna blocks 8964625 to 8964684 our reactive contract had no transaction and no stray event, and its float stayed
  at 8.9037806 lREACT: once the last watch on a vault ends, that vault's changes are not delivered to us and cost
  us nothing (SPEC.md section 8).

`python scripts/runs.py --check 2026-11-22` re-reads these runs from the chains' receipts (the turn-off and the burst
have nothing to re-derive).

## Contracts of the 18 Nov 2026 testnet deployment

| Contract | Chain | Address |
|---|---|---|
| `NoticeExit` | Base Sepolia (84532) | [`0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8`](https://base-sepolia.blockscout.com/address/0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8) |
| `NoticeReactive` | Reactive Lasna (5318007) | [`0x00E4996c7255B919B619902E1Ac4b254D3c3f014`](https://lasna.reactscan.net/address/0x00E4996c7255B919B619902E1Ac4b254D3c3f014) |
| `DemoVaultFactory` | Base Sepolia | [`0xFFc96A898AF31e2ED652A8A0C0E90584999093CD`](https://base-sepolia.blockscout.com/address/0xFFc96A898AF31e2ED652A8A0C0E90584999093CD) |
| `DemoToken` (demo dollar, 6 decimals) | Base Sepolia | [`0x2690DF70a37939c582a800f32FFEE52ec40d150B`](https://base-sepolia.blockscout.com/address/0x2690DF70a37939c582a800f32FFEE52ec40d150B) |

Reactive's own contracts used here: the callback proxy on Base Sepolia `0x476F44b11F5C942c58f4c8E3d0300E5710743585`
and the system contract on Lasna `0x8888888888888888888888888888888888888888`.

## Runs on the 18 Nov 2026 contracts: seven exits and one change revoked

All runs were sent by our own test accounts (`0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4`, and for runs 5, 6 and 8 the
second key derived from it, `0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19`), each on a demo vault of its own: runs 1 and 2
on 18 Nov 2026, runs 3 to 6 on 21 Nov 2026, runs 7 and 8 on 22 Nov 2026. Run 6 is the one where the deposit must stay.
Seconds are differences of block times. Each run is a file in [`records/`](records/), and
`python scripts/runs.py --check 2026-11-18` re-reads every one of them from the chains' receipts.

| | Run 1, "leave now" | Run 2, "wait for the deadline" |
|---|---|---|
| Change scheduled (Base Sepolia) | [`0xdd4ce73f…4891`](https://base-sepolia.blockscout.com/tx/0xdd4ce73f5073de51dc3ec51c0e75fc50f01b5753c74f16ca374eb255b3544891) 01:04:46 UTC | [`0x19353d51…a378`](https://base-sepolia.blockscout.com/tx/0x19353d516295390f7ff762d3e3bdfce296fadf95b9d9dffffa435977a6b5a378) 01:06:48 UTC |
| Reactive transaction (Lasna) | [`0x1a6b032a…aa3e`](https://lasna.reactscan.net/tx/0x1a6b032aa7afc9f89e25fdef852bebbffad4ee1b750ba4fd4cc5bb6a5f84aa3e) +0 s | [`0x98b822a5…c530`](https://lasna.reactscan.net/tx/0x98b822a593a99bf8ab4d085d94f7d77a0986830755a3f15223e3c47023efc530) +61 s, on the timer |
| Deposit back in the depositor's wallet (Base Sepolia) | [`0x7f6456d9…7b04`](https://base-sepolia.blockscout.com/tx/0x7f6456d9b7938e6a205c87a86d0e95ae5e347ec160a39c1e7a7251caebc67b04) +2 s | [`0x681bd1f9…0b47`](https://base-sepolia.blockscout.com/tx/0x681bd1f976e0b708c29ffe7639d9a987701bf2f8fc89480ae97e8ace77470b47) +62 s |
| Notice left when the deposit was back | 178 s of 180 | 118 s of 180 |

In run 2 the reactive contract stored the change and asked for the exit on the first timer tick with 120 s or
less left (`LEAD` in this deployment). That is what the mode is for: the deposit stays if the curator cancels first (run 6 below).

Runs 3 and 4 used "leave now" on the two other kinds a watch covers by default, on the same contracts:

| | Run 3, a shorter waiting period | Run 4, a new allocator |
|---|---|---|
| Change scheduled (Base Sepolia) | [`0xb0934f38…18d9`](https://base-sepolia.blockscout.com/tx/0xb0934f38424d40a15e29813221e2ff5fcaa1d7890270091b79852b7afe4718d9) 19:31:53 UTC | [`0xcb46ba5b…0656`](https://base-sepolia.blockscout.com/tx/0xcb46ba5b790545fe26a4102d709c24cc2f393ec393565910ce7370176dfc0656) 19:36:24 UTC |
| Reactive transaction (Lasna) | [`0xd6781732…d950`](https://lasna.reactscan.net/tx/0xd6781732b0ebc3605e4935bbdfff19f099e7734363ee6cc825f32a1469fbd950) +0 s | [`0x394f2e9b…8aeb`](https://lasna.reactscan.net/tx/0x394f2e9b74612cead05c02972f57f16e3e07d9d88ce6962b36556b7f81f68aeb) +0 s (Lasna's block time is 1 s earlier) |
| Deposit back in the depositor's wallet (Base Sepolia) | [`0xd4e01422…eed2`](https://base-sepolia.blockscout.com/tx/0xd4e0142294a334290c093c6e55ad4ae121dd3419cc47c5c2f4d05420481aeed2) +2 s | [`0xfeefba14…15b1`](https://base-sepolia.blockscout.com/tx/0xfeefba149291d58e5bcb775d74f11e2bb589806288d0511da2c78f75b5fb15b1) +1 s |
| Notice left when the deposit was back | 178 s of 180 | 179 s of 180 |

Run 5 first checked that a change the watch does not cover moves nothing. The curator scheduled a cap increase
([`0x44f92103…ae52`](https://base-sepolia.blockscout.com/tx/0x44f92103c64c3dc4b8d2f715c1d96083c024a8ad24335f6f5cfffa957910ae52));
in the next 44 Lasna blocks (8922053 to 8922096) our reactive contract logged nothing for the watch, its stray and unknown counters
stayed at 0, and the watch stayed on. Then the curator scheduled a new adapter
([`0xcac46e4f…b252`](https://base-sepolia.blockscout.com/tx/0xcac46e4f8088ebdbb5ba4bd46ec49f79dd1a7bbeec10c5d03844edfd6c8bb252)),
Reactive answered
([`0x9100fdc7…f308`](https://lasna.reactscan.net/tx/0x9100fdc75b0896b2edfdea8f89aa019d74d4f1666d8bd1aa6b015158730df308)),
and the deposit was back 1 s later
([`0x7d7be1a6…7932`](https://base-sepolia.blockscout.com/tx/0x7d7be1a69c3518a25c63c14ac517eeb350fbbb891c552a911222e9a68ab87932)),
179 s before the change could run.

Run 6, also from the second key, checked the other half of "wait for the deadline": a change the curator takes back
moves nothing. The curator scheduled a new adapter at 21:15:37 UTC
([`0xb92cb49f…d9da`](https://base-sepolia.blockscout.com/tx/0xb92cb49fe52c9d5cccb28f2ddedb5c5c871a09890eb06a1a71d00e6bd3c9d9da))
and revoked it 18 s later
([`0x60744f1b…9a58`](https://base-sepolia.blockscout.com/tx/0x60744f1b9efb8141a85b951d9b43665fce26ebab71e301fe3f8545f6053c9a58));
our reactive contract dropped the stored change in the same second
([`0xf4c8652a…7524`](https://lasna.reactscan.net/tx/0xf4c8652a3ae410bbf960d02621142ba3821cf11e060da7ef476ece8292787524)).
Until 30 s past the time the change could have run (21:18:37 UTC), Lasna blocks 8922434 to 8922657 hold no exit
request for the watch, and all 100000000 shares stayed in the vault. The depositor then turned the watch off
([`0x997f06eb…f4c8`](https://base-sepolia.blockscout.com/tx/0x997f06eb550e05cfaf42ad8d8aad48b9591369be827dbfba2aea646efe29f4c8)).

Run 7 is the fourth kind, the one a depositor has to switch on: a watch that also covers cap increases. The curator
scheduled a cap increase at 06:20:11 UTC
([`0x7066827c…991f`](https://base-sepolia.blockscout.com/tx/0x7066827c63a73722651f68b14ec0552728107040ea8bf0dc316c23a8e76c991f)),
Reactive answered in the same second
([`0x02395d2e…71b1`](https://lasna.reactscan.net/tx/0x02395d2ebc5d87877f40082ac24ae0768b741061e3962a1ec5ab2fd8595271b1)),
and the deposit was back 2 s later
([`0xf20877f2…8597`](https://base-sepolia.blockscout.com/tx/0xf20877f28e574b7eac8341a85afff2dac7b3f38cf9adbd06571d9546fbd48597)),
178 s before the change could run. With run 5 this shows both sides of the same rule: a cap increase moves nothing
unless the depositor chose it.

Run 8 checks that a watch keeps working while nobody touches it. The second key turned it on at 06:21:12 UTC
([`0x06e42190…bea6`](https://base-sepolia.blockscout.com/tx/0x06e421902f5c3a94e9121b79671a647e8d38c16295c5e5746f1bc3fa5111bea6))
and left it. 10832 s later, at 09:21:44 UTC, the curator scheduled a new adapter
([`0x835c238c…f855`](https://base-sepolia.blockscout.com/tx/0x835c238cca37494c9aefea1dc03450ebe83ed1be0f9877751c2850c69c96f855)),
Reactive answered (Lasna's block time is 1 s earlier)
([`0x833910d1…44e0`](https://lasna.reactscan.net/tx/0x833910d12d0f9004679e29a9973e95c4d19ce2e56089dac10024a6e169bd44e0)),
and the deposit was back 1 s later
([`0x1ae72fd8…115c`](https://base-sepolia.blockscout.com/tx/0x1ae72fd8c1f51f5198bc03336063a1513d586bff8900118890e17a7c7a92115c)),
179 s before the change could run.

## Check every claim in ten minutes

1. **The three records belong together.** Open the three links of a run. In run 1 Reactive's transaction names
   the Base Sepolia transaction as its origin (on both deployments). In a "wait for the deadline" run (run 6 of
   22 Nov, run 2 of 18 Nov) the origin is the timer tick, and the Base Sepolia hash is a topic of the
   `ExitRequested` log. In both, the withdrawal's `WatchEnded` log carries the same hash.
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
6. **Re-derive it yourself.** With Python 3 and nothing else installed:
   - `python scripts/runs.py --check` reads every receipt of the recorded runs ([`records/`](records)) from public
     endpoints and stops unless the three hashes carry the same origin, the exit landed before the change could
     run, and the tokens went from the vault to the watch owner in the amount `WatchEnded` reports (add
     `2026-11-22` or `2026-11-18` to check one deployment);
   - `python scripts/replay_mainnet.py` repeats the replay below.

7. **The code on chain is this source.** The four contracts of 22 Nov match their source exactly on Sourcify
   ([`NoticeExit`](https://repo.sourcify.dev/84532/0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca),
   [`NoticeReactive` on Lasna](https://repo.sourcify.dev/5318007/0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32)); their
   bytecode comparison is in [`status/bytecode-2026-11-22.json`](status/bytecode-2026-11-22.json) (four of four,
   `verify` run [45008039542](https://github.com/bongbongcrypto/notice-period/actions/runs/45008039542)).
   On the 18 Nov deployment all four contracts and the two vaults of runs 1 and 2 are verified with an
   exact match on Sourcify ([`NoticeExit`](https://repo.sourcify.dev/84532/0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8),
   [`NoticeReactive` on Lasna](https://repo.sourcify.dev/5318007/0x00E4996c7255B919B619902E1Ac4b254D3c3f014)).
   Blockscout shows the Base Sepolia contracts of both deployments as verified (follow the addresses above). For
   18 Nov the `verify` workflow
   (run [44993160761](https://github.com/bongbongcrypto/notice-period/actions/runs/44993160761)) built the
   deployment's source commit, compared it with the code on chain first without any third party
   (`scripts/bytecode_match.py`, result in [`status/bytecode-2026-11-18.json`](status/bytecode-2026-11-18.json): six of
   six match), and only then sent the sources to Sourcify and Blockscout.

## Real vault replay

Label: replay of our deployed exit code on a real vault; Reactive not in it.

On Ethereum mainnet state at block 26,406,895, `eth_simulateV1` put the runtime code of our Base Sepolia
`NoticeExit` at its own address, armed a watch for a real holder of Gauntlet USDC Frontier (a Morpho Vault V2), and
delivered the real 13 Nov 2026 `Submit` (a shorter waiting period, log 259 of
[`0x335fe388…2441`](https://etherscan.io/tx/0x335fe3887288e04ddf6daf958b0634cd211dddd5f8bd260aaafd62ee694a2441))
as the callback proxy would. Nothing was sent; the result is in
[`status/replay-mainnet.json`](status/replay-mainnet.json):

- with the gas a 1,000,000 callback limit forwards, the holder's 5,600.30 shares were redeemed and 5,954.048177 USDC
  arrived in the holder's wallet, the amount `WatchEnded` reports;
- with the gas a 600,000 limit forwards (the limit of the 18 Nov deployment), the call ran out of gas and nothing
  moved. On this vault the exit needs a larger callback limit than the demo deployment uses.

## What each Reactive feature does here

| Feature | What it does here | Without it | Where |
|---|---|---|---|
| Event subscription with topic filters | The trigger: the vault's address, the `Submit` topic and the selector of each kind the depositor chose | A bot that watches the chain and holds a key to send the exit. Without the vault-address filter, a stranger's contract could emit matching events, bill ours into debt and switch the exit off | `NoticeReactive._onArmed`, `_filter` |
| Subscribe and unsubscribe at runtime | One topic filter per kind of change the depositor chose on the vault (three for the default watch; a cap increase adds two), subscribed when the watch is turned on. Watches on the same vault share filters by count, so the last one to end unsubscribes | Filters fixed in advance, and fees for filters no watch uses | `NoticeReactive._filter` (reference-counted) |
| A timer that runs only while a change is waiting | The second mode: store the change, ask for the exit `LEAD` seconds before it can run, stay if the curator revokes | Only "leave now". Left on all the time, the timer would spend the float while idle | `NoticeReactive._cronFilter`, `_onTick` |
| Callback through the callback proxy | The redeem on the vault's chain | Nothing moves the deposit. Without the caller check anyone could force an exit; the deposit would still go only to its owner | `NoticeReactive._fire`, `NoticeExit.exit` |
| Blocks about one second apart | In run 1 of the 22 Nov 2026 contracts Reactive's transaction landed within a second of the vault's event, and the deposit was back 1 s later | The exit would still beat a waiting period of days. It counts when the notice is short, as in the 3-minute demo | the run table above |

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

None of these withdraws for a depositor. We found no tool that exits for one depositor when a vault change is
scheduled; the search was not exhaustive.

## Limits, said plainly

- The demo dollar and `MorphoVaultMaker` are ours, and the dollar has no value. On the 22 Nov 2026 contracts each
  vault is a real Morpho Vault V2 made by Morpho's own factory through our maker (a 180 s waiting period, no gate,
  no fee); the curator in our runs is our own test account. The 18 Nov 2026 contracts used our own demo vault, which
  copies the timelock and the events of Morpho Vault V2. This project is not affiliated with Morpho.
- On the 22 Nov contracts a "leave now" watch has no end date: it ends when it fires or when its owner turns it off.
  A "wait for the deadline" watch (the page does not offer it; our own runs use it) can be ended by anyone one day
  after it was turned on, and a change scheduled in about its last 168 s can be left without an exit; such a change
  can never run before that day ends (SPEC.md section 11). The demo allows 50 watches a day for everyone, 4 per
  address, and 8 "wait for the deadline" watches at a time (4 new a day), because Reactive fees are paid from our
  float. On the 18 Nov contracts every watch lasted one day, with 10 a day for everyone, 2 per address and 8 at a time.
- A watch is served only while our float on Reactive Lasna is above zero; the page shows the float and any debt
  live. One vault holds at most three watches at a time: a fourth is refused on Reactive Lasna and stays on in
  the exit contract's record until its owner turns it off, and a place frees when one of the three ends. If the
  vault refuses the redeem, the watch ends without a retry. A version for real use would have each depositor fund
  their own watch; that is not built.
- A change with no waiting period leaves no time to exit.
- Every kind has a recorded exit on testnet, sent by our own loop workflow. On the 22 Nov contracts: the three kinds
  a watch covers by default, in runs 1, 3, 4 and 5, and the opt-in cap increase, in run 11; on the 18 Nov contracts
  the cap increase is run 7.
  The page's curator buttons encode the same calls ([`docs/abi.js`](docs/abi.js)). Against a simulated pair of
  chains ([`docs/TESTING.md`](docs/TESTING.md)) the adapter, waiting-period and allocator buttons were clicked
  through to a returned deposit, and the cap button on a watch that does not cover it. On the live contracts the
  adapter button was pressed by our own page walk (run 12); no visitor has run them yet.
- The 18 Nov demo vault counts every demo dollar it holds, and demo dollars are free to mint. So someone can send
  demo dollars to a visitor's fresh vault and skew its share price. The page refuses to deposit into such a vault;
  that contract itself does not prevent it (SPEC.md section 11).
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
| `src/morpho/` | `MorphoVaultMaker`: asks Morpho's `VaultV2Factory` for a Vault V2 and hands it to the caller (the 22 Nov deployment) |
| `src/hello/` | The smallest full loop: an event on Base Sepolia, a reactive transaction on Lasna, a callback on Base Sepolia |
| `test/` | Unit, attack, fuzz, invariant and real-log fixture tests, with a mock system contract and callback proxy |
| `scripts/` | CI toolchain setup, the mutation check, deploy and loop scripts, the local dry run, run records and their checker, bytecode match, the mainnet replay |
| `deployments/`, `records/`, `status/` | Addresses of each deployment, one file per recorded run, results of the mainnet replay and of the bytecode match (`verify.yml`) |
| `docs/` | The page: a guided run with a browser wallet, a replay of the recorded runs, live reads from both chains. Testing notes in `docs/TESTING.md` |

## Checks

Everything builds and runs in GitHub Actions (`.github/workflows/ci.yml`). It starts on a push that touches the
contracts, tests or scripts unless the commit says `[skip ci]`, and by hand; our commits usually say `[skip ci]`, and
we start it by hand on the branch head. Pushes that change only the page or prose never start it. It runs:

- `forge test`: unit and attack tests (each refusal test sits next to a sibling call that succeeds and checks the
  exact error), fuzz tests, invariants over random visitor, curator, clock and attacker actions, and fixture
  tests that feed real logs read from Base and Lasna;
- mutation check: `scripts/mutations.py` removes one refusal rule at a time and the named test must fail;
- dry run: the same deploy and loop scripts the testnet workflows use, run against two local anvil chains with
  the mock network contracts at the real addresses and a relay script playing the network;
- fork (non-blocking, its result does not fail the run): `fork/RealVault.fork.t.sol` on Ethereum mainnet state at
  block 26,406,895 from public archive endpoints, the real Vault V2 exit at 1,000,000 and 600,000 (SPEC.md
  section 12). Its four tests passed in ci run 45003290072 (22 Nov 2026).

Toolchain: Foundry v1.9.0 and solc 0.8.30, both checked against sha256 digests; the sponsor library
`reactive-lib-omni` and `forge-std` are fetched at pinned commits in CI and never committed. EVM target `cancun`.

## Testnet workflows (manual)

`deploy-hello`, `deploy-system`, `loop`, `fund`, `health` and `page-walk` run only by hand, inside the `testnet`
environment (main branch only, a deployment-branch rule of that environment on GitHub),
with the key in that environment's `TESTNET_KEY` secret. Each stops before sending anything when a balance is
zero, unknown or too small, and prints addresses and transaction hashes. `loop` fires the origin event and waits
for the reactive transaction and the callback, then prints the three hashes and the seconds between them.
Its other actions (a change the watch ignores, a revoked change, a watch held and fired later, cancel, expiry,
top-up) and `health` (a second key derived from the testnet key; reads the float and debts, runs one loop) take
their addresses from `deployments/<name>.json`. `verify` needs no key: it builds the deployment's source commit and
compares the bytecode.
`page-walk` walks the guided run of the hosted page with an injected wallet that signs only the calls listed in
the header of `scripts/page-walk.mjs`, then checks the three transactions the page showed by receipt.

## Licence

MIT, see [LICENSE](LICENSE). The sponsor library fetched in CI has its own terms.

Built by Bongbong ([@bongbongcrypto](https://x.com/bongbongcrypto)).
