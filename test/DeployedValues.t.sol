// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { NoticeExit } from "../src/NoticeExit.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice Mode 1 with every value scripts/deploy-system.sh deploys, together: a 180 s waiting period, LEAD 120,
///         MAX_WAIT 200, 16 reactions per watch, 1,000 armed watches, 4 arms per address and 50 a day, 4 timer arms a
///         day. The other test files use smaller caps and MAX_WAIT 900 so each cap is reached in a few calls.
contract DeployedValuesTest is NoticeSetup {
    uint256 internal constant TICK = 11; // Cron10 period measured at 10.7 s, rounded up
    uint256 internal constant HOP = 10; // seconds kept for the callback to land on Base after the request

    function setUp() public {
        cfgMaxWait = 200;
        cfgMaxReactions = 16;
        cfgMaxActive = 1000;
        cfgPerAddress = 4;
        cfgPerDay = 50;
        cfgTimedPerDay = 4;
        _deploy();
    }

    /// @dev A 180 s change seen at once is stored (120 < 180 <= 200), and the tick LEAD seconds before it can run asks
    ///      for the exit (reason Deadline) early enough to land, within the 16-reaction budget.
    function test_timer_watch_leaves_on_a_180s_change_at_the_deadline() public {
        DemoVault v = _vaultWithDeposit(alice, 100e6);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, 1, type(uint256).max);
        assertEq(_rStatus(id), reactive.ST_ARMED());
        uint256 callbacks = sys.callbackCount();
        bytes memory change = _adapterCall(address(0xAD));
        _submit(alice, v, change);
        uint256 at = v.executableAt(change);
        assertEq(at, block.timestamp + TIMELOCK);
        assertEq(_rPendingCount(id), 1, "stored, not fled at once");
        assertEq(sys.callbackCount(), callbacks);
        while (sys.callbackCount() == callbacks && block.timestamp + TICK < at) {
            vm.warp(block.timestamp + TICK);
            _tickAndPump();
        }
        assertEq(sys.callbackCount(), callbacks + 1, "one exit asked for");
        (uint256 cid,,, uint8 reason) = _callbackArgs(callbacks);
        assertEq(cid, id);
        assertEq(reason, reactive.R_DEADLINE());
        assertLe(block.timestamp + HOP, at, "asked for early enough to land before the change can run");
        assertLe(uint256(_rReactions(id)), 16, "within the reaction budget");
        assertEq(_status(id), exitC.STATUS_ENDED());
        assertEq(token.balanceOf(alice), 100e6, "the deposit is back");
    }

    /// @dev The same change reaching Lasna 61 s late is due within LEAD when seen, so it is fled at once (TooSoon):
    ///      mode 1 then acts as mode 0. Seen 59 s late it is still stored.
    function test_late_delivery_turns_a_180s_change_into_leave_now() public {
        DemoVault va = _vaultWithDeposit(alice, 100e6);
        uint256 ida = _arm(alice, va, NoticeKinds.DEFAULT, 1, type(uint256).max);
        bytes memory change = _adapterCall(address(0xAD));
        vm.prank(alice);
        va.submit(change);
        vm.warp(block.timestamp + 59);
        _pump(address(reactive));
        assertEq(_rPendingCount(ida), 1, "59 s late: stored");

        DemoVault vb = _vaultWithDeposit(bob, 100e6);
        uint256 idb = _arm(bob, vb, NoticeKinds.DEFAULT, 1, type(uint256).max);
        uint256 callbacks = sys.callbackCount();
        vm.prank(bob);
        vb.submit(change);
        vm.warp(block.timestamp + 61);
        _pump(address(reactive));
        assertEq(sys.callbackCount(), callbacks + 1, "61 s late: fled at once");
        (uint256 cid,,, uint8 reason) = _callbackArgs(callbacks);
        assertEq(cid, idb);
        assertEq(reason, reactive.R_TOO_SOON());
        assertEq(_status(idb), exitC.STATUS_ENDED());
    }

    /// @dev Revoked 15 s after it was scheduled, the change is dropped, no exit is asked for up to and past the time it
    ///      could have run, the CRON subscription is gone, and the deposit stays in.
    function test_revoked_change_keeps_the_deposit_in() public {
        DemoVault v = _vaultWithDeposit(alice, 100e6);
        uint256 shares = v.balanceOf(alice);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, 1, type(uint256).max);
        uint256 callbacks = sys.callbackCount();
        bytes memory change = _adapterCall(address(0xAD));
        _submit(alice, v, change);
        uint256 at = v.executableAt(change);
        vm.warp(block.timestamp + 15);
        _revokeChange(alice, v, change);
        assertEq(_rPendingCount(id), 0, "the revoke dropped the stored change");
        assertEq(reactive.cronFilterRefs(), 0, "no timer while nothing is stored");
        while (block.timestamp <= at + TICK) {
            vm.warp(block.timestamp + TICK);
            _tickAndPump();
        }
        assertEq(sys.callbackCount(), callbacks, "no exit");
        assertEq(_rStatus(id), reactive.ST_ARMED(), "the watch is still on");
        assertEq(_status(id), exitC.STATUS_ACTIVE());
        assertEq(v.balanceOf(alice), shares, "the deposit stays in");
        assertLe(uint256(_rReactions(id)), 16);
    }

    /// @dev The deployed daily caps: four timer arms a day for everyone together, the fifth refused; a "leave now" arm
    ///      the same day is still taken.
    function test_four_timer_arms_a_day() public {
        for (uint256 i = 0; i < 4; i++) {
            DemoVault v = _vaultWithDeposit(vm.addr(7000 + i), 1e6);
            _arm(vm.addr(7000 + i), v, NoticeKinds.DEFAULT, 1, type(uint256).max);
        }
        address late = vm.addr(7010);
        DemoVault vl = _vaultWithDeposit(late, 1e6);
        _approveExit(late, vl, type(uint256).max);
        vm.expectRevert(NoticeExit.DailyCapForTimed.selector);
        vm.prank(late);
        exitC.arm(address(vl), NoticeKinds.DEFAULT, 1, type(uint256).max);
        vm.prank(late);
        exitC.arm(address(vl), NoticeKinds.DEFAULT, 0, type(uint256).max);
        assertEq(reactive.timedWatches(), 4);
    }
}
