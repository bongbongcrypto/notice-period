// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice The exit callback at the deployed gas limit (CB_GAS, the value deploy-system.sh passes), once the real
///         proxy keeps its share (MockCallbackProxy, measured against the Base Sepolia proxy). The exit runs with
///         the exit contract, the vault and the token cold, as in its own transaction on chain, and must have at
///         least twice the gas it uses.
contract CallbackGasTest is NoticeSetup {
    uint256 internal constant DEPOSIT = 100e6;

    function setUp() public {
        _deploy();
    }

    /// @dev addAdapter(x) padded to exactly MAX_DATA_LENGTH bytes: the longest change carried whole (484-byte payload).
    function _longestCarried() internal pure returns (bytes memory) {
        return abi.encodePacked(_adapterCall(address(0xAD)), new bytes(256 - 36));
    }

    function _deliverCold(DemoVault v_) internal {
        vm.cool(address(exitC));
        vm.cool(address(v_));
        vm.cool(address(token));
        _deliverCallbacks();
    }

    function _checkExit(string memory what_, DemoVault v_, uint256 id_) internal view {
        console.log(what_);
        console.log("  payload bytes", sys.callbackAt(0).payload.length);
        console.log("  forwarded", proxy.lastForwarded(), "used", proxy.lastUsed());
        assertEq(sys.callbackAt(0).gasLimit, CB_GAS);
        assertTrue(proxy.lastOk(), "the exit ran within the gas the proxy forwarded");
        assertEq(_status(id_), exitC.STATUS_ENDED());
        assertGt(proxy.lastUsed(), 0);
        // The deposit and the arm wrote slots the exit writes again; in its own transaction those writes cost more,
        // which the cushion covers (MockCallbackProxy.DIRTY_SLOT_CUSHION).
        assertGe(
            proxy.lastForwarded(),
            2 * (proxy.lastUsed() + proxy.DIRTY_SLOT_CUSHION()),
            "at least twice what the exit uses"
        );
    }

    function _checkAllBack(DemoVault v_) internal view {
        assertEq(token.balanceOf(alice), DEPOSIT, "the deposit is back");
        assertEq(v_.balanceOf(alice), 0);
    }

    function test_exit_now_with_longest_carried_change_fits() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, exitC.MODE_NOW(), type(uint256).max);
        holdCallbacks = true;
        _submit(alice, v, _longestCarried());
        assertEq(sys.callbackCount(), 1);
        _deliverCold(v);
        _checkExit("exit now, 256-byte change", v, id);
        _checkAllBack(v);
    }

    function test_exit_now_with_padded_change_fits() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, exitC.MODE_NOW(), type(uint256).max);
        holdCallbacks = true;
        _submit(alice, v, abi.encodePacked(_adapterCall(address(0xAD)), new bytes(4000)));
        _deliverCold(v);
        _checkExit("exit now, padded change sent as its selector", v, id);
        _checkAllBack(v);
    }

    function test_exit_if_pending_at_deadline_fits() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        uint256 id = _arm(alice, v, NoticeKinds.ALL, exitC.MODE_IF_PENDING(), type(uint256).max);
        bytes memory change = _longestCarried();
        _submit(alice, v, change);
        holdCallbacks = true;
        vm.warp(v.executableAt(change) - LEAD);
        _tickAndPump();
        assertEq(sys.callbackCount(), 1);
        _deliverCold(v);
        _checkExit("exit if pending, at the deadline", v, id);
        _checkAllBack(v);
    }

    /// @dev A partial maxShares and a second depositor in the same vault: the redeem path with every read live.
    function test_exit_with_partial_cap_and_other_depositor_fits() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        _deposit(bob, v, DEPOSIT);
        uint256 shares = v.balanceOf(alice);
        uint256 id = _arm(alice, v, NoticeKinds.DEFAULT, exitC.MODE_NOW(), shares);
        holdCallbacks = true;
        _submit(alice, v, _longestCarried());
        _deliverCold(v);
        _checkExit("exit now, maxShares = balance, second depositor", v, id);
        _checkAllBack(v);
        assertEq(v.balanceOf(bob), shares, "the other depositor stays");
    }

    /// @dev Half the shares under the cap and a finite allowance of exactly that: the redeem spends the allowance.
    function test_exit_with_half_cap_and_finite_allowance_fits() public {
        DemoVault v = _vaultWithDeposit(alice, DEPOSIT);
        uint256 half = v.balanceOf(alice) / 2;
        _approveExit(alice, v, half);
        vm.prank(alice);
        uint256 id = exitC.arm(address(v), NoticeKinds.DEFAULT, exitC.MODE_NOW(), half);
        _pump(address(reactive));
        holdCallbacks = true;
        _submit(alice, v, _longestCarried());
        _deliverCold(v);
        _checkExit("exit now, half cap, finite allowance", v, id);
        assertEq(v.balanceOf(alice), half, "the other half stays");
        assertEq(v.allowance(alice, address(exitC)), 0, "the allowance is spent");
        assertGt(token.balanceOf(alice), 0);
    }
}
