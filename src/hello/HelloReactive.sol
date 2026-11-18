// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { HelloCallback } from "./HelloCallback.sol";

/// @title HelloReactive
/// @notice Reactive side of the hello-world loop on Lasna: a Ping on the origin chain becomes a pong callback.
contract HelloReactive is AbstractReactive {
    /// @dev The delivery's whole gas limit. The Base Sepolia proxy keeps about 150,000 plus 1/64 of it, so pong (about
    ///      70,000) gets about 220,000. At 200,000 it got 23,253 and failed on chain (SPEC.md section 12).
    uint64 public constant CALLBACK_GAS = 400_000;
    /// @dev Equal to HelloOrigin.Ping.selector (checked in the tests).
    uint256 public constant PING_TOPIC = uint256(keccak256("Ping(address,uint256)"));

    uint256 public immutable ORIGIN_CHAIN_ID;
    address public immutable ORIGIN;
    address public immutable CALLBACK;

    uint256 public relayed;
    uint256 public ignored;

    event Relayed(uint256 indexed originTxHash, uint256 indexed nonce, address indexed pinger);
    event Ignored(uint256 indexed chainId, address indexed source, uint256 indexed topic0);

    constructor(uint256 originChainId_, address origin_, address callback_) payable {
        ORIGIN_CHAIN_ID = originChainId_;
        ORIGIN = origin_;
        CALLBACK = callback_;
        SYSTEM.subscribe(originChainId_, origin_, PING_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Settles debt to the system contract from this contract's balance. Open to anyone.
    function coverDebt() external {
        _coverDebt();
    }

    function react(LogRecord calldata log_) external onlySystem {
        // A revert is billed, so an unwanted log is counted and dropped.
        if (
            log_.chainId != ORIGIN_CHAIN_ID || log_.contractAddress != ORIGIN || log_.topic0 != PING_TOPIC
                || log_.opCode != 3
        ) {
            ignored += 1;
            emit Ignored(log_.chainId, log_.contractAddress, log_.topic0);
            return;
        }
        address pinger = address(uint160(log_.topic1));
        uint256 nonce = log_.topic2;
        bytes memory payload = abi.encodeCall(HelloCallback.pong, (address(0), log_.txHash, nonce, pinger));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: ORIGIN_CHAIN_ID, recipient: CALLBACK, gasLimit: CALLBACK_GAS, payload: payload
            })
        );
        relayed += 1;
        emit Relayed(log_.txHash, nonce, pinger);
    }
}
