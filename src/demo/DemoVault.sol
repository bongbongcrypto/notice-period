// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { NoticeKinds } from "../lib/NoticeKinds.sol";

interface IDemoAsset {
    function transfer(address to_, uint256 amount_) external returns (bool);
    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool);
    function balanceOf(address account_) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title DemoVault
/// @notice Demo ERC-4626 vault of Notice Period (ours, test only). Its curator actions go through a timelock and emit
///         `Submit`, `Revoke` and `Accept` with exactly the shape of Morpho Vault V2's events. It is not Morpho's
///         vault: adapters and caps are only recorded, and the assets stay in this contract.
/// @dev Written for this project; it follows the V2 rules for submit, revoke, the timelock check and
///      decreaseTimelock, but none of V2's allocation, fees, gates or interest.
contract DemoVault {
    string public constant name = "Notice Period demo vault (ours, test only)";
    string public constant symbol = "npVAULT";
    uint256 internal constant WAD = 1e18;

    address public immutable asset;
    address public immutable curator;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    mapping(bytes4 selector => uint256) public timelock;
    mapping(bytes data => uint256) public executableAt;
    mapping(address => bool) public isAdapter;
    address[] public adapters;
    mapping(address => bool) public isAllocator;
    mapping(bytes32 id => uint256) public absoluteCap;
    mapping(bytes32 id => uint256) public relativeCap;

    // ERC-20 / ERC-4626
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    // Morpho Vault V2 shapes (topics checked in the tests)
    event Submit(bytes4 indexed selector, bytes data, uint256 executableAt);
    event Revoke(address indexed sender, bytes4 indexed selector, bytes data);
    event Accept(bytes4 indexed selector, bytes data);
    // Effects of curator actions
    event AddAdapter(address indexed account);
    event SetIsAllocator(address indexed account, bool newIsAllocator);
    event IncreaseTimelock(bytes4 indexed selector, uint256 newDuration);
    event DecreaseTimelock(bytes4 indexed selector, uint256 newDuration);
    event IncreaseAbsoluteCap(bytes32 indexed id, bytes idData, uint256 newAbsoluteCap);
    event IncreaseRelativeCap(bytes32 indexed id, bytes idData, uint256 newRelativeCap);

    error ZeroAddress();
    error Unauthorized();
    error DataAlreadyPending();
    error DataNotTimelocked();
    error TimelockNotExpired();
    error TimelockNotIncreasing();
    error TimelockNotDecreasing();
    error AutomaticallyTimelocked();
    error AbsoluteCapNotIncreasing();
    error RelativeCapNotIncreasing();
    error RelativeCapAboveOne();
    error ZeroShares();
    error ZeroAssets();
    error InsufficientBalance();
    error InsufficientAllowance();
    error TransferFailed();

    /// @param asset_ Token held by the vault.
    /// @param curator_ The only address that can submit and revoke changes.
    /// @param timelock_ Starting timelock in seconds for every curator selector.
    constructor(address asset_, address curator_, uint256 timelock_) {
        if (asset_ == address(0) || curator_ == address(0)) revert ZeroAddress();
        asset = asset_;
        curator = curator_;
        decimals = _readDecimals(asset_);
        timelock[NoticeKinds.ADD_ADAPTER] = timelock_;
        timelock[NoticeKinds.SET_IS_ALLOCATOR] = timelock_;
        timelock[NoticeKinds.INCREASE_ABSOLUTE_CAP] = timelock_;
        timelock[NoticeKinds.INCREASE_RELATIVE_CAP] = timelock_;
        timelock[NoticeKinds.INCREASE_TIMELOCK] = timelock_;
    }

    // ------------------------------------------------------------------
    // Timelock (V2 rules)
    // ------------------------------------------------------------------

    function submit(bytes calldata data_) external {
        if (msg.sender != curator) revert Unauthorized();
        if (executableAt[data_] != 0) revert DataAlreadyPending();
        bytes4 selector = bytes4(data_);
        // A shorter timelock waits for the current timelock of the selector it shortens.
        uint256 delay =
            selector == NoticeKinds.DECREASE_TIMELOCK ? timelock[bytes4(data_[4:8])] : timelock[selector];
        uint256 at = block.timestamp + delay;
        executableAt[data_] = at;
        emit Submit(selector, data_, at);
    }

    function revoke(bytes calldata data_) external {
        if (msg.sender != curator) revert Unauthorized();
        if (executableAt[data_] == 0) revert DataNotTimelocked();
        executableAt[data_] = 0;
        emit Revoke(msg.sender, bytes4(data_), data_);
    }

    function _timelocked() internal {
        uint256 at = executableAt[msg.data];
        if (at == 0) revert DataNotTimelocked();
        if (block.timestamp < at) revert TimelockNotExpired();
        executableAt[msg.data] = 0;
        emit Accept(bytes4(msg.data), msg.data);
    }

    // ------------------------------------------------------------------
    // Curator actions: anyone can run them once submitted and due
    // ------------------------------------------------------------------

    function addAdapter(address account_) external {
        _timelocked();
        if (!isAdapter[account_]) {
            isAdapter[account_] = true;
            adapters.push(account_);
        }
        emit AddAdapter(account_);
    }

    function setIsAllocator(address account_, bool newIsAllocator_) external {
        _timelocked();
        isAllocator[account_] = newIsAllocator_;
        emit SetIsAllocator(account_, newIsAllocator_);
    }

    function increaseTimelock(bytes4 selector_, uint256 newDuration_) external {
        _timelocked();
        if (selector_ == NoticeKinds.DECREASE_TIMELOCK) revert AutomaticallyTimelocked();
        if (newDuration_ < timelock[selector_]) revert TimelockNotIncreasing();
        timelock[selector_] = newDuration_;
        emit IncreaseTimelock(selector_, newDuration_);
    }

    function decreaseTimelock(bytes4 selector_, uint256 newDuration_) external {
        _timelocked();
        if (selector_ == NoticeKinds.DECREASE_TIMELOCK) revert AutomaticallyTimelocked();
        if (newDuration_ > timelock[selector_]) revert TimelockNotDecreasing();
        timelock[selector_] = newDuration_;
        emit DecreaseTimelock(selector_, newDuration_);
    }

    function increaseAbsoluteCap(bytes memory idData_, uint256 newAbsoluteCap_) external {
        _timelocked();
        bytes32 id = keccak256(idData_);
        if (newAbsoluteCap_ < absoluteCap[id]) revert AbsoluteCapNotIncreasing();
        absoluteCap[id] = newAbsoluteCap_;
        emit IncreaseAbsoluteCap(id, idData_, newAbsoluteCap_);
    }

    function increaseRelativeCap(bytes memory idData_, uint256 newRelativeCap_) external {
        _timelocked();
        bytes32 id = keccak256(idData_);
        if (newRelativeCap_ > WAD) revert RelativeCapAboveOne();
        if (newRelativeCap_ < relativeCap[id]) revert RelativeCapNotIncreasing();
        relativeCap[id] = newRelativeCap_;
        emit IncreaseRelativeCap(id, idData_, newRelativeCap_);
    }

    function adaptersLength() external view returns (uint256) {
        return adapters.length;
    }

    // ------------------------------------------------------------------
    // ERC-4626. Rounding always favours the vault:
    // deposit rounds shares down, mint rounds assets up, withdraw rounds shares up, redeem rounds assets down.
    // One virtual share and one virtual asset: shares = assets * (supply + 1) / (totalAssets + 1).
    // ------------------------------------------------------------------

    function totalAssets() public view returns (uint256) {
        return IDemoAsset(asset).balanceOf(address(this));
    }

    function convertToShares(uint256 assets_) public view returns (uint256) {
        return _toShares(assets_, false);
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        return _toAssets(shares_, false);
    }

    function previewDeposit(uint256 assets_) public view returns (uint256) {
        return _toShares(assets_, false);
    }

    function previewMint(uint256 shares_) public view returns (uint256) {
        return _toAssets(shares_, true);
    }

    function previewWithdraw(uint256 assets_) public view returns (uint256) {
        return _toShares(assets_, true);
    }

    function previewRedeem(uint256 shares_) public view returns (uint256) {
        return _toAssets(shares_, false);
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner_) external view returns (uint256) {
        return _toAssets(balanceOf[owner_], false);
    }

    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf[owner_];
    }

    function deposit(uint256 assets_, address receiver_) external returns (uint256 shares) {
        shares = previewDeposit(assets_);
        if (shares == 0) revert ZeroShares();
        _pull(msg.sender, assets_);
        _mint(receiver_, shares);
        emit Deposit(msg.sender, receiver_, assets_, shares);
    }

    function mint(uint256 shares_, address receiver_) external returns (uint256 assets) {
        if (shares_ == 0) revert ZeroShares();
        assets = previewMint(shares_);
        _pull(msg.sender, assets);
        _mint(receiver_, shares_);
        emit Deposit(msg.sender, receiver_, assets, shares_);
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) external returns (uint256 shares) {
        if (assets_ == 0) revert ZeroAssets();
        shares = previewWithdraw(assets_);
        _spendAllowance(owner_, shares);
        _burn(owner_, shares);
        _push(receiver_, assets_);
        emit Withdraw(msg.sender, receiver_, owner_, assets_, shares);
    }

    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets) {
        assets = previewRedeem(shares_);
        if (assets == 0) revert ZeroAssets();
        _spendAllowance(owner_, shares_);
        _burn(owner_, shares_);
        _push(receiver_, assets);
        emit Withdraw(msg.sender, receiver_, owner_, assets, shares_);
    }

    // ------------------------------------------------------------------
    // ERC-20 shares
    // ------------------------------------------------------------------

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _move(msg.sender, to_, amount_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        _spendAllowance(from_, amount_);
        _move(from_, to_, amount_);
        return true;
    }

    // ------------------------------------------------------------------
    // internals
    // ------------------------------------------------------------------

    function _toShares(uint256 assets_, bool roundUp_) internal view returns (uint256) {
        return _mulDiv(assets_, totalSupply + 1, totalAssets() + 1, roundUp_);
    }

    function _toAssets(uint256 shares_, bool roundUp_) internal view returns (uint256) {
        return _mulDiv(shares_, totalAssets() + 1, totalSupply + 1, roundUp_);
    }

    function _mulDiv(uint256 x_, uint256 y_, uint256 d_, bool roundUp_) internal pure returns (uint256 z) {
        z = (x_ * y_) / d_;
        if (roundUp_ && mulmod(x_, y_, d_) != 0) z += 1;
    }

    /// @dev Spends `shares_` of `owner_`'s allowance to msg.sender, unless msg.sender is the owner. An allowance of
    ///      type(uint256).max is never reduced.
    function _spendAllowance(address owner_, uint256 shares_) internal {
        if (msg.sender == owner_) return;
        uint256 allowed = allowance[owner_][msg.sender];
        if (allowed == type(uint256).max) return;
        if (allowed < shares_) revert InsufficientAllowance();
        allowance[owner_][msg.sender] = allowed - shares_;
    }

    function _mint(address to_, uint256 shares_) internal {
        if (to_ == address(0)) revert ZeroAddress();
        totalSupply += shares_;
        balanceOf[to_] += shares_;
        emit Transfer(address(0), to_, shares_);
    }

    function _burn(address from_, uint256 shares_) internal {
        uint256 bal = balanceOf[from_];
        if (bal < shares_) revert InsufficientBalance();
        unchecked {
            balanceOf[from_] = bal - shares_;
            totalSupply -= shares_;
        }
        emit Transfer(from_, address(0), shares_);
    }

    function _move(address from_, address to_, uint256 shares_) internal {
        if (to_ == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from_];
        if (bal < shares_) revert InsufficientBalance();
        unchecked {
            balanceOf[from_] = bal - shares_;
        }
        balanceOf[to_] += shares_;
        emit Transfer(from_, to_, shares_);
    }

    function _pull(address from_, uint256 amount_) internal {
        _callToken(abi.encodeCall(IDemoAsset.transferFrom, (from_, address(this), amount_)));
    }

    function _push(address to_, uint256 amount_) internal {
        if (to_ == address(0)) revert ZeroAddress();
        _callToken(abi.encodeCall(IDemoAsset.transfer, (to_, amount_)));
    }

    /// @dev Bubbles the token's own revert data so callers see the exact error.
    function _callToken(bytes memory call_) internal {
        (bool ok, bytes memory ret) = asset.call(call_);
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            revert TransferFailed();
        }
        if (ret.length > 0 && !abi.decode(ret, (bool))) revert TransferFailed();
    }

    function _readDecimals(address asset_) internal view returns (uint8) {
        (bool ok, bytes memory ret) = asset_.staticcall(abi.encodeCall(IDemoAsset.decimals, ()));
        if (ok && ret.length >= 32) {
            uint256 d = abi.decode(ret, (uint256));
            if (d <= type(uint8).max) return uint8(d);
        }
        return 18;
    }
}
