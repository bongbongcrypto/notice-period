// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { MockVaultV2, MockVaultV2Factory } from "./mocks/MockMorpho.sol";
import { IMorphoVaultV2Factory, IMorphoVaultV2 } from "../src/morpho/IMorpho.sol";
import { MorphoVaultMaker } from "../src/morpho/MorphoVaultMaker.sol";
import { NoticeExit, IVaultRegistry } from "../src/NoticeExit.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice MorphoVaultMaker against a stand-in of Morpho's factory and Vault V2 that keeps the real refusals
///         (DataAlreadyPending, timelocked calls, abdicated selectors). The real factory bytecode runs in the dry run.
contract MorphoTest is NoticeSetup {
    MockVaultV2Factory internal mFactory;
    MorphoVaultMaker internal maker;
    NoticeExit internal exitM;

    function setUp() public {
        _deploy();
        mFactory = new MockVaultV2Factory();
        maker = new MorphoVaultMaker(IMorphoVaultV2Factory(address(mFactory)), address(token), TIMELOCK);
        exitM = new NoticeExit(
            IPayable(payable(address(proxy))),
            address(reactive),
            IVaultRegistry(address(maker)),
            PER_ADDRESS,
            PER_DAY,
            LIFETIME,
            PER_DAY
        );
    }

    function _make(address user_) internal returns (MockVaultV2 v) {
        vm.prank(user_);
        v = MockVaultV2(maker.create());
    }

    function _depositInto(address user_, MockVaultV2 v_, uint256 amount_) internal {
        vm.startPrank(user_);
        token.mint(user_, amount_);
        token.approve(address(v_), amount_);
        v_.deposit(amount_, user_);
        v_.approve(address(exitM), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The selectors the maker uses come from IMorphoVaultV2; each is pinned here to a Keccak-256 computed outside
    ///      the compiler, so a wrong parameter type in the interface fails this test.
    function test_interface_selectors_match_vault_v2() public pure {
        assertEq(IMorphoVaultV2.addAdapter.selector, NoticeKinds.ADD_ADAPTER);
        assertEq(IMorphoVaultV2.setIsAllocator.selector, NoticeKinds.SET_IS_ALLOCATOR);
        assertEq(IMorphoVaultV2.increaseAbsoluteCap.selector, NoticeKinds.INCREASE_ABSOLUTE_CAP);
        assertEq(IMorphoVaultV2.increaseRelativeCap.selector, NoticeKinds.INCREASE_RELATIVE_CAP);
        assertEq(IMorphoVaultV2.increaseTimelock.selector, NoticeKinds.INCREASE_TIMELOCK);
        assertEq(IMorphoVaultV2.abdicate.selector, bytes4(0xb2e32848));
        assertEq(IMorphoVaultV2.setReceiveSharesGate.selector, bytes4(0x2cb19f98));
        assertEq(IMorphoVaultV2.setSendSharesGate.selector, bytes4(0xc21ad028));
        assertEq(IMorphoVaultV2.setReceiveAssetsGate.selector, bytes4(0x04dbf0ce));
        assertEq(IMorphoVaultV2.setSendAssetsGate.selector, bytes4(0x871c979c));
        assertEq(IMorphoVaultV2.setPerformanceFee.selector, bytes4(0x70897b23));
        assertEq(IMorphoVaultV2.setManagementFee.selector, bytes4(0xfe56e232));
        assertEq(IMorphoVaultV2.setOwner.selector, bytes4(0x13af4035));
        assertEq(IMorphoVaultV2.setCurator.selector, bytes4(0xe90956cf));
        assertEq(IMorphoVaultV2.setName.selector, bytes4(0xc47f0027));
        assertEq(IMorphoVaultV2.submit.selector, bytes4(0xef7fa71b));
        assertEq(IMorphoVaultV2Factory.createVaultV2.selector, bytes4(0xa7a28469));
        assertEq(IMorphoVaultV2Factory.vaultV2.selector, bytes4(0x8d8b08a8));
        assertEq(IMorphoVaultV2Factory.isVaultV2.selector, bytes4(0x5edec50d));
    }

    /// @dev Bites `v.setCurator(msg.sender);` and `v.setOwner(msg.sender);` in create(): the caller ends as curator and
    ///      owner, and the maker keeps no role.
    function test_create_hands_over_owner_and_curator() public {
        vm.expectEmit(false, true, true, false, address(maker));
        emit MorphoVaultMaker.VaultCreated(address(0), alice);
        MockVaultV2 v = _make(alice);
        assertEq(v.owner(), alice, "owner handed over");
        assertEq(v.curator(), alice, "curator handed over");
        assertEq(v.name(), maker.VAULT_NAME());
        assertEq(maker.lastVaultOf(alice), address(v));
        assertEq(maker.vaultCount(), 1);
        assertTrue(maker.made(address(v)));
        vm.expectRevert(MockVaultV2.Unauthorized.selector);
        vm.prank(address(maker));
        v.setOwner(address(maker));
    }

    /// @dev Bites `v_.increaseTimelock(selector_, TIMELOCK);` in _raiseTimelock: the four watched-kind changes wait
    ///      TIMELOCK seconds in a fresh maker vault, and nothing the maker submitted is left pending.
    function test_create_sets_four_timelocks() public {
        MockVaultV2 v = _make(alice);
        bytes4[4] memory sels = [
            IMorphoVaultV2.addAdapter.selector,
            IMorphoVaultV2.setIsAllocator.selector,
            IMorphoVaultV2.increaseAbsoluteCap.selector,
            IMorphoVaultV2.increaseRelativeCap.selector
        ];
        for (uint256 i = 0; i < 4; i++) {
            assertEq(v.timelock(sels[i]), TIMELOCK, "watched-kind change waits TIMELOCK");
            bytes memory raise = abi.encodeCall(IMorphoVaultV2.increaseTimelock, (sels[i], TIMELOCK));
            assertEq(v.executableAt(raise), 0, "the raise ran");
        }
        // the curator's new adapter now waits TIMELOCK, and so does a shorter waiting period for it
        bytes memory newAdapter = abi.encodeCall(IMorphoVaultV2.addAdapter, (address(0xAD)));
        vm.prank(alice);
        v.submit(newAdapter);
        assertEq(v.executableAt(newAdapter), block.timestamp + TIMELOCK);
        bytes memory shorter = abi.encodeWithSelector(NoticeKinds.DECREASE_TIMELOCK, NoticeKinds.ADD_ADAPTER, 0);
        vm.prank(alice);
        v.submit(shorter);
        assertEq(v.executableAt(shorter), block.timestamp + TIMELOCK);
    }

    /// @dev Bites `v_.abdicate(selector_);` in _abdicate: the four gate setters and the two fee setters are abdicated,
    ///      so even the new curator cannot set a gate or a fee (the submit is accepted, the call is refused for good).
    function test_create_abdicates_gates_and_fees() public {
        MockVaultV2 v = _make(alice);
        bytes4[6] memory sels = [
            IMorphoVaultV2.setReceiveSharesGate.selector,
            IMorphoVaultV2.setSendSharesGate.selector,
            IMorphoVaultV2.setReceiveAssetsGate.selector,
            IMorphoVaultV2.setSendAssetsGate.selector,
            IMorphoVaultV2.setPerformanceFee.selector,
            IMorphoVaultV2.setManagementFee.selector
        ];
        for (uint256 i = 0; i < 6; i++) {
            assertTrue(v.abdicated(sels[i]), "abdicated");
            assertEq(v.executableAt(abi.encodeCall(IMorphoVaultV2.abdicate, (sels[i]))), 0, "the abdication ran");
        }
        bytes memory gate = abi.encodeCall(IMorphoVaultV2.setReceiveSharesGate, (address(0xBAD)));
        vm.prank(alice);
        v.submit(gate);
        vm.expectRevert(MockVaultV2.Abdicated.selector);
        v.setReceiveSharesGate(address(0xBAD));
        bytes memory fee = abi.encodeCall(IMorphoVaultV2.setManagementFee, (1));
        vm.prank(alice);
        v.submit(fee);
        vm.expectRevert(MockVaultV2.Abdicated.selector);
        v.setManagementFee(1);
        assertEq(v.receiveSharesGate(), address(0));
        assertEq(v.managementFee(), 0);
    }

    /// @dev Bites `block.number` in the salt of _freeSalt. A stranger takes the next salt in Morpho's open factory: it
    ///      is skipped and the stranger's vault is never listed. A stranger takes the next 16 salts of this block:
    ///      create() refuses in this block (NoFreeSalt) and succeeds in the next with a salt nobody could take ahead.
    function test_create_survives_precreated_salts() public {
        uint256 t = maker.saltTries();
        bytes32 s0 = keccak256(abi.encode(alice, block.number, t));
        address pre = mFactory.createVaultV2(address(maker), address(token), s0);
        MockVaultV2 v1 = _make(alice);
        assertEq(mFactory.lastSalt(), keccak256(abi.encode(alice, block.number, t + 1)), "the taken salt is skipped");
        assertTrue(maker.isVault(address(v1)));
        assertFalse(maker.isVault(pre), "a vault made in the maker's name by someone else is not listed");
        assertEq(MockVaultV2(pre).curator(), address(0), "and is never touched");

        uint256 t2 = maker.saltTries();
        assertEq(t2, t + 2, "the counter moved on both tries");
        for (uint256 k = 0; k < maker.MAX_SALT_TRIES(); k++) {
            mFactory.createVaultV2(address(maker), address(token), keccak256(abi.encode(alice, block.number, t2 + k)));
        }
        vm.expectRevert(MorphoVaultMaker.NoFreeSalt.selector);
        vm.prank(alice);
        maker.create();
        vm.roll(block.number + 1);
        MockVaultV2 v2 = _make(alice);
        assertEq(mFactory.lastSalt(), keccak256(abi.encode(alice, block.number, t2)), "next block: a fresh salt");
        assertTrue(maker.isVault(address(v2)));
    }

    /// @dev Bites `made[vault_] &&` in isVault: a Vault V2 from Morpho's factory that this maker did not make is not
    ///      listed (it may have gates, fees or any asset).
    function test_isVault_false_for_factory_vault_not_made_here() public {
        address other = mFactory.createVaultV2(alice, address(token), bytes32(uint256(1)));
        assertTrue(mFactory.isVaultV2(other));
        assertFalse(maker.isVault(other));
        MockVaultV2 v = _make(alice);
        assertTrue(maker.isVault(address(v)), "sibling: a maker vault is listed");
    }

    /// @dev Bites `&& FACTORY.isVaultV2(vault_)` in isVault: a vault the factory does not list is not listed here.
    function test_isVault_false_when_factory_says_no() public {
        MockVaultV2 v = _make(alice);
        assertTrue(maker.isVault(address(v)), "sibling: listed while the factory lists it");
        mFactory.unlist(address(v));
        assertFalse(maker.isVault(address(v)));
        assertTrue(maker.made(address(v)));
    }

    /// @dev NoticeExit with the maker as registry: a watch arms on a maker vault and is refused on a factory vault the
    ///      maker did not make (existing rule `arm-unknown-vault`).
    function test_arm_on_maker_vault() public {
        MockVaultV2 v = _make(alice);
        _depositInto(alice, v, 100e6);
        vm.prank(alice);
        uint256 id = exitM.arm(address(v), NoticeKinds.DEFAULT, 0, type(uint256).max);
        assertEq(exitM.activeWatchOf(alice, address(v)), id);
        MockVaultV2 other = MockVaultV2(mFactory.createVaultV2(alice, address(token), bytes32(uint256(7))));
        _depositInto(alice, other, 100e6);
        vm.expectRevert(abi.encodeWithSelector(NoticeExit.UnknownVault.selector, address(other)));
        vm.prank(alice);
        exitM.arm(address(other), NoticeKinds.DEFAULT, 0, type(uint256).max);
    }

    /// @dev The mock's redeem, which the dry run uses when Morpho's factory code cannot be fetched: the exit contract
    ///      spends the owner's share allowance and the assets reach the receiver; a spender without allowance fails.
    function test_mock_vault_redeem_for_exit() public {
        MockVaultV2 v = _make(alice);
        _depositInto(alice, v, 100e6);
        uint256 before = token.balanceOf(alice);
        vm.prank(address(exitM));
        assertEq(v.redeem(40e6, alice, alice), 40e6);
        assertEq(token.balanceOf(alice), before + 40e6);
        assertEq(v.balanceOf(alice), 60e6);
        assertEq(v.allowance(alice, address(exitM)), type(uint256).max - 40e6);
        vm.expectRevert(bytes("allowance"));
        vm.prank(bob);
        v.redeem(1, bob, alice);
    }
}
