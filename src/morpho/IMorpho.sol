// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IMorphoVaultV2Factory
/// @notice The functions of Morpho's VaultV2Factory that MorphoVaultMaker calls, declared from its public ABI.
interface IMorphoVaultV2Factory {
    function isVaultV2(address account_) external view returns (bool);
    function vaultV2(address owner_, address asset_, bytes32 salt_) external view returns (address);
    function createVaultV2(address owner_, address asset_, bytes32 salt_) external returns (address);
}

/// @title IMorphoVaultV2
/// @notice The owner and curator functions of a Morpho Vault V2 that MorphoVaultMaker calls, declared from its public
///         ABI. The four timelocked changes and the six setters at the end are declared only for their selectors
///         (MorphoVaultMaker raises the waiting period of the four and abdicates the six).
interface IMorphoVaultV2 {
    function owner() external view returns (address);
    function curator() external view returns (address);
    function timelock(bytes4 selector_) external view returns (uint256);
    function abdicated(bytes4 selector_) external view returns (bool);

    function setOwner(address newOwner_) external;
    function setCurator(address newCurator_) external;
    function setName(string memory newName_) external;
    function submit(bytes calldata data_) external;
    function increaseTimelock(bytes4 selector_, uint256 newDuration_) external;
    function abdicate(bytes4 selector_) external;

    function addAdapter(address account_) external;
    function setIsAllocator(address account_, bool newIsAllocator_) external;
    function increaseAbsoluteCap(bytes memory idData_, uint256 newAbsoluteCap_) external;
    function increaseRelativeCap(bytes memory idData_, uint256 newRelativeCap_) external;

    function setReceiveSharesGate(address newReceiveSharesGate_) external;
    function setSendSharesGate(address newSendSharesGate_) external;
    function setReceiveAssetsGate(address newReceiveAssetsGate_) external;
    function setSendAssetsGate(address newSendAssetsGate_) external;
    function setPerformanceFee(uint256 newPerformanceFee_) external;
    function setManagementFee(uint256 newManagementFee_) external;
}
