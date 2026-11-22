// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { Network } from "../test/utils/Network.sol";
import { MockSystem } from "../test/mocks/MockSystem.sol";
import { AllowAllRegistry } from "../test/mocks/Hostile.sol";
import { NoticeExit, IVaultRegistry } from "../src/NoticeExit.sol";
import { NoticeReactive } from "../src/NoticeReactive.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @dev The Morpho Vault V2 functions this test calls (morpho-org/vault-v2 VaultV2.sol; every selector below was found
///      in the runtime code of VAULT at the fork block).
interface IForkVaultV2 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 shares) external returns (bool);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
    function executableAt(bytes calldata data) external view returns (uint256);
    function isAllocator(address account) external view returns (bool);
    function liquidityAdapter() external view returns (address);
    function setLiquidityAdapterAndData(address newLiquidityAdapter, bytes calldata newLiquidityData) external;
}

interface IForkErc20 {
    function balanceOf(address account) external view returns (uint256);
}

/// @title RealVaultForkTest (F2, F2b)
/// @notice Fork test: Ethereum mainnet state at block 26,406,895, the real Morpho Vault V2 "Gauntlet USDC Frontier",
///         our current NoticeReactive and NoticeExit. The Reactive Network is played by MockSystem and
///         MockCallbackProxy (gas per SPEC.md section 12); the registry is a stub that accepts every vault. The real
///         Submit log of transaction 0x335fe388... (log 259) is fed to react(), and the callback it requests is
///         delivered to exit() with the gas the proxy forwards for the requested limit.
/// @dev Needs ETH_RPC (an archive endpoint); without it every test is skipped. Lives in fork/, outside the test
///      directory, so the blocking jobs never compile it: run it with FOUNDRY_TEST=fork (the non-blocking ci.yml job
///      "fork"). The constants below are the values scripts/deploy-system.sh deploys (Track 1).
contract RealVaultForkTest is Network {
    uint256 internal constant MAINNET = 1;
    uint256 internal constant FORK_BLOCK = 26_406_895;

    address internal constant VAULT = 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e; // Gauntlet USDC Frontier
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev The holder of the replay (status/replay-mainnet.json); its claim is below the vault's idle USDC.
    address internal constant HOLDER = 0xa69abE7a806a1b75E148b1d7977B87CC3e0fEE94;
    /// @dev For F2b: an EOA holder whose claim exceeds the vault's idle USDC at the fork block.
    address internal constant BIG_HOLDER = 0xeb79aF8570f8a523D17A47706cF28dA41B490ea0;
    /// @dev An allocator of the vault at the fork block (isAllocator true; it set the liquidity adapter at 26,301,377).
    address internal constant ALLOCATOR = 0xA0648494037132df17ebac10b902f1568fdA8698;
    /// @dev Accounts the redeem reads: the vault's only adapter, Morpho Blue, the IRM of the adapter's 16 markets.
    address internal constant ADAPTER = 0x3dd6e19D306700560a8C500d5ABBdA6C7e2a01b2;
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    /// @dev FiatTokenProxy implementation slot (keccak256("org.zeppelinos.proxy.implementation")).
    bytes32 internal constant USDC_IMPL_SLOT = 0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;

    bytes32 internal constant SUBMIT_TX = 0x335fe3887288e04ddf6daf958b0634cd211dddd5f8bd260aaafd62ee694a2441;
    bytes32 internal constant SUBMIT_BLOCK_HASH = 0x9a0f1732647ad9807fc8c42c4c0f393d35dbf3198b7ceb39a5688b9b4fccd469;
    uint256 internal constant EXECUTABLE_AT = 1_794_842_387;

    /// @dev Data of log 259 of SUBMIT_TX: Submit(decreaseTimelock(setIsAllocator, 0)), a watched kind (TIMELOCK_DOWN).
    bytes internal constant LOG_259_DATA = hex"0000000000000000000000000000000000000000000000000000000000000040"
        hex"000000000000000000000000000000000000000000000000000000006afb1f13"
        hex"0000000000000000000000000000000000000000000000000000000000000044"
        hex"5c1a1a4fb192a84a000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000";
    /// @dev Data of log 258 of the same transaction: Submit(increaseTimelock(addAdapter, 604800)), not a watched kind.
    bytes internal constant LOG_258_DATA = hex"0000000000000000000000000000000000000000000000000000000000000040"
        hex"000000000000000000000000000000000000000000000000000000006b006513"
        hex"0000000000000000000000000000000000000000000000000000000000000044"
        hex"4796629160d54d41000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"00093a8000000000000000000000000000000000000000000000000000000000";

    bytes32 internal constant WATCH_ENDED_TOPIC = keccak256("WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)");
    bytes32 internal constant REDEEM_REVERTED_TOPIC = keccak256("RedeemReverted(uint256,bytes)");

    // Values scripts/deploy-system.sh deploys (SPEC.md section 9, Track 1 column).
    uint256 internal constant LEAD = 120;
    uint256 internal constant MAX_WAIT = 200;
    uint256 internal constant MAX_ACTIVE = 1000;
    uint256 internal constant MAX_REACTIONS = 16;
    uint256 internal constant PER_ADDRESS = 4;
    uint256 internal constant PER_DAY = 50;
    uint256 internal constant TIMED_PER_DAY = 4;
    uint256 internal constant LIFETIME = 1 days;
    /// @dev The deployed callback gas limit, and the 11-18 pair's for the comparison.
    uint64 internal constant CB_GAS = 1_000_000;
    uint64 internal constant OLD_CB_GAS = 600_000;
    uint8 internal constant MODE_NOW = 0;

    IForkVaultV2 internal constant VAULT_V2 = IForkVaultV2(VAULT);
    IForkErc20 internal constant USDC_T = IForkErc20(USDC);

    NoticeExit internal exitC;
    NoticeReactive internal reactive;

    struct Ended {
        bool found;
        uint8 outcome;
        uint8 reason;
        uint256 shares;
        uint256 assets;
        uint256 origin;
        bool redeemReverted;
        bytes revertData;
    }

    // ------------------------------------------------------------------
    // F2: the full path at the deployed 1,000,000 and at the 11-18 pair's 600,000
    // ------------------------------------------------------------------

    /// @notice F2, green side: at a callback limit of 1,000,000 the real holder is redeemed to its own wallet.
    function test_F2_realSubmit_redeemsHolder_at1000000() public {
        vm.skip(!_hasRpc());
        _fork();
        _deploySystem(CB_GAS);
        (uint256 id, uint256 shares) = _armOnRealVault(HOLDER);
        MockSystem.Callback memory cb = _deliverRealSubmits(CB_GAS, id);
        uint256 expected = VAULT_V2.previewRedeem(shares);
        uint256 usdcBefore = USDC_T.balanceOf(HOLDER);

        _deliverCallbackCold(cb);
        _checkForwardedAgainstReplayFormula(CB_GAS);
        Ended memory e = _endedOf(id);

        assertTrue(proxy.lastOk(), "the exit ran within the forwarded gas");
        assertEq(_status(id), exitC.STATUS_ENDED());
        assertTrue(e.found, "WatchEnded emitted");
        assertEq(e.outcome, exitC.OUTCOME_REDEEMED());
        assertEq(e.reason, reactive.R_SCHEDULED());
        assertEq(e.origin, uint256(SUBMIT_TX), "the real origin transaction hash reached the exit");
        assertEq(e.shares, shares, "every share redeemed");
        assertEq(VAULT_V2.balanceOf(HOLDER), 0);
        assertGt(e.assets, 0);
        assertEq(USDC_T.balanceOf(HOLDER) - usdcBefore, e.assets, "the holder received exactly WatchEnded.assets");
        assertEq(e.assets, expected, "the vault's own previewRedeem in the same block");
    }

    /// @notice F2, red side: at the 11-18 pair's limit of 600,000 the same exit is not redeemed (the replay saw the
    ///         exit run out of gas; on the same state the redeem needs at least 447,005 forwarded, 600,000 gives
    ///         about 416,000).
    function test_F2_realSubmit_notRedeemed_at600000() public {
        vm.skip(!_hasRpc());
        _fork();
        _deploySystem(OLD_CB_GAS);
        (uint256 id, uint256 shares) = _armOnRealVault(HOLDER);
        MockSystem.Callback memory cb = _deliverRealSubmits(OLD_CB_GAS, id);
        uint256 usdcBefore = USDC_T.balanceOf(HOLDER);

        _deliverCallbackCold(cb);
        _checkForwardedAgainstReplayFormula(OLD_CB_GAS);
        Ended memory e = _endedOf(id);

        bool redeemed = proxy.lastOk() && e.found && e.outcome == exitC.OUTCOME_REDEEMED();
        assertFalse(redeemed, "not redeemed at 600,000");
        assertEq(VAULT_V2.balanceOf(HOLDER), shares, "the shares stay with the holder");
        assertEq(USDC_T.balanceOf(HOLDER), usdcBefore, "no USDC moved");
        if (!proxy.lastOk()) {
            // The replay's outcome: the whole exit reverted out of gas; on chain the watch stays active.
            assertEq(proxy.lastReturn().length, 0, "empty revert data: out of gas");
            assertGe(proxy.lastUsed(), proxy.lastForwarded(), "the exit used all the gas it was given");
            assertEq(_status(id), exitC.STATUS_ACTIVE());
            console.log("600,000: the exit reverted out of gas (same outcome as the replay)");
        } else {
            // The redeem ran out of gas inside the try; the catch ended the watch.
            assertTrue(e.found);
            assertEq(e.outcome, exitC.OUTCOME_REDEEM_FAILED());
            console.log("600,000: the redeem failed inside the exit, watch ended REDEEM_FAILED (differs from the replay)");
        }
    }

    // ------------------------------------------------------------------
    // F2b: an allocator empties the exit path first (SPEC.md section 11, NP-04)
    // ------------------------------------------------------------------

    /// @notice F2b: an allocator (no timelock) clears the liquidity adapter before the curator's change is scheduled;
    ///         the redeem reverts and the watch ends REDEEM_FAILED, not retried, shares left with the holder.
    /// @dev The replay holder cannot show this: the vault's idle USDC covers its claim, so its redeem never touches the
    ///      liquidity adapter. BIG_HOLDER's claim exceeds idle.
    function test_F2b_allocatorClearsLiquidityAdapter_endsRedeemFailed() public {
        vm.skip(!_hasRpc());
        _fork();
        _deploySystem(CB_GAS);
        uint256 idle = USDC_T.balanceOf(VAULT);
        assertLt(VAULT_V2.previewRedeem(VAULT_V2.balanceOf(HOLDER)), idle, "idle covers the replay holder");
        assertGt(VAULT_V2.previewRedeem(VAULT_V2.balanceOf(BIG_HOLDER)), idle, "idle does not cover BIG_HOLDER");

        (uint256 id, uint256 shares) = _armOnRealVault(BIG_HOLDER);
        assertTrue(VAULT_V2.isAllocator(ALLOCATOR));
        vm.prank(ALLOCATOR);
        VAULT_V2.setLiquidityAdapterAndData(address(0), hex"");
        assertEq(VAULT_V2.liquidityAdapter(), address(0));

        MockSystem.Callback memory cb = _deliverRealSubmits(CB_GAS, id);
        uint256 usdcBefore = USDC_T.balanceOf(BIG_HOLDER);
        _deliverCallbackCold(cb);
        Ended memory e = _endedOf(id);

        assertTrue(proxy.lastOk(), "the exit itself succeeded; the redeem inside it failed");
        assertEq(_status(id), exitC.STATUS_ENDED(), "the watch ends and is not retried");
        assertTrue(e.found, "WatchEnded emitted");
        assertEq(e.outcome, exitC.OUTCOME_REDEEM_FAILED());
        assertEq(e.shares, 0);
        assertEq(e.assets, 0);
        assertTrue(e.redeemReverted, "RedeemReverted carries the vault's revert");
        console.log("F2b revert data:");
        console.logBytes(e.revertData);
        assertEq(VAULT_V2.balanceOf(BIG_HOLDER), shares, "the shares stay with the holder");
        assertEq(USDC_T.balanceOf(BIG_HOLDER), usdcBefore, "no USDC moved");
    }

    /// @notice Control for F2b: the same holder, with the liquidity adapter left in place, is redeemed, so F2b's
    ///         failure comes from the cleared adapter.
    function test_F2b_control_sameHolderRedeems_withLiquidityAdapter() public {
        vm.skip(!_hasRpc());
        _fork();
        _deploySystem(CB_GAS);
        (uint256 id, uint256 shares) = _armOnRealVault(BIG_HOLDER);
        MockSystem.Callback memory cb = _deliverRealSubmits(CB_GAS, id);
        uint256 usdcBefore = USDC_T.balanceOf(BIG_HOLDER);
        _deliverCallbackCold(cb);
        Ended memory e = _endedOf(id);

        assertTrue(proxy.lastOk());
        assertTrue(e.found);
        assertEq(e.outcome, exitC.OUTCOME_REDEEMED());
        assertEq(e.shares, shares);
        assertEq(VAULT_V2.balanceOf(BIG_HOLDER), 0);
        assertEq(USDC_T.balanceOf(BIG_HOLDER) - usdcBefore, e.assets);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _hasRpc() internal view returns (bool) {
        return bytes(vm.envOr("ETH_RPC", string(""))).length != 0;
    }

    function _fork() internal {
        vm.createSelectFork(vm.envOr("ETH_RPC", string("")), FORK_BLOCK);
        assertEq(block.chainid, MAINNET, "ETH_RPC must serve Ethereum mainnet");
        assertEq(block.number, FORK_BLOCK);
        assertEq(VAULT_V2.asset(), USDC);
    }

    /// @dev Our current contracts on the fork, in the deployment order of SPEC.md section 7. The reactive contract
    ///      watches chain 1 (the real log's chain) and asks for `callbackGas_`.
    function _deploySystem(uint64 callbackGas_) internal {
        _setUpNetwork();
        AllowAllRegistry registry = new AllowAllRegistry();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        reactive = new NoticeReactive(
            MAINNET, predicted, CRON10_TOPIC, LEAD, MAX_WAIT, callbackGas_, MAX_ACTIVE, MAX_REACTIONS
        );
        exitC = new NoticeExit(
            IPayable(payable(address(proxy))),
            address(reactive),
            IVaultRegistry(address(registry)),
            PER_ADDRESS,
            PER_DAY,
            LIFETIME,
            TIMED_PER_DAY
        );
        assertEq(address(exitC), predicted, "exit address computed before deployment");
        _drainLogs();
    }

    /// @dev The holder approves exactly its shares (as the replay did) and arms a "leave now" watch on the default
    ///      kinds; the recorded WatchArmed reaches react() through the subscriptions.
    function _armOnRealVault(address holder_) internal returns (uint256 id, uint256 shares) {
        shares = VAULT_V2.balanceOf(holder_);
        assertGt(shares, 0, "the holder has shares at the fork block");
        vm.prank(holder_);
        VAULT_V2.approve(address(exitC), shares);
        vm.prank(holder_);
        id = exitC.arm(VAULT, NoticeKinds.DEFAULT, MODE_NOW, type(uint256).max);
        assertEq(_deliverRecorded(), 1, "WatchArmed is the one recorded log the reactive contract subscribes to");
        assertEq(_rStatus(id), reactive.ST_ARMED());
        assertEq(reactive.submitFilterRefs(VAULT, NoticeKinds.DECREASE_TIMELOCK), 1, "subscribed to the real vault");
    }

    /// @dev Delivers the recorded logs as chain-1 logs; the mock system's subscriptions decide.
    function _deliverRecorded() internal returns (uint256 matched) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        txCounter += 1;
        uint256 txHash = uint256(keccak256(abi.encode("fork-origin-tx", txCounter)));
        for (uint256 i = 0; i < logs.length; i++) {
            IReactive.LogRecord memory r = _toRecord(logs[i], txHash);
            r.chainId = MAINNET; // Network._toRecord labels origin logs 84532
            if (sys.deliver(address(reactive), r)) matched += 1;
        }
    }

    /// @dev The two Submit logs of SUBMIT_TX, as the network would hand them to react(): 258 (not watched) must not
    ///      match, 259 must match and produce exactly one callback request.
    function _deliverRealSubmits(uint64 callbackGas_, uint256 id_) internal returns (MockSystem.Callback memory cb) {
        IReactive.LogRecord memory dec = _realSubmit(259, NoticeKinds.DECREASE_TIMELOCK, LOG_259_DATA);
        (bytes memory change, uint256 at) = abi.decode(dec.data, (bytes, uint256));
        assertEq(
            change, abi.encodeWithSelector(NoticeKinds.DECREASE_TIMELOCK, NoticeKinds.SET_IS_ALLOCATOR, uint256(0))
        );
        assertEq(at, EXECUTABLE_AT);
        assertEq(VAULT_V2.executableAt(change), EXECUTABLE_AT, "the forked vault holds this exact change as pending");

        assertFalse(
            sys.deliver(address(reactive), _realSubmit(258, NoticeKinds.INCREASE_TIMELOCK, LOG_258_DATA)),
            "log 258 (increaseTimelock) is not a watched kind"
        );
        assertTrue(sys.deliver(address(reactive), dec), "log 259 matches the filter the watch created");
        assertEq(sys.reverts(), 0, "react() did not revert");
        assertEq(sys.overGasLimit(), 0, "react() stayed under 900,000 (modelled)");
        assertEq(sys.callbackCount(), 1);

        cb = sys.callbackAt(0);
        assertEq(cb.sender, address(reactive));
        assertEq(cb.chainId, MAINNET);
        assertEq(cb.recipient, address(exitC));
        assertEq(uint256(cb.gasLimit), uint256(callbackGas_));
        _checkExitPayload(cb.payload, id_, change);
    }

    /// @dev Kept apart from _deliverRealSubmits to stay clear of "stack too deep" (no via_ir in foundry.toml).
    function _checkExitPayload(bytes memory payload_, uint256 id_, bytes memory change_) internal view {
        (uint256 id, address vault, bytes memory data, uint256 origin, uint8 reason) = _decodeExit(payload_);
        assertEq(id, id_);
        assertEq(vault, VAULT);
        assertEq(data, change_, "a 68-byte change travels whole");
        assertEq(origin, uint256(SUBMIT_TX));
        assertEq(reason, reactive.R_SCHEDULED());
    }

    function _realSubmit(uint256 logIndex_, bytes4 selector_, bytes memory data_)
        internal
        pure
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = MAINNET;
        r.contractAddress = VAULT;
        r.topic0 = NoticeKinds.SUBMIT_TOPIC;
        r.topic1 = NoticeKinds.selectorTopic(selector_);
        r.data = data_;
        r.blockNumber = FORK_BLOCK;
        r.opCode = 2;
        r.blockHash = uint256(SUBMIT_BLOCK_HASH);
        r.txHash = uint256(SUBMIT_TX);
        r.logIndex = logIndex_;
    }

    /// @dev Delivers the callback through the mock proxy with the requested limit, with every account the exit
    ///      touches cold, as in its own transaction on chain (CallbackGas.t.sol does the same).
    function _deliverCallbackCold(MockSystem.Callback memory cb_) internal {
        address usdcImpl = address(uint160(uint256(vm.load(USDC, USDC_IMPL_SLOT))));
        vm.cool(address(exitC));
        vm.cool(VAULT);
        vm.cool(USDC);
        vm.cool(usdcImpl);
        vm.cool(ADAPTER);
        vm.cool(MORPHO);
        vm.cool(IRM);
        _drainLogs();
        proxy.deliverWithGas(cb_.recipient, cb_.payload, cb_.sender, cb_.gasLimit);
        console.log("callback gas limit", uint256(cb_.gasLimit));
        console.log("  forwarded", proxy.lastForwarded(), "used", proxy.lastUsed());
        console.log("  exit call ok", proxy.lastOk());
    }

    /// @dev The mock's forwardedGas against the replay's formula (limit - 23,340) x 63/64 - 150,000.
    function _checkForwardedAgainstReplayFormula(uint256 limit_) internal view {
        uint256 replay = (limit_ - 23_340) * 63 / 64 - 150_000;
        assertApproxEqAbs(proxy.lastForwarded(), replay, 3_000, "mock forwards what the replay formula gives");
    }

    function _endedOf(uint256 id_) internal returns (Ended memory e) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(exitC) || l.topics.length < 2 || uint256(l.topics[1]) != id_) continue;
            if (l.topics[0] == WATCH_ENDED_TOPIC) {
                e.found = true;
                e.origin = uint256(l.topics[2]);
                (e.outcome, e.reason, e.shares, e.assets) = abi.decode(l.data, (uint8, uint8, uint256, uint256));
            } else if (l.topics[0] == REDEEM_REVERTED_TOPIC) {
                e.redeemReverted = true;
                e.revertData = abi.decode(l.data, (bytes));
            }
        }
    }

    function _decodeExit(bytes memory payload_)
        internal
        pure
        returns (uint256 id, address vault, bytes memory data, uint256 origin, uint8 reason)
    {
        bytes memory args = new bytes(payload_.length - 4);
        for (uint256 k = 0; k < args.length; k++) {
            args[k] = payload_[k + 4];
        }
        (, id, vault, data, origin, reason) = abi.decode(args, (address, uint256, address, bytes, uint256, uint8));
    }

    function _status(uint256 id_) internal view returns (uint8 s) {
        (,,, s,,) = exitC.watches(id_);
    }

    function _rStatus(uint256 id_) internal view returns (uint8 s) {
        (,,, s,,) = reactive.watches(id_);
    }
}
