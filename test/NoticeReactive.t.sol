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
        assertEq(vault.balanceOf(alice), DEPOSIT, "change no longer pending: nothing moves");
        assertEq(token.balanceOf(alice), 0);
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
