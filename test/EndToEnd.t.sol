// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice The visitor journeys of the demo, from deposit to funds back in the visitor's wallet, through the
///         simulated network (both chains in one EVM, see SPEC.md section 12 for what this does not show).
contract EndToEndTest is NoticeSetup {
    uint256 internal constant DEPOSIT = 100e6; // 100 npUSD, 6 decimals

    function setUp() public {
        _deploy();
    }

    /// @dev Journey 1, "leave now": the curator button schedules a new adapter and the deposit comes back at once.
    function test_journey_leave_now() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        assertEq(token.balanceOf(alice), 0);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, exitC.MODE_NOW(), type(uint256).max);

        uint256 originTx = _submit(alice, v, _adapterCall(address(0xAD)));

        assertEq(token.balanceOf(alice), DEPOSIT, "the whole deposit is back in the visitor's wallet");
        assertEq(v.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(exitC)), 0, "the exit contract never holds the tokens");
        assertEq(v.balanceOf(address(exitC)), 0, "the exit contract never holds the shares");
        assertEq(_status(id), exitC.STATUS_ENDED());
        (uint256 cbId,, uint256 cbOrigin, uint8 reason) = _callbackArgs(0);
        assertEq(cbId, id);
        assertEq(cbOrigin, originTx, "the callback carries the hash of the curator's transaction");
        assertEq(reason, reactive.R_SCHEDULED());
        assertTrue(proxy.lastOk());
        assertEq(sys.reverts(), 0);
        assertEq(reactive.activeWatches(), 0);
    }

    /// @dev Journey 2, "leave if still pending": nothing moves until shortly before the change can run.
    function test_journey_leave_if_still_pending() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, exitC.MODE_IF_PENDING(), type(uint256).max);
        bytes memory change = _adapterCall(address(0xAD));
        uint256 originTx = _submit(alice, v, change);
        uint256 at = v.executableAt(change);
        assertEq(at, START + TIMELOCK);
        assertEq(token.balanceOf(alice), 0, "still invested while the change is only scheduled");

        vm.warp(at - LEAD - 1);
        _tickAndPump();
        assertEq(token.balanceOf(alice), 0, "more time left than the lead");

        vm.warp(at - LEAD);
        _tickAndPump();
        assertEq(token.balanceOf(alice), DEPOSIT, "out with the lead to spare");
        assertLt(block.timestamp, at, "left before the change could run");
        (,, uint256 cbOrigin, uint8 reason) = _callbackArgs(0);
        assertEq(cbOrigin, originTx);
        assertEq(reason, reactive.R_DEADLINE());
        assertEq(_status(id), exitC.STATUS_ENDED());
        assertEq(reactive.cronFilterRefs(), 0, "no CRON subscription once nothing waits");

        vm.warp(at);
        v.addAdapter(address(0xAD));
        assertEq(v.adaptersLength(), 1, "the change ran, but the visitor was already out");
    }

    /// @dev Journey 3: the curator takes the change back; the visitor stays invested and stays protected.
    function test_journey_revoke_disarms_then_next_change_exits() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, exitC.MODE_IF_PENDING(), type(uint256).max);
        bytes memory change = _adapterCall(address(0xAD));
        _submit(alice, v, change);
        assertEq(reactive.cronFilterRefs(), 1);
        _revokeChange(alice, v, change);
        assertEq(reactive.cronFilterRefs(), 0, "revoke stops the ticks");

        for (uint256 i = 1; i <= 4; i++) {
            vm.warp(START + 60 * i);
            _tickAndPump();
        }
        assertEq(sys.callbackCount(), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(_status(id), exitC.STATUS_ACTIVE(), "still watching");

        bytes memory other = _allocatorCall(address(0xA110));
        uint256 originTx = _submit(alice, v, other);
        vm.warp(block.timestamp + TIMELOCK - LEAD);
        _tickAndPump();
        assertEq(token.balanceOf(alice), DEPOSIT);
        (,, uint256 cbOrigin,) = _callbackArgs(0);
        assertEq(cbOrigin, originTx);
    }

    /// @dev Journey 4: a change the visitor did not choose to flee leaves the deposit in place.
    function test_journey_unwatched_change_keeps_deposit() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, exitC.MODE_NOW(), type(uint256).max);
        _submit(alice, v, _capCall(1e12));
        assertEq(sys.callbackCount(), 0);
        assertEq(v.balanceOf(alice), v.previewDeposit(DEPOSIT));
        assertEq(_status(id), exitC.STATUS_ACTIVE());
    }

    /// @dev Journey 5: a second visitor's vault and watch are untouched by the first visitor's curator button.
    function test_journey_two_visitors_are_isolated() public {
        DemoVault va = _vaultWithDeposit(alice, DEPOSIT);
        DemoVault vb = _vaultWithDeposit(bob, DEPOSIT);
        uint256 ida = _arm(alice, va, NoticeKinds.DEFAULT, exitC.MODE_NOW(), type(uint256).max);
        uint256 idb = _arm(bob, vb, NoticeKinds.DEFAULT, exitC.MODE_NOW(), type(uint256).max);
        _submit(alice, va, _adapterCall(address(0xAD)));
        assertEq(token.balanceOf(alice), DEPOSIT);
        assertEq(token.balanceOf(bob), 0);
        assertEq(_status(ida), exitC.STATUS_ENDED());
        assertEq(_status(idb), exitC.STATUS_ACTIVE());
    }
}
