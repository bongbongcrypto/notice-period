// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title HelloOrigin
/// @notice Origin side of the hello-world loop on Base Sepolia. Anyone can ping.
contract HelloOrigin {
    event Ping(address indexed sender, uint256 indexed nonce);

    function ping(uint256 nonce_) external {
        emit Ping(msg.sender, nonce_);
    }
}
