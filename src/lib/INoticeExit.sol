// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title INoticeExit
/// @notice The callback the reactive contract asks the network to deliver. The first argument is a placeholder
///         that the network overwrites with the requesting reactive contract's address.
interface INoticeExit {
    function exit(
        address sender_,
        uint256 watchId_,
        address vault_,
        bytes calldata data_,
        uint256 originTxHash_,
        uint8 reason_
    ) external;
}
