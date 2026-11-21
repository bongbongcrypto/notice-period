# Notice Period: rule book

This file says what the contracts do and refuse. If the code and this file disagree, that is a bug.
All contracts are testnet contracts. The demo token and the demo vault are ours: they imitate the
events of Morpho Vault V2 and are not Morpho's vault.

## 1. The parts

| Contract | Chain | Job |
|---|---|---|
| `DemoToken` | Base Sepolia (84532) | Test token, 6 decimals, free `mint` of up to 1,000 tokens per call |
| `DemoVaultFactory` | Base Sepolia | Creates one `DemoVault` per call; the caller is that vault's curator. Keeps the list of vaults it made (`isVault`) |
| `DemoVault` | Base Sepolia | ERC-4626 vault with a timelock on curator actions. `Submit`, `Revoke` and `Accept` events have the exact shape of Morpho Vault V2 |
| `MorphoVaultMaker` | Base Sepolia | Ours (contracts after 2026-11-18). One call makes a real Morpho Vault V2 of the demo dollar through Morpho's own `VaultV2Factory` and hands it to the caller as curator and owner. Keeps the list of vaults `NoticeExit` accepts (`isVault`) |
| `NoticeExit` | Base Sepolia | The callback contract. Keeps the watches, holds share allowances, redeems shares to their owner |
| `NoticeReactive` | Reactive Lasna (5318007) | The reactive contract. Subscribes to the vaults that are watched and asks for the exit |
| `HelloOrigin`, `HelloReactive`, `HelloCallback` | Base Sepolia, Lasna, Base Sepolia | The smallest full loop: an event, a reactive transaction, a callback that records it |

No contract has an owner, an admin key, a pause switch or an upgrade path. Wiring is fixed at deployment
(immutables). There is no function that sends a user's shares or tokens anywhere except the redeem to
the share owner described in section 5.

## 2. Words used here

- **Change**: a curator action scheduled with `submit(data)` on a vault. `data` is the full call, its first
  four bytes are the selector. It can run at `executableAt`; until then it is **pending**.
- **Kind**: a group of selectors a depositor can choose to flee from.
- **Watch**: one depositor's instruction for one vault: which kinds, which mode, how many shares at most.
- **Vault revoke**: the curator cancels a pending change (`revoke(data)`, event `Revoke`).
- **Cancel**: the depositor ends their own watch (`NoticeExit.cancel`). Not the same as a vault revoke.

## 3. Kinds (bit mask)

| Bit | Kind | Selectors | Default |
|---|---|---|---|
| 1 | New adapter | `addAdapter(address)` `0x60d54d41` | on |
| 2 | Shorter timelock | `decreaseTimelock(bytes4,uint256)` `0x5c1a1a4f` | on |
| 4 | Role change (allocator) | `setIsAllocator(address,bool)` `0xb192a84a` | on |
| 8 | Cap increase | `increaseAbsoluteCap(bytes,uint256)` `0xf6f98fd5`, `increaseRelativeCap(bytes,uint256)` `0x2438525b` | off (opt-in) |

`DEFAULT_KINDS = 7`. Cap increases are off by default because they are by far the most common change
(57 of 63 pending V2 changes on 2026-11-17), so watching them would exit most users on routine changes.

"Role change" covers allocators only. In Morpho Vault V2, `setOwner`, `setCurator` and `setIsSentinel` are
owner actions that take effect at once and emit no `Submit`, so no watch can flee them.

## 4. Who can do what

### DemoVault

| Action | Who | Refusal (exact error) |
|---|---|---|
| `deposit`, `mint` | anyone | `ZeroShares()` if the deposit would mint 0 shares |
| `withdraw`, `redeem` for `owner` | the owner, or someone the owner approved for shares | `InsufficientAllowance()`, `InsufficientBalance()`, `ZeroAssets()` if a redeem would pay 0 |
| `submit(data)` | the curator | `Unauthorized()`; `DataAlreadyPending()` if the same `data` is pending |
| `revoke(data)` | the curator | `Unauthorized()`; `DataNotTimelocked()` if `data` is not pending |
| run a change (`addAdapter`, `increaseAbsoluteCap`, `increaseRelativeCap`, `decreaseTimelock`, `increaseTimelock`, `setIsAllocator`) | anyone, once the exact call was submitted and its time has come | `DataNotTimelocked()` if never submitted or already run; `TimelockNotExpired()` if early; `TimelockNotDecreasing()`, `TimelockNotIncreasing()`, `AutomaticallyTimelocked()`, `AbsoluteCapNotIncreasing()`, `RelativeCapNotIncreasing()`, `RelativeCapAboveOne()` as in Vault V2 |
| share `transfer`, `transferFrom` | the holder, or someone the holder approved | `ZeroAddress()` for receiver 0; `InsufficientBalance()`; `InsufficientAllowance()` |
| any action that pays out or mints | — | `ZeroAddress()` if the receiver is 0 (shares or assets) |
| any action that moves the token | — | the token's own revert data is passed on unchanged; `TransferFailed()` if the token reverts with no data or answers `false` |
| `constructor(asset, curator, timelock)` | the factory | `ZeroAddress()` if `asset` or `curator` is 0 |

`DemoVaultFactory`: `constructor(asset, timelock)` refuses `asset` 0 with `ZeroAddress()` and gives every vault
it makes that starting timelock (180 s in the demo deployment); `create()` is open to anyone and makes the
caller the curator of a new vault.

`MorphoVaultMaker` (ours; the vaults it makes are Morpho's code): `constructor(factory, asset, timelock)`, all
immutable, no refusal (the deploy script checks the factory before and the vault shape after). `create()` is open
to anyone and, in one transaction: picks the first salt `keccak256(caller, block number, n)` (`n` a public counter
that moves on every try and goes back when the call reverts) for which Morpho's factory holds no vault of (maker,
asset, salt), refusing with `NoFreeSalt()` after 16 taken salts; calls `createVaultV2(maker, asset, salt)`; makes itself curator; raises the timelock of
`addAdapter`, `setIsAllocator`, `increaseAbsoluteCap` and `increaseRelativeCap` to `TIMELOCK` (180 s in the
deployment; a `decreaseTimelock` of one of them then waits as long); abdicates the four gate setters and
`setPerformanceFee` and `setManagementFee` (each submitted and run in the same call, which a fresh vault allows),
so that vault never has a gate or a fee; sets the vault's name; then makes the caller curator and owner. The maker
keeps no role and holds nothing. `isVault(v)` is true only if this maker made `v` and Morpho's factory still lists
it (`isVaultV2`); a vault made directly on Morpho's factory, even in the maker's name, is not listed. Morpho's
own refusals apply inside (`DataAlreadyPending`, timelocked calls, `Abdicated`), so a failed step reverts the whole
`create()`. Block numbers are predictable, so a stranger can take one caller's 16 salts of a coming block ahead of
time (16 vault creations per block, paid by the stranger) and make that caller's `create()` refuse in that block.
Such vaults are never listed or touched and no funds move; a block the stranger did not prepare works again.

`DemoToken` (ours, test token, 6 decimals): `mint(to, amount)` is open to anyone, at most 1,000 tokens per
call: `MintTooLarge(amount, max)`, `ZeroAddress()` for receiver 0. `transfer`, `transferFrom`:
`ZeroAddress()` for receiver 0, `InsufficientBalance()`, `InsufficientAllowance()`.

Every curator selector except `decreaseTimelock` starts with the factory's timelock (180 s). As in Vault V2,
`decreaseTimelock` has no timelock of its own: `decreaseTimelock(sel, x)` waits for the current timelock of
`sel`, and neither `increaseTimelock` nor `decreaseTimelock` can target the `decreaseTimelock` selector
(`AutomaticallyTimelocked()`). Each vault has its own curator (the address that created it),
so one visitor's curator action is an event on their own vault only and cannot touch a watch on another
visitor's vault.

Rounding (ERC-4626, all in favour of the vault): `deposit` rounds shares down, `mint` rounds assets up,
`withdraw` rounds shares up, `redeem` rounds assets down. Conversion uses one virtual share and one
virtual asset: `shares = assets * (supply + 1) / (totalAssets + 1)`.

### NoticeExit

| Action | Who | Refusal (exact error), checked in this order |
|---|---|---|
| `arm(vault, kinds, mode, maxShares)` | any share owner, for their own shares only (the owner is always `msg.sender`) | `Reentrancy()`; `UnknownVault(vault)` if the registry does not list it (`DemoVaultFactory`: it did not make it; `MorphoVaultMaker`: it did not make it, or Morpho's factory does not list it); `NoKinds()`; `UnknownKinds(kinds)` for bits above 8; `BadMode(mode)` for a mode other than 0 or 1; `ZeroMaxShares()`; `NoShares()`; `NoAllowance()` if the owner has not approved this contract for any shares; `AlreadyWatching(watchId)` if the owner already has an active watch on this vault; `DailyCapForAddress()`; `DailyCapReached()`; `DailyCapForTimed()` for a mode-1 arm once `MAX_TIMED_ARMS_PER_DAY` mode-1 arms were made this UTC day (all addresses together) |
| `cancel(watchId)` | the watch owner | `Reentrancy()`; `NotWatchOwner()`; `WatchNotActive(watchId)` |
| `expire(watchId)` | anyone, for a mode-1 watch only, once `LIFETIME` (1 day) has passed since the arm | `Reentrancy()`; `NoExpiry(watchId)` for any watch that is not mode 1 (a mode-0 "leave now" watch has no expiry; an unknown id also answers this); `WatchNotActive(watchId)`; `WatchNotExpired(watchId, expiresAt)` before `armedAt + LIFETIME`. Sets status `Expired` (4), emits `WatchExpired` and `WatchCancelled` (so Lasna drops it like a cancel). Moves no shares |
| `exit(sender, watchId, vault, data, originTxHash, reason)` | the callback proxy only, and only when the network-injected `sender` is our reactive contract | `NotAuthorized(msg.sender, proxy)` for any other caller; `CallbackNotAuthorized(sender, reactive)` for any other reactive contract; `Reentrancy()`; `WatchNotActive(watchId)` for an unknown, cancelled, expired or finished watch (this is what stops a replay or a second exit); `WrongVault(watchId, vault)` if `vault` is not the watch's vault; `KindNotWatched(selector)` if `data` is not a kind this watch chose (empty `data` reads as selector 0); `AssetsNotReceived(expected, received)` if the owner did not receive the assets the vault reported |
| `coverDebt()` | anyone | pays the proxy's recorded debt of this contract from its fee reserve; `InsufficientFunds(required, available)` if the reserve is short |

`constructor(proxy, reactive, registry, armsPerAddressPerDay, armsPerDay, lifetime, timedArmsPerDay)`: all
immutable. The
payload carries the vault the reactive contract recorded for the watch, so a payload built for one vault can
never end a watch on another.

A refused `exit` reverts and changes nothing. An `exit` that is accepted always ends the watch, with one
of these outcomes in `WatchEnded`:

| Outcome | Code | When |
|---|---|---|
| `Redeemed` | 0 | Shares redeemed, assets in the owner's wallet |
| `NothingToRedeem` | 1 | The owner holds no shares or allows none to this contract |
| (retired) | 2 | Was `ChangeNotPending`: Base Sepolia no longer asks the vault again (section 6). The code is not reused |
| `RedeemFailed` | 3 | The vault's `redeem` reverted (for example short of liquidity). The revert data is in `RedeemReverted`. Shares stay with the owner |

### NoticeReactive

The constructor refuses a callback gas limit below `MIN_CALLBACK_GAS` (400,000) with
`CallbackGasTooLow(callbackGas)`: the proxy keeps about 180,000 of the limit (section 12).

Only the system contract (`0x8888…8888`) can call `react()`; anyone else gets `NotAuthorized(sender,
system)`. `react()` never reverts on an event it does not want, because a revert is billed: it counts the
event and returns. Anyone can send it lREACT or call `coverDebt()`. Nobody can take lREACT out.
`HelloReactive` and `HelloCallback` have the same open `coverDebt()`.

`WatchArmed` and `WatchCancelled` are taken only with four topics, `Submit` only with two, `Revoke` only with
three (the topic count is the log's `opCode`); any other count is counted in `unknownEvents`.

A `WatchArmed` it cannot take is refused with `WatchRefused(watchId, code)`, checked in this order: 1 bad kinds
(none, or bits above 8), 2 bad mode, 3 too many active watches, 4 vault full, 5 too many mode-1 watches
(`MAX_TIMED`, 8, a constant; section 9). A refused watch stays `Active` on Base Sepolia until its owner cancels it
(nothing tells Base about a refusal), so the page reads both sides. A `Submit` or
`Revoke` whose data is not a valid ABI encoding is counted in `unknownEvents`, never decoded blindly.

What travels in the exit callback: the scheduled call itself when it is at most 256 bytes; a longer one
travels as its 4-byte selector alone, and `ExitRequested` then carries `dataHash` 0. A curator controls the
length of the call (the ABI decoder ignores trailing bytes, so `addAdapter(x)` with 100 KB of padding still
runs), so without this bound padding could push the reaction over the 900,000 gas cap or the exit over the
callback gas limit, and switch the exit off. Only calls of at most 256 bytes are ever stored (mode 1), so a
`Revoke` of a longer call is not hashed and removes nothing.

## 5. What an exit does, and the limits on it

The exit contract redeems `min(maxShares, owner's share balance, owner's share allowance to NoticeExit)`
with `receiver = owner` and `owner = owner`, through the vault's ERC-4626 `redeem`. The receiver is read
from storage, never from the callback payload, so no input can name another receiver. After the redeem the
contract checks that the owner's asset balance rose by at least the amount the vault reported, else the
whole callback reverts. NoticeExit never holds shares or tokens: they go straight from the vault to the
owner.

An allowance larger than the watch does not let one exit take more than `maxShares`, and no other function
can use the allowance. It does outlive the watch: the leftover stays approved until the owner lowers it, and a
later watch by the same owner can use it. The page therefore approves exactly `maxShares`. To stop all exits a
user can cancel, or set the share allowance to zero.

## 6. The two modes

**Mode 0, "leave now".** When the vault emits `Submit` for a selector of a watched kind, the reactive
contract asks for the exit at once (reason 1, `Scheduled`) and ends the watch.

**Mode 1, "leave if still pending".** When the vault emits `Submit` for a watched kind, the reactive
contract stores the change (hash of `data`, `data`, `executableAt`, the origin transaction hash) and turns
on a CRON tick (Cron10, about every 10.7 s on Lasna). On each tick every watch that stores a change is
billed one reaction; a watch is due when its earliest stored change has `executableAt <= now + LEAD`
(reason 2, `Deadline`) or when it has used its reaction budget (reason 7, `Budget`). Of the due watches, the
one whose change can run first gets its exit asked for; the others wait for the next tick (one exit per
tick, because an exit releases filters, the costly part of a reaction). `LEAD` is 120 s in the demo
deployment: it covers `MAX_TIMED` (8) ticks of about 10.7 s, so even 8 mode-1 watches due together are all
served, plus the callback's trip to Base Sepolia (`test/Timing.t.sol`). Only mode-1 watches store changes, and
at most `MAX_TIMED` of them are armed at a time, whatever `MAX_ACTIVE` is.

"Still pending" is decided on Lasna only. The exit contract does not ask the vault again: an exit asked for is
carried out. A decoy is why: a curator could store a decoy change and a real one, wait for the public
`ExitRequested` of the decoy and revoke the decoy before the callback lands; a re-check on Base Sepolia would
then keep the depositor in while the real change stays pending (review finding, pinned by
`test_decoy_revoked_after_the_tick_does_not_disarm_the_watch`).

A vault revoke of a stored change removes it (matched by the hash of the full `data`, so revoking one
change does not disarm another change of the same kind). When a watch has no stored change left it stops
counting for the tick; when no watch has one, the CRON subscription is removed.

The exit is asked for at once, instead of waiting, when (reason code in brackets):
- the change is already due within `LEAD` when it is seen (3, `TooSoon`);
- the change is due later than `MAX_WAIT` (900 s on the 11-18 pair, 200 s in `scripts/deploy-system.sh`), which
  would cost too many ticks (4, `WaitTooLong`);
- `data` is longer than 256 bytes (5, `DataTooLong`);
- the watch already stores `MAX_PENDING` (3) changes (6, `PendingFull`);
- the watch has used its reaction budget (7, `Budget`), on a `Submit`, a `Revoke` or a tick.

All of these protect the depositor: when the contract cannot afford to wait, it leaves. They also mean a
curator can make every mode-1 watcher on the vault leave whenever they like (one padded change, four changes,
or one change due within `LEAD`, revoked afterwards): the funds still go only to their owners, but the
position is lost. And with `MAX_WAIT` 900 s (200 s in `scripts/deploy-system.sh`), every change on a Vault V2
with a waiting period of days is fled at once, so on such a vault mode 1 behaves like mode 0 until a slower CRON
and a larger budget are used. With the values of `scripts/deploy-system.sh` (waiting period 180 s, `LEAD` 120,
`MAX_WAIT` 200) a change is stored only if Lasna sees its `Submit` less than 60 s after it was scheduled; seen
later it is fled at once (`TooSoon`), and mode 1 then behaves like mode 0 (`test/DeployedValues.t.sol`).

Race between a vault revoke and the tick: if the revoke reaches the reactive contract first, the change is
removed and nothing is sent. If the tick fires first, the exit is on its way and is carried out, whatever the
vault says by then. So a curator who revokes in the last `LEAD` seconds may still see the depositor leave,
and a mode-1 watch ends with every fire: once a depositor has left, a new change needs a new watch.

A `Revoke` of any kind reaches every mode-1 watch on the vault (one `Revoke` filter per vault, see section 8)
and is billed to each as a reaction. When that pushes a watch over its budget, the watch leaves (reason 7)
with its earliest stored change, or with the selector of its first watched kind when it stores none. A
mode-0 watch is never billed for a `Revoke`.

## 7. Order of operations

The manual `fund` workflow uses `TESTNET_KEY` in the main-only `testnet` environment, matched against
`TESTNET_ADDRESS`, to convert faucet-funded Sepolia ETH to Lasna lREACT (default 0.1 ETH, cap 2) and
bridge ETH to the same account on Base Sepolia (default 0.05 ETH, cap 0.2). Zero skips a leg; both cannot
be zero. The contract addresses are fixed in the script. Before sending it checks:
- chain IDs and contract code;
- a Sepolia gas price of at most 1 gwei (sends go at twice the read price, legacy, fixed nonce and gas limit);
- a balance covering the values plus max(0.01 ETH, the gas limits at the send price);
- for an lREACT leg, the payout state, because the Sepolia faucet keeps every wei it receives and has no refund
  path: the faucet's `max_payout` covers the amount; the Lasna payer is wired to that faucet, is not paused, pays
  100 lREACT per ETH, has a `max_payout` and a balance (above its gas reserve) that cover the payout, and owes the
  system contract nothing. Above 5 ETH the whole request is lost, not just the excess; the 2 ETH cap stays below;
- the input `sepolia_nonce` equals the account's Sepolia nonce, with nothing pending. Only this job sends from the
  account on Sepolia, so a repeated dispatch or a re-run after anything was sent is refused. The summary prints the
  value for a deliberate next run.

A failed or unconfirmed faucet receipt stops the bridge. Credits are polled every 15 s for up to 15 minutes and count
only when the balance rose by the expected amount. A missing or short Lasna credit fails the job (payouts land
within seconds; do not resend). A missing Base Sepolia credit only warns (deposits can take longer). CI tests the
script on three local anvil chains with mocks at the real addresses and simulated credits.

Deployment (no owner setter: the circular dependency is broken by computing the next contract address):
1. Base Sepolia: `DemoToken`, then `DemoVaultFactory` (the 2026-11-18 deployment) or, in
   `scripts/deploy-system.sh` after it, `MorphoVaultMaker` on Morpho's factory (checked first: code present,
   `isVaultV2(0x…dEaD)` false). The maker is then `NoticeExit`'s registry, every value is read back, and one
   smoke `create()` is checked (listed, four timelocks of 180 s, six setters abdicated, caller is curator and owner).
2. Read the deployer's Base Sepolia nonce `n`; the exit contract will live at `CREATE(deployer, n)`.
3. Lasna: `NoticeReactive` with that address, sent no value (not yet shown on Lasna: that a reactive
   contract deployed with a zero balance keeps the subscriptions its constructor made; if the hello loop
   sees no reaction, deploy with value instead). Its constructor subscribes to `WatchArmed` and
   `WatchCancelled` of that address.
4. Base Sepolia: `NoticeExit` with the reactive contract's address, sent no value. The workflow stops if the
   address is not the one computed in step 2, or if the read-back wiring differs.
5. Only then: send lREACT to `NoticeReactive` and a little Base Sepolia ETH to `NoticeExit` (the callback
   proxy takes callback fees from it), and call `coverDebt()` on both in case either ran up a debt while
   empty. The hello-world deployment follows the same order.

A watch, "leave now":
1. Depositor: `factory.create()` (own vault), `token.mint`, `token.approve(vault)`, `vault.deposit`.
2. Depositor: `vault.approve(NoticeExit, shares)`, then `NoticeExit.arm(vault, kinds, 0, maxShares)`. Event `WatchArmed`.
3. Lasna: `react(WatchArmed)` subscribes one filter per selector `(84532, vault, Submit, selector)`. Event `WatchSubscribed`.
4. Curator (here the same visitor): `vault.submit(addAdapter(x))`. Event `Submit`. **Hash 1.**
5. Lasna: `react(Submit)` asks for the callback, removes the filters. Event `ExitRequested(watchId, hash 1)`. **Hash 2.**
6. Base Sepolia: the proxy calls `NoticeExit.exit`; the shares are redeemed to the depositor. Event `WatchEnded(watchId, hash 1, …)`. **Hash 3.**

The origin transaction hash travels in the payload and is an indexed topic of both `ExitRequested` and
`WatchEnded`, so the three hashes can be linked with plain log queries.

## 8. Subscriptions, and stray events after unsubscribe

| Filter (chain, contract, topic0, topic1, topic2, topic3) | Added | Removed |
|---|---|---|
| (84532, NoticeExit, `WatchArmed`, any, any, any) | constructor | never |
| (84532, NoticeExit, `WatchCancelled`, any, any, any) | constructor | never |
| (84532, vault, `Submit`, selector, any, any), one per selector of the watched kinds | arming | when the last watch that needs it ends |
| (84532, vault, `Revoke`, any, any, any), mode 1 only | arming | when the last mode-1 watch on that vault ends |

The `Revoke` filter takes any selector on purpose. `Revoke` carries the selector in `topic2`, so one filter per
watched selector would be possible, but it would double the subscriptions of a mode-1 watch (up to 5 more per
watch, each a costly subscribe and unsubscribe inside a reaction). The price is that revokes of unwatched kinds
reach mode-1 watches; the reaction budget bounds what that can cost (section 9).
| (5318007, `0x…fffFfF`, `Cron10`, any, any, any) | first stored change of any watch | when no watch stores a change |

A real Cron10 log read on Lasna (2026-11-17) carries its counter as indexed `topic1` and empty data, not in data
as the docs describe. The contract reads neither: it only checks source, chain and `topic0`. The fixture test
feeds that real log.

Filters are reference-counted: the network treats two identical subscriptions as one, so an unsubscribe for
one watch would otherwise silence another watch on the same vault. The contract subscribes on 0 → 1 and
unsubscribes on 1 → 0, always with the same six arguments.

The network's unsubscribe fails silently when the arguments differ. So an event that arrives for a filter
whose count is 0 is a **stray**: `strayEvents` goes up by one, `StrayEvent` is emitted, and the exact
unsubscribe is sent again. Events that fit no filter shape at all (wrong chain, wrong topic count, an
unknown topic) are counted in `unknownEvents` and ignored.

## 9. Who pays, and the caps on the operator float

- Reactive transactions (every event delivered, every CRON tick) are paid in lREACT by `NoticeReactive`, from
  an operator float we top up. Visitors pay nothing on Lasna. Callbacks are paid in Base Sepolia ETH by
  `NoticeExit`. Visitors pay only their own Base Sepolia transactions.
- The callback proxy and the system contract can pull any amount of native balance from our two contracts
  to settle debt (`pay()` in the sponsor library). So these contracts hold only a fee reserve, never user
  assets.
- Caps, all fixed at deployment: the 11-18 pair (deployed), and the values `scripts/deploy-system.sh` deploys
  for the contracts after 2026-11-18 (not deployed yet):

| Cap | Where | 11-18 pair | `deploy-system.sh` | What it limits |
|---|---|---|---|---|
| Arms per address per UTC day | NoticeExit | 2 | 4 | One visitor's spend |
| Arms per UTC day, all addresses | NoticeExit | 10 | 50 | Total daily spend |
| One active watch per owner and vault | NoticeExit | 1 | 1 | Duplicate watches |
| Watch lifetime (`LIFETIME`) | NoticeExit | 1 day, every watch | 1 day, mode 1 only | How long an unused timer watch can hold a timer place; after it, anyone can `expire` it. On the newer contracts a mode-0 watch has no expiry |
| Mode-1 arms per UTC day, all addresses (`MAX_TIMED_ARMS_PER_DAY`) | NoticeExit | none | 4 | The costly mode's daily spend |
| Mode-1 watches at a time (`MAX_TIMED`) | NoticeReactive | none (the 8 active watches bound both modes) | 8 (a constant) | Work per tick and `LEAD` |
| Active watches (`MAX_ACTIVE`) | NoticeReactive | 8 | 1,000 | Watches armed at a time. On the 11-18 pair also the work per tick; on the newer contracts `MAX_TIMED` bounds that, and no loop runs over all armed watches |
| Watches per vault | NoticeReactive | 3 | 3 | Work per `Submit` |
| Stored changes per watch | NoticeReactive | 3 | 3 | Work per tick |
| Reactions per watch (`MAX_REACTIONS`; mode 1: every `Submit` of a watched kind, every `Revoke` on its vault, every tick while it stores a change; mode 0 leaves on its first reaction) | NoticeReactive | 80 | 16 | Spam of submit and revoke on one vault; ends with an exit, never by dropping the watch |
| Longest wait paid in ticks (`MAX_WAIT`) | NoticeReactive | 900 s | 200 s | Ticks per stored change (section 6) |
| Exits per tick | NoticeReactive | 1 | 1 | Gas per tick (900,000 cap per reactive transaction) |
| Callback gas limit | NoticeReactive | 600,000 | 600,000 | Gas limit of the exit delivery; about 415,000 reaches `exit` after the proxy's share, and `NoticeExit` is billed for gas used, not for the limit (section 12). A redeem that needs more fails and is not retried (section 11) |

A watch the reactive contract refuses (caps above) is reported by `WatchRefused` on Lasna; the depositor
can cancel it on Base Sepolia and arm again later.

Computed, not measured: about 0.013 lREACT per reactive transaction plus about 0.05 per arming. On the 11-18
pair, with 80 reactions per watch, one watch costs at most about 1.5 lREACT, and the 10 arms a day at most about
15 lREACT a day. With the values of `scripts/deploy-system.sh`, the same formula gives about 0.27 lREACT for a
mode-1 watch that uses its 16 reactions (the 17th asks for the exit) and about 0.063 for a mode-0 watch, so
about 4 lREACT for a day with every cap used (4 mode-1 and 46 mode-0 arms). These are estimates, not bounds:
the measured mode-1 loop below cost 0.1607 lREACT, more than the formula gives for its reactions, and a large
stored change costs more per reaction. Two costs are outside this bound and must be watched on the live float: stray events after a
silent unsubscribe (counted in `strayEvents`, billed by the network), and callbacks that anyone can make the
proxy bill to `NoticeExit` through their own reactive contracts (section 11).

Measured on 2026-11-18 (testnet deployment of that day: `NoticeReactive`
`0x00E4996c7255B919B619902E1Ac4b254D3c3f014` on Lasna, `NoticeExit` `0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8`
on Base Sepolia; balances read before and after each loop; reactive gas price 100 gwei):
- Mode 0, one watch from arming to exit: 0.0491812 lREACT from `NoticeReactive` (arm reaction
  `0x9d183f32d43cb8319aa4a646d327aac360fa303e9ab1f181387eabaf28035f52`, 255,293 gas; exit reaction
  `0x1a6b032aa7afc9f89e25fdef852bebbffad4ee1b750ba4fd4cc5bb6a5f84aa3e`, 141,892 gas). Gas × price is
  0.0397185; the remaining 0.0094627 is not attributed.
- Mode 1, one watch from arming to the deadline exit 62 s later: 0.1606827 lREACT (arm reaction
  `0xfc9cbe8e9c4acd00e683b65243d96f8ae81a3da1d98d3acb8fcee774e14903d6`, 285,385 gas; deadline reaction
  `0x98b822a593a99bf8ab4d085d94f7d77a0986830755a3f15223e3c47023efc530`, 198,489 gas; plus the Cron10 ticks
  while the change was stored). A mode-1 watch that waits the whole 180 s timelock costs more; not measured.
- Hello reaction: 0.0147093 lREACT at callback limit 200,000 and again at 400,000 (106,806 gas both times), so
  the lREACT charge does not grow with the requested callback gas limit.
- Base Sepolia, per exit: `NoticeExit`'s reserve went down by 1,239,473,400,000 wei (mode 0) and
  1,126,613,400,000 wei (mode 1) at 0.006 gwei, i.e. (80,000 + gas used) × price × 1.1 as in the proxy's
  source. The proxy's `debt(NoticeExit)` read 0 afterwards.

## 10. Events

| Contract | Event | Indexed |
|---|---|---|
| DemoVault | `Submit(bytes4 selector, bytes data, uint256 executableAt)` | selector (topic1, left-aligned) |
| DemoVault | `Revoke(address sender, bytes4 selector, bytes data)` | sender (topic1), selector (topic2) |
| DemoVault | `Accept(bytes4 selector, bytes data)` | selector (topic1) |
| DemoVaultFactory | `VaultCreated(address vault, address curator)` | both |
| MorphoVaultMaker | `VaultCreated(address vault, address curator)` (same shape as the factory's) | both |
| NoticeExit | `WatchArmed(uint256 watchId, address owner, address vault, uint8 kinds, uint8 mode, uint256 maxShares)` | watchId, owner, vault |
| NoticeExit | `WatchCancelled(uint256 watchId, address owner, address vault)` | all three |
| NoticeExit | `WatchExpired(uint256 watchId)` (followed by `WatchCancelled` for the same watch) | watchId |
| NoticeExit | `WatchEnded(uint256 watchId, uint256 originTxHash, uint8 outcome, uint8 reason, uint256 shares, uint256 assets)` | watchId, originTxHash |
| NoticeExit | `RedeemReverted(uint256 watchId, bytes reason)` | watchId |
| NoticeReactive | `WatchSubscribed(uint256 watchId, address vault, uint8 kinds, uint8 mode)` | watchId, vault |
| NoticeReactive | `WatchRefused(uint256 watchId, uint8 reason)` | watchId |
| NoticeReactive | `ChangeStored(uint256 watchId, bytes32 dataHash, uint256 executableAt, uint256 originTxHash)` | watchId, dataHash |
| NoticeReactive | `ChangeRevoked(uint256 watchId, bytes32 dataHash)` | watchId, dataHash |
| NoticeReactive | `ExitRequested(uint256 watchId, uint256 originTxHash, uint8 reason, bytes32 dataHash)` | watchId, originTxHash |
| NoticeReactive | `WatchClosed(uint256 watchId, uint8 status)` | watchId |
| NoticeReactive | `FilterOn(bytes32 key)`, `FilterOff(bytes32 key)` | key |
| NoticeReactive | `StrayEvent(uint256 chainId, address source, uint256 topic0, uint256 total)` | chainId, source, topic0 |
| NoticeReactive | `UnknownEvent(uint256 chainId, address source, uint256 topic0, uint256 total)` | chainId, source, topic0 |

## 11. Limits, said plainly

- The demo vault is ours. It imitates Vault V2's timelock and events; its "adapters" and "caps" are only
  recorded, the assets stay in the vault. Morpho's own `VaultV2Factory` is deployed on Base Sepolia, so a
  real Vault V2 can replace it later; `NoticeExit` and `NoticeReactive` only rely on the event shapes and
  ERC-4626 `redeem` (the deploy and loop scripts also read `executableAt(bytes)`). The contracts after
  2026-11-18 do that: `MorphoVaultMaker` makes real Vault V2s on Morpho's factory, with no gate and no fee
  ever; the demo dollar in them is still ours. A Vault V2 made any other way is refused (`UnknownVault`),
  because it may have gates, fees or a waiting period of zero.
- The demo vault counts every demo dollar it holds as its assets (`totalAssets` is its token balance, with one
  virtual share), and `DemoToken.mint` is open to anyone. So a third party can send demo dollars to a vault
  before its first deposit and skew the share price: with 50 sent first, a deposit of 100 mints 1 share that
  redeems for 75; with 100 or more sent first, the deposit reverts with `ZeroShares`. The address of the next
  vault can be computed in advance (plain `CREATE` from the factory). This is the demo vault's weakness, not the
  exit contract's: `NoticeExit` redeems whatever the shares are worth, to the owner. The page refuses to deposit
  into a vault that already holds demo dollars and makes a new one; the contracts as deployed do not prevent it.
  A fix (assets tracked in storage, or a vault address salted with the creator) needs a new deployment.
- The demo pays for watches from an operator float; user-paid watches are later scope.
- One origin chain (Base Sepolia) in this version.
- The exit runs in seconds, not in the same block. A change with no timelock cannot be fled.
- Mode 1 decides "still pending" on Lasna and is not re-checked on Base Sepolia (section 6). The cost: a
  depositor can leave on a change the curator revoked in the seconds between the tick and the callback.
- A change scheduled before the watch was armed is never seen: the watch only learns about `Submit` events
  after its filters exist. The page must show the vault's pending changes before arming.
- Anyone can fill the daily arm caps and the active-watch cap with watches of their own (one share is
  enough). `expire` frees a mode-1 place after `LIFETIME`; many addresses can still use up a day's arms. On one
  vault the first three watches take its places for good if they are mode 0 (a deposit into another's vault is
  open), and a fourth is refused with code 4 (pinned by `test_vault_squat_is_permanent_and_visible`); the
  cure is a fresh vault. This comes with an operator-paid demo; user-paid watches are later scope.
- Anyone can deploy their own reactive contract and ask for callbacks to `NoticeExit`. They are refused
  (`CallbackNotAuthorized`), but the proxy may still bill the failed call to `NoticeExit`'s fee reserve
  (not yet measured). The reserve is small and refillable; `coverDebt()` settles debt, and the float watch
  must read the proxy's `debt(NoticeExit)`.
- `expire` is open to anyone, the curator included, but only for a mode-1 watch. A mode-1 watch protects for
  `LIFETIME` (1 day) only: after that the curator can expire it and then schedule a change, and an expiry that
  lands while an exit callback is on its way makes that callback revert (`WatchNotActive`) and the depositor
  stays in. The lease also ends the protection from a change the watch already stores: a curator who schedules
  a change shortly before the lease ends and expires the watch when it ends makes Lasna close the watch and
  forget the change without an exit (pinned by `test_expiry_at_lease_end_drops_a_stored_change`). So a mode-1
  watch is sure to serve only changes scheduled at least `MAX_WAIT - LEAD` seconds (80 s as deployed by
  `scripts/deploy-system.sh`, 780 s on the 11-18 pair), plus the delivery time, before its lease ends. A mode-0 watch has no expiry and ends only when it fires or its owner cancels it. On the 11-18
  deployment every watch, mode 0 included, can still be expired after one day.
- The callback gas limit stays 600,000 on the newer contracts too (about 415,000 reaches `exit`). A maker vault
  as made has no adapter, which keeps its redeem cheap (not yet measured on chain). Its curator can still add
  adapters and allocators through 180 s changes; added before anyone arms a watch, they are never seen, and a
  redeem through them can need more gas than that. The real-vault replay (README) ran out of gas at 600,000
  and redeemed at 1,000,000. The reactive contract closes a watch when it asks for the exit, so an exit that
  fails (`RedeemFailed`, or a callback that runs out of gas) is not tried again and the depositor stays in. A
  deployment for configured vaults needs a larger limit (about 1,000,000 for the replayed vault).
- Stray events after a silent unsubscribe are billed by the network and cannot be refused by the contract;
  they are counted (`strayEvents`) and alerted on.
- "No server, no key that can send the funds elsewhere": the exit right exists only through the vault's own
  event, the network's callback, and a redeem whose receiver is fixed to the owner.
- If an exit callback reverts on Base Sepolia (`AssetsNotReceived`, or a failure of the callback itself), the
  reactive contract has already closed the watch, while on Base Sepolia it is still `Active`. That watch no
  longer protects anything and blocks a new arm on the same vault (`AlreadyWatching`) until the owner cancels
  it (or, for a mode-1 watch, anyone expires it after `LIFETIME`). The page must show the Lasna status next to
  the Base status.

## 12. What the Foundry simulation shows and what it cannot

The tests run every contract in one local EVM. A mock system contract at `0x8888…8888` records
subscriptions and delivers a log only when all six subscribe arguments match (so a drifting unsubscribe
fails a test), and a mock callback proxy writes the requesting contract's address into the first argument
as the network does. Real logs (a Morpho V2 `Submit` from Base, a Cron10 tick from Lasna) are decoded in
fixture tests.

Checks in CI on every push: unit and attack tests (each refusal test next to a sibling call that succeeds), fuzz
tests, an invariant run with random visitor, curator, clock and attacker actions (the exit contract never
holds tokens or shares, tokens go only to their depositor, no visitor's wallet plus shares is ever worth more
than they put in (rounding aside), both chains agree on each watch's status, the CRON
subscription exists exactly while a change is stored, `react()` never reverts, every reaction fits the gas
cap, padded curator calls included; actions include deposits and watches in other visitors' vaults, revoke
spam of unwatched kinds, a revoke or run of a change between a tick and its callback, expiry, and callbacks
naming the wrong vault), a mutation check that removes
each refusal rule in turn and requires its named test to fail (`scripts/mutations.py`), and a dry run of the
deploy and loop scripts on two local anvil chains with the mock network contracts at the real addresses and a
relay script that plays the network.

Gas, as far as a simulation can show it: the mock system contract measures the gas each `react()` uses, leaves
out its own bookkeeping, adds what the real system contract would spend on a callback request, and counts every
reaction above 900,000 (`overGasLimit`, required 0 in tests, invariants and the dry run). The mock proxy gives
each callback what the real Base Sepolia proxy would give it at the requested gas limit (see "Callback gas"
below), and refuses a limit too low for the proxy's own share as the real one does. Padded calls of 4 KB, 32 KB and 100 KB on a
vault with three watches in both modes stay under the cap (`test/Padding.t.sol`), and so does a padded `Revoke` that ends a watch over its budget.
Each `subscribe` and `unsubscribe` is charged a modelled 60,000 gas (an estimate from Lasna transactions, not
the network's code), whether the mock spent more or less. Not modelled: whether the network's cap also counts
the calldata of a large log.

Fees: both mocks keep a debt per contract that a test sets and a payment settles, so `coverDebt()` is tested
against a non-zero debt. No fee is charged per reaction or per callback, so how the real proxy and system
contract record and bill debt, and what a spam loop costs, is not shown.

Callback gas, measured 2026-11-18 on Base Sepolia (proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`, an
ERC-1967 stub; implementation `0x49E4AC6954E39c006B0a31955A26a9655c7CE059`, verified source `CallbackProxy`;
live `_extraGas()` 80,000, `_maxChargeGas()` 50,000):
- The delivery transaction's gas limit is the `gasLimit` the reactive contract asked for. The stub delegates
  with 63/64 of what is left after the intrinsic gas; the implementation spends about 20,000 on its own checks,
  refuses the whole delivery with `InsufficientGas` when what is left is not above 130,000 (no
  `CallbackFailure`, nothing charged), and otherwise calls the recipient with what is left minus 130,000.
- Measured with `eth_simulateV1` (recipient code replaced by a probe that logs `gasleft()`): forwarded =
  floor((limit − intrinsic) × 63/64) − C, with C = 149,746 for a 36-byte payload, 149,800 for 132 (pong),
  149,873 for 260 (an exit carrying a selector), 150,001 for 484 (an exit carrying a 256-byte change) and
  150,887 for 2,000. So a limit below about 180,000 can never deliver, although the library accepts 100,000.
- The first hello delivery (`0xd6559e81729f0ea110ff4ea560450543225402f08d9c2cae433e618fd9a1bc89`, limit
  200,000) gave pong 23,253 gas; pong needs about 70,000, so it ended in `CallbackFailure`. `HelloReactive`
  now asks for 400,000 (about 220,000 forwarded).
- `NoticeExit.exit` at the deployed 600,000: about 415,000 forwarded, 104,000 to 107,400 used with the exit
  contract, vault and token cold (`test/CallbackGas.t.sol`, five exit paths). The tests require at least
  twice the use plus a 20,000 cushion for slots the same test wrote before.
- On chain after the fix (2026-11-18): hello delivery `0xc90d8a9ed266ffd83cc5430186bf79fa83e6057a436f652c2c496a3e0398e25a`
  (limit 400,000, 139,253 used, `Ponged`; billed for 72,567 of recipient gas, CI measured 72,115); exit
  deliveries `0x7f6456d9b7938e6a205c87a86d0e95ae5e347ec160a39c1e7a7251caebc67b04` (mode 0, limit 600,000,
  156,350 used, billed for 107,799 of recipient gas) and
  `0x681bd1f976e0b708c29ffe7639d9a987701bf2f8fc89480ae97e8ace77470b47` (mode 1, 142,670 used), both
  `WatchEnded` with outcome redeemed.
- The mock (`test/mocks/MockCallbackProxy.sol`) uses an upper bound of C, so it forwards 289 to 374 gas less
  than the real proxy at every measured point and never more (`test/ProxyModel.t.sol` pins it to the points).
- The fee charged to the recipient is (80,000 + gas used) × price × 1.1, so a higher limit costs nothing on
  Base Sepolia unless it is used.

Shown by the first real loops (2026-11-18, hashes above and in section 9): the network injects our reactive
contract's address; a subscription added inside `react()` caught the curator's `Submit` after the loop's 15 s
grace (mode 0: `WatchSubscribed` at Lasna 1794963864, `Submit` at Base 1794963886, reacted in the same
second); real reaction gas 106,806 to 285,385, far under the 900,000 cap; the exit reached the depositor 2 s
(mode 0) and 62 s (mode 1, at the deadline, 118 s before the change could run) after the curator's
transaction; no stray or unknown events afterwards. Still not shown: how much shorter than 15 s the
subscription delay can be, whether an unsubscribe really goes silent (strayEvents stayed 0 but no event was
sent after the watches closed), the gas of a large padded log on chain, and the cost of a mode-1 watch over a
whole timelock.

## 13. Build targets

Solidity 0.8.30, EVM target `cancun`. Checked on 2026-11-17 with read-only `eth_call` contract-creation
probes against both public RPCs: PUSH0, TLOAD/TSTORE and MCOPY execute on Lasna and Base Sepolia (and
CLZ from Osaka too); an undefined opcode is refused on both, so the probe is meaningful. `BLOBBASEFEE`
crashed the Lasna RPC handler, so no contract reads `block.blobbasefee`. This is evidence from `eth_call`
execution, not from a mined transaction.
