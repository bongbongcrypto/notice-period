// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { MockSystem } from "../mocks/MockSystem.sol";
import { MockCallbackProxy } from "../mocks/MockCallbackProxy.sol";
import { CronSource } from "../mocks/CronSource.sol";

/// @title Network
/// @notice Test harness that plays the Reactive Network inside one local EVM.
/// @dev Origin-chain logs get chainId 84532 (Base Sepolia); logs of the CRON source get block.chainid (the
///      reactive chain). Each pump round gives the logs of that round one synthetic transaction hash.
abstract contract Network is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant CRON_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant ORIGIN_CHAIN = 84532;
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant CRON10_TOPIC = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;

    MockSystem internal sys;
    MockCallbackProxy internal proxy;

    uint256 internal txCounter;
    uint256 internal callbacksDone;
    /// @dev Synthetic hash given to the logs of the first round of the last pump (the origin action).
    uint256 internal lastTxHash;

    function _setUpNetwork() internal {
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM_ADDR));
        vm.etch(CRON_ADDR, address(new CronSource()).code);
        proxy = new MockCallbackProxy();
        vm.recordLogs();
    }

    function _toRecord(Vm.Log memory l_, uint256 txHash_) internal view returns (IReactive.LogRecord memory r) {
        r.chainId = l_.emitter == CRON_ADDR ? block.chainid : ORIGIN_CHAIN;
        r.contractAddress = l_.emitter;
        uint256 n = l_.topics.length;
        if (n > 0) r.topic0 = uint256(l_.topics[0]);
        if (n > 1) r.topic1 = uint256(l_.topics[1]);
        if (n > 2) r.topic2 = uint256(l_.topics[2]);
        if (n > 3) r.topic3 = uint256(l_.topics[3]);
        r.data = l_.data;
        r.blockNumber = block.number;
        r.opCode = n;
        r.blockHash = uint256(blockhash(block.number > 0 ? block.number - 1 : 0));
        r.txHash = txHash_;
        r.logIndex = 0;
    }

    /// @notice Delivers recorded logs to `reactive_` through the mock system (subscriptions decide), then delivers
    ///         every callback the reactive side requested for the origin chain through the mock proxy. Repeats until
    ///         no new log appears.
    function _pump(address reactive_) internal {
        for (uint256 round = 0; round < 10; round++) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (logs.length == 0) return;
            txCounter += 1;
            uint256 txHash = uint256(keccak256(abi.encode("origin-tx", txCounter)));
            if (round == 0) lastTxHash = txHash;
            for (uint256 i = 0; i < logs.length; i++) {
                sys.deliver(reactive_, _toRecord(logs[i], txHash));
            }
            _deliverCallbacks();
        }
    }

    function _deliverCallbacks() internal {
        while (callbacksDone < sys.callbackCount()) {
            MockSystem.Callback memory cb = sys.callbackAt(callbacksDone);
            callbacksDone += 1;
            if (cb.chainId == ORIGIN_CHAIN) {
                proxy.deliver(cb.recipient, cb.payload, cb.sender);
            }
        }
    }

    /// @notice Emits one Cron10 tick from the CRON source; deliver it with _pump.
    function _tick() internal {
        CronSource(CRON_ADDR).tick();
    }

    function _drainLogs() internal {
        vm.getRecordedLogs();
    }
}
