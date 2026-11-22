// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { Network } from "./Network.sol";
import { DemoToken } from "../../src/demo/DemoToken.sol";
import { DemoVault } from "../../src/demo/DemoVault.sol";
import { DemoVaultFactory } from "../../src/demo/DemoVaultFactory.sol";
import { NoticeExit, IVaultRegistry } from "../../src/NoticeExit.sol";
import { NoticeReactive } from "../../src/NoticeReactive.sol";
import { INoticeExit } from "../../src/lib/INoticeExit.sol";
import { NoticeKinds } from "../../src/lib/NoticeKinds.sol";

/// @notice Deploys the full system in the deployment order of SPEC.md section 7. TIMELOCK, LEAD, CB_GAS and LIFETIME
///         are the deployed values (scripts/check-values.py holds them equal to scripts/deploy-system.sh); MAX_WAIT
///         and the caps are small test values so each is reached in a few calls (deployed values: SPEC.md section 9,
///         used together in test/DeployedValues.t.sol).
abstract contract NoticeSetup is Network {
    uint256 internal constant TIMELOCK = 180;
    /// @dev Covers MAX_TIMED Cron10 ticks (8 x 10.7 s) plus the callback's trip: one exit is asked for per tick.
    uint256 internal constant LEAD = 120;
    uint256 internal constant MAX_WAIT = 900;
    /// @dev The callback gas limit scripts/deploy-system.sh deploys (CALLBACK_GAS there; check-values.py compares).
    uint64 internal constant CB_GAS = 1_000_000;
    uint256 internal constant MAX_ACTIVE = 8;
    uint256 internal constant MAX_REACTIONS = 80;
    uint256 internal constant PER_ADDRESS = 2;
    uint256 internal constant PER_DAY = 10;
    uint256 internal constant LIFETIME = 1 days;
    uint256 internal constant START = 1_800_000_000;

    /// @dev Reaction budget used by _deploy; a test contract may lower it before calling _deploy.
    uint256 internal cfgMaxReactions = MAX_REACTIONS;
    /// @dev Cap on armed watches (both modes) used by _deploy; a test contract may raise it before calling _deploy.
    uint256 internal cfgMaxActive = MAX_ACTIVE;
    /// @dev Longest wait the reactive contract pays ticks for, used by _deploy; a test contract may change it first.
    uint256 internal cfgMaxWait = MAX_WAIT;
    /// @dev NoticeExit's daily arm caps used by _deploy (per address, all addresses, timer arms); a test contract may
    ///      change them before calling _deploy.
    uint256 internal cfgPerAddress = PER_ADDRESS;
    uint256 internal cfgPerDay = PER_DAY;
    uint256 internal cfgTimedPerDay = PER_DAY;

    DemoToken internal token;
    DemoVaultFactory internal factory;
    NoticeExit internal exitC;
    NoticeReactive internal reactive;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _deploy() internal {
        _setUpNetwork();
        vm.warp(START);
        token = new DemoToken();
        factory = new DemoVaultFactory(address(token), TIMELOCK);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        reactive = new NoticeReactive(
            ORIGIN_CHAIN, predicted, CRON10_TOPIC, LEAD, cfgMaxWait, CB_GAS, cfgMaxActive, cfgMaxReactions
        );
        exitC = new NoticeExit(
            IPayable(payable(address(proxy))),
            address(reactive),
            IVaultRegistry(address(factory)),
            cfgPerAddress,
            cfgPerDay,
            LIFETIME,
            cfgTimedPerDay
        );
        assertEq(address(exitC), predicted, "exit address computed before deployment");
        _drainLogs();
    }

    function _newVault(address curator_) internal returns (DemoVault v) {
        vm.prank(curator_);
        v = DemoVault(factory.create());
    }

    function _deposit(address user_, DemoVault v_, uint256 amount_) internal returns (uint256 shares) {
        vm.startPrank(user_);
        token.mint(user_, amount_);
        token.approve(address(v_), amount_);
        shares = v_.deposit(amount_, user_);
        vm.stopPrank();
    }

    function _vaultWithDeposit(address user_, uint256 amount_) internal returns (DemoVault v) {
        v = _newVault(user_);
        _deposit(user_, v, amount_);
    }

    function _approveExit(address user_, DemoVault v_, uint256 shares_) internal {
        vm.prank(user_);
        v_.approve(address(exitC), shares_);
    }

    /// @notice Approves the exit contract for all shares, arms, and lets the network deliver WatchArmed.
    function _arm(address user_, DemoVault v_, uint8 kinds_, uint8 mode_, uint256 maxShares_)
        internal
        returns (uint256 id)
    {
        _approveExit(user_, v_, type(uint256).max);
        vm.prank(user_);
        id = exitC.arm(address(v_), kinds_, mode_, maxShares_);
        _pump(address(reactive));
    }

    /// @notice Curator schedules `data_`; returns the synthetic origin transaction hash of the Submit.
    function _submit(address curator_, DemoVault v_, bytes memory data_) internal returns (uint256) {
        vm.prank(curator_);
        v_.submit(data_);
        _pump(address(reactive));
        return lastTxHash;
    }

    function _revokeChange(address curator_, DemoVault v_, bytes memory data_) internal {
        vm.prank(curator_);
        v_.revoke(data_);
        _pump(address(reactive));
    }

    function _tickAndPump() internal {
        _tick();
        _pump(address(reactive));
    }

    function _adapterCall(address adapter_) internal pure returns (bytes memory) {
        return abi.encodeCall(DemoVault.addAdapter, (adapter_));
    }

    function _capCall(uint256 cap_) internal pure returns (bytes memory) {
        return abi.encodeCall(DemoVault.increaseAbsoluteCap, (abi.encode("demo-market"), cap_));
    }

    function _timelockDownCall() internal pure returns (bytes memory) {
        return abi.encodeCall(DemoVault.decreaseTimelock, (NoticeKinds.ADD_ADAPTER, 0));
    }

    function _allocatorCall(address who_) internal pure returns (bytes memory) {
        return abi.encodeCall(DemoVault.setIsAllocator, (who_, true));
    }

    function _exitPayload(uint256 id_, address vault_, bytes memory data_, uint256 origin_, uint8 reason_)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(INoticeExit.exit, (address(0), id_, vault_, data_, origin_, reason_));
    }

    function _status(uint256 id_) internal view returns (uint8 s) {
        (,,, s,,) = exitC.watches(id_);
    }

    function _rStatus(uint256 id_) internal view returns (uint8 s) {
        (,,, s,,) = reactive.watches(id_);
    }

    function _rReactions(uint256 id_) internal view returns (uint32 r) {
        (,,,,, r) = reactive.watches(id_);
    }

    function _rPendingCount(uint256 id_) internal view returns (uint8 n) {
        (,,,, n,) = reactive.watches(id_);
    }

    /// @notice A WatchArmed log of our exit contract as the network hands it to react(), for a test that delivers it
    ///         itself (sys.forceDeliver) to read the exact refusal code.
    function _watchArmedLog(uint256 id_, address vault_, uint8 mode_)
        internal
        view
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = ORIGIN_CHAIN;
        r.contractAddress = address(exitC);
        r.topic0 = reactive.WATCH_ARMED_TOPIC();
        r.topic1 = id_;
        r.topic2 = uint256(uint160(alice));
        r.topic3 = uint256(uint160(vault_));
        r.opCode = 4;
        r.data = abi.encode(NoticeKinds.DEFAULT, mode_, type(uint256).max);
    }

    /// @notice Decodes callback request `i_` into the exit arguments.
    function _callbackArgs(uint256 i_)
        internal
        view
        returns (uint256 id, bytes memory data, uint256 origin, uint8 reason)
    {
        bytes memory payload = sys.callbackAt(i_).payload;
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 k = 0; k < args.length; k++) {
            args[k] = payload[k + 4];
        }
        (, id,, data, origin, reason) = abi.decode(args, (address, uint256, address, bytes, uint256, uint8));
    }
}
