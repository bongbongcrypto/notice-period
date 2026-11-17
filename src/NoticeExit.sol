// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { NoticeKinds } from "./lib/NoticeKinds.sol";
import { INoticeExit } from "./lib/INoticeExit.sol";

interface IVaultRegistry {
    function isVault(address vault_) external view returns (bool);
}

/// @dev The ERC-4626 and Vault V2 functions the exit contract calls.
interface IExitVault {
    function asset() external view returns (address);
    function balanceOf(address account_) external view returns (uint256);
    function allowance(address owner_, address spender_) external view returns (uint256);
    function executableAt(bytes calldata data_) external view returns (uint256);
    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets);
}

interface IBalanceOf {
    function balanceOf(address account_) external view returns (uint256);
}

/// @title NoticeExit
/// @notice Callback contract of Notice Period on the vault's chain. A depositor arms a watch on a vault and approves
///         this contract for vault shares; when the reactive contract asks for the exit, the shares are redeemed to
///         the depositor's own wallet. Rules: SPEC.md sections 4 to 6.
/// @dev No owner, no admin, no upgrade path. The receiver of a redeem is always the watch owner read from storage.
///      This contract never holds shares or tokens. Its native balance pays callback fees and can be pulled by the
///      callback proxy through pay() (sponsor library), so it only ever holds a small fee reserve.
contract NoticeExit is AbstractCallback, INoticeExit {
    uint8 public constant MODE_NOW = 0;
    uint8 public constant MODE_IF_PENDING = 1;
    /// @notice Reason code of NoticeReactive for "stored change due within LEAD" (its R_DEADLINE).
    uint8 public constant REASON_DEADLINE = 2;
    uint8 public constant DEFAULT_KINDS = NoticeKinds.DEFAULT;

    uint8 public constant STATUS_NONE = 0;
    uint8 public constant STATUS_ACTIVE = 1;
    uint8 public constant STATUS_CANCELLED = 2;
    uint8 public constant STATUS_ENDED = 3;

    uint8 public constant OUTCOME_REDEEMED = 0;
    uint8 public constant OUTCOME_NOTHING_TO_REDEEM = 1;
    uint8 public constant OUTCOME_CHANGE_NOT_PENDING = 2;
    uint8 public constant OUTCOME_REDEEM_FAILED = 3;

    struct Watch {
        address owner;
        uint8 kinds;
        uint8 mode;
        uint8 status;
        address vault;
        uint256 maxShares;
    }

    IVaultRegistry public immutable REGISTRY;
    uint256 public immutable MAX_ARMS_PER_ADDRESS_PER_DAY;
    uint256 public immutable MAX_ARMS_PER_DAY;

    uint256 public nextWatchId = 1;
    mapping(uint256 watchId => Watch) public watches;
    mapping(address owner => mapping(address vault => uint256 watchId)) public activeWatchOf;
    mapping(address owner => mapping(uint256 day => uint256)) public armsByAddressOnDay;
    mapping(uint256 day => uint256) public armsOnDay;
    uint256 private _entered;

    event WatchArmed(
        uint256 indexed watchId,
        address indexed owner,
        address indexed vault,
        uint8 kinds,
        uint8 mode,
        uint256 maxShares
    );
    event WatchCancelled(uint256 indexed watchId, address indexed owner, address indexed vault);
    event WatchEnded(
        uint256 indexed watchId,
        uint256 indexed originTxHash,
        uint8 outcome,
        uint8 reason,
        uint256 shares,
        uint256 assets
    );
    event RedeemReverted(uint256 indexed watchId, bytes reason);

    error Reentrancy();
    error UnknownVault(address vault);
    error NoKinds();
    error UnknownKinds(uint8 kinds);
    error BadMode(uint8 mode);
    error ZeroMaxShares();
    error NoShares();
    error NoAllowance();
    error AlreadyWatching(uint256 watchId);
    error DailyCapForAddress();
    error DailyCapReached();
    error NotWatchOwner();
    error WatchNotActive(uint256 watchId);
    error KindNotWatched(bytes4 selector);
    error AssetsNotReceived(uint256 expected, uint256 received);

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    /// @param callbackProxy_ Callback proxy of this chain (the only caller of exit).
    /// @param reactive_ Our reactive contract on Lasna (the only accepted requester).
    /// @param registry_ The factory that lists the vaults watches may be armed on.
    constructor(
        IPayable callbackProxy_,
        address reactive_,
        IVaultRegistry registry_,
        uint256 maxArmsPerAddressPerDay_,
        uint256 maxArmsPerDay_
    ) payable AbstractCallback(callbackProxy_, reactive_) {
        REGISTRY = registry_;
        MAX_ARMS_PER_ADDRESS_PER_DAY = maxArmsPerAddressPerDay_;
        MAX_ARMS_PER_DAY = maxArmsPerDay_;
    }

    // ------------------------------------------------------------------
    // Depositor actions
    // ------------------------------------------------------------------

    /// @notice Arms a watch over the caller's own shares of `vault_`.
    /// @param kinds_ Bit mask of kinds to flee (NoticeKinds); DEFAULT_KINDS = new adapter, shorter timelock, allocator.
    /// @param mode_ 0 = leave now, 1 = leave if still pending shortly before the change can run.
    /// @param maxShares_ Most shares one exit redeems; type(uint256).max for all.
    function arm(address vault_, uint8 kinds_, uint8 mode_, uint256 maxShares_)
        external
        nonReentrant
        returns (uint256 watchId)
    {
        if (!REGISTRY.isVault(vault_)) revert UnknownVault(vault_);
        if (kinds_ == 0) revert NoKinds();
        if (kinds_ & ~NoticeKinds.ALL != 0) revert UnknownKinds(kinds_);
        if (mode_ > MODE_IF_PENDING) revert BadMode(mode_);
        if (maxShares_ == 0) revert ZeroMaxShares();
        if (IExitVault(vault_).balanceOf(msg.sender) == 0) revert NoShares();
        if (IExitVault(vault_).allowance(msg.sender, address(this)) == 0) revert NoAllowance();
        uint256 existing = activeWatchOf[msg.sender][vault_];
        if (existing != 0) revert AlreadyWatching(existing);
        uint256 day = block.timestamp / 1 days;
        if (armsByAddressOnDay[msg.sender][day] >= MAX_ARMS_PER_ADDRESS_PER_DAY) revert DailyCapForAddress();
        if (armsOnDay[day] >= MAX_ARMS_PER_DAY) revert DailyCapReached();

        armsByAddressOnDay[msg.sender][day] += 1;
        armsOnDay[day] += 1;
        watchId = nextWatchId;
        nextWatchId = watchId + 1;
        watches[watchId] = Watch({
            owner: msg.sender, kinds: kinds_, mode: mode_, status: STATUS_ACTIVE, vault: vault_, maxShares: maxShares_
        });
        activeWatchOf[msg.sender][vault_] = watchId;
        emit WatchArmed(watchId, msg.sender, vault_, kinds_, mode_, maxShares_);
    }

    /// @notice Ends the caller's own watch. The reactive contract drops its subscriptions when it sees the event.
    function cancel(uint256 watchId_) external nonReentrant {
        Watch storage w = watches[watchId_];
        if (w.owner != msg.sender) revert NotWatchOwner();
        if (w.status != STATUS_ACTIVE) revert WatchNotActive(watchId_);
        w.status = STATUS_CANCELLED;
        activeWatchOf[w.owner][w.vault] = 0;
        emit WatchCancelled(watchId_, w.owner, w.vault);
    }

    // ------------------------------------------------------------------
    // Callback
    // ------------------------------------------------------------------

    /// @notice Redeems the watch owner's shares to the watch owner. Callable only through the callback proxy, on
    ///         request of our reactive contract.
    /// @param sender_ Overwritten by the network with the requesting reactive contract's address.
    /// @param data_ The scheduled call that triggered the exit: the whole call when it is at most 256 bytes, else its
    ///        selector alone. Its selector must be a watched kind.
    /// @param originTxHash_ Transaction hash of the vault's Submit, carried for the hash chain.
    /// @param reason_ Why the reactive contract asked (SPEC.md section 6). Recorded in WatchEnded; for a mode-1 watch,
    ///        only reason Deadline (2) makes this contract re-check that the change is still pending.
    function exit(address sender_, uint256 watchId_, bytes calldata data_, uint256 originTxHash_, uint8 reason_)
        external
        onlyServiceProvider
        onlyCallbackSender(sender_)
        nonReentrant
    {
        Watch storage w = watches[watchId_];
        if (w.status != STATUS_ACTIVE) revert WatchNotActive(watchId_);
        bytes4 selector = bytes4(data_);
        if (NoticeKinds.kindOf(selector) & w.kinds == 0) revert KindNotWatched(selector);

        address owner = w.owner;
        address vault = w.vault;
        // Effects before any external call: this watch can never exit twice.
        w.status = STATUS_ENDED;
        activeWatchOf[owner][vault] = 0;

        // Only a Deadline exit carries the full stored change and is re-checked; the other mode-1 reasons mean the
        // reactive contract chose to leave at once, and `data_` may then be the selector alone (SPEC.md section 6).
        if (w.mode == MODE_IF_PENDING && reason_ == REASON_DEADLINE && IExitVault(vault).executableAt(data_) == 0) {
            emit WatchEnded(watchId_, originTxHash_, OUTCOME_CHANGE_NOT_PENDING, reason_, 0, 0);
            return;
        }

        uint256 shares = _redeemable(vault, owner, w.maxShares);
        if (shares == 0) {
            emit WatchEnded(watchId_, originTxHash_, OUTCOME_NOTHING_TO_REDEEM, reason_, 0, 0);
            return;
        }
        _redeemToOwner(watchId_, originTxHash_, reason_, vault, owner, shares);
    }

    /// @dev min(maxShares, owner's share balance, owner's share allowance to this contract).
    function _redeemable(address vault_, address owner_, uint256 maxShares_) internal view returns (uint256 shares) {
        shares = maxShares_;
        uint256 balance = IExitVault(vault_).balanceOf(owner_);
        if (balance < shares) shares = balance;
        uint256 allowed = IExitVault(vault_).allowance(owner_, address(this));
        if (allowed < shares) shares = allowed;
    }

    /// @dev Redeems with receiver = owner = the watch owner, then checks the owner really received the assets.
    function _redeemToOwner(
        uint256 watchId_,
        uint256 originTxHash_,
        uint8 reason_,
        address vault_,
        address owner_,
        uint256 shares_
    ) internal {
        address asset = IExitVault(vault_).asset();
        uint256 before = IBalanceOf(asset).balanceOf(owner_);
        try IExitVault(vault_).redeem(shares_, owner_, owner_) returns (uint256 assets) {
            uint256 afterBalance = IBalanceOf(asset).balanceOf(owner_);
            uint256 received = afterBalance > before ? afterBalance - before : 0;
            if (received < assets) revert AssetsNotReceived(assets, received);
            emit WatchEnded(watchId_, originTxHash_, OUTCOME_REDEEMED, reason_, shares_, assets);
        } catch (bytes memory err) {
            emit RedeemReverted(watchId_, err);
            emit WatchEnded(watchId_, originTxHash_, OUTCOME_REDEEM_FAILED, reason_, 0, 0);
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function watchOf(uint256 watchId_) external view returns (Watch memory) {
        return watches[watchId_];
    }

    /// @notice Shares an exit would redeem for this watch right now (0 if the watch is not active).
    function redeemableShares(uint256 watchId_) external view returns (uint256 shares) {
        Watch storage w = watches[watchId_];
        if (w.status != STATUS_ACTIVE) return 0;
        shares = _redeemable(w.vault, w.owner, w.maxShares);
    }
}
