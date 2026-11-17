// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { DemoToken } from "../src/demo/DemoToken.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { DemoVaultFactory } from "../src/demo/DemoVaultFactory.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";
import { FalseToken } from "./mocks/Hostile.sol";

contract DemoVaultTest is Test {
    DemoToken internal token;
    DemoVaultFactory internal factory;
    DemoVault internal vault;
    address internal curator = makeAddr("curator");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");
    address internal adapter = makeAddr("adapter");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new DemoToken();
        factory = new DemoVaultFactory(address(token), 180);
        vm.prank(curator);
        vault = DemoVault(factory.create());
        token.mint(user, 1_000e6);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    // ---------------- shapes and constants ----------------

    function test_event_topics_match_morpho_v2() public pure {
        assertEq(DemoVault.Submit.selector, keccak256("Submit(bytes4,bytes,uint256)"));
        assertEq(DemoVault.Revoke.selector, keccak256("Revoke(address,bytes4,bytes)"));
        assertEq(DemoVault.Accept.selector, keccak256("Accept(bytes4,bytes)"));
        // Values read from Morpho's EventsLib and day-1 checks
        assertEq(uint256(DemoVault.Submit.selector), NoticeKinds.SUBMIT_TOPIC);
        assertEq(uint256(DemoVault.Revoke.selector), NoticeKinds.REVOKE_TOPIC);
        assertEq(uint256(DemoVault.Accept.selector), NoticeKinds.ACCEPT_TOPIC);
        assertEq(NoticeKinds.SUBMIT_TOPIC, 0x8b18afeb361b83b025999ed5b42f1d90c68aaa5a0fd49c015f04c3b8b81e80eb);
    }

    function test_selectors_match_morpho_v2() public pure {
        assertEq(DemoVault.addAdapter.selector, NoticeKinds.ADD_ADAPTER);
        assertEq(DemoVault.decreaseTimelock.selector, NoticeKinds.DECREASE_TIMELOCK);
        assertEq(DemoVault.increaseTimelock.selector, NoticeKinds.INCREASE_TIMELOCK);
        assertEq(DemoVault.setIsAllocator.selector, NoticeKinds.SET_IS_ALLOCATOR);
        assertEq(DemoVault.increaseAbsoluteCap.selector, NoticeKinds.INCREASE_ABSOLUTE_CAP);
        assertEq(DemoVault.increaseRelativeCap.selector, NoticeKinds.INCREASE_RELATIVE_CAP);
        assertEq(NoticeKinds.ADD_ADAPTER, bytes4(keccak256("addAdapter(address)")));
        assertEq(NoticeKinds.DECREASE_TIMELOCK, bytes4(keccak256("decreaseTimelock(bytes4,uint256)")));
        assertEq(NoticeKinds.SET_IS_ALLOCATOR, bytes4(keccak256("setIsAllocator(address,bool)")));
        assertEq(NoticeKinds.INCREASE_ABSOLUTE_CAP, bytes4(keccak256("increaseAbsoluteCap(bytes,uint256)")));
        assertEq(NoticeKinds.INCREASE_RELATIVE_CAP, bytes4(keccak256("increaseRelativeCap(bytes,uint256)")));
    }

    function test_kinds_map_selectors() public pure {
        assertEq(NoticeKinds.kindOf(NoticeKinds.ADD_ADAPTER), NoticeKinds.ADAPTER);
        assertEq(NoticeKinds.kindOf(NoticeKinds.DECREASE_TIMELOCK), NoticeKinds.TIMELOCK_DOWN);
        assertEq(NoticeKinds.kindOf(NoticeKinds.SET_IS_ALLOCATOR), NoticeKinds.ALLOCATOR);
        assertEq(NoticeKinds.kindOf(NoticeKinds.INCREASE_ABSOLUTE_CAP), NoticeKinds.CAP_UP);
        assertEq(NoticeKinds.kindOf(NoticeKinds.INCREASE_RELATIVE_CAP), NoticeKinds.CAP_UP);
        assertEq(NoticeKinds.kindOf(NoticeKinds.INCREASE_TIMELOCK), 0);
        assertEq(NoticeKinds.selectorsOf(NoticeKinds.DEFAULT).length, 3);
        assertEq(NoticeKinds.selectorsOf(NoticeKinds.ALL).length, 5);
        assertEq(NoticeKinds.DEFAULT & NoticeKinds.CAP_UP, 0, "cap increase is opt-in");
        assertEq(NoticeKinds.selectorTopic(NoticeKinds.ADD_ADAPTER), uint256(bytes32(bytes4(0x60d54d41))));
    }

    function test_submit_log_shape() public {
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.recordLogs();
        vm.prank(curator);
        vault.submit(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(vault));
        assertEq(logs[0].topics.length, 2);
        assertEq(uint256(logs[0].topics[0]), NoticeKinds.SUBMIT_TOPIC);
        assertEq(logs[0].topics[1], bytes32(NoticeKinds.ADD_ADAPTER), "selector is left-aligned in topic1");
        (bytes memory gotData, uint256 at) = abi.decode(logs[0].data, (bytes, uint256));
        assertEq(gotData, data);
        assertEq(at, block.timestamp + 180);
        assertEq(vault.executableAt(data), block.timestamp + 180);
    }

    function test_revoke_log_shape() public {
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.prank(curator);
        vault.submit(data);
        vm.recordLogs();
        vm.prank(curator);
        vault.revoke(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 3);
        assertEq(uint256(logs[0].topics[0]), NoticeKinds.REVOKE_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(curator))));
        assertEq(logs[0].topics[2], bytes32(NoticeKinds.ADD_ADAPTER), "selector is topic2 in Revoke");
        assertEq(abi.decode(logs[0].data, (bytes)), data);
        assertEq(vault.executableAt(data), 0);
    }

    function test_accept_log_shape_and_effect() public {
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.prank(curator);
        vault.submit(data);
        vm.warp(block.timestamp + 180);
        vm.recordLogs();
        vault.addAdapter(adapter);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint256(logs[0].topics[0]), NoticeKinds.ACCEPT_TOPIC);
        assertEq(logs[0].topics[1], bytes32(NoticeKinds.ADD_ADAPTER));
        assertEq(abi.decode(logs[0].data, (bytes)), data);
        assertTrue(vault.isAdapter(adapter));
        assertEq(vault.adaptersLength(), 1);
        assertEq(vault.executableAt(data), 0);
    }

    // ---------------- timelock refusals (each from the succeeding case above) ----------------

    function test_submit_refuses_non_curator() public {
        vm.expectRevert(DemoVault.Unauthorized.selector);
        vm.prank(other);
        vault.submit(abi.encodeCall(DemoVault.addAdapter, (adapter)));
    }

    function test_submit_refuses_same_data_twice() public {
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.startPrank(curator);
        vault.submit(data);
        vm.expectRevert(DemoVault.DataAlreadyPending.selector);
        vault.submit(data);
        vm.stopPrank();
    }

    function test_run_refuses_early() public {
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.prank(curator);
        vault.submit(data);
        vm.warp(block.timestamp + 179);
        vm.expectRevert(DemoVault.TimelockNotExpired.selector);
        vault.addAdapter(adapter);
    }

    function test_run_refuses_unsubmitted() public {
        vm.expectRevert(DemoVault.DataNotTimelocked.selector);
        vault.addAdapter(adapter);
    }

    function test_run_refuses_twice() public {
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.prank(curator);
        vault.submit(data);
        vm.warp(block.timestamp + 180);
        vault.addAdapter(adapter);
        vm.expectRevert(DemoVault.DataNotTimelocked.selector);
        vault.addAdapter(adapter);
    }

    function test_revoked_change_cannot_run() public {
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.startPrank(curator);
        vault.submit(data);
        vault.revoke(data);
        vm.stopPrank();
        vm.warp(block.timestamp + 180);
        vm.expectRevert(DemoVault.DataNotTimelocked.selector);
        vault.addAdapter(adapter);
    }

    function test_revoke_refuses_non_curator() public {
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.prank(curator);
        vault.submit(data);
        vm.expectRevert(DemoVault.Unauthorized.selector);
        vm.prank(other);
        vault.revoke(data);
    }

    function test_revoke_refuses_not_pending() public {
        vm.expectRevert(DemoVault.DataNotTimelocked.selector);
        vm.prank(curator);
        vault.revoke(abi.encodeCall(DemoVault.addAdapter, (adapter)));
    }

    function test_curator_of_one_vault_cannot_act_on_another() public {
        vm.prank(other);
        DemoVault otherVault = DemoVault(factory.create());
        bytes memory data = abi.encodeCall(DemoVault.addAdapter, (adapter));
        vm.prank(other);
        otherVault.submit(data); // succeeds on its own vault
        vm.expectRevert(DemoVault.Unauthorized.selector);
        vm.prank(other);
        vault.submit(data);
    }

    function test_decrease_timelock_waits_for_target_timelock() public {
        bytes memory data = abi.encodeCall(DemoVault.decreaseTimelock, (NoticeKinds.ADD_ADAPTER, 0));
        vm.prank(curator);
        vault.submit(data);
        assertEq(vault.executableAt(data), block.timestamp + 180);
        vm.warp(block.timestamp + 180);
        vault.decreaseTimelock(NoticeKinds.ADD_ADAPTER, 0);
        assertEq(vault.timelock(NoticeKinds.ADD_ADAPTER), 0);
    }

    function test_decrease_timelock_refuses_increase() public {
        bytes memory data = abi.encodeCall(DemoVault.decreaseTimelock, (NoticeKinds.ADD_ADAPTER, 181));
        vm.prank(curator);
        vault.submit(data);
        vm.warp(block.timestamp + 180);
        vm.expectRevert(DemoVault.TimelockNotDecreasing.selector);
        vault.decreaseTimelock(NoticeKinds.ADD_ADAPTER, 181);
    }

    function test_decrease_timelock_refuses_its_own_selector() public {
        bytes memory data = abi.encodeCall(DemoVault.decreaseTimelock, (NoticeKinds.DECREASE_TIMELOCK, 0));
        vm.prank(curator);
        vault.submit(data);
        vm.expectRevert(DemoVault.AutomaticallyTimelocked.selector);
        vault.decreaseTimelock(NoticeKinds.DECREASE_TIMELOCK, 0);
    }

    function test_increase_timelock_and_refusal() public {
        bytes memory up = abi.encodeCall(DemoVault.increaseTimelock, (NoticeKinds.ADD_ADAPTER, 600));
        bytes memory down = abi.encodeCall(DemoVault.increaseTimelock, (NoticeKinds.ADD_ADAPTER, 10));
        vm.startPrank(curator);
        vault.submit(up);
        vault.submit(down);
        vm.stopPrank();
        vm.warp(block.timestamp + 180);
        vault.increaseTimelock(NoticeKinds.ADD_ADAPTER, 600);
        assertEq(vault.timelock(NoticeKinds.ADD_ADAPTER), 600);
        vm.expectRevert(DemoVault.TimelockNotIncreasing.selector);
        vault.increaseTimelock(NoticeKinds.ADD_ADAPTER, 10);
    }

    function test_caps_and_refusals() public {
        bytes memory idData = abi.encode("market");
        bytes memory up = abi.encodeCall(DemoVault.increaseAbsoluteCap, (idData, 100e6));
        bytes memory down = abi.encodeCall(DemoVault.increaseAbsoluteCap, (idData, 50e6));
        bytes memory relTooHigh = abi.encodeCall(DemoVault.increaseRelativeCap, (idData, 1e18 + 1));
        bytes memory rel = abi.encodeCall(DemoVault.increaseRelativeCap, (idData, 5e17));
        vm.startPrank(curator);
        vault.submit(up);
        vault.submit(down);
        vault.submit(relTooHigh);
        vault.submit(rel);
        vm.stopPrank();
        vm.warp(block.timestamp + 180);
        vault.increaseAbsoluteCap(idData, 100e6);
        assertEq(vault.absoluteCap(keccak256(idData)), 100e6);
        vm.expectRevert(DemoVault.AbsoluteCapNotIncreasing.selector);
        vault.increaseAbsoluteCap(idData, 50e6);
        vm.expectRevert(DemoVault.RelativeCapAboveOne.selector);
        vault.increaseRelativeCap(idData, 1e18 + 1);
        vault.increaseRelativeCap(idData, 5e17);
        assertEq(vault.relativeCap(keccak256(idData)), 5e17);
    }

    function test_allocator_role_change() public {
        bytes memory data = abi.encodeCall(DemoVault.setIsAllocator, (other, true));
        vm.prank(curator);
        vault.submit(data);
        vm.warp(block.timestamp + 180);
        vault.setIsAllocator(other, true);
        assertTrue(vault.isAllocator(other));
    }

    // ---------------- factory ----------------

    function test_factory_lists_vault_and_sets_curator() public view {
        assertTrue(factory.isVault(address(vault)));
        assertEq(vault.curator(), curator);
        assertEq(factory.lastVaultOf(curator), address(vault));
        assertEq(vault.asset(), address(token));
        assertEq(vault.decimals(), 6);
        assertEq(vault.timelock(NoticeKinds.ADD_ADAPTER), 180);
        assertFalse(factory.isVault(address(token)));
    }

    // ---------------- ERC-4626 ----------------

    function test_deposit_redeem_roundtrip() public {
        vm.prank(user);
        uint256 shares = vault.deposit(500e6, user);
        assertEq(shares, 500e6);
        vm.prank(user);
        uint256 assets = vault.redeem(shares, user, user);
        assertEq(assets, 500e6);
        assertEq(token.balanceOf(user), 1_000e6);
        assertEq(vault.totalSupply(), 0);
    }

    function test_deposit_refuses_zero_shares() public {
        vm.expectRevert(DemoVault.ZeroShares.selector);
        vm.prank(user);
        vault.deposit(0, user);
    }

    function test_redeem_refuses_zero_assets() public {
        vm.prank(user);
        vault.deposit(500e6, user);
        vm.expectRevert(DemoVault.ZeroAssets.selector);
        vm.prank(user);
        vault.redeem(0, user, user);
    }

    function test_redeem_for_owner_needs_allowance() public {
        vm.prank(user);
        vault.deposit(500e6, user);
        vm.expectRevert(DemoVault.InsufficientAllowance.selector);
        vm.prank(other);
        vault.redeem(100e6, user, user);
        vm.prank(user);
        vault.approve(other, 100e6);
        vm.prank(other);
        vault.redeem(100e6, user, user);
        assertEq(token.balanceOf(user), 600e6);
        assertEq(vault.allowance(user, other), 0);
    }

    function test_redeem_refuses_more_than_balance() public {
        // another depositor first, so the vault holds more tokens than the user's shares are worth: the refusal must
        // come from the vault's share balance check, not from the token running out
        token.mint(other, 100e6);
        vm.startPrank(other);
        token.approve(address(vault), 100e6);
        vault.deposit(100e6, other);
        vm.stopPrank();
        vm.startPrank(user);
        vault.deposit(500e6, user);
        vault.redeem(1e6, user, user);
        vm.expectRevert(DemoVault.InsufficientBalance.selector);
        vault.redeem(499e6 + 1, user, user);
        vm.stopPrank();
    }

    function test_increase_timelock_refuses_decrease_selector() public {
        bytes memory ok = abi.encodeCall(DemoVault.increaseTimelock, (NoticeKinds.ADD_ADAPTER, 600));
        bytes memory bad = abi.encodeCall(DemoVault.increaseTimelock, (NoticeKinds.DECREASE_TIMELOCK, 600));
        vm.startPrank(curator);
        vault.submit(ok);
        vault.submit(bad);
        vm.stopPrank();
        vm.warp(block.timestamp + 180);
        vault.increaseTimelock(NoticeKinds.ADD_ADAPTER, 600);
        vm.expectRevert(DemoVault.AutomaticallyTimelocked.selector);
        vault.increaseTimelock(NoticeKinds.DECREASE_TIMELOCK, 600);
    }

    function test_mint_and_withdraw_round_up() public {
        vm.prank(user);
        vault.deposit(500e6, user);
        token.mint(address(vault), 7); // donation makes the price uneven
        uint256 assetsForMint = vault.previewMint(3);
        assertGe(assetsForMint, vault.convertToAssets(3));
        uint256 sharesForWithdraw = vault.previewWithdraw(3);
        assertGe(sharesForWithdraw, vault.convertToShares(3));
    }

    function test_token_mint_cap() public {
        vm.expectRevert(abi.encodeWithSelector(DemoToken.MintTooLarge.selector, 1_000e6 + 1, 1_000e6));
        token.mint(user, 1_000e6 + 1);
    }

    // ---------------- remaining refusals, each next to the same call succeeding ----------------

    function test_relative_cap_refuses_decrease() public {
        bytes memory idData = abi.encode("market");
        vm.startPrank(curator);
        vault.submit(abi.encodeCall(DemoVault.increaseRelativeCap, (idData, 5e17)));
        vault.submit(abi.encodeCall(DemoVault.increaseRelativeCap, (idData, 4e17)));
        vm.stopPrank();
        vm.warp(block.timestamp + 180);
        vault.increaseRelativeCap(idData, 5e17);
        vm.expectRevert(DemoVault.RelativeCapNotIncreasing.selector);
        vault.increaseRelativeCap(idData, 4e17);
    }

    function test_mint_refuses_zero_shares() public {
        vm.prank(user);
        vault.mint(1, user);
        vm.expectRevert(DemoVault.ZeroShares.selector);
        vm.prank(user);
        vault.mint(0, user);
    }

    function test_withdraw_refuses_zero_assets() public {
        vm.startPrank(user);
        vault.deposit(10e6, user);
        vault.withdraw(1, user, user);
        vm.expectRevert(DemoVault.ZeroAssets.selector);
        vault.withdraw(0, user, user);
        vm.stopPrank();
    }

    function test_vault_refuses_zero_receiver() public {
        vm.startPrank(user);
        vault.deposit(10e6, user);
        vault.redeem(1e6, user, user);
        vm.expectRevert(DemoVault.ZeroAddress.selector);
        vault.redeem(1e6, address(0), user);
        vm.expectRevert(DemoVault.ZeroAddress.selector);
        vault.deposit(1e6, address(0));
        vm.stopPrank();
    }

    function test_share_transfer_refusals() public {
        vm.startPrank(user);
        vault.deposit(10e6, user);
        vault.transfer(other, 1e6);
        vm.expectRevert(DemoVault.ZeroAddress.selector);
        vault.transfer(address(0), 1e6);
        vm.expectRevert(DemoVault.InsufficientBalance.selector);
        vault.transfer(other, 10e6);
        vm.stopPrank();
    }

    function deployVault(address asset_, address curator_) external returns (address) {
        return address(new DemoVault(asset_, curator_, 180));
    }

    function deployFactory(address asset_) external returns (address) {
        return address(new DemoVaultFactory(asset_, 180));
    }

    /// @dev Plain try/catch on an external deploy helper, so the check does not depend on how a cheatcode treats CREATE.
    function _assertDeployRefused(bool vault_, address asset_, address curator_, bytes4 err_) internal {
        if (vault_) {
            try this.deployVault(asset_, curator_) returns (address) {
                revert("vault deployed with a zero address");
            } catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSelector(err_));
            }
        } else {
            try this.deployFactory(asset_) returns (address) {
                revert("factory deployed with a zero address");
            } catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSelector(err_));
            }
        }
    }

    function test_vault_and_factory_refuse_zero_addresses() public {
        assertTrue(this.deployVault(address(token), curator) != address(0));
        _assertDeployRefused(true, address(0), curator, DemoVault.ZeroAddress.selector);
        _assertDeployRefused(true, address(token), address(0), DemoVault.ZeroAddress.selector);
        assertTrue(this.deployFactory(address(token)) != address(0));
        _assertDeployRefused(false, address(0), address(0), DemoVaultFactory.ZeroAddress.selector);
    }

    function test_vault_refuses_token_answering_false() public {
        FalseToken ft = new FalseToken();
        DemoVault v = new DemoVault(address(ft), curator, 180);
        ft.mint(user, 100);
        vm.startPrank(user);
        v.deposit(10, user);
        ft.setRefuse(true);
        vm.expectRevert(DemoVault.TransferFailed.selector);
        v.deposit(10, user);
        vm.stopPrank();
    }

    function test_vault_refuses_token_reverting_without_reason() public {
        FalseToken ft = new FalseToken();
        DemoVault v = new DemoVault(address(ft), curator, 180);
        ft.mint(user, 100);
        vm.startPrank(user);
        v.deposit(10, user);
        ft.setRevertEmpty(true);
        vm.expectRevert(DemoVault.TransferFailed.selector);
        v.deposit(10, user);
        vm.stopPrank();
    }

    /// @dev The vault's own receiver check, with a token that would happily send to the zero address.
    function test_vault_refuses_zero_receiver_even_if_token_allows() public {
        FalseToken ft = new FalseToken();
        DemoVault v = new DemoVault(address(ft), curator, 180);
        ft.mint(user, 100);
        vm.startPrank(user);
        v.deposit(10, user);
        v.redeem(1, user, user);
        vm.expectRevert(DemoVault.ZeroAddress.selector);
        v.redeem(1, address(0), user);
        vm.stopPrank();
    }

    function test_token_refusals() public {
        vm.startPrank(user);
        token.transfer(other, 1e6);
        vm.expectRevert(DemoToken.InsufficientBalance.selector);
        token.transfer(other, 1_000e6);
        vm.expectRevert(DemoToken.ZeroAddress.selector);
        token.transfer(address(0), 1e6);
        token.approve(other, 1e6);
        vm.stopPrank();
        vm.startPrank(other);
        token.transferFrom(user, other, 1e6);
        vm.expectRevert(DemoToken.InsufficientAllowance.selector);
        token.transferFrom(user, other, 1);
        vm.stopPrank();
        token.mint(user, 1);
        vm.expectRevert(DemoToken.ZeroAddress.selector);
        token.mint(address(0), 1);
    }

    function testFuzz_redeem_never_pays_more_than_deposited(uint256 amount_, uint256 donation_, uint256 other_)
        public
    {
        amount_ = bound(amount_, 1, 1_000e6);
        donation_ = bound(donation_, 0, 1_000e6);
        other_ = bound(other_, 1, 1_000e6);
        // someone else deposits first, then a donation moves the price
        token.mint(other, other_);
        vm.startPrank(other);
        token.approve(address(vault), other_);
        vault.deposit(other_, other);
        vm.stopPrank();
        token.mint(address(vault), donation_);
        uint256 expectedShares = vault.previewDeposit(amount_);
        vm.assume(expectedShares > 0);
        vm.prank(user);
        uint256 shares = vault.deposit(amount_, user);
        uint256 preview = vault.previewRedeem(shares);
        // never more than deposited plus a share of the donation made before the deposit
        assertLe(preview, amount_ + 1, "redeem pays at most what was put in (no donation after deposit)");
        if (preview > 0) {
            vm.prank(user);
            uint256 assets = vault.redeem(shares, user, user);
            assertEq(assets, preview);
        }
    }
}
