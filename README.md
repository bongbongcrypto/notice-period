# Notice Period

When the curator of a vault you deposited in schedules a change you did not accept, your deposit leaves by itself
before the change can take effect.

Built for the Reactive Network Omni buildathon. Testnets only: Base Sepolia (the vault side) and Reactive Lasna
(the reactive contract). No server, no key that can send the funds elsewhere: the exit happens only because the
vault emitted its own `Submit` event, the network delivered the callback, and the redeem pays the depositor and
nobody else.

Work in progress. The rule book is [SPEC.md](SPEC.md).

## Layout

| Path | What |
|---|---|
| `src/NoticeExit.sol` | Base Sepolia. Keeps the watches, redeems a depositor's shares to that depositor on the network's callback |
| `src/NoticeReactive.sol` | Lasna. Subscribes to the watched vaults' `Submit` (and `Revoke` in mode 1) and to the CRON tick while a change waits; asks for the exit |
| `src/demo/` | Our own demo token and ERC-4626 demo vault with a Morpho Vault V2 style timelock (`Submit`, `Revoke`, `Accept`). Test only, not Morpho's vault |
| `src/hello/` | The smallest full loop: an event on Base Sepolia, a reactive transaction on Lasna, a callback on Base Sepolia |
| `test/` | Unit, attack, fuzz, invariant and real-log fixture tests, with a mock system contract and callback proxy |
| `scripts/` | CI toolchain setup, the mutation check, deploy and loop scripts, the local dry run |

## Checks

Everything builds and runs in GitHub Actions (`.github/workflows/ci.yml`) on every push:

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
