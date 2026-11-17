// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice Mode 1 under a realistic clock: Cron10 ticks about every 10.7 s on Lasna, and the callback needs some
///         seconds to land on Base. Every exit must be asked for early enough to land before its change can run,
///         even when every admitted watch comes due at once and the first tick comes as late as it can.
contract TimingTest is NoticeSetup {
    uint256 internal constant TICK = 11; // Cron10 period measured at 10.7 s, rounded up
    uint256 internal constant HOP = 10; // seconds kept for the callback to land on Base after the request

    function setUp() public {
        _deploy();
    }

    function _user(uint256 i_) internal view returns (address) {
        return vm.addr(3000 + i_);
    }

    function test_all_admitted_watches_due_together_exit_in_time() public {
        uint256 n = MAX_ACTIVE;
        DemoVault[] memory vs = new DemoVault[](n);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vs[i] = _vaultWithDeposit(_user(i), 1e6);
            ids[i] = _arm(_user(i), vs[i], NoticeKinds.DEFAULT, 1, type(uint256).max);
        }
        bytes memory change = _adapterCall(address(0xAD));
        for (uint256 i = 0; i < n; i++) {
            _submit(_user(i), vs[i], change);
        }
        uint256 at = vs[0].executableAt(change);
        assertEq(reactive.pendingWatchIds().length, n);
        // worst tick phase: the first tick after the changes came due arrives almost one tick late
        vm.warp(at - LEAD + TICK - 1);
        uint256 fired;
        for (uint256 k = 0; k < 2 * n && fired < n; k++) {
            uint256 before = sys.callbackCount();
            _tickAndPump();
            uint256 now_ = sys.callbackCount();
            if (now_ > before) {
                assertLe(block.timestamp + HOP, at, "exit asked for too late to land before the change can run");
                fired += now_ - before;
            }
            vm.warp(block.timestamp + TICK);
        }
        assertEq(fired, n, "every watch asked for its exit");
        for (uint256 i = 0; i < n; i++) {
            assertEq(_status(ids[i]), exitC.STATUS_ENDED());
            assertEq(token.balanceOf(_user(i)), 1e6);
        }
        assertEq(sys.overGasLimit(), 0);
    }
}
