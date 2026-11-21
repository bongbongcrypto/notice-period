// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { NoticeKinds } from "../../src/lib/NoticeKinds.sol";

interface IMockAsset {
    function transfer(address to_, uint256 amount_) external returns (bool);
    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool);
}

/// @notice Stand-in for a Morpho Vault V2 with the parts MorphoVaultMaker and the arm path touch, and the same refusals
///         as the real one: setOwner, setCurator and setName are owner-only and immediate; submit is curator-only and
///         refuses the same bytes twice (DataAlreadyPending); a timelocked call runs only with the exact bytes
///         submitted, once its time has come, and never for an abdicated selector; decreaseTimelock waits for the
///         timelock of the selector it shortens; a timelock only goes up through increaseTimelock. Shares are 1:1
///         with assets. Written for the tests from Vault V2's documented behaviour; deployed only on the local chain of
///         the dry run, and there only when Morpho's real factory code cannot be fetched.
contract MockVaultV2 {
    address public owner;
    address public curator;
    address public immutable asset;
    string public name;
    mapping(bytes4 selector => uint256) public timelock;
    mapping(bytes4 selector => bool) public abdicated;
    mapping(bytes data => uint256) public executableAt;
    mapping(address account => uint256) public balanceOf;
    mapping(address holder => mapping(address spender => uint256)) public allowance;

    address public receiveSharesGate;
    address public sendSharesGate;
    address public receiveAssetsGate;
    address public sendAssetsGate;
    uint256 public performanceFee;
    uint256 public managementFee;

    event Submit(bytes4 indexed selector, bytes data, uint256 executableAt);

    error Unauthorized();
    error DataAlreadyPending();
    error DataNotTimelocked();
    error TimelockNotExpired();
    error Abdicated();
    error AutomaticallyTimelocked();
    error TimelockNotIncreasing();

    constructor(address owner_, address asset_) {
        owner = owner_;
        asset = asset_;
    }

    // ---------------------------------------------------------------- owner

    function setOwner(address newOwner_) external {
        if (msg.sender != owner) revert Unauthorized();
        owner = newOwner_;
    }

    function setCurator(address newCurator_) external {
        if (msg.sender != owner) revert Unauthorized();
        curator = newCurator_;
    }

    function setName(string memory newName_) external {
        if (msg.sender != owner) revert Unauthorized();
        name = newName_;
    }

    // ---------------------------------------------------------------- timelock

    function submit(bytes calldata data_) external {
        if (msg.sender != curator) revert Unauthorized();
        if (executableAt[data_] != 0) revert DataAlreadyPending();
        bytes4 selector = bytes4(data_);
        uint256 wait = selector == NoticeKinds.DECREASE_TIMELOCK ? timelock[bytes4(data_[4:8])] : timelock[selector];
        executableAt[data_] = block.timestamp + wait;
        emit Submit(selector, data_, executableAt[data_]);
    }

    function _timelocked() internal {
        uint256 at = executableAt[msg.data];
        if (at == 0) revert DataNotTimelocked();
        if (block.timestamp < at) revert TimelockNotExpired();
        if (abdicated[msg.sig]) revert Abdicated();
        executableAt[msg.data] = 0;
    }

    function increaseTimelock(bytes4 selector_, uint256 newDuration_) external {
        _timelocked();
        if (selector_ == NoticeKinds.DECREASE_TIMELOCK) revert AutomaticallyTimelocked();
        if (newDuration_ < timelock[selector_]) revert TimelockNotIncreasing();
        timelock[selector_] = newDuration_;
    }

    function abdicate(bytes4 selector_) external {
        _timelocked();
        abdicated[selector_] = true;
    }

    function setReceiveSharesGate(address newGate_) external {
        _timelocked();
        receiveSharesGate = newGate_;
    }

    function setSendSharesGate(address newGate_) external {
        _timelocked();
        sendSharesGate = newGate_;
    }

    function setReceiveAssetsGate(address newGate_) external {
        _timelocked();
        receiveAssetsGate = newGate_;
    }

    function setSendAssetsGate(address newGate_) external {
        _timelocked();
        sendAssetsGate = newGate_;
    }

    function setPerformanceFee(uint256 newFee_) external {
        _timelocked();
        performanceFee = newFee_;
    }

    function setManagementFee(uint256 newFee_) external {
        _timelocked();
        managementFee = newFee_;
    }

    // ---------------------------------------------------------------- shares (1:1, only what arm() and exit() use)

    function deposit(uint256 assets_, address onBehalf_) external returns (uint256 shares) {
        require(IMockAsset(asset).transferFrom(msg.sender, address(this), assets_), "transfer");
        balanceOf[onBehalf_] += assets_;
        shares = assets_;
    }

    function approve(address spender_, uint256 shares_) external returns (bool) {
        allowance[msg.sender][spender_] = shares_;
        return true;
    }

    /// @dev A caller other than `owner_` spends `owner_`'s allowance, as in ERC-4626.
    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets) {
        if (msg.sender != owner_) {
            require(allowance[owner_][msg.sender] >= shares_, "allowance");
            allowance[owner_][msg.sender] -= shares_;
        }
        require(balanceOf[owner_] >= shares_, "balance");
        balanceOf[owner_] -= shares_;
        assets = shares_;
        require(IMockAsset(asset).transfer(receiver_, assets), "transfer");
    }
}

/// @notice Stand-in for Morpho's VaultV2Factory: open to anyone, CREATE2 with the caller's salt (a second vault for the
///         same owner, asset and salt reverts, as with the real one), and the list of vaults it made. `unlist` and
///         `lastSalt` exist for the tests only.
contract MockVaultV2Factory {
    mapping(address account => bool) public isVaultV2;
    mapping(address owner => mapping(address asset => mapping(bytes32 salt => address))) public vaultV2;
    bytes32 public lastSalt;

    function createVaultV2(address owner_, address asset_, bytes32 salt_) external returns (address vault) {
        vault = address(new MockVaultV2{ salt: salt_ }(owner_, asset_));
        isVaultV2[vault] = true;
        vaultV2[owner_][asset_][salt_] = vault;
        lastSalt = salt_;
    }

    function unlist(address vault_) external {
        isVaultV2[vault_] = false;
    }
}
