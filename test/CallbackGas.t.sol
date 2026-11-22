// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { ReentrantToken } from "./mocks/Hostile.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { DemoVaultFactory } from "../src/demo/DemoVaultFactory.sol";
import { NoticeExit, IVaultRegistry } from "../src/NoticeExit.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice Burns a fixed amount of gas when called: stands in for the extra work of a real Vault V2's redeem path.
contract RedeemGasBurner {
    function burn(uint256 gas_) external {
        uint256 start = gasleft();
        while (start - gasleft() < gas_) { }
    }
}

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
        uint8 modeNow = exitC.MODE_NOW(); // read before the prank, which the next call uses up
        vm.prank(alice);
        uint256 id = exitC.arm(address(v), NoticeKinds.DEFAULT, modeNow, half);
        _pump(address(reactive));
        holdCallbacks = true;
        _submit(alice, v, _longestCarried());
        _deliverCold(v);
        _checkExit("exit now, half cap, finite allowance", v, id);
        assertEq(v.balanceOf(alice), half, "the other half stays");
        assertEq(v.allowance(alice, address(exitC)), 0, "the allowance is spent");
        assertGt(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- a redeem as heavy as the real-vault replay

    /// @dev Extra gas the replayed real vault's redeem needed (Gauntlet USDC Frontier at block 26,406,895, one adapter
    ///      over 16 markets: exit() used 444,838) beyond a demo-vault exit (about 105,000 above): the hook burns it.
    uint256 internal constant REPLAY_EXTRA_GAS = 340_000;
    /// @dev The 11-18 pair's limit, for the comparison.
    uint64 internal constant OLD_CB_GAS = 600_000;

    struct Heavy {
        NoticeExit exitH;
        DemoVault v;
        uint256 id;
        uint256 shares;
        ReentrantToken token;
    }

    /// @dev A demo vault on a token whose transfer calls the burner, so the redeem inside exit() costs about what the
    ///      replayed vault's did. A separate exit contract lists that token's factory; the requester is our reactive.
    function _heavySetup() internal returns (Heavy memory h) {
        h.token = new ReentrantToken();
        DemoVaultFactory heavyFactory = new DemoVaultFactory(address(h.token), TIMELOCK);
        h.exitH = new NoticeExit(
            IPayable(payable(address(proxy))),
            address(reactive),
            IVaultRegistry(address(heavyFactory)),
            4,
            50,
            LIFETIME,
            4
        );
        vm.startPrank(alice);
        h.v = DemoVault(heavyFactory.create());
        h.token.mint(alice, DEPOSIT);
        h.token.approve(address(h.v), DEPOSIT);
        h.v.deposit(DEPOSIT, alice);
        h.shares = h.v.balanceOf(alice);
        h.v.approve(address(h.exitH), type(uint256).max);
        h.id = h.exitH.arm(address(h.v), NoticeKinds.DEFAULT, 0, type(uint256).max);
        vm.stopPrank();
        RedeemGasBurner burner = new RedeemGasBurner();
        h.token.setHook(address(burner), abi.encodeCall(RedeemGasBurner.burn, (REPLAY_EXTRA_GAS)));
    }

    /// @dev Delivers the exit of the heavy watch with `gas_` as the callback limit; true when WatchEnded says redeemed.
    function _heavyExit(Heavy memory h_, uint64 gas_) internal returns (bool redeemed) {
        vm.cool(address(h_.exitH));
        vm.cool(address(h_.v));
        vm.cool(address(h_.token));
        vm.recordLogs();
        bytes memory payload = _exitPayload(h_.id, address(h_.v), _adapterCall(address(0xAD)), 1, 1);
        proxy.deliverWithGas(address(h_.exitH), payload, address(reactive), gas_);
        console.log("heavy redeem, callback limit", uint256(gas_));
        console.log("  forwarded", proxy.lastForwarded(), "used", proxy.lastUsed());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(h_.exitH) || logs[i].topics[0] != NoticeExit.WatchEnded.selector) continue;
            (uint8 outcome,,,) = abi.decode(logs[i].data, (uint8, uint8, uint256, uint256));
            redeemed = proxy.lastOk() && outcome == h_.exitH.OUTCOME_REDEEMED();
        }
    }

    /// @dev At the deployed limit the heavy redeem goes through and pays the owner.
    function test_heavy_redeem_like_the_replayed_vault_fits_the_deployed_limit() public {
        Heavy memory h = _heavySetup();
        assertTrue(_heavyExit(h, CB_GAS), "redeemed at the deployed callback gas limit");
        assertGt(proxy.lastForwarded(), proxy.lastUsed(), "with gas to spare");
        assertEq(h.v.balanceOf(alice), 0);
        assertEq(h.token.balanceOf(alice), DEPOSIT, "the deposit is back");
    }

    /// @dev The same redeem at the 11-18 pair's 600,000 is not redeemed: the shares stay, as in the replay.
    function test_heavy_redeem_like_the_replayed_vault_fails_at_600000() public {
        Heavy memory h = _heavySetup();
        assertFalse(_heavyExit(h, OLD_CB_GAS), "not redeemed at 600,000");
        assertEq(h.v.balanceOf(alice), h.shares, "the shares stay with the owner");
        assertEq(h.token.balanceOf(alice), 0);
    }
}
