// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Local-only stand-ins for the funding destinations, not their implementations. The dry run places them at the real
// addresses with anvil_setCode, which skips constructors, and sets every value below with anvil_setStorageAt.

/// @notice Like the Reactive faucet on Sepolia: accepts any non-zero value, keeps all of it, and only emits
/// PaymentRequest(receiver, min(value, max_payout)). It never refuses a large request; above the Lasna payer's
/// limit the whole request is lost.
contract MockFundFaucet {
    uint256 public max_payout; // slot 0

    event PaymentRequest(address indexed receiver, uint256 indexed amount);

    receive() external payable {
        _request(msg.sender, msg.value);
    }

    function request(address receiver) external payable {
        _request(receiver, msg.value);
    }

    function _request(address receiver, uint256 value) internal {
        uint256 amount = value > max_payout ? max_payout : value;
        require(amount > 0, "Just no");
        emit PaymentRequest(receiver, amount);
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

/// @notice The Lasna payer's public state, read before a faucet request (payouts happen in the harness).
contract MockFundPayer {
    address public l1; // slot 0
    uint256 public chainId; // slot 1
    uint256 public max_payout; // slot 2
    uint256 public exchangeRate; // slot 3
    uint256 public gasReserve; // slot 4
    bool public paused; // slot 5
}

/// @notice The Lasna system contract's debt ledger.
contract MockFundSystem {
    mapping(address => uint256) public debt; // slot 0
}
