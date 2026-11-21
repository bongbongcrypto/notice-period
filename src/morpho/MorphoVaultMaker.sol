// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMorphoVaultV2Factory, IMorphoVaultV2 } from "./IMorpho.sol";

/// @title MorphoVaultMaker
/// @notice One call makes a real Morpho Vault V2 through Morpho's own factory for the caller: a waiting period of
///         TIMELOCK seconds on new adapters, new allocators and cap increases, no share or asset gate and no fee ever
///         (those six setters are abdicated), then the caller as its curator and owner. It is also the list of vaults
///         NoticeExit accepts: isVault(v) is true only for a vault this maker made that Morpho's factory still lists.
///         Keeps the interface of DemoVaultFactory (create, lastVaultOf, vaultCount, VaultCreated), so the page and
///         the loop script make a vault the same way.
/// @dev Never holds tokens or shares. It owns a vault only inside the call that made it, and only acts on the vault it
///      made in that call. Morpho's factory is open to anyone, so a vault for (this maker, ASSET, salt) can be made
///      by someone else first; such a salt is skipped and that vault is never touched. The salt depends on the caller,
///      the block and a counter that moves on every try, so no salt can be taken in advance for a later block.
contract MorphoVaultMaker {
    /// @notice Salts tried per call before giving up.
    uint256 public constant MAX_SALT_TRIES = 16;
    string public constant VAULT_NAME = "Notice Period demo (Morpho Vault V2, test asset)";

    IMorphoVaultV2Factory public immutable FACTORY;
    address public immutable ASSET;
    /// @notice Waiting period, in seconds, set on addAdapter, setIsAllocator, increaseAbsoluteCap and
    ///         increaseRelativeCap in every vault this maker makes (decreaseTimelock of one of them waits as long).
    uint256 public immutable TIMELOCK;

    mapping(address vault => bool) public made;
    mapping(address curator => address) public lastVaultOf;
    uint256 public vaultCount;
    /// @notice Salts tried so far, all callers together.
    uint256 public saltTries;

    event VaultCreated(address indexed vault, address indexed curator);

    error NoFreeSalt();

    /// @param factory_ Morpho's VaultV2Factory on this chain.
    /// @param asset_ The asset of every vault made here (the demo dollar).
    /// @param timelock_ Waiting period in seconds for the four watched-kind changes above.
    constructor(IMorphoVaultV2Factory factory_, address asset_, uint256 timelock_) {
        FACTORY = factory_;
        ASSET = asset_;
        TIMELOCK = timelock_;
    }

    /// @notice Makes a Vault V2 of ASSET with Morpho's factory and hands it to the caller as curator and owner.
    function create() external returns (address vault) {
        bytes32 salt = _freeSalt();
        vault = FACTORY.createVaultV2(address(this), ASSET, salt);
        IMorphoVaultV2 v = IMorphoVaultV2(vault);
        v.setCurator(address(this));
        // A fresh vault has no waiting period on anything, so each change below is submitted and run in this call.
        _raiseTimelock(v, IMorphoVaultV2.addAdapter.selector);
        _raiseTimelock(v, IMorphoVaultV2.setIsAllocator.selector);
        _raiseTimelock(v, IMorphoVaultV2.increaseAbsoluteCap.selector);
        _raiseTimelock(v, IMorphoVaultV2.increaseRelativeCap.selector);
        _abdicate(v, IMorphoVaultV2.setReceiveSharesGate.selector);
        _abdicate(v, IMorphoVaultV2.setSendSharesGate.selector);
        _abdicate(v, IMorphoVaultV2.setReceiveAssetsGate.selector);
        _abdicate(v, IMorphoVaultV2.setSendAssetsGate.selector);
        _abdicate(v, IMorphoVaultV2.setPerformanceFee.selector);
        _abdicate(v, IMorphoVaultV2.setManagementFee.selector);
        v.setName(VAULT_NAME);
        v.setCurator(msg.sender);
        v.setOwner(msg.sender);
        made[vault] = true;
        lastVaultOf[msg.sender] = vault;
        vaultCount += 1;
        emit VaultCreated(vault, msg.sender);
    }

    /// @notice True only for a vault this maker made that Morpho's factory lists (NoticeExit's registry).
    function isVault(address vault_) external view returns (bool) {
        return made[vault_] && FACTORY.isVaultV2(vault_);
    }

    /// @dev The first salt keccak256(caller, block number, n), n the global try counter, for which Morpho's factory
    ///      holds no vault of (this maker, ASSET, salt). The counter moves on every try, taken or not.
    function _freeSalt() internal returns (bytes32 salt) {
        for (uint256 i = 0; i < MAX_SALT_TRIES; i++) {
            uint256 n = saltTries;
            saltTries = n + 1;
            salt = keccak256(abi.encode(msg.sender, block.number, n));
            if (FACTORY.vaultV2(address(this), ASSET, salt) == address(0)) return salt;
        }
        revert NoFreeSalt();
    }

    /// @dev Submits increaseTimelock(selector_, TIMELOCK) and runs it. The direct call sends exactly the bytes
    ///      submitted (standard ABI encoding of the same two arguments), which is what the vault's timelock checks.
    function _raiseTimelock(IMorphoVaultV2 v_, bytes4 selector_) internal {
        v_.submit(abi.encodeCall(IMorphoVaultV2.increaseTimelock, (selector_, TIMELOCK)));
        v_.increaseTimelock(selector_, TIMELOCK);
    }

    /// @dev Submits abdicate(selector_) and runs it: the vault then refuses `selector_` for good (Abdicated).
    function _abdicate(IMorphoVaultV2 v_, bytes4 selector_) internal {
        v_.submit(abi.encodeCall(IMorphoVaultV2.abdicate, (selector_)));
        v_.abdicate(selector_);
    }
}
