// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DemoVault } from "./DemoVault.sol";

/// @title DemoVaultFactory
/// @notice Creates one demo vault per call, with the caller as its curator, so one visitor's curator actions are
///         events of their own vault only. Keeps the list of vaults it made.
contract DemoVaultFactory {
    address public immutable ASSET;
    uint256 public immutable TIMELOCK;

    mapping(address vault => bool) public isVault;
    mapping(address curator => address) public lastVaultOf;
    uint256 public vaultCount;

    event VaultCreated(address indexed vault, address indexed curator);

    error ZeroAddress();

    constructor(address asset_, uint256 timelock_) {
        if (asset_ == address(0)) revert ZeroAddress();
        ASSET = asset_;
        TIMELOCK = timelock_;
    }

    function create() external returns (address vault) {
        vault = address(new DemoVault(ASSET, msg.sender, TIMELOCK));
        isVault[vault] = true;
        lastVaultOf[msg.sender] = vault;
        vaultCount += 1;
        emit VaultCreated(vault, msg.sender);
    }
}
