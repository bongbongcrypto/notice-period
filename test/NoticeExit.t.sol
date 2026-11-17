// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { DemoVaultFactory } from "../src/demo/DemoVaultFactory.sol";
import { NoticeExit, IVaultRegistry } from "../src/NoticeExit.sol";
import { INoticeExit } from "../src/lib/INoticeExit.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";
import { AllowAllRegistry, ReentrantToken, RedirectingVault, OwnerWallet } from "./mocks/Hostile.sol";

/// @notice Unit and attack tests of the exit (callback) contract. Callbacks are delivered by the mock proxy with the
///         requester set to our reactive contract, exactly as the network would.
contract NoticeExitTest is NoticeSetup {
    DemoVault internal vault;
    uint256 internal constant DEPOSIT = 500e6;

    function setUp() public {
        _deploy();
        vault = _vaultWithDeposit(alice, DEPOSIT);
    }

    function _armAlice(uint8 mode_) internal returns (uint256 id) {
        _approveExit(alice, vault, type(uint256).max);
        vm.prank(alice);
        id = exitC.arm(address(vault), NoticeKinds.DEFAULT, mode_, type(uint256).max);
    }

    function _deliver(uint256 id_, bytes memory data_) internal {
        _deliverReason(id_, data_, 1);
    }

    function _deliverReason(uint256 id_, bytes memory data_, uint8 reason_) internal {
        proxy.deliverOrRevert(address(exitC), _exitPayload(id_, address(vault), data_, 0xABC, reason_), address(reactive));
    }

    function _lastOutcome() internal returns (uint8 outcome, uint256 shares, uint256 assets) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(exitC) && logs[i].topics[0] == NoticeExit.WatchEnded.selector) {
                (outcome,, shares, assets) = abi.decode(logs[i].data, (uint8, uint8, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "WatchEnded emitted");
    }

    // ---------------------------------------------------------------- arm

    function test_arm_succeeds() public {
        _approveExit(alice, vault, type(uint256).max);
        vm.expectEmit(true, true, true, true, address(exitC));
        emit NoticeExit.WatchArmed(1, alice, address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
        vm.prank(alice);
        uint256 id = exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
        assertEq(id, 1);
        NoticeExit.Watch memory w = exitC.watchOf(id);
        assertEq(w.owner, alice);
        assertEq(w.vault, address(vault));
        assertEq(w.kinds, NoticeKinds.DEFAULT);
        assertEq(w.status, exitC.STATUS_ACTIVE());
        assertEq(exitC.activeWatchOf(alice, address(vault)), 1);
        assertEq(exitC.redeemableShares(id), DEPOSIT);
    }

    function test_arm_refuses_unknown_vault() public {
        DemoVault stray = new DemoVault(address(token), alice, TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.UnknownVault.selector, address(stray)));
        vm.prank(alice);
        exitC.arm(address(stray), NoticeKinds.DEFAULT, 0, type(uint256).max);
    }

    function test_arm_refuses_no_kinds() public {
        _approveExit(alice, vault, type(uint256).max);
        vm.expectRevert(NoticeExit.NoKinds.selector);
        vm.prank(alice);
        exitC.arm(address(vault), 0, 0, type(uint256).max);
    }

    function test_arm_refuses_unknown_kinds() public {
        _approveExit(alice, vault, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.UnknownKinds.selector, uint8(16)));
        vm.prank(alice);
        exitC.arm(address(vault), 16, 0, type(uint256).max);
    }

    function test_arm_refuses_bad_mode() public {
        _approveExit(alice, vault, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.BadMode.selector, uint8(2)));
        vm.prank(alice);
        exitC.arm(address(vault), NoticeKinds.DEFAULT, 2, type(uint256).max);
    }

    function test_arm_refuses_zero_max_shares() public {
        _approveExit(alice, vault, type(uint256).max);
        vm.expectRevert(NoticeExit.ZeroMaxShares.selector);
        vm.prank(alice);
        exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, 0);
    }

    function test_arm_refuses_no_shares() public {
        _approveExit(bob, vault, type(uint256).max);
        vm.expectRevert(NoticeExit.NoShares.selector);
        vm.prank(bob);
        exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
    }

    function test_arm_refuses_no_allowance() public {
        vm.expectRevert(NoticeExit.NoAllowance.selector);
        vm.prank(alice);
        exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
    }

    function test_arm_refuses_second_active_watch() public {
        uint256 id = _armAlice(0);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.AlreadyWatching.selector, id));
        vm.prank(alice);
        exitC.arm(address(vault), NoticeKinds.ALL, 1, 1);
    }

    function test_arm_again_after_cancel() public {
        uint256 id = _armAlice(0);
        vm.prank(alice);
        exitC.cancel(id);
        vm.prank(alice);
        uint256 id2 = exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
        assertEq(id2, id + 1, "watch ids are never reused");
    }

    function test_arm_refuses_over_daily_cap_for_address() public {
        _armAlice(0); // 1
        DemoVault v2 = _vaultWithDeposit(alice, 1e6);
        _approveExit(alice, v2, 1e6);
        vm.prank(alice);
        exitC.arm(address(v2), NoticeKinds.DEFAULT, 0, 1e6); // 2
        DemoVault v3 = _vaultWithDeposit(alice, 1e6);
        _approveExit(alice, v3, 1e6);
        vm.expectRevert(NoticeExit.DailyCapForAddress.selector);
        vm.prank(alice);
        exitC.arm(address(v3), NoticeKinds.DEFAULT, 0, 1e6);
        // next UTC day it works again
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        exitC.arm(address(v3), NoticeKinds.DEFAULT, 0, 1e6);
    }

    function test_arm_refuses_over_daily_cap() public {
        for (uint256 i = 0; i < PER_DAY; i++) {
            address u = vm.addr(1000 + i);
            DemoVault v = _vaultWithDeposit(u, 1e6);
            _approveExit(u, v, 1e6);
            vm.prank(u);
            exitC.arm(address(v), NoticeKinds.DEFAULT, 0, 1e6);
        }
        _approveExit(alice, vault, type(uint256).max);
        vm.expectRevert(NoticeExit.DailyCapReached.selector);
        vm.prank(alice);
        exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
    }

    // ---------------------------------------------------------------- cancel

    function test_cancel_succeeds() public {
        uint256 id = _armAlice(0);
        vm.expectEmit(true, true, true, true, address(exitC));
        emit NoticeExit.WatchCancelled(id, alice, address(vault));
        vm.prank(alice);
        exitC.cancel(id);
        assertEq(_status(id), exitC.STATUS_CANCELLED());
        assertEq(exitC.activeWatchOf(alice, address(vault)), 0);
        assertEq(exitC.redeemableShares(id), 0);
    }

    function test_cancel_refuses_other_owner() public {
        uint256 id = _armAlice(0);
        vm.expectRevert(NoticeExit.NotWatchOwner.selector);
        vm.prank(bob);
        exitC.cancel(id);
    }

    function test_cancel_refuses_twice() public {
        uint256 id = _armAlice(0);
        vm.prank(alice);
        exitC.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotActive.selector, id));
        vm.prank(alice);
        exitC.cancel(id);
    }

    // ---------------------------------------------------------------- exit

    function test_exit_redeems_to_owner() public {
        uint256 id = _armAlice(0);
        vm.recordLogs();
        _deliver(id, _adapterCall(address(0xA1)));
        (uint8 outcome, uint256 shares, uint256 assets) = _lastOutcome();
        assertEq(outcome, exitC.OUTCOME_REDEEMED());
        assertEq(shares, DEPOSIT);
        assertEq(assets, DEPOSIT);
        assertEq(token.balanceOf(alice), DEPOSIT);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(exitC)), 0);
        assertEq(vault.balanceOf(address(exitC)), 0);
        assertEq(_status(id), exitC.STATUS_ENDED());
        assertEq(exitC.activeWatchOf(alice, address(vault)), 0);
    }

    /// @dev Sibling of test_exit_redeems_to_owner: same watch and change, but the payload names another vault.
    function test_exit_refuses_wrong_vault() public {
        uint256 id = _armAlice(0);
        DemoVault other = _vaultWithDeposit(bob, 10e6);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WrongVault.selector, id, address(other)));
        proxy.deliverOrRevert(
            address(exitC), _exitPayload(id, address(other), _adapterCall(address(0xA1)), 1, 1), address(reactive)
        );
        assertEq(_status(id), exitC.STATUS_ACTIVE(), "a refused exit changes nothing");
        assertEq(vault.balanceOf(alice), DEPOSIT);
    }

    function test_exit_refuses_direct_caller() public {
        uint256 id = _armAlice(0);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(proxy)));
        exitC.exit(address(reactive), id, address(vault), _adapterCall(address(0xA1)), 1, 1);
    }

    function test_exit_refuses_wrong_reactive_identity() public {
        uint256 id = _armAlice(0);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(reactive))
        );
        proxy.deliverOrRevert(
            address(exitC), _exitPayload(id, address(vault), _adapterCall(address(0xA1)), 1, 1), address(0xBAD)
        );
        assertEq(_status(id), exitC.STATUS_ACTIVE());
    }

    function test_exit_refuses_replay() public {
        uint256 id = _armAlice(0);
        bytes memory payload = _exitPayload(id, address(vault), _adapterCall(address(0xA1)), 1, 1);
        proxy.deliverOrRevert(address(exitC), payload, address(reactive));
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotActive.selector, id));
        proxy.deliverOrRevert(address(exitC), payload, address(reactive));
    }

    function test_exit_refuses_second_exit_of_same_watch() public {
        uint256 id = _armAlice(0);
        _deliver(id, _adapterCall(address(0xA1)));
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotActive.selector, id));
        _deliver(id, _timelockDownCall());
    }

    function test_exit_refuses_unknown_watch() public {
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotActive.selector, uint256(99)));
        _deliver(99, _adapterCall(address(0xA1)));
    }

    function test_exit_refuses_after_cancel() public {
        uint256 id = _armAlice(0);
        vm.prank(alice);
        exitC.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotActive.selector, id));
        _deliver(id, _adapterCall(address(0xA1)));
        assertEq(vault.balanceOf(alice), DEPOSIT);
    }

    function test_exit_refuses_unwatched_kind() public {
        uint256 id = _armAlice(0);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.KindNotWatched.selector, NoticeKinds.INCREASE_ABSOLUTE_CAP));
        _deliver(id, _capCall(1));
        assertEq(_status(id), exitC.STATUS_ACTIVE(), "a refused exit changes nothing");
        assertEq(vault.balanceOf(alice), DEPOSIT);
    }

    function test_exit_refuses_short_data() public {
        uint256 id = _armAlice(0);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.KindNotWatched.selector, bytes4(0)));
        _deliver(id, "");
    }

    /// @dev Mode 1: the decision "still pending" is made on Lasna, where a revoke that arrives before the tick
    ///      removes the stored change. Once the exit is asked for, Base does not ask the vault again (SPEC.md
    ///      section 6): a curator who revokes after the tick cannot keep the depositor in.
    function test_exit_if_pending_redeems_while_pending() public {
        uint256 id = _armAlice(1);
        bytes memory data = _adapterCall(address(0xA1));
        vm.prank(alice);
        vault.submit(data);
        vm.recordLogs();
        _deliverReason(id, data, 2); // Deadline
        (uint8 outcome,,) = _lastOutcome();
        assertEq(outcome, exitC.OUTCOME_REDEEMED());
        assertEq(token.balanceOf(alice), DEPOSIT);
    }

    function test_exit_after_a_late_vault_revoke_still_redeems() public {
        uint256 id = _armAlice(1);
        bytes memory data = _adapterCall(address(0xA1));
        vm.startPrank(alice);
        vault.submit(data);
        vault.revoke(data);
        vm.stopPrank();
        vm.recordLogs();
        _deliverReason(id, data, 2); // Deadline
        (uint8 outcome,,) = _lastOutcome();
        assertEq(outcome, exitC.OUTCOME_REDEEMED(), "revoked after the request: the depositor still leaves");
        assertEq(token.balanceOf(alice), DEPOSIT);
        assertEq(_status(id), exitC.STATUS_ENDED());
    }

    /// @dev A change over 256 bytes travels as its selector alone, and is accepted as such.
    function test_exit_accepts_the_selector_alone() public {
        uint256 id = _armAlice(1);
        vm.recordLogs();
        _deliverReason(id, abi.encodePacked(NoticeKinds.ADD_ADAPTER), 5); // DataTooLong, selector only
        (uint8 outcome,,) = _lastOutcome();
        assertEq(outcome, exitC.OUTCOME_REDEEMED());
        assertEq(token.balanceOf(alice), DEPOSIT);
    }

    /// @dev Even if the change already ran when the callback lands (it can only be late, never skipped), the
    ///      depositor leaves; before the re-check was retired, this case left the depositor in.
    function test_exit_after_the_change_ran_still_redeems() public {
        uint256 id = _armAlice(1);
        bytes memory data = _adapterCall(address(0xA1));
        vm.prank(alice);
        vault.submit(data);
        vm.warp(block.timestamp + TIMELOCK);
        vault.addAdapter(address(0xA1));
        vm.recordLogs();
        _deliverReason(id, data, 2); // Deadline
        (uint8 outcome,,) = _lastOutcome();
        assertEq(outcome, exitC.OUTCOME_REDEEMED());
        assertEq(token.balanceOf(alice), DEPOSIT);
    }

    function test_exit_now_mode_ignores_pending_state() public {
        uint256 id = _armAlice(0);
        vm.recordLogs();
        _deliver(id, _adapterCall(address(0xA1))); // never submitted on the vault
        (uint8 outcome,,) = _lastOutcome();
        assertEq(outcome, exitC.OUTCOME_REDEEMED());
    }

    function test_exit_allowance_larger_than_watch() public {
        _approveExit(alice, vault, type(uint256).max);
        vm.prank(alice);
        uint256 id = exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, 100e6);
        _deliver(id, _adapterCall(address(0xA1)));
        assertEq(token.balanceOf(alice), 100e6, "only the watch's shares");
        assertEq(vault.balanceOf(alice), DEPOSIT - 100e6);
        assertEq(vault.allowance(alice, address(exitC)), type(uint256).max);
        // the leftover allowance cannot be used: the watch is over
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotActive.selector, id));
        _deliver(id, _adapterCall(address(0xA2)));
        assertEq(vault.balanceOf(alice), DEPOSIT - 100e6);
    }

    function test_exit_allowance_smaller_than_watch() public {
        _approveExit(alice, vault, 50e6);
        vm.prank(alice);
        uint256 id = exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
        _deliver(id, _adapterCall(address(0xA1)));
        assertEq(token.balanceOf(alice), 50e6);
        assertEq(vault.allowance(alice, address(exitC)), 0);
    }

    function test_exit_nothing_to_redeem() public {
        uint256 id = _armAlice(0);
        vm.prank(alice);
        vault.transfer(bob, DEPOSIT);
        vm.recordLogs();
        _deliver(id, _adapterCall(address(0xA1)));
        (uint8 outcome,,) = _lastOutcome();
        assertEq(outcome, exitC.OUTCOME_NOTHING_TO_REDEEM());
        assertEq(vault.balanceOf(bob), DEPOSIT, "someone else's shares are never touched");
        assertEq(token.balanceOf(bob), 0);
    }

    function test_exit_only_touches_the_watch_owner() public {
        // bob deposits into alice's vault and arms his own watch; his exit moves only his shares, to him
        _deposit(bob, vault, 200e6);
        _approveExit(bob, vault, type(uint256).max);
        vm.prank(bob);
        uint256 idBob = exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
        _approveExit(alice, vault, type(uint256).max);
        _deliver(idBob, _adapterCall(address(0xA1)));
        assertEq(token.balanceOf(bob), 200e6);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(alice), DEPOSIT);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_exit_redeem_failure_keeps_shares() public {
        uint256 id = _armAlice(0);
        // the vault's own redeem refuses: alice's shares are worth 0 assets after a tiny balance
        vm.prank(alice);
        vault.transfer(bob, DEPOSIT - 1);
        // 1 share is worth 1 asset here, so make the vault empty of assets by burning through bob
        vm.prank(bob);
        vault.redeem(DEPOSIT - 1, bob, bob);
        // 1 share, 1 asset left: redeem works. Drain the vault's token balance to force ZeroAssets.
        vm.prank(address(vault));
        token.transfer(carol, 1);
        vm.recordLogs();
        _deliver(id, _adapterCall(address(0xA1)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory reason;
        uint8 outcome = 255;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(exitC)) continue;
            if (logs[i].topics[0] == NoticeExit.RedeemReverted.selector) reason = abi.decode(logs[i].data, (bytes));
            if (logs[i].topics[0] == NoticeExit.WatchEnded.selector) {
                (outcome,,,) = abi.decode(logs[i].data, (uint8, uint8, uint256, uint256));
            }
        }
        assertEq(outcome, exitC.OUTCOME_REDEEM_FAILED());
        assertEq(reason, abi.encodeWithSelector(DemoVault.ZeroAssets.selector));
        assertEq(vault.balanceOf(alice), 1, "shares stay with the owner");
    }

    // ---------------------------------------------------------------- hostile vault and token

    function test_attack_vault_paying_someone_else_is_refused() public {
        AllowAllRegistry anyRegistry = new AllowAllRegistry();
        NoticeExit exitH = new NoticeExit(
            IPayable(payable(address(proxy))), address(reactive), IVaultRegistry(address(anyRegistry)), 5, 50, LIFETIME
        );
        address thief = makeAddr("thief");
        RedirectingVault bad = new RedirectingVault(address(token), thief);
        bad.seed(alice, 100e6);
        vm.prank(alice);
        bad.approve(address(exitH), type(uint256).max);
        vm.prank(alice);
        uint256 id = exitH.arm(address(bad), NoticeKinds.DEFAULT, 0, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.AssetsNotReceived.selector, 100e6, 0));
        proxy.deliverOrRevert(
            address(exitH), _exitPayload(id, address(bad), _adapterCall(address(1)), 1, 1), address(reactive)
        );
        assertEq(token.balanceOf(thief), 0, "the whole callback reverted");
        assertEq(bad.balanceOf(alice), 100e6);
        (,,, uint8 st,,) = exitH.watches(id);
        assertEq(st, exitH.STATUS_ACTIVE());
    }

    // ---------------------------------------------------------------- reentrancy
    // A contract wallet owns shares in two vaults of a token that calls the wallet while paying it. During the
    // exit's redeem the wallet calls back into the exit contract as an owner. Each refusal test starts from
    // test_reentry_sibling_exit_pays_the_wallet, where the same exit succeeds with a harmless hook.

    struct Reentry {
        NoticeExit exitR;
        ReentrantToken evil;
        OwnerWallet wallet;
        DemoVault v1;
        DemoVault v2;
        uint256 id1;
    }

    function _walletDeposit(Reentry memory r_, DemoVault v_) internal {
        r_.evil.mint(address(r_.wallet), 100e6);
        r_.wallet.exec(address(r_.evil), abi.encodeCall(ReentrantToken.approve, (address(v_), 100e6)));
        r_.wallet.exec(address(v_), abi.encodeCall(DemoVault.deposit, (100e6, address(r_.wallet))));
        r_.wallet.exec(address(v_), abi.encodeCall(DemoVault.approve, (address(r_.exitR), type(uint256).max)));
    }

    function _reentrySetup() internal returns (Reentry memory r) {
        r.evil = new ReentrantToken();
        DemoVaultFactory evilFactory = new DemoVaultFactory(address(r.evil), TIMELOCK);
        r.exitR = new NoticeExit(
            IPayable(payable(address(proxy))), address(reactive), IVaultRegistry(address(evilFactory)), 5, 50, LIFETIME
        );
        r.wallet = new OwnerWallet();
        vm.startPrank(alice);
        r.v1 = DemoVault(evilFactory.create());
        r.v2 = DemoVault(evilFactory.create());
        vm.stopPrank();
        _walletDeposit(r, r.v1);
        _walletDeposit(r, r.v2);
        bytes memory ret = r.wallet.exec(
            address(r.exitR),
            abi.encodeCall(NoticeExit.arm, (address(r.v1), NoticeKinds.DEFAULT, 0, type(uint256).max))
        );
        r.id1 = abi.decode(ret, (uint256));
        // the token calls the wallet whenever it moves tokens out (the redeem pays the wallet)
        r.evil.setHook(address(r.wallet), abi.encodeCall(OwnerWallet.reenter, ()));
    }

    function _armV2(Reentry memory r_) internal returns (uint256 id2) {
        bytes memory ret = r_.wallet.exec(
            address(r_.exitR),
            abi.encodeCall(NoticeExit.arm, (address(r_.v2), NoticeKinds.DEFAULT, 0, type(uint256).max))
        );
        id2 = abi.decode(ret, (uint256));
    }

    /// @dev Delivers the exit of the wallet's first watch; returns the RedeemReverted reason (empty if none).
    function _exitV1(Reentry memory r_) internal returns (bytes memory reason, uint8 outcome) {
        vm.recordLogs();
        proxy.deliverOrRevert(
            address(r_.exitR), _exitPayload(r_.id1, address(r_.v1), _adapterCall(address(1)), 1, 1), address(reactive)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        outcome = 255;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(r_.exitR)) continue;
            if (logs[i].topics[0] == NoticeExit.RedeemReverted.selector) reason = abi.decode(logs[i].data, (bytes));
            if (logs[i].topics[0] == NoticeExit.WatchEnded.selector) {
                (outcome,,,) = abi.decode(logs[i].data, (uint8, uint8, uint256, uint256));
            }
        }
    }

    function _st(NoticeExit exitR_, uint256 id_) internal view returns (uint8 st) {
        (,,, st,,) = exitR_.watches(id_);
    }

    function test_reentry_sibling_exit_pays_the_wallet() public {
        Reentry memory r = _reentrySetup();
        uint256 id2 = _armV2(r);
        // a harmless hook: reading a view succeeds
        r.wallet.setReenter(address(r.exitR), abi.encodeCall(NoticeExit.redeemableShares, (id2)));
        (bytes memory reason, uint8 outcome) = _exitV1(r);
        assertEq(reason.length, 0);
        assertEq(outcome, r.exitR.OUTCOME_REDEEMED());
        assertEq(r.evil.balanceOf(address(r.wallet)), 100e6);
        assertEq(_st(r.exitR, id2), r.exitR.STATUS_ACTIVE());
    }

    function test_reentry_into_arm_is_blocked() public {
        Reentry memory r = _reentrySetup();
        r.wallet.setReenter(
            address(r.exitR), abi.encodeCall(NoticeExit.arm, (address(r.v2), NoticeKinds.ALL, 0, type(uint256).max))
        );
        (bytes memory reason, uint8 outcome) = _exitV1(r);
        assertEq(reason, abi.encodeWithSelector(NoticeExit.Reentrancy.selector), "the re-entry hit the guard");
        assertEq(outcome, r.exitR.OUTCOME_REDEEM_FAILED());
        assertEq(r.exitR.activeWatchOf(address(r.wallet), address(r.v2)), 0, "no watch was created");
        assertEq(r.exitR.nextWatchId(), r.id1 + 1);
        assertEq(r.v1.balanceOf(address(r.wallet)), 100e6, "redeem rolled back, shares stay");
    }

    function test_reentry_into_cancel_is_blocked() public {
        Reentry memory r = _reentrySetup();
        uint256 id2 = _armV2(r);
        r.wallet.setReenter(address(r.exitR), abi.encodeCall(NoticeExit.cancel, (id2)));
        (bytes memory reason,) = _exitV1(r);
        assertEq(reason, abi.encodeWithSelector(NoticeExit.Reentrancy.selector), "the re-entry hit the guard");
        assertEq(_st(r.exitR, id2), r.exitR.STATUS_ACTIVE(), "the other watch was not cancelled");
        assertEq(_st(r.exitR, r.id1), r.exitR.STATUS_ENDED());
    }

    function test_reentry_into_expire_is_blocked() public {
        Reentry memory r = _reentrySetup();
        uint256 id2 = _armV2(r);
        vm.warp(block.timestamp + LIFETIME);
        r.wallet.setReenter(address(r.exitR), abi.encodeCall(NoticeExit.expire, (id2)));
        (bytes memory reason,) = _exitV1(r);
        assertEq(reason, abi.encodeWithSelector(NoticeExit.Reentrancy.selector), "the re-entry hit the guard");
        assertEq(_st(r.exitR, id2), r.exitR.STATUS_ACTIVE(), "the other watch did not expire");
    }

    /// @dev Only the network's proxy can call exit(); the mock proxy can be called by anyone, which lets the test
    ///      reach exit() from inside a redeem.
    function test_reentry_into_exit_is_blocked() public {
        Reentry memory r = _reentrySetup();
        uint256 id2 = _armV2(r);
        r.wallet.setReenter(
            address(proxy),
            abi.encodeCall(
                proxy.deliverOrRevert,
                (address(r.exitR), _exitPayload(id2, address(r.v2), _adapterCall(address(1)), 2, 1), address(reactive))
            )
        );
        (bytes memory reason,) = _exitV1(r);
        assertEq(reason, abi.encodeWithSelector(NoticeExit.Reentrancy.selector), "the re-entry hit the guard");
        assertEq(_st(r.exitR, id2), r.exitR.STATUS_ACTIVE(), "the other watch did not exit");
        assertEq(r.v2.balanceOf(address(r.wallet)), 100e6);
    }

    // ---------------------------------------------------------------- expire

    function test_expire_after_lifetime() public {
        uint256 id = _armAlice(0);
        vm.warp(block.timestamp + LIFETIME);
        vm.expectEmit(true, true, true, true, address(exitC));
        emit NoticeExit.WatchExpired(id);
        vm.expectEmit(true, true, true, true, address(exitC));
        emit NoticeExit.WatchCancelled(id, alice, address(vault));
        vm.prank(carol);
        exitC.expire(id);
        assertEq(_status(id), exitC.STATUS_EXPIRED());
        assertEq(exitC.activeWatchOf(alice, address(vault)), 0);
        assertEq(vault.balanceOf(alice), DEPOSIT, "expiry moves no shares");
        vm.prank(alice);
        exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, type(uint256).max);
    }

    function test_expire_refuses_before_lifetime() public {
        uint256 id = _armAlice(0);
        uint256 at = block.timestamp + LIFETIME;
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotExpired.selector, id, at));
        vm.prank(carol);
        exitC.expire(id);
        assertEq(_status(id), exitC.STATUS_ACTIVE());
    }

    function test_expire_refuses_ended_watch() public {
        uint256 id = _armAlice(0);
        vm.prank(alice);
        exitC.cancel(id);
        vm.warp(block.timestamp + LIFETIME);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotActive.selector, id));
        exitC.expire(id);
        assertEq(_status(id), exitC.STATUS_CANCELLED());
    }

    function test_exit_refuses_expired_watch() public {
        uint256 id = _armAlice(0);
        vm.warp(block.timestamp + LIFETIME);
        exitC.expire(id);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.WatchNotActive.selector, id));
        _deliver(id, _adapterCall(address(0xA1)));
        assertEq(vault.balanceOf(alice), DEPOSIT);
    }

    // ---------------------------------------------------------------- fee reserve

    function test_cover_debt_pays_the_proxy() public {
        vm.deal(address(exitC), 1 ether);
        proxy.setDebt(address(exitC), 0.4 ether);
        uint256 before = address(proxy).balance;
        vm.prank(carol);
        exitC.coverDebt();
        assertEq(address(proxy).balance - before, 0.4 ether);
        assertEq(proxy.debt(address(exitC)), 0);
        assertEq(address(exitC).balance, 0.6 ether);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_exit_redeems_min_of_cap_balance_allowance(
        uint256 maxShares_,
        uint256 allowance_,
        uint256 moved_
    ) public {
        maxShares_ = bound(maxShares_, 1, type(uint256).max);
        allowance_ = bound(allowance_, 1, type(uint256).max);
        moved_ = bound(moved_, 0, DEPOSIT - 1);
        _approveExit(alice, vault, allowance_);
        vm.prank(alice);
        uint256 id = exitC.arm(address(vault), NoticeKinds.DEFAULT, 0, maxShares_);
        if (moved_ > 0) {
            vm.prank(alice);
            vault.transfer(bob, moved_);
        }
        uint256 balance = DEPOSIT - moved_;
        uint256 expected = maxShares_;
        if (balance < expected) expected = balance;
        if (allowance_ < expected) expected = allowance_;
        assertEq(exitC.redeemableShares(id), expected);
        _deliver(id, _adapterCall(address(0xA1)));
        assertEq(vault.balanceOf(alice), balance - expected);
        assertEq(token.balanceOf(alice), expected, "1:1 vault: assets equal shares");
        assertEq(vault.balanceOf(bob), moved_);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(exitC)), 0);
    }

    function test_exit_selector_matches_interface() public pure {
        assertEq(NoticeExit.exit.selector, INoticeExit.exit.selector);
        assertEq(NoticeExit.exit.selector, bytes4(keccak256("exit(address,uint256,address,bytes,uint256,uint8)")));
    }
}
