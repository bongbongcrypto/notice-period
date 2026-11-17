// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockCallbackProxy
/// @notice Stand-in for the callback proxy on the destination chain.
/// @dev Does what the docs and the day-1 on-chain reading say the network does: overwrites the first argument of
///      the payload with the address of the reactive contract that requested the callback, then calls the
///      recipient. A failed call does not revert the delivery (the network emits CallbackFailure instead).
contract MockCallbackProxy {
    uint256 public delivered;
    uint256 public failed;
    bool public lastOk;
    bytes public lastReturn;

    /// @dev Debt per contract, set by a test; a payment from the contract settles it (the docs: "pay their debts").
    mapping(address account => uint256) public debt;

    event Delivered(address indexed recipient, address indexed requester, bool ok, bytes ret);

    receive() external payable {
        uint256 d = debt[msg.sender];
        debt[msg.sender] = msg.value >= d ? 0 : d - msg.value;
    }

    function setDebt(address account_, uint256 amount_) external {
        debt[account_] = amount_;
    }

    function deliver(address recipient_, bytes memory payload_, address requester_)
        public
        returns (bool ok, bytes memory ret)
    {
        return deliverWithGas(recipient_, payload_, requester_, 0);
    }

    /// @notice As deliver, with the callback's gas limit (0 = no limit). The network runs the callback with the
    ///         gas limit the reactive contract asked for; a callback that needs more fails.
    function deliverWithGas(address recipient_, bytes memory payload_, address requester_, uint256 gas_)
        public
        returns (bool ok, bytes memory ret)
    {
        require(payload_.length >= 36, "payload too short");
        assembly {
            // payload_ + 32 is the selector; the first argument word starts 4 bytes later.
            mstore(add(payload_, 36), requester_)
        }
        if (gas_ == 0) (ok, ret) = recipient_.call(payload_);
        else (ok, ret) = recipient_.call{ gas: gas_ }(payload_);
        delivered += 1;
        if (!ok) failed += 1;
        lastOk = ok;
        lastReturn = ret;
        emit Delivered(recipient_, requester_, ok, ret);
    }

    /// @notice Same as deliver, but bubbles the recipient's revert so a test can match the exact error.
    function deliverOrRevert(address recipient_, bytes memory payload_, address requester_) external {
        (bool ok, bytes memory ret) = deliver(recipient_, payload_, requester_);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
