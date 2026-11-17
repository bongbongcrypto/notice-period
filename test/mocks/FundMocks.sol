// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Local-only stand-ins for the two Sepolia funding destinations, not their implementations.
contract MockFundFaucet {
    uint256 public requests;

    function request(address receiver) external payable {
        require(receiver == msg.sender && msg.value > 0 && msg.value <= 5 ether, "bad request");
        ++requests;
    }
}

contract MockFundBridge {
    uint256 public deposits;

    function depositETH(uint32 minGasLimit, bytes calldata extraData) external payable {
        require(minGasLimit == 200000 && extraData.length == 0 && msg.value > 0, "bad deposit");
        ++deposits;
    }
}

contract MockFundRevertingFaucet {
    function request(address) external payable {
        revert("faucet unavailable");
    }
}
