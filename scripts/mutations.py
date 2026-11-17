"""Mutation list: one entry per refusal rule (SPEC.md).

Each entry removes or weakens exactly one rule. The mutation check (scripts/mutate.py) applies one entry at a time,
requires the named test to pass on the real code and to FAIL on the mutant. An entry whose `old` text is not found
exactly once is an error, so a list that drifts from the code fails loudly.
"""

X = "src/NoticeExit.sol"
R = "src/NoticeReactive.sol"
V = "src/demo/DemoVault.sol"
F = "src/demo/DemoVaultFactory.sol"
T = "src/demo/DemoToken.sol"
HR = "src/hello/HelloReactive.sol"
HC = "src/hello/HelloCallback.sol"

E = "NoticeExitTest"
NR = "NoticeReactiveTest"
NB = "NoticeReactiveBudgetTest"
DV = "DemoVaultTest"
EE = "EndToEndTest"
H = "HelloTest"

MUTATIONS = []


def add(id_, rule, file, old, new, contract, test):
    MUTATIONS.append(
        {"id": id_, "rule": rule, "file": file, "old": old, "new": new, "contract": contract, "test": test}
    )


# ---------------------------------------------------------------- exit contract (origin chain)
add("exit-only-proxy", "exit() only from the callback proxy", X,
    "external onlyServiceProvider onlyCallbackSender(sender_) nonReentrant {",
    "external onlyCallbackSender(sender_) nonReentrant {",
    E, "test_exit_refuses_direct_caller")
add("exit-only-our-reactive", "exit() only on request of our reactive contract", X,
    "external onlyServiceProvider onlyCallbackSender(sender_) nonReentrant {",
    "external onlyServiceProvider nonReentrant {",
    E, "test_exit_refuses_wrong_reactive_identity")
# Reentrancy: an owner's contract wallet calls back while the redeem pays it, so only the guard stops the call.
add("exit-reentrancy-guard", "no exit() from inside exit()", X,
    "external onlyServiceProvider onlyCallbackSender(sender_) nonReentrant {",
    "external onlyServiceProvider onlyCallbackSender(sender_) {",
    E, "test_reentry_into_exit_is_blocked")
add("arm-reentrancy-guard", "no arm() from inside exit()", X,
    "        external\n        nonReentrant\n        returns (uint256 watchId)",
    "        external\n        returns (uint256 watchId)",
    E, "test_reentry_into_arm_is_blocked")
add("cancel-reentrancy-guard", "no cancel() from inside exit()", X,
    "function cancel(uint256 watchId_) external nonReentrant {",
    "function cancel(uint256 watchId_) external {",
    E, "test_reentry_into_cancel_is_blocked")
add("expire-reentrancy-guard", "no expire() from inside exit()", X,
    "function expire(uint256 watchId_) external nonReentrant {",
    "function expire(uint256 watchId_) external {",
    E, "test_reentry_into_expire_is_blocked")
add("expire-only-active", "expire only an active watch", X,
    "        if (w.status != STATUS_ACTIVE) revert WatchNotActive(watchId_);\n        uint256 expiresAt",
    "        uint256 expiresAt",
    E, "test_expire_refuses_ended_watch")
add("expire-after-lifetime", "expire only after LIFETIME", X,
    "if (block.timestamp < expiresAt) revert WatchNotExpired(watchId_, expiresAt);", "",
    E, "test_expire_refuses_before_lifetime")
add("arm-unknown-vault", "arm only on vaults of our factory", X,
    "if (!REGISTRY.isVault(vault_)) revert UnknownVault(vault_);", "",
    E, "test_arm_refuses_unknown_vault")
add("arm-no-kinds", "arm needs at least one kind", X,
    "if (kinds_ == 0) revert NoKinds();", "",
    E, "test_arm_refuses_no_kinds")
add("arm-unknown-kinds", "arm only known kinds", X,
    "if (kinds_ & ~NoticeKinds.ALL != 0) revert UnknownKinds(kinds_);", "",
    E, "test_arm_refuses_unknown_kinds")
add("arm-bad-mode", "arm only modes 0 and 1", X,
    "if (mode_ > MODE_IF_PENDING) revert BadMode(mode_);", "",
    E, "test_arm_refuses_bad_mode")
add("arm-zero-max-shares", "arm needs a non-zero share cap", X,
    "if (maxShares_ == 0) revert ZeroMaxShares();", "",
    E, "test_arm_refuses_zero_max_shares")
add("arm-no-shares", "arm only over own shares", X,
    "if (IExitVault(vault_).balanceOf(msg.sender) == 0) revert NoShares();", "",
    E, "test_arm_refuses_no_shares")
add("arm-no-allowance", "arm needs a share allowance", X,
    "if (IExitVault(vault_).allowance(msg.sender, address(this)) == 0) revert NoAllowance();", "",
    E, "test_arm_refuses_no_allowance")
add("arm-one-watch-per-vault", "one active watch per owner and vault", X,
    "if (existing != 0) revert AlreadyWatching(existing);", "",
    E, "test_arm_refuses_second_active_watch")
add("arm-daily-cap-address", "daily arm cap per address", X,
    "if (armsByAddressOnDay[msg.sender][day] >= MAX_ARMS_PER_ADDRESS_PER_DAY) revert DailyCapForAddress();", "",
    E, "test_arm_refuses_over_daily_cap_for_address")
add("arm-daily-cap", "daily arm cap overall", X,
    "if (armsOnDay[day] >= MAX_ARMS_PER_DAY) revert DailyCapReached();", "",
    E, "test_arm_refuses_over_daily_cap")
add("cancel-only-owner", "only the owner cancels", X,
    "if (w.owner != msg.sender) revert NotWatchOwner();", "",
    E, "test_cancel_refuses_other_owner")
add("cancel-only-active", "cancel only an active watch", X,
    "        if (w.status != STATUS_ACTIVE) revert WatchNotActive(watchId_);\n        w.status = STATUS_CANCELLED;",
    "        w.status = STATUS_CANCELLED;",
    E, "test_cancel_refuses_twice")
add("exit-only-active", "exit only an active watch (replay)", X,
    "        if (w.status != STATUS_ACTIVE) revert WatchNotActive(watchId_);\n        if (w.vault != vault_)",
    "        if (w.vault != vault_)",
    E, "test_exit_refuses_replay")
add("exit-vault-bound", "exit only for the watch's own vault", X,
    "if (w.vault != vault_) revert WrongVault(watchId_, vault_);", "",
    E, "test_exit_refuses_wrong_vault")
add("exit-ends-watch-first", "a watch exits at most once", X,
    "        w_.status = STATUS_ENDED;\n", "",
    E, "test_exit_refuses_second_exit_of_same_watch")
add("exit-kind-watched", "exit only for a watched kind", X,
    "if (NoticeKinds.kindOf(selector) & w.kinds == 0) revert KindNotWatched(selector);", "",
    E, "test_exit_refuses_unwatched_kind")
add("exit-receiver-is-owner", "redeem pays the watch owner only", X,
    "redeem(shares_, owner_, owner_)", "redeem(shares_, msg.sender, owner_)",
    E, "test_exit_redeems_to_owner")
add("exit-assets-received", "the owner must really receive the assets", X,
    "if (received < assets) revert AssetsNotReceived(assets, received);", "",
    E, "test_attack_vault_paying_someone_else_is_refused")
add("exit-cap-by-allowance", "redeem at most the allowance", X,
    "if (allowed < shares) shares = allowed;", "",
    E, "test_exit_allowance_smaller_than_watch")
add("exit-cap-by-watch", "redeem at most the watch's share cap", X,
    "        shares = maxShares_;\n", "        shares = type(uint256).max;\n",
    E, "test_exit_allowance_larger_than_watch")
add("exit-cap-by-balance", "redeem at most the owner's balance", X,
    "if (balance < shares) shares = balance;", "",
    E, "test_exit_redeems_to_owner")

# ---------------------------------------------------------------- reactive contract (Lasna)
add("react-only-system", "react() only from the system contract", R,
    "function react(LogRecord calldata log_) external onlySystem {",
    "function react(LogRecord calldata log_) external {",
    NR, "test_react_refuses_non_system")
add("react-cron-chain-topic", "ticks only from the CRON source of this chain", R,
    "if (log_.chainId == block.chainid && log_.topic0 == CRON_TOPIC) _onTick();", "if (true) _onTick();",
    NR, "test_unknown_logs_are_counted_not_reverted")
add("react-origin-chain", "vault events only from the origin chain", R,
    "if (log_.chainId != ORIGIN_CHAIN_ID) {", "if (false) {",
    NR, "test_unknown_logs_are_counted_not_reverted")
add("react-exit-source", "watches only from our exit contract", R,
    "if (log_.contractAddress == EXIT) {",
    "if (log_.contractAddress == EXIT || log_.topic0 == WATCH_ARMED_TOPIC) {",
    NR, "test_watch_armed_from_another_contract_is_ignored")
add("armed-shape", "a WatchArmed must have its real topic count", R,
    "log_.topic0 == WATCH_ARMED_TOPIC && log_.opCode == 4", "log_.topic0 == WATCH_ARMED_TOPIC",
    NR, "test_watch_armed_with_wrong_topic_count_is_ignored")
add("cancelled-shape", "a WatchCancelled must have its real topic count", R,
    "log_.topic0 == WATCH_CANCELLED_TOPIC && log_.opCode == 4", "log_.topic0 == WATCH_CANCELLED_TOPIC",
    NR, "test_watch_cancelled_with_wrong_topic_count_is_ignored")
add("revoke-shape", "a Revoke must have its real topic count", R,
    "log_.topic0 == NoticeKinds.REVOKE_TOPIC && log_.opCode == 3", "log_.topic0 == NoticeKinds.REVOKE_TOPIC",
    NR, "test_revoke_with_wrong_topic_count_is_ignored")
add("react-submit-shape", "a Submit must have its real topic count", R,
    "log_.topic0 == NoticeKinds.SUBMIT_TOPIC && log_.opCode == 2", "log_.topic0 == NoticeKinds.SUBMIT_TOPIC",
    NR, "test_unknown_logs_are_counted_not_reverted")
add("armed-once", "a WatchArmed is applied once", R,
    "if (w.status != ST_NONE) return; // the same event delivered twice", "",
    NR, "test_duplicate_watch_armed_is_ignored")
add("armed-bad-kinds", "refuse unknown kinds", R,
    "if (kinds == 0 || kinds & ~NoticeKinds.ALL != 0) refusal = REFUSE_BAD_KINDS;",
    "if (false) refusal = REFUSE_BAD_KINDS;",
    NR, "test_bad_kinds_in_event_are_refused_not_reverted")
add("armed-bad-mode", "refuse unknown modes", R,
    "else if (mode > MODE_IF_PENDING) refusal = REFUSE_BAD_MODE;", "else if (false) refusal = REFUSE_BAD_MODE;",
    NR, "test_bad_mode_in_event_is_refused_not_reverted")
add("armed-active-cap", "cap on active watches (operator float)", R,
    "else if (activeWatches >= MAX_ACTIVE) refusal = REFUSE_TOO_MANY_WATCHES;",
    "else if (false) refusal = REFUSE_TOO_MANY_WATCHES;",
    NR, "test_refuses_watch_over_active_cap")
add("armed-vault-cap", "cap on watches per vault (gas per reaction)", R,
    "else if (_vaultWatches[vault].length >= MAX_WATCHES_PER_VAULT) refusal = REFUSE_VAULT_FULL;",
    "else if (false) refusal = REFUSE_VAULT_FULL;",
    NR, "test_refuses_fourth_watch_on_one_vault")
add("cancelled-only-armed", "a cancel on Base closes only a watch Lasna armed (not a refused one)", R,
    "if (watches[id].status == ST_ARMED) _close(id, ST_CANCELLED);", "_close(id, ST_CANCELLED);",
    NR, "test_cancel_of_a_refused_watch_changes_nothing_on_lasna")
add("stray-submit", "a Submit after unsubscribe is a stray", R,
    "if (filterRefs[_submitKey(vault, log_.topic1)] == 0) {", "if (false) {",
    NR, "test_stray_submit_after_unsubscribe_is_counted")
add("stray-revoke", "a Revoke after unsubscribe is a stray", R,
    "if (filterRefs[_revokeKey(vault)] == 0) {", "if (false) {",
    NR, "test_stray_revoke_after_unsubscribe_is_counted")
add("stray-tick", "a tick while disarmed is a stray", R,
    "if (filterRefs[_cronKey()] == 0) {", "if (false) {",
    NR, "test_stray_tick_after_unsubscribe_is_counted")
add("submit-kind-per-watch", "a change exits only the watches of its kind", R,
    "if (w.status != ST_ARMED || w.kinds & s_.kind == 0) continue;", "if (w.status != ST_ARMED) continue;",
    NR, "test_cap_change_exits_only_the_watch_that_opted_in")
add("wait-budget", "the reaction budget ends a spammed watch", R,
    "if (w_.reactions > MAX_REACTIONS) return R_BUDGET;", "",
    NR, "test_submit_revoke_spam_ends_in_exit_by_budget")
add("wait-too-soon", "too little time left: leave at once", R,
    "if (executableAt_ <= block.timestamp + LEAD) return R_TOO_SOON;", "",
    NR, "test_leaves_at_once_when_too_soon")
add("wait-too-long", "too long a wait: leave at once", R,
    "if (executableAt_ > block.timestamp + MAX_WAIT) return R_WAIT_TOO_LONG;", "",
    NR, "test_leaves_at_once_when_wait_too_long")
add("wait-data-too-long", "too long a change: leave at once", R,
    "if (dataLength_ > MAX_DATA_LENGTH) return R_DATA_TOO_LONG;", "",
    NR, "test_leaves_at_once_when_data_too_long")
add("wait-pending-full", "too many stored changes: leave at once", R,
    "if (w_.pendingCount >= MAX_PENDING) return R_PENDING_FULL;", "",
    NR, "test_leaves_at_once_when_pending_full")
add("tick-budget", "ticks count toward the budget", R,
    "else if (w.reactions > MAX_REACTIONS) reason = R_BUDGET;", "else if (false) reason = R_BUDGET;",
    NB, "test_ticks_count_toward_budget")
add("tick-deadline", "leave shortly before the change can run", R,
    "if (at <= block.timestamp + LEAD) reason = R_DEADLINE;", "if (false) reason = R_DEADLINE;",
    NR, "test_pending_mode_waits_then_exits_shortly_before_deadline")
add("tick-one-exit", "at most one exit per tick", R,
    "            if (at < pickAt) {\n                pick = id;",
    "            if (at < pickAt) {\n                _fireStored(id, w, reason);\n                pick = id;",
    NR, "test_one_exit_per_tick")
add("tick-urgency", "the change that can run first leaves first", R,
    "if (at < pickAt) {", "if (pickReason == 0) {",
    NR, "test_tick_fires_most_urgent_first")
add("revoke-budget", "the budget also ends a watch spammed through Revoke", R,
    "if (w.reactions > MAX_REACTIONS) _fireOverBudget(id, w, log_.txHash);", "",
    NR, "test_unwatched_revoke_spam_is_bounded_by_budget")
add("revoke-mode-only", "a Revoke bills only leave-if-still-pending watches", R,
    "if (w.status != ST_ARMED || w.mode != MODE_IF_PENDING) continue;", "if (w.status != ST_ARMED) continue;",
    NR, "test_revoke_does_not_bill_a_leave_now_watch")
add("submit-malformed", "a malformed Submit is counted, never decoded blindly", R,
    "if (!ok || log_.data.length < 64) {", "if (false) {",
    NR, "test_malformed_submit_is_counted_not_reverted")
add("revoke-malformed", "a malformed Revoke is counted, never decoded blindly", R,
    "        if (!ok) {\n            _unknown(log_);\n            return;\n        }\n"
    "        // Only changes of at most MAX_DATA_LENGTH",
    "        if (false) {\n            _unknown(log_);\n            return;\n        }\n"
    "        // Only changes of at most MAX_DATA_LENGTH",
    NR, "test_malformed_revoke_is_counted_not_reverted")
add("carry-bounded", "a change longer than 256 bytes travels as its selector alone", R,
    "        if (data.length <= MAX_DATA_LENGTH) {\n            s.data = data;",
    "        if (true) {\n            s.data = data;",
    "PaddingTest", "test_padding_4kb_does_not_stop_the_exit")
add("store-dedupe", "a change is stored once", R,
    "if (_pending[id_][j].dataHash == h) return; // the same change delivered twice", "",
    NR, "test_duplicate_submit_delivery_is_stored_once")
add("revoke-exact-change", "a Revoke removes only its own change", R,
    "if (_pending[id_][j].dataHash != h_) continue;", "",
    NR, "test_revoke_of_one_change_keeps_the_other_of_same_kind")
add("cron-off-when-idle", "no CRON subscription once nothing waits", R,
    "if (len == 1) _cronFilter(false);", "",
    EE, "test_journey_revoke_disarms_then_next_change_exits")
add("close-releases-filters", "a closed watch releases its subscriptions", R,
    "            _submitFilter(vault, sels[i], false);\n", "",
    NR, "test_cancel_releases_all_filters")

# ---------------------------------------------------------------- demo vault (ours, test only)
add("vault-submit-curator", "only the curator schedules", V,
    "    function submit(bytes calldata data_) external {\n        if (msg.sender != curator) revert Unauthorized();",
    "    function submit(bytes calldata data_) external {",
    DV, "test_submit_refuses_non_curator")
add("vault-submit-once", "a change is scheduled once", V,
    "if (executableAt[data_] != 0) revert DataAlreadyPending();", "",
    DV, "test_submit_refuses_same_data_twice")
add("vault-revoke-curator", "only the curator revokes", V,
    "    function revoke(bytes calldata data_) external {\n        if (msg.sender != curator) revert Unauthorized();",
    "    function revoke(bytes calldata data_) external {",
    DV, "test_revoke_refuses_non_curator")
add("vault-revoke-pending", "revoke only a pending change", V,
    "if (executableAt[data_] == 0) revert DataNotTimelocked();", "",
    DV, "test_revoke_refuses_not_pending")
add("vault-run-submitted", "run only a scheduled change", V,
    "if (at == 0) revert DataNotTimelocked();", "",
    DV, "test_run_refuses_unsubmitted")
add("vault-run-after-timelock", "run only after the timelock", V,
    "if (block.timestamp < at) revert TimelockNotExpired();", "",
    DV, "test_run_refuses_early")
add("vault-run-once", "a change runs once", V,
    "        executableAt[msg.data] = 0;\n", "",
    DV, "test_run_refuses_twice")
add("vault-decrease-waits-target", "a shorter timelock waits for the current one", V,
    "selector == NoticeKinds.DECREASE_TIMELOCK ? timelock[bytes4(data_[4:8])] : timelock[selector]",
    "timelock[selector]",
    DV, "test_decrease_timelock_waits_for_target_timelock")
add("vault-increase-not-own-selector", "decreaseTimelock's own timelock is fixed (increase side)", V,
    "        if (selector_ == NoticeKinds.DECREASE_TIMELOCK) revert AutomaticallyTimelocked();\n"
    "        if (newDuration_ < timelock[selector_]) revert TimelockNotIncreasing();",
    "        if (newDuration_ < timelock[selector_]) revert TimelockNotIncreasing();",
    DV, "test_increase_timelock_refuses_decrease_selector")
add("vault-decrease-not-own-selector", "decreaseTimelock's own timelock is fixed (decrease side)", V,
    "        if (selector_ == NoticeKinds.DECREASE_TIMELOCK) revert AutomaticallyTimelocked();\n"
    "        if (newDuration_ > timelock[selector_]) revert TimelockNotDecreasing();",
    "        if (newDuration_ > timelock[selector_]) revert TimelockNotDecreasing();",
    DV, "test_decrease_timelock_refuses_its_own_selector")
add("vault-increase-only-up", "increaseTimelock only increases", V,
    "if (newDuration_ < timelock[selector_]) revert TimelockNotIncreasing();", "",
    DV, "test_increase_timelock_and_refusal")
add("vault-decrease-only-down", "decreaseTimelock only decreases", V,
    "if (newDuration_ > timelock[selector_]) revert TimelockNotDecreasing();", "",
    DV, "test_decrease_timelock_refuses_increase")
add("vault-abs-cap-up", "the absolute cap only increases", V,
    "if (newAbsoluteCap_ < absoluteCap[id]) revert AbsoluteCapNotIncreasing();", "",
    DV, "test_caps_and_refusals")
add("vault-rel-cap-max", "the relative cap is at most 100%", V,
    "if (newRelativeCap_ > WAD) revert RelativeCapAboveOne();", "",
    DV, "test_caps_and_refusals")
add("vault-rel-cap-up", "the relative cap only increases", V,
    "if (newRelativeCap_ < relativeCap[id]) revert RelativeCapNotIncreasing();", "",
    DV, "test_relative_cap_refuses_decrease")
add("vault-deposit-zero", "no deposit for zero shares", V,
    "if (shares == 0) revert ZeroShares();", "",
    DV, "test_deposit_refuses_zero_shares")
add("vault-mint-zero", "no mint of zero shares", V,
    "if (shares_ == 0) revert ZeroShares();", "",
    DV, "test_mint_refuses_zero_shares")
add("vault-withdraw-zero", "no withdraw of zero assets", V,
    "if (assets_ == 0) revert ZeroAssets();", "",
    DV, "test_withdraw_refuses_zero_assets")
add("vault-redeem-zero", "no redeem for zero assets", V,
    "if (assets == 0) revert ZeroAssets();", "",
    DV, "test_redeem_refuses_zero_assets")
add("vault-mint-rounds-up", "mint rounds the assets it takes up", V,
    "return _toAssets(shares_, true);", "return _toAssets(shares_, false);",
    DV, "test_mint_and_withdraw_round_up")
add("vault-withdraw-rounds-up", "withdraw rounds the shares it burns up", V,
    "return _toShares(assets_, true);", "return _toShares(assets_, false);",
    DV, "test_mint_and_withdraw_round_up")
add("vault-allowance", "redeeming someone else's shares needs their allowance", V,
    "if (allowed < shares_) revert InsufficientAllowance();", "",
    DV, "test_redeem_for_owner_needs_allowance")
add("vault-burn-balance", "redeem at most the share balance", V,
    "        if (bal < shares_) revert InsufficientBalance();\n        unchecked {\n"
    "            balanceOf[from_] = bal - shares_;\n            totalSupply -= shares_;",
    "        unchecked {\n            balanceOf[from_] = bal - shares_;\n            totalSupply -= shares_;",
    DV, "test_redeem_refuses_more_than_balance")
add("vault-move-balance", "a share transfer moves at most the balance", V,
    "        if (bal < shares_) revert InsufficientBalance();\n        unchecked {\n"
    "            balanceOf[from_] = bal - shares_;\n        }",
    "        unchecked {\n            balanceOf[from_] = bal - shares_;\n        }",
    DV, "test_share_transfer_refusals")
add("vault-move-zero", "no share transfer to the zero address", V,
    "    function _move(address from_, address to_, uint256 shares_) internal {\n"
    "        if (to_ == address(0)) revert ZeroAddress();",
    "    function _move(address from_, address to_, uint256 shares_) internal {",
    DV, "test_share_transfer_refusals")
add("vault-mint-to-zero", "no shares to the zero address", V,
    "    function _mint(address to_, uint256 shares_) internal {\n        if (to_ == address(0)) revert ZeroAddress();",
    "    function _mint(address to_, uint256 shares_) internal {",
    DV, "test_vault_refuses_zero_receiver")
add("vault-push-to-zero", "no assets to the zero address", V,
    "    function _push(address to_, uint256 amount_) internal {\n        if (to_ == address(0)) revert ZeroAddress();",
    "    function _push(address to_, uint256 amount_) internal {",
    DV, "test_vault_refuses_zero_receiver_even_if_token_allows")
add("vault-token-false", "a token answering false is a failed transfer", V,
    "if (ret.length > 0 && !abi.decode(ret, (bool))) revert TransferFailed();", "",
    DV, "test_vault_refuses_token_answering_false")
add("vault-token-revert-empty", "a token reverting without a reason is a failed transfer", V,
    "            }\n            revert TransferFailed();\n        }",
    "            }\n        }",
    DV, "test_vault_refuses_token_reverting_without_reason")
add("vault-ctor-zero", "a vault needs an asset and a curator", V,
    "if (asset_ == address(0) || curator_ == address(0)) revert ZeroAddress();", "",
    DV, "test_vault_and_factory_refuse_zero_addresses")
add("factory-ctor-zero", "the factory needs an asset", F,
    "if (asset_ == address(0)) revert ZeroAddress();", "",
    DV, "test_vault_and_factory_refuse_zero_addresses")

# ---------------------------------------------------------------- demo token (ours, test only)
add("token-mint-cap", "mint at most 1,000 tokens per call", T,
    "if (amount_ > MAX_MINT) revert MintTooLarge(amount_, MAX_MINT);", "",
    DV, "test_token_mint_cap")
add("token-mint-zero", "no mint to the zero address", T,
    "        if (to_ == address(0)) revert ZeroAddress();\n        totalSupply += amount_;",
    "        totalSupply += amount_;",
    DV, "test_token_refusals")
add("token-allowance", "transferFrom needs an allowance", T,
    "if (allowed < amount_) revert InsufficientAllowance();", "",
    DV, "test_token_refusals")
add("token-transfer-zero", "no transfer to the zero address", T,
    "        if (to_ == address(0)) revert ZeroAddress();\n        uint256 bal = balanceOf[from_];",
    "        uint256 bal = balanceOf[from_];",
    DV, "test_token_refusals")
add("token-balance", "a transfer moves at most the balance", T,
    "if (bal < amount_) revert InsufficientBalance();", "",
    DV, "test_token_refusals")

# ---------------------------------------------------------------- hello-world pair
add("hello-react-only-system", "hello react() only from the system contract", HR,
    "function react(LogRecord calldata log_) external onlySystem {",
    "function react(LogRecord calldata log_) external {",
    H, "test_react_refuses_non_system")
add("hello-pong-only-proxy", "hello pong() only from the callback proxy", HC,
    "        onlyServiceProvider\n        onlyCallbackSender(reactive_)",
    "        onlyCallbackSender(reactive_)",
    H, "test_pong_refuses_direct_caller")
add("hello-pong-only-our-reactive", "hello pong() only on request of our reactive contract", HC,
    "        onlyServiceProvider\n        onlyCallbackSender(reactive_)",
    "        onlyServiceProvider",
    H, "test_pong_refuses_other_reactive")
