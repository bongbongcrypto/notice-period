// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { NoticeExit } from "../src/NoticeExit.sol";
import { NoticeReactive } from "../src/NoticeReactive.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice Tests of the reactive contract through the mock network: subscriptions decide what react() sees.
contract NoticeReactiveTest is NoticeSetup {
    DemoVault internal vault;
    uint256 internal constant DEPOSIT = 500e6;

    function setUp() public virtual {
        _deploy();
        vault = _vaultWithDeposit(alice, DEPOSIT);
    }

    // ---------------------------------------------------------------- helpers

    function _submitRecord(address vault_, bytes memory data_, uint256 executableAt_, uint256 txHash_)
        internal
        pure
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = vault_;
        r.topic0 = NoticeKinds.SUBMIT_TOPIC;
        r.topic1 = NoticeKinds.selectorTopic(bytes4(data_));
        r.opCode = 2;
        r.data = abi.encode(data_, executableAt_);
        r.txHash = txHash_;
    }

    function _cronRecord() internal view returns (IReactive.LogRecord memory r) {
        r.chainId = block.chainid;
        r.contractAddress = CRON_ADDR;
        r.topic0 = CRON10_TOPIC;
        r.topic1 = block.number;
        r.opCode = 2;
    }

    function _submitActive(address vault_, bytes4 sel_) internal view returns (bool) {
        return sys.isActive(
            address(reactive), ORIGIN_CHAIN, vault_, NoticeKinds.SUBMIT_TOPIC, NoticeKinds.selectorTopic(sel_), IGNORE, IGNORE
        );
    }

    function _revokeActive(address vault_) internal view returns (bool) {
        return sys.isActive(address(reactive), ORIGIN_CHAIN, vault_, NoticeKinds.REVOKE_TOPIC, IGNORE, IGNORE, IGNORE);
    }

    function _cronActive() internal view returns (bool) {
        return sys.isActive(address(reactive), block.chainid, CRON_ADDR, CRON10_TOPIC, IGNORE, IGNORE, IGNORE);
    }

    // ---------------------------------------------------------------- wiring

    function test_constructor_subscribes_to_exit_events() public view {
        assertTrue(
            sys.isActive(
                address(reactive), ORIGIN_CHAIN, address(exitC), reactive.WATCH_ARMED_TOPIC(), IGNORE, IGNORE, IGNORE
            )
        );
        assertTrue(
            sys.isActive(
                address(reactive), ORIGIN_CHAIN, address(exitC), reactive.WATCH_CANCELLED_TOPIC(), IGNORE, IGNORE, IGNORE
            )
        );
        assertEq(sys.activeCount(address(reactive)), 2);
        assertEq(reactive.EXIT(), address(exitC));
        assertEq(exitC._CALLBACK_SENDER(), address(reactive));
    }

    function test_watch_topics_match_exit_events() public view {
        assertEq(reactive.WATCH_ARMED_TOPIC(), uint256(NoticeExit.WatchArmed.selector));
        assertEq(reactive.WATCH_CANCELLED_TOPIC(), uint256(NoticeExit.WatchCancelled.selector));
    }

    function test_react_refuses_non_system() public {
        IReactive.LogRecord memory r;
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        reactive.react(r);
    }

    // ---------------------------------------------------------------- arming

    function test_arm_now_subscribes_one_filter_per_default_selector() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        assertEq(_rStatus(id), reactive.ST_ARMED());
        assertTrue(_submitActive(address(vault), NoticeKinds.ADD_ADAPTER));
        assertTrue(_submitActive(address(vault), NoticeKinds.DECREASE_TIMELOCK));
        assertTrue(_submitActive(address(vault), NoticeKinds.SET_IS_ALLOCATOR));
        assertFalse(_submitActive(address(vault), NoticeKinds.INCREASE_ABSOLUTE_CAP));
        assertFalse(_revokeActive(address(vault)));
        assertEq(sys.activeCount(address(reactive)), 5);
        assertEq(reactive.activeWatches(), 1);
        assertEq(reactive.vaultWatches(address(vault)).length, 1);
        assertEq(sys.reverts(), 0);
    }

    function test_arm_pending_adds_revoke_filter() public {
        _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        assertTrue(_revokeActive(address(vault)));
        assertEq(sys.activeCount(address(reactive)), 6);
        assertFalse(_cronActive(), "CRON only while a change is stored");
    }

    function test_arm_cap_opt_in_adds_both_cap_selectors() public {
        _arm(alice, vault, NoticeKinds.ALL, 0, type(uint256).max);
        assertTrue(_submitActive(address(vault), NoticeKinds.INCREASE_ABSOLUTE_CAP));
        assertTrue(_submitActive(address(vault), NoticeKinds.INCREASE_RELATIVE_CAP));
        assertEq(sys.activeCount(address(reactive)), 7);
    }

    function test_duplicate_watch_armed_is_ignored() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        uint256 calls = sys.subscribeCalls();
        IReactive.LogRecord memory r;
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(exitC);
        r.topic0 = reactive.WATCH_ARMED_TOPIC();
        r.topic1 = id;
        r.topic2 = uint256(uint160(alice));
        r.topic3 = uint256(uint160(address(vault)));
        r.opCode = 4;
        r.data = abi.encode(NoticeKinds.DEFAULT, uint8(0), type(uint256).max);
        sys.forceDeliver(address(reactive), r);
        assertEq(sys.subscribeCalls(), calls);
        assertEq(reactive.activeWatches(), 1);
        assertEq(sys.reverts(), 0);
    }

    function test_bad_kinds_in_event_are_refused_not_reverted() public {
        IReactive.LogRecord memory r;
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(exitC);
        r.topic0 = reactive.WATCH_ARMED_TOPIC();
        r.topic1 = 77;
        r.topic3 = uint256(uint160(address(vault)));
        r.opCode = 4;
        r.data = abi.encode(uint8(0), uint8(0), uint256(1));
        sys.forceDeliver(address(reactive), r);
        assertEq(_rStatus(77), reactive.ST_REFUSED());
        assertEq(reactive.activeWatches(), 0);
        assertEq(sys.reverts(), 0);
    }

    function test_watch_armed_from_another_contract_is_ignored() public {
        IReactive.LogRecord memory r;
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(exitC);
        r.topic0 = reactive.WATCH_ARMED_TOPIC();
        r.topic1 = 80;
        r.topic3 = uint256(uint160(address(vault)));
        r.opCode = 4;
        r.data = abi.encode(NoticeKinds.DEFAULT, uint8(0), uint256(1));
        sys.forceDeliver(address(reactive), r);
        assertEq(_rStatus(80), reactive.ST_ARMED(), "from our exit contract: armed");
        r.contractAddress = address(0xBAD);
        r.topic1 = 81;
        sys.forceDeliver(address(reactive), r);
        assertEq(_rStatus(81), reactive.ST_NONE(), "same event from anyone else: ignored");
        assertEq(reactive.unknownEvents(), 1);
        assertEq(reactive.activeWatches(), 1);
    }

    function test_bad_mode_in_event_is_refused_not_reverted() public {
        IReactive.LogRecord memory r;
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(exitC);
        r.topic0 = reactive.WATCH_ARMED_TOPIC();
        r.topic1 = 78;
        r.topic3 = uint256(uint160(address(vault)));
        r.opCode = 4;
        r.data = abi.encode(NoticeKinds.DEFAULT, uint8(1), uint256(1));
        sys.forceDeliver(address(reactive), r);
        assertEq(_rStatus(78), reactive.ST_ARMED(), "mode 1 is accepted");
        r.topic1 = 79;
        r.data = abi.encode(NoticeKinds.DEFAULT, uint8(2), uint256(1));
        sys.forceDeliver(address(reactive), r);
        assertEq(_rStatus(79), reactive.ST_REFUSED(), "mode 2 does not exist");
        assertEq(sys.reverts(), 0);
    }

    function test_refuses_fourth_watch_on_one_vault() public {
        address dave = makeAddr("dave");
        _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deposit(bob, vault, 1e6);
        _arm(bob, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deposit(carol, vault, 1e6);
        _arm(carol, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deposit(dave, vault, 1e6);
        uint256 calls = sys.subscribeCalls();
        uint256 id = _arm(dave, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        assertEq(_rStatus(id), reactive.ST_REFUSED());
        assertEq(sys.subscribeCalls(), calls, "a refused watch subscribes nothing");
        assertEq(reactive.activeWatches(), 3);
    }

    function test_refuses_watch_over_active_cap() public {
        uint256 last;
        for (uint256 i = 0; i <= MAX_ACTIVE; i++) {
            address u = vm.addr(2000 + i);
            DemoVault v = _vaultWithDeposit(u, 1e6);
            last = _arm(u, v, NoticeKinds.DEFAULT, 0, type(uint256).max);
        }
        assertEq(_rStatus(last), reactive.ST_REFUSED());
        assertEq(reactive.activeWatches(), MAX_ACTIVE);
    }

    /// @dev Bites `if (callbackGas_ < MIN_CALLBACK_GAS) revert CallbackGasTooLow(callbackGas_);` in the constructor:
    ///      399,999 is refused, 400,000 deploys.
    function test_constructor_refuses_low_callback_gas() public {
        uint64 floor = reactive.MIN_CALLBACK_GAS();
        assertEq(floor, 400_000);
        vm.expectRevert(abi.encodeWithSelector(NoticeReactive.CallbackGasTooLow.selector, floor - 1));
        new NoticeReactive(ORIGIN_CHAIN, address(0xE717), CRON10_TOPIC, LEAD, MAX_WAIT, floor - 1, MAX_ACTIVE, 80);
        // sibling: the floor itself is taken
        NoticeReactive ok =
            new NoticeReactive(ORIGIN_CHAIN, address(0xE717), CRON10_TOPIC, LEAD, MAX_WAIT, floor, MAX_ACTIVE, 80);
        assertEq(ok.CALLBACK_GAS(), floor);
    }

    // ---------------------------------------------------------------- leave now

    function test_now_mode_exits_on_watched_submit() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        bytes memory data = _adapterCall(address(0xA1));
        uint256 cb0 = sys.callbackCount();
        uint256 origin = _submit(alice, vault, data);
        assertEq(sys.callbackCount(), cb0 + 1);
        assertEq(sys.callbackAt(cb0).recipient, address(exitC));
        assertEq(sys.callbackAt(cb0).chainId, ORIGIN_CHAIN);
        assertEq(sys.callbackAt(cb0).gasLimit, CB_GAS);
        assertEq(sys.callbackAt(cb0).sender, address(reactive));
        (uint256 gid, bytes memory gdata, uint256 gorigin, uint8 greason) = _callbackArgs(cb0);
        assertEq(gid, id);
        assertEq(gdata, data);
        assertEq(gorigin, origin, "origin transaction hash travels to the callback");
        assertEq(greason, reactive.R_SCHEDULED());
        // filters released, watch closed, deposit back in the owner's wallet
        assertEq(sys.activeCount(address(reactive)), 2);
        assertEq(_rStatus(id), reactive.ST_EXITED());
        assertEq(reactive.activeWatches(), 0);
        assertTrue(proxy.lastOk());
        assertEq(token.balanceOf(alice), DEPOSIT);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(_status(id), exitC.STATUS_ENDED());
        assertEq(sys.reverts(), 0);
    }

    function test_payload_reserves_first_argument() public {
        _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _submit(alice, vault, _adapterCall(address(0xA1)));
        bytes memory payload = sys.callbackAt(0).payload;
        bytes4 sel;
        address first;
        assembly {
            sel := mload(add(payload, 32))
            first := mload(add(payload, 36))
        }
        assertEq(sel, NoticeExit.exit.selector);
        assertEq(first, address(0));
    }

    function test_default_rules_ignore_cap_increase() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        uint256 delivered = sys.delivered();
        _submit(alice, vault, _capCall(100e6));
        assertEq(sys.delivered(), delivered, "no filter, no reactive transaction, no cost");
        assertEq(sys.callbackCount(), 0);
        assertEq(_rStatus(id), reactive.ST_ARMED());
        assertEq(vault.balanceOf(alice), DEPOSIT);
    }

    function test_cap_increase_exits_when_opted_in() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT | NoticeKinds.CAP_UP, 0, type(uint256).max);
        _submit(alice, vault, _capCall(100e6));
        assertEq(_rStatus(id), reactive.ST_EXITED());
        assertEq(token.balanceOf(alice), DEPOSIT);
    }

    function test_cap_change_exits_only_the_watch_that_opted_in() public {
        _deposit(bob, vault, 10e6);
        uint256 idA = _arm(alice, vault, NoticeKinds.DEFAULT | NoticeKinds.CAP_UP, 0, type(uint256).max);
        uint256 idB = _arm(bob, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _submit(alice, vault, _capCall(1e12));
        assertEq(sys.callbackCount(), 1);
        (uint256 id,,,) = _callbackArgs(0);
        assertEq(id, idA);
        assertEq(_rStatus(idB), reactive.ST_ARMED());
        assertEq(_status(idB), exitC.STATUS_ACTIVE());
    }

    function test_shorter_timelock_and_allocator_exit_by_default() public {
        uint256 idA = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        DemoVault vb = _vaultWithDeposit(bob, 300e6);
        uint256 idB = _arm(bob, vb, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _submit(alice, vault, _timelockDownCall());
        _submit(bob, vb, _allocatorCall(carol));
        assertEq(_rStatus(idA), reactive.ST_EXITED());
        assertEq(_rStatus(idB), reactive.ST_EXITED());
        assertEq(token.balanceOf(alice), DEPOSIT);
        assertEq(token.balanceOf(bob), 300e6);
    }

    function test_curator_action_on_one_vault_leaves_other_vaults_alone() public {
        uint256 idA = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        DemoVault vb = _vaultWithDeposit(bob, 300e6);
        uint256 idB = _arm(bob, vb, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _submit(bob, vb, _adapterCall(address(0xB1)));
        assertEq(_rStatus(idB), reactive.ST_EXITED());
        assertEq(_rStatus(idA), reactive.ST_ARMED());
        assertEq(vault.balanceOf(alice), DEPOSIT);
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- leave if still pending

    function test_pending_mode_waits_then_exits_shortly_before_deadline() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory data = _adapterCall(address(0xA1));
        uint256 at = block.timestamp + TIMELOCK;
        uint256 origin = _submit(alice, vault, data);
        assertEq(sys.callbackCount(), 0);
        assertEq(_rPendingCount(id), 1);
        assertTrue(_cronActive());
        assertEq(reactive.cronFilterRefs(), 1);

        _tickAndPump();
        assertEq(reactive.ticks(), 1);
        assertEq(sys.callbackCount(), 0);

        vm.warp(at - LEAD - 1);
        _tickAndPump();
        assertEq(sys.callbackCount(), 0);

        vm.warp(at - LEAD);
        _tickAndPump();
        assertEq(sys.callbackCount(), 1);
        (uint256 gid, bytes memory gdata, uint256 gorigin, uint8 greason) = _callbackArgs(0);
        assertEq(gid, id);
        assertEq(gdata, data);
        assertEq(gorigin, origin);
        assertEq(greason, reactive.R_DEADLINE());
        assertFalse(_cronActive());
        assertEq(reactive.pendingWatchIds().length, 0);
        assertEq(token.balanceOf(alice), DEPOSIT, "still pending on the vault: redeemed");
        assertEq(sys.reverts(), 0);
    }

    function test_vault_revoke_disarms_pending_watch() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory data = _adapterCall(address(0xA1));
        _submit(alice, vault, data);
        assertTrue(_cronActive());
        _revokeChange(alice, vault, data);
        assertEq(_rPendingCount(id), 0);
        assertFalse(_cronActive(), "no stored change, no CRON");
        assertEq(_rStatus(id), reactive.ST_ARMED(), "the watch keeps watching");
        vm.warp(block.timestamp + TIMELOCK + 1);
        _tickAndPump();
        assertEq(sys.callbackCount(), 0);
        assertEq(vault.balanceOf(alice), DEPOSIT);
        // a new change is stored again
        _submit(alice, vault, _adapterCall(address(0xA2)));
        assertEq(_rPendingCount(id), 1);
        assertTrue(_cronActive());
    }

    function test_revoke_of_one_change_keeps_the_other_of_same_kind() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory a = _adapterCall(address(0xA1));
        bytes memory b = _adapterCall(address(0xB2));
        uint256 atA = block.timestamp + TIMELOCK;
        _submit(alice, vault, a);
        vm.warp(block.timestamp + 10);
        _submit(alice, vault, b);
        assertEq(_rPendingCount(id), 2);
        _revokeChange(alice, vault, b);
        assertEq(_rPendingCount(id), 1);
        vm.warp(atA - LEAD);
        _tickAndPump();
        assertEq(sys.callbackCount(), 1);
        (, bytes memory gdata,,) = _callbackArgs(0);
        assertEq(gdata, a);
    }

    function test_revoke_racing_tick_revoke_arrives_first() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory data = _adapterCall(address(0xA1));
        uint256 at = block.timestamp + TIMELOCK;
        _submit(alice, vault, data);
        vm.warp(at - LEAD);
        _revokeChange(alice, vault, data); // reaches the reactive contract before the tick
        _tickAndPump();
        assertEq(sys.callbackCount(), 0);
        assertEq(_rStatus(id), reactive.ST_ARMED());
        assertEq(vault.balanceOf(alice), DEPOSIT);
    }

    function test_revoke_racing_tick_tick_fires_first() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory data = _adapterCall(address(0xA1));
        uint256 at = block.timestamp + TIMELOCK;
        _submit(alice, vault, data);
        vm.warp(at - LEAD);
        holdCallbacks = true;
        _tickAndPump(); // exit requested, not yet delivered
        assertEq(sys.callbackCount(), 1);
        assertEq(_rStatus(id), reactive.ST_EXITED());
        _revokeChange(alice, vault, data); // lands on the vault's chain before the callback
        holdCallbacks = false;
        _deliverCallbacks();
        assertTrue(proxy.lastOk());
        assertEq(_status(id), exitC.STATUS_ENDED());
        // Base does not ask the vault again (SPEC.md section 6): once the tick asked for the exit, the depositor
        // leaves even though the change was revoked in the seconds before the callback.
        assertEq(vault.balanceOf(alice), 0);
        assertEq(token.balanceOf(alice), DEPOSIT);
    }

    /// @dev Two watches due on the same tick: the one whose change can run first leaves first, whatever the order
    ///      in which the changes were stored.
    function test_tick_fires_most_urgent_first() public {
        DemoVault vb = _vaultWithDeposit(bob, 300e6);
        // bob's vault gets a longer timelock (before anyone watches it), so his change is stored first but can run
        // later
        bytes memory longer = abi.encodeCall(DemoVault.increaseTimelock, (NoticeKinds.ADD_ADAPTER, TIMELOCK + 60));
        vm.prank(bob);
        vb.submit(longer);
        vm.warp(block.timestamp + TIMELOCK);
        (bool ok,) = address(vb).call(longer);
        assertTrue(ok, "timelock raised");
        assertEq(vb.timelock(NoticeKinds.ADD_ADAPTER), TIMELOCK + 60);
        uint256 idB = _arm(bob, vb, NoticeKinds.DEFAULT, 1, type(uint256).max);
        uint256 idA = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory change = _adapterCall(address(0xA1));
        _submit(bob, vb, change);
        _submit(alice, vault, change);
        uint256 atA = vault.executableAt(change);
        uint256 atB = vb.executableAt(change);
        assertLt(atA, atB);
        vm.warp(atB - LEAD); // both are within LEAD of their deadline
        _tickAndPump();
        assertEq(sys.callbackCount(), 1, "one exit per tick");
        (uint256 first,,,) = _callbackArgs(0);
        assertEq(first, idA, "the change that can run first leaves first");
        _tickAndPump();
        assertEq(sys.callbackCount(), 2);
        (uint256 second,,,) = _callbackArgs(1);
        assertEq(second, idB);
    }

    /// @dev A curator stores a decoy and a real change, waits for the exit request of the decoy (ExitRequested is
    ///      public on Lasna) and revokes the decoy before the callback lands. The real change stays pending and will
    ///      run, so the depositor must be out.
    function test_decoy_revoked_after_the_tick_does_not_disarm_the_watch() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory decoy = _adapterCall(address(0xDEC0));
        bytes memory real = _allocatorCall(address(0xBAD1));
        _submit(alice, vault, decoy);
        _submit(alice, vault, real);
        assertEq(_rPendingCount(id), 2);
        vm.warp(vault.executableAt(decoy) - LEAD);
        holdCallbacks = true;
        _tickAndPump(); // the exit for the decoy is on its way
        assertEq(sys.callbackCount(), 1);
        _revokeChange(alice, vault, decoy); // lands on the vault's chain before the callback
        holdCallbacks = false;
        _deliverCallbacks();
        _pump(address(reactive));
        assertGt(vault.executableAt(real), 0, "the real change is still pending");
        assertEq(token.balanceOf(alice), DEPOSIT, "the depositor is out before the real change can run");
        assertEq(vault.balanceOf(alice), 0);
        assertEq(_status(id), exitC.STATUS_ENDED());
    }

    /// @dev The one-change form of the same race: revoke after the tick, submit the same change again later.
    function test_revoke_after_the_tick_then_resubmit_does_not_disarm_the_watch() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory change = _adapterCall(address(0xA1));
        _submit(alice, vault, change);
        vm.warp(vault.executableAt(change) - LEAD);
        holdCallbacks = true;
        _tickAndPump();
        _revokeChange(alice, vault, change);
        holdCallbacks = false;
        _deliverCallbacks();
        _pump(address(reactive));
        _submit(alice, vault, change); // the same change again, after the callback
        assertGt(vault.executableAt(change), 0, "the change is pending again");
        assertEq(token.balanceOf(alice), DEPOSIT, "the depositor is out");
        assertEq(_status(id), exitC.STATUS_ENDED());
    }

    /// @dev A watch refused on Lasna is still active on Base; cancelling it there must not touch Lasna's counts.
    function test_cancel_of_a_refused_watch_changes_nothing_on_lasna() public {
        address dave = makeAddr("dave");
        _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deposit(bob, vault, 1e6);
        _arm(bob, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deposit(carol, vault, 1e6);
        _arm(carol, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deposit(dave, vault, 1e6);
        uint256 id = _arm(dave, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        assertEq(_rStatus(id), reactive.ST_REFUSED());
        assertEq(_status(id), exitC.STATUS_ACTIVE(), "Base does not know about the refusal");
        uint256 active = reactive.activeWatches();
        vm.prank(dave);
        exitC.cancel(id);
        _pump(address(reactive));
        assertEq(_rStatus(id), reactive.ST_REFUSED(), "a refused watch stays refused");
        assertEq(reactive.activeWatches(), active, "the count of active watches is unchanged");
        assertEq(reactive.vaultWatches(address(vault)).length, 3);
        assertEq(sys.reverts(), 0);
    }

    function test_cancel_releases_all_filters() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        _submit(alice, vault, _adapterCall(address(0xA1)));
        assertTrue(_cronActive());
        vm.prank(alice);
        exitC.cancel(id);
        _pump(address(reactive));
        assertEq(_rStatus(id), reactive.ST_CANCELLED());
        assertEq(sys.activeCount(address(reactive)), 2, "only the two permanent filters remain");
        assertEq(reactive.pendingWatchIds().length, 0);
        assertEq(reactive.activeWatches(), 0);
    }

    function test_shared_filters_are_reference_counted() public {
        uint256 idA = _arm(alice, vault, NoticeKinds.ADAPTER, 0, type(uint256).max);
        _deposit(bob, vault, 200e6);
        uint256 idB = _arm(bob, vault, NoticeKinds.ADAPTER | NoticeKinds.CAP_UP, 0, type(uint256).max);
        assertEq(reactive.submitFilterRefs(address(vault), NoticeKinds.ADD_ADAPTER), 2);
        vm.prank(alice);
        exitC.cancel(idA);
        _pump(address(reactive));
        assertTrue(_submitActive(address(vault), NoticeKinds.ADD_ADAPTER), "bob still needs it");
        assertEq(reactive.submitFilterRefs(address(vault), NoticeKinds.ADD_ADAPTER), 1);
        _submit(alice, vault, _adapterCall(address(0xA1)));
        assertEq(_rStatus(idB), reactive.ST_EXITED());
        assertEq(token.balanceOf(bob), 200e6);
        assertFalse(_submitActive(address(vault), NoticeKinds.ADD_ADAPTER));
        assertFalse(_submitActive(address(vault), NoticeKinds.INCREASE_ABSOLUTE_CAP));
        assertEq(vault.balanceOf(alice), DEPOSIT);
    }

    function test_two_watches_on_one_vault_both_leave() public {
        uint256 idA = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deposit(bob, vault, 200e6);
        uint256 idB = _arm(bob, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _submit(alice, vault, _adapterCall(address(0xA1)));
        assertEq(_rStatus(idA), reactive.ST_EXITED());
        assertEq(_rStatus(idB), reactive.ST_EXITED());
        assertEq(token.balanceOf(alice), DEPOSIT);
        assertEq(token.balanceOf(bob), 200e6);
        assertEq(sys.activeCount(address(reactive)), 2);
    }

    function test_one_exit_per_tick() public {
        uint256 idA = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        DemoVault vb = _vaultWithDeposit(bob, 300e6);
        uint256 idB = _arm(bob, vb, NoticeKinds.DEFAULT, 1, type(uint256).max);
        uint256 at = block.timestamp + TIMELOCK;
        _submit(alice, vault, _adapterCall(address(0xA1)));
        _submit(bob, vb, _adapterCall(address(0xB1)));
        vm.warp(at - LEAD);
        _tickAndPump();
        assertEq(sys.callbackCount(), 1);
        _tickAndPump();
        assertEq(sys.callbackCount(), 2);
        assertEq(_rStatus(idA), reactive.ST_EXITED());
        assertEq(_rStatus(idB), reactive.ST_EXITED());
        assertFalse(_cronActive());
    }

    // ---------------------------------------------------------------- reasons to leave at once

    function _armPendingAndDeliver(IReactive.LogRecord memory r_) internal returns (uint8 reason) {
        _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        holdCallbacks = true;
        assertTrue(sys.deliver(address(reactive), r_), "matches the watch's filter");
        assertEq(sys.callbackCount(), 1);
        (,,, reason) = _callbackArgs(0);
    }

    function test_leaves_at_once_when_too_soon() public {
        IReactive.LogRecord memory r =
            _submitRecord(address(vault), _adapterCall(address(1)), block.timestamp + LEAD, 1);
        assertEq(_armPendingAndDeliver(r), reactive.R_TOO_SOON());
    }

    function test_leaves_at_once_when_wait_too_long() public {
        IReactive.LogRecord memory r =
            _submitRecord(address(vault), _adapterCall(address(1)), block.timestamp + MAX_WAIT + 1, 1);
        assertEq(_armPendingAndDeliver(r), reactive.R_WAIT_TOO_LONG());
    }

    function test_leaves_at_once_when_data_too_long() public {
        bytes memory longData = abi.encodePacked(NoticeKinds.ADD_ADAPTER, new bytes(reactive.MAX_DATA_LENGTH()));
        IReactive.LogRecord memory r = _submitRecord(address(vault), longData, block.timestamp + TIMELOCK, 1);
        assertEq(_armPendingAndDeliver(r), reactive.R_DATA_TOO_LONG());
    }

    function test_leaves_at_once_when_pending_full() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        _submit(alice, vault, _adapterCall(address(1)));
        _submit(alice, vault, _adapterCall(address(2)));
        _submit(alice, vault, _adapterCall(address(3)));
        assertEq(_rPendingCount(id), 3);
        assertEq(sys.callbackCount(), 0);
        holdCallbacks = true;
        _submit(alice, vault, _adapterCall(address(4)));
        assertEq(sys.callbackCount(), 1);
        (,,, uint8 reason) = _callbackArgs(0);
        assertEq(reason, reactive.R_PENDING_FULL());
    }

    function test_duplicate_submit_delivery_is_stored_once() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        IReactive.LogRecord memory r =
            _submitRecord(address(vault), _adapterCall(address(1)), block.timestamp + TIMELOCK, 5);
        sys.deliver(address(reactive), r);
        sys.deliver(address(reactive), r);
        assertEq(_rPendingCount(id), 1);
    }

    function test_submit_revoke_spam_ends_in_exit_by_budget() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        for (uint256 i = 0; i < MAX_REACTIONS / 2; i++) {
            bytes memory d = _adapterCall(address(uint160(100 + i)));
            _submit(alice, vault, d);
            _revokeChange(alice, vault, d);
        }
        assertEq(_rReactions(id), MAX_REACTIONS);
        assertEq(sys.callbackCount(), 0);
        holdCallbacks = true;
        _submit(alice, vault, _adapterCall(address(9999)));
        assertEq(sys.callbackCount(), 1);
        (,,, uint8 reason) = _callbackArgs(0);
        assertEq(reason, reactive.R_BUDGET());
        assertEq(_rStatus(id), reactive.ST_EXITED());
    }

    /// @dev Revokes of a kind the watch does not flee still reach it (one Revoke filter per vault, whatever the
    ///      selector), and the matching Submits do not. Such a spam must not bill the operator float without end:
    ///      the reaction budget ends the watch with an exit, and then nothing more is delivered.
    function test_unwatched_revoke_spam_is_bounded_by_budget() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        uint256 d0 = sys.delivered();
        for (uint256 i = 0; i < 200; i++) {
            bytes memory d = abi.encodeCall(DemoVault.increaseTimelock, (NoticeKinds.ADD_ADAPTER, 1000 + i));
            _submit(alice, vault, d);
            _revokeChange(alice, vault, d);
        }
        assertEq(sys.delivered() - d0, MAX_REACTIONS + 1, "billed reactions stop at the budget");
        assertEq(_rStatus(id), reactive.ST_EXITED());
        assertEq(sys.callbackCount(), 1);
        (,,, uint8 reason) = _callbackArgs(0);
        assertEq(reason, reactive.R_BUDGET());
        assertTrue(proxy.lastOk(), "the budget exit is accepted on Base");
        assertEq(token.balanceOf(alice), DEPOSIT, "the depositor leaves instead of staying unwatched");
        assertEq(_status(id), exitC.STATUS_ENDED());
        assertEq(sys.reverts(), 0);
    }

    // ---------------------------------------------------------------- strays and unknown logs

    function test_stray_submit_after_unsubscribe_is_counted() public {
        _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _submit(alice, vault, _adapterCall(address(0xA1)));
        assertFalse(_submitActive(address(vault), NoticeKinds.ADD_ADAPTER));
        uint256 unsubs = sys.unsubscribeCalls();
        uint256 misses = sys.silentMisses();
        uint256 cbs = sys.callbackCount();
        // the network delivers anyway, as if the unsubscribe had silently failed
        sys.forceDeliver(
            address(reactive), _submitRecord(address(vault), _adapterCall(address(0xA2)), block.timestamp + 180, 9)
        );
        assertEq(reactive.strayEvents(), 1);
        assertEq(sys.unsubscribeCalls(), unsubs + 1, "the exact unsubscribe is sent again");
        assertEq(sys.silentMisses(), misses + 1);
        assertEq(sys.callbackCount(), cbs, "a stray never exits anyone");
        assertEq(sys.reverts(), 0);
    }

    function test_stray_revoke_after_unsubscribe_is_counted() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        IReactive.LogRecord memory r;
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(vault);
        r.topic0 = NoticeKinds.REVOKE_TOPIC;
        r.topic1 = uint256(uint160(alice));
        r.topic2 = NoticeKinds.selectorTopic(NoticeKinds.ADD_ADAPTER);
        r.opCode = 3;
        r.data = abi.encode(_adapterCall(address(1)));
        assertTrue(sys.deliver(address(reactive), r), "while the pending watch lives, Revoke is subscribed");
        assertEq(reactive.strayEvents(), 0);
        vm.prank(alice);
        exitC.cancel(id);
        _pump(address(reactive));
        assertFalse(_revokeActive(address(vault)));
        sys.forceDeliver(address(reactive), r);
        assertEq(reactive.strayEvents(), 1);
        assertEq(sys.reverts(), 0);
    }

    function test_malformed_revoke_is_counted_not_reverted() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        IReactive.LogRecord memory r;
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(vault);
        r.topic0 = NoticeKinds.REVOKE_TOPIC;
        r.topic1 = uint256(uint160(alice));
        r.topic2 = NoticeKinds.selectorTopic(NoticeKinds.ADD_ADAPTER);
        r.opCode = 3;
        r.data = abi.encode(_adapterCall(address(1)));
        assertTrue(sys.deliver(address(reactive), r), "a well-formed Revoke is taken");
        assertEq(reactive.unknownEvents(), 0);
        r.data = hex"1234"; // not an ABI encoding of (bytes)
        assertTrue(sys.deliver(address(reactive), r));
        assertEq(reactive.unknownEvents(), 1);
        r.data = abi.encode(uint256(32), uint256(1 << 200)); // length far beyond the data
        sys.deliver(address(reactive), r);
        assertEq(reactive.unknownEvents(), 2);
        assertEq(sys.reverts(), 0);
        assertEq(_rStatus(id), reactive.ST_ARMED());
    }

    function test_malformed_submit_is_counted_not_reverted() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        IReactive.LogRecord memory r = _submitRecord(address(vault), _adapterCall(address(1)), block.timestamp + 180, 7);
        r.data = hex"1234"; // not an ABI encoding of (bytes, uint256)
        assertTrue(sys.deliver(address(reactive), r), "matches the watch's filter");
        assertEq(reactive.unknownEvents(), 1);
        assertEq(sys.callbackCount(), 0);
        assertEq(_rStatus(id), reactive.ST_ARMED());
        r.data = abi.encode(uint256(1 << 200), uint256(0)); // offset far outside the data
        sys.deliver(address(reactive), r);
        assertEq(reactive.unknownEvents(), 2);
        assertEq(sys.reverts(), 0);
    }

    function test_stray_tick_after_unsubscribe_is_counted() public {
        sys.forceDeliver(address(reactive), _cronRecord());
        assertEq(reactive.strayEvents(), 1);
        assertEq(reactive.ticks(), 0);
        assertEq(sys.reverts(), 0);
    }

    function test_unknown_logs_are_counted_not_reverted() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        IReactive.LogRecord memory r = _submitRecord(address(vault), _adapterCall(address(1)), block.timestamp, 1);
        r.chainId = 1; // wrong chain
        sys.forceDeliver(address(reactive), r);
        r.chainId = ORIGIN_CHAIN;
        r.opCode = 3; // wrong topic count for Submit
        sys.forceDeliver(address(reactive), r);
        IReactive.LogRecord memory e;
        e.chainId = ORIGIN_CHAIN;
        e.contractAddress = address(exitC);
        e.topic0 = uint256(keccak256("Other()"));
        e.opCode = 1;
        sys.forceDeliver(address(reactive), e);
        IReactive.LogRecord memory c = _cronRecord();
        c.chainId = 1;
        sys.forceDeliver(address(reactive), c);
        assertEq(reactive.unknownEvents(), 4);
        assertEq(sys.callbackCount(), 0);
        assertEq(_rStatus(id), reactive.ST_ARMED());
        assertEq(sys.reverts(), 0);
    }

    function test_cover_debt_is_open() public {
        vm.prank(bob);
        reactive.coverDebt();
    }

    function test_cover_debt_pays_the_system_contract() public {
        vm.deal(address(reactive), 2 ether);
        sys.setDebt(address(reactive), 0.5 ether);
        uint256 before = address(sys).balance;
        vm.prank(bob);
        reactive.coverDebt();
        assertEq(address(sys).balance - before, 0.5 ether);
        assertEq(sys.debt(address(reactive)), 0);
        assertEq(address(reactive).balance, 1.5 ether);
    }

    // ---------------------------------------------------------------- topic counts (opCode = number of topics)

    function _armedRecord(uint256 id_, uint8 opCode_) internal view returns (IReactive.LogRecord memory r) {
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(exitC);
        r.topic0 = reactive.WATCH_ARMED_TOPIC();
        r.topic1 = id_;
        r.topic2 = uint256(uint160(alice));
        r.topic3 = uint256(uint160(address(vault)));
        r.opCode = opCode_;
        r.data = abi.encode(NoticeKinds.DEFAULT, uint8(0), type(uint256).max);
    }

    function test_watch_armed_with_wrong_topic_count_is_ignored() public {
        sys.forceDeliver(address(reactive), _armedRecord(90, 4));
        assertEq(_rStatus(90), reactive.ST_ARMED(), "sibling: four topics arm the watch");
        sys.forceDeliver(address(reactive), _armedRecord(91, 3));
        assertEq(_rStatus(91), reactive.ST_NONE(), "three topics: not our event");
        assertEq(reactive.unknownEvents(), 1);
        assertEq(reactive.activeWatches(), 1);
    }

    function test_watch_cancelled_with_wrong_topic_count_is_ignored() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        IReactive.LogRecord memory r;
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(exitC);
        r.topic0 = reactive.WATCH_CANCELLED_TOPIC();
        r.topic1 = id;
        r.topic2 = uint256(uint160(alice));
        r.topic3 = uint256(uint160(address(vault)));
        r.opCode = 3;
        sys.forceDeliver(address(reactive), r);
        assertEq(_rStatus(id), reactive.ST_ARMED(), "three topics: not our event");
        assertEq(reactive.unknownEvents(), 1);
        r.opCode = 4;
        sys.forceDeliver(address(reactive), r);
        assertEq(_rStatus(id), reactive.ST_CANCELLED(), "sibling: four topics cancel the watch");
    }

    function test_revoke_with_wrong_topic_count_is_ignored() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory data = _adapterCall(address(0xA1));
        _submit(alice, vault, data);
        assertEq(_rPendingCount(id), 1);
        IReactive.LogRecord memory r;
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(vault);
        r.topic0 = NoticeKinds.REVOKE_TOPIC;
        r.topic1 = uint256(uint160(alice));
        r.topic2 = NoticeKinds.selectorTopic(NoticeKinds.ADD_ADAPTER);
        r.opCode = 4;
        r.data = abi.encode(data);
        sys.forceDeliver(address(reactive), r);
        assertEq(_rPendingCount(id), 1, "four topics: not a vault Revoke");
        assertEq(reactive.unknownEvents(), 1);
        r.opCode = 3;
        sys.forceDeliver(address(reactive), r);
        assertEq(_rPendingCount(id), 0, "sibling: three topics remove the change");
    }

    /// @dev A Revoke concerns only "leave if still pending" watches; a "leave now" watch on the same vault is not
    ///      billed for it.
    function test_revoke_does_not_bill_a_leave_now_watch() public {
        uint256 idNow = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deposit(bob, vault, 10e6);
        uint256 idPending = _arm(bob, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory d = abi.encodeCall(DemoVault.increaseTimelock, (NoticeKinds.ADD_ADAPTER, 1000));
        _submit(alice, vault, d);
        _revokeChange(alice, vault, d);
        assertEq(_rReactions(idPending), 1, "sibling: the pending watch is billed");
        assertEq(_rReactions(idNow), 0);
    }
}

/// @notice Ticks count against the reaction budget: with a budget of 3 a stored change is fled on the fourth reaction.
contract NoticeReactiveBudgetTest is NoticeSetup {
    DemoVault internal vault;

    function setUp() public {
        cfgMaxReactions = 3;
        _deploy();
        vault = _vaultWithDeposit(alice, 500e6);
    }

    function test_ticks_count_toward_budget() public {
        uint256 id = _arm(alice, vault, NoticeKinds.DEFAULT, 1, type(uint256).max);
        _submit(alice, vault, _adapterCall(address(0xA1))); // 1
        _tickAndPump(); // 2
        _tickAndPump(); // 3
        assertEq(sys.callbackCount(), 0);
        _tickAndPump(); // 4 > 3
        assertEq(sys.callbackCount(), 1);
        (,,, uint8 reason) = _callbackArgs(0);
        assertEq(reason, reactive.R_BUDGET());
        assertEq(_rStatus(id), reactive.ST_EXITED());
        assertEq(token.balanceOf(alice), 500e6);
    }
}

/// @notice The cap on timer ("leave if still pending") watches on Lasna is its own cap. Deployed with room for 64 armed
///         watches in total, so the total cap (code 3) cannot answer first and these tests reach the timer cap (code 5).
contract NoticeReactiveTimedTest is NoticeSetup {
    function setUp() public {
        cfgMaxActive = 64;
        _deploy();
    }

    function _user(uint256 i_) internal view returns (address) {
        return vm.addr(6000 + i_);
    }

    /// @dev Arms a fresh user's watch over a fresh vault of their own, through the whole simulated network.
    function _armUser(uint256 i_, uint8 mode_) internal returns (uint256 id) {
        DemoVault v = _vaultWithDeposit(_user(i_), 1e6);
        id = _arm(_user(i_), v, NoticeKinds.DEFAULT, mode_, type(uint256).max);
    }

    function _fillTimed() internal returns (uint256[] memory ids) {
        uint256 n = reactive.MAX_TIMED();
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = _armUser(i, 1);
            assertEq(_rStatus(ids[i]), reactive.ST_ARMED());
        }
        assertEq(reactive.timedWatches(), n);
    }

    /// @dev Bites `else if (mode == MODE_IF_PENDING && timedWatches >= MAX_TIMED) refusal = REFUSE_TOO_MANY_TIMED;` in
    ///      _onArmed: with eight timer watches armed, a ninth is refused with code 5. Sibling: the same event for a
    ///      "leave now" watch is taken.
    function test_refuses_ninth_timed_watch() public {
        _fillTimed();
        uint8 code = reactive.REFUSE_TOO_MANY_TIMED();
        assertEq(code, 5);
        IReactive.LogRecord memory ninth = _watchArmedLog(900, address(0xF9), 1); // built before expectEmit
        vm.expectEmit(true, true, true, true, address(reactive));
        emit NoticeReactive.WatchRefused(900, code);
        sys.forceDeliver(address(reactive), ninth);
        assertEq(_rStatus(900), reactive.ST_REFUSED());
        assertEq(reactive.timedWatches(), reactive.MAX_TIMED());
        sys.forceDeliver(address(reactive), _watchArmedLog(901, address(0xFA), 0));
        assertEq(_rStatus(901), reactive.ST_ARMED(), "sibling: a leave-now watch is taken");
        assertEq(reactive.timedWatches(), reactive.MAX_TIMED(), "and does not count as a timer watch");
        assertEq(sys.reverts(), 0);
    }

    /// @dev Bites the `mode == MODE_IF_PENDING &&` part of the timer cap: a "leave now" watch is neither counted nor
    ///      refused for lack of a timer place. One leave-now watch, all eight timer places, another leave-now watch.
    function test_leave_now_not_counted_as_timed() public {
        uint256 first = _armUser(20, 0);
        assertEq(_rStatus(first), reactive.ST_ARMED());
        assertEq(reactive.timedWatches(), 0);
        _fillTimed();
        uint256 last = _armUser(21, 0);
        assertEq(_rStatus(last), reactive.ST_ARMED(), "a leave-now watch is taken while the timer places are full");
        assertEq(reactive.activeWatches(), reactive.MAX_TIMED() + 2);
        assertEq(reactive.timedWatches(), reactive.MAX_TIMED());
    }

    /// @dev Bites `if (w.mode == MODE_IF_PENDING) timedWatches -= 1;` in _close: the count goes down when a timer watch
    ///      exits (deadline tick), when its owner cancels it, and when anyone expires it after LIFETIME.
    function test_timed_count_released_on_exit_cancel_expire() public {
        DemoVault va = _vaultWithDeposit(_user(40), 1e6);
        uint256 idA = _arm(_user(40), va, NoticeKinds.DEFAULT, 1, type(uint256).max);
        uint256 idB = _armUser(41, 1);
        uint256 idC = _armUser(42, 1);
        assertEq(reactive.timedWatches(), 3);
        // exit: the change is stored, then fled by the tick that comes LEAD seconds before it can run
        bytes memory d = _adapterCall(address(0xA1));
        _submit(_user(40), va, d);
        assertEq(_rPendingCount(idA), 1);
        vm.warp(va.executableAt(d) - LEAD);
        _tickAndPump();
        assertEq(_rStatus(idA), reactive.ST_EXITED());
        assertEq(reactive.timedWatches(), 2, "released on exit");
        // cancel by the owner
        vm.prank(_user(41));
        exitC.cancel(idB);
        _pump(address(reactive));
        assertEq(_rStatus(idB), reactive.ST_CANCELLED());
        assertEq(reactive.timedWatches(), 1, "released on cancel");
        // expiry by anyone after LIFETIME
        vm.warp(block.timestamp + LIFETIME);
        vm.prank(carol);
        exitC.expire(idC);
        _pump(address(reactive));
        assertEq(_rStatus(idC), reactive.ST_CANCELLED());
        assertEq(reactive.timedWatches(), 0, "released on expiry");
        assertEq(reactive.activeWatches(), 0);
    }

    /// @dev Recovery from a timer squat: after LIFETIME anyone expires one timer watch on Base, Lasna closes it and
    ///      frees its place, and a new timer watch is taken.
    function test_timed_place_freed_by_expiry() public {
        uint256[] memory ids = _fillTimed();
        vm.warp(block.timestamp + LIFETIME);
        vm.prank(carol);
        exitC.expire(ids[0]);
        _pump(address(reactive));
        assertEq(_rStatus(ids[0]), reactive.ST_CANCELLED());
        assertEq(reactive.timedWatches(), reactive.MAX_TIMED() - 1);
        uint256 again = _armUser(30, 1);
        assertEq(_rStatus(again), reactive.ST_ARMED());
        assertEq(reactive.timedWatches(), reactive.MAX_TIMED());
    }
}
