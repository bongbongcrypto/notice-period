// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title HelloCallback
/// @notice Destination side of the hello-world loop on Base Sepolia. Records each authenticated pong.
/// @dev Accepts a call only from the callback proxy (onlyServiceProvider) and only when the network-injected
///      first argument is our reactive contract (onlyCallbackSender).
contract HelloCallback is AbstractCallback {
    uint256 public pongs;
    uint256 public lastNonce;
    uint256 public lastOriginTxHash;

    event Ponged(uint256 indexed originTxHash, uint256 indexed nonce, address indexed pinger, address reactive);

    constructor(IPayable callbackProxy_, address reactive_) payable AbstractCallback(callbackProxy_, reactive_) { }

    function pong(address reactive_, uint256 originTxHash_, uint256 nonce_, address pinger_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        pongs += 1;
        lastNonce = nonce_;
        lastOriginTxHash = originTxHash_;
        emit Ponged(originTxHash_, nonce_, pinger_, reactive_);
    }
}
