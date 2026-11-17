// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice A curator controls the length of a scheduled call: the ABI decoder ignores bytes after the arguments, so
///         `addAdapter(x)` followed by padding still runs once its timelock is over. Padding must not switch the exit
///         off by pushing a reaction over the network's 900,000 gas cap or a callback over its gas limit.
contract PaddingTest is NoticeSetup {
    DemoVault internal vault;
    uint256 internal idAlice;
    uint256 internal idBob;
    uint256 internal idCarol;

    function setUp() public {
        _deploy();
        vault = _vaultWithDeposit(alice, 300e6);
        _deposit(bob, vault, 100e6);
        _deposit(carol, vault, 100e6);
        idAlice = _arm(alice, vault, NoticeKinds.DEFAULT, 0, type(uint256).max); // leave now
        idBob = _arm(bob, vault, NoticeKinds.DEFAULT, 1, type(uint256).max); // leave if still pending
        idCarol = _arm(carol, vault, NoticeKinds.ALL, 0, type(uint256).max); // leave now, all kinds
    }

    function _padded(uint256 extra_) internal pure returns (bytes memory) {
        return abi.encodePacked(_adapterCall(address(0xAD)), new bytes(extra_));
    }

    function _assertAllThreeLeft(uint256 extra_) internal {
        _submit(alice, vault, _padded(extra_));
        console.log("padding bytes", extra_, "max react gas", sys.maxReactGas());
        assertEq(sys.reverts(), 0, "react() did not revert");
        assertEq(sys.overGasLimit(), 0, "every reaction fits the 900,000 gas cap");
        assertEq(sys.callbackCount(), 3);
        assertEq(proxy.failed(), 0, "every callback ran within its gas limit");
        for (uint256 i = 0; i < 3; i++) {
            (, bytes memory data,,) = _callbackArgs(i);
            assertEq(data, abi.encodePacked(NoticeKinds.ADD_ADAPTER), "a long change travels as its selector");
        }
        assertEq(_status(idAlice), exitC.STATUS_ENDED());
        assertEq(_status(idBob), exitC.STATUS_ENDED());
        assertEq(_status(idCarol), exitC.STATUS_ENDED());
        assertEq(token.balanceOf(alice), 300e6);
        assertEq(token.balanceOf(bob), 100e6, "mode 1 left at once (DataTooLong), no re-check on Base");
        assertEq(token.balanceOf(carol), 100e6);
    }

    function test_padded_change_still_runs_on_the_vault() public {
        bytes memory data = _padded(4096);
        vm.prank(alice);
        vault.submit(data);
        vm.warp(block.timestamp + TIMELOCK);
        (bool ok,) = address(vault).call(data);
        assertTrue(ok, "the padded call runs: the padding is not a harmless curiosity");
        assertTrue(vault.isAdapter(address(0xAD)));
    }

    function test_padding_4kb_does_not_stop_the_exit() public {
        _assertAllThreeLeft(4096);
    }

    function test_padding_32kb_does_not_stop_the_exit() public {
        _assertAllThreeLeft(32_768);
    }

    function test_padding_100kb_does_not_stop_the_exit() public {
        _assertAllThreeLeft(100_000);
    }

    function test_unpadded_change_is_carried_whole() public {
        bytes memory data = _adapterCall(address(0xAD));
        _submit(alice, vault, data);
        (, bytes memory carried,,) = _callbackArgs(0);
        assertEq(carried, data);
        assertEq(sys.overGasLimit(), 0);
    }

    /// @dev A padded Revoke reaches bob's mode-1 watch (Revoke is watched per vault, whatever the kind) and must
    ///      neither revert nor disturb the change bob has stored.
    function test_padded_revoke_is_harmless() public {
        // keep only bob's watch: alice and carol would leave on the adapter change below
        vm.prank(alice);
        exitC.cancel(idAlice);
        vm.prank(carol);
        exitC.cancel(idCarol);
        _pump(address(reactive));
        _submit(alice, vault, _adapterCall(address(0xA1)));
        assertEq(_rPendingCount(idBob), 1);
        // a cap change is not a kind bob watches, so only its Revoke reaches the reactive contract
        bytes memory big = abi.encodePacked(_capCall(1e12), new bytes(50_000));
        vm.startPrank(alice);
        vault.submit(big);
        vault.revoke(big);
        vm.stopPrank();
        _pump(address(reactive));
        assertEq(sys.reverts(), 0);
        assertEq(sys.overGasLimit(), 0);
        assertEq(_rPendingCount(idBob), 1, "the stored adapter change is still there");
        assertEq(_status(idBob), exitC.STATUS_ACTIVE());
        assertEq(sys.callbackCount(), 0);
    }
}
