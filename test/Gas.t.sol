// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice The heaviest reactions the contracts can be made to run, measured by the mock system contract with
///         subscribe and unsubscribe charged at its modelled cost (MockSystem.SUBSCRIBE_GAS). Each must fit the
///         network's 900,000 gas cap. This is a model: the real costs are measured on Lasna (SPEC.md section 12).
contract GasTest is NoticeSetup {
    function setUp() public {
        _deploy();
    }

    function _fits(string memory what_) internal view {
        console.log(what_, sys.maxReactGas());
        assertEq(sys.overGasLimit(), 0, "a reaction went over the 900,000 gas cap");
        assertEq(sys.reverts(), 0, "react() reverted");
    }

    /// @dev Arming subscribes the most filters: five selectors plus Revoke.
    function test_arming_every_kind_in_pending_mode_fits() public {
        DemoVault v = _vaultWithDeposit(alice, 1e6);
        _arm(alice, v, NoticeKinds.ALL, 1, type(uint256).max);
        assertEq(sys.activeCount(address(reactive)), 2 + 6);
        _fits("arm, every kind, mode 1: max react gas");
    }

    /// @dev Three full watches on one vault leave on one padded change: three callbacks and every filter released.
    function test_three_full_watches_leaving_on_one_padded_change_fit() public {
        DemoVault v = _vaultWithDeposit(alice, 1e6);
        _deposit(bob, v, 1e6);
        _deposit(carol, v, 1e6);
        _arm(alice, v, NoticeKinds.ALL, 1, type(uint256).max);
        _arm(bob, v, NoticeKinds.ALL, 1, type(uint256).max);
        _arm(carol, v, NoticeKinds.ALL, 0, type(uint256).max);
        _submit(alice, v, abi.encodePacked(_adapterCall(address(0xAD)), new bytes(100_000)));
        assertEq(sys.callbackCount(), 3);
        assertEq(sys.activeCount(address(reactive)), 2, "only the permanent filters remain");
        _fits("three watches leave on a 100 KB change: max react gas");
    }

    /// @dev Eight watches each storing three changes of the longest stored length, then one tick when all are due.
    function test_tick_over_eight_full_watches_fits() public {
        uint256 at;
        for (uint256 i = 0; i < MAX_ACTIVE; i++) {
            address u = vm.addr(4000 + i);
            DemoVault v = _vaultWithDeposit(u, 1e6);
            _arm(u, v, NoticeKinds.DEFAULT, 1, type(uint256).max);
            for (uint256 j = 0; j < 3; j++) {
                // addAdapter(x) padded to exactly 256 bytes, the longest change that is stored
                bytes memory d = abi.encodePacked(_adapterCall(address(uint160(0xA0 + j))), new bytes(220));
                _submit(u, v, d);
                at = v.executableAt(d);
            }
        }
        assertEq(reactive.pendingWatchIds().length, MAX_ACTIVE);
        vm.warp(at);
        _tickAndPump();
        assertGt(sys.callbackCount(), 0);
        _fits("tick over eight watches with three stored changes each: max react gas");
    }
}
