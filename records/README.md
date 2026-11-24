# Run records

One JSON file per record, re-derived from public receipts by `python scripts/runs.py --check` (add `2026-11-22` or
`2026-11-18` for one deployment). A run number is the watch id (`watchId` in each file), as in the README and on the
page. File numbers count records in the order they were written, so they are not run numbers: a run that was turned
on and fired or turned off later has two files, and the burst test has no watch.

## 22 Nov 2026 contracts (real Morpho Vault V2s)

| File | Run | What |
|---|---|---|
| `2026-11-22-1.json` | 1 | "leave now", new adapter: exit |
| `2026-11-22-2.json` | 2 | watch turned on |
| `2026-11-22-3.json` | 2 | the same watch turned off by its owner |
| `2026-11-22-4.json` | none | burst test: three new adapters in one `multicall` on run 1's vault after its watch had ended; nothing delivered, float 8.9037806 lREACT before and after |
| `2026-11-22-5.json` | 3 | "leave now", shorter waiting period: exit |
| `2026-11-22-6.json` | 4 | "leave now", new allocator: exit |
| `2026-11-22-7.json` | 5 | "leave now": a cap increase the watch does not cover moves nothing, then a new adapter: exit |
| `2026-11-22-8.json` | 6 | "wait for the deadline", new adapter: exit on the timer |
| `2026-11-22-9.json` | 7 | "wait for the deadline": the curator revoked the new adapter, the deposit stayed, then the owner turned the watch off |
| `2026-11-22-10.json` | 8 | "leave now" watch turned on and left on |
| `2026-11-22-11.json` | 9 | "wait for the deadline", shorter waiting period: exit on the timer |
| `2026-11-22-12.json` | 10 | "wait for the deadline", new allocator: exit on the timer |
| `2026-11-22-13.json` | 11 | "leave now" with the opt-in cap increase: exit |
| `2026-11-22-14.json` | 12 | "leave now", new adapter, pressed on the hosted page by the `page-walk` workflow: exit |

## 18 Nov 2026 contracts (our own demo vault)

| File | Run | What |
|---|---|---|
| `2026-11-18-1.json` | 1 | "leave now", new adapter: exit |
| `2026-11-18-2.json` | 2 | "wait for the deadline", new adapter: exit on the timer |
| `2026-11-18-3.json` | 3 | "leave now", shorter waiting period: exit |
| `2026-11-18-4.json` | 4 | "leave now", new allocator: exit |
| `2026-11-18-5.json` | 5 | "leave now": a cap increase the watch does not cover moves nothing, then a new adapter: exit |
| `2026-11-18-6.json` | 6 | "wait for the deadline": the curator revoked the new adapter, the deposit stayed, then the owner turned the watch off |
| `2026-11-18-7.json` | 7 | "leave now" with the opt-in cap increase: exit |
| `2026-11-18-8.json` | 8 | watch turned on and left |
| `2026-11-18-9.json` | 8 | the same watch, 10,832 s later: new adapter, exit |
| `2026-11-18-10.json` | 9 | "leave now", new adapter, the `health` workflow's check: exit |
