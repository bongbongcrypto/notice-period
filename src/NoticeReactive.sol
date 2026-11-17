// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { NoticeKinds } from "./lib/NoticeKinds.sol";
import { INoticeExit } from "./lib/INoticeExit.sol";

/// @title NoticeReactive
/// @notice Reactive contract of Notice Period on Reactive Lasna. Learns about watches from the exit contract's
///         events, subscribes to the watched vaults at runtime, and asks for the exit callback when a watched kind
///         of change is scheduled ("leave now") or is still pending shortly before it can run ("leave if still
///         pending"). Rules: SPEC.md sections 6, 8 and 9.
/// @dev No owner and no setter: every address and limit is fixed at deployment. react() never reverts on a log it
///      does not want (a revert is billed); it counts the log and returns.
contract NoticeReactive is AbstractReactive {
    address public constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant WATCH_ARMED_TOPIC =
        uint256(keccak256("WatchArmed(uint256,address,address,uint8,uint8,uint256)"));
    uint256 public constant WATCH_CANCELLED_TOPIC = uint256(keccak256("WatchCancelled(uint256,address,address)"));

    uint256 public constant MAX_WATCHES_PER_VAULT = 3;
    uint256 public constant MAX_PENDING = 3;
    uint256 public constant MAX_DATA_LENGTH = 256;

    uint8 public constant MODE_NOW = 0;
    uint8 public constant MODE_IF_PENDING = 1;

    uint8 public constant ST_NONE = 0;
    uint8 public constant ST_ARMED = 1;
    uint8 public constant ST_EXITED = 2;
    uint8 public constant ST_CANCELLED = 3;
    uint8 public constant ST_REFUSED = 4;

    uint8 public constant R_SCHEDULED = 1;
    uint8 public constant R_DEADLINE = 2;
    uint8 public constant R_TOO_SOON = 3;
    uint8 public constant R_WAIT_TOO_LONG = 4;
    uint8 public constant R_DATA_TOO_LONG = 5;
    uint8 public constant R_PENDING_FULL = 6;
    uint8 public constant R_BUDGET = 7;

    uint8 public constant REFUSE_BAD_KINDS = 1;
    uint8 public constant REFUSE_BAD_MODE = 2;
    uint8 public constant REFUSE_TOO_MANY_WATCHES = 3;
    uint8 public constant REFUSE_VAULT_FULL = 4;

    struct Watch {
        address vault;
        uint8 kinds;
        uint8 mode;
        uint8 status;
        uint8 pendingCount;
        uint32 reactions;
    }

    struct Pending {
        bytes32 dataHash;
        uint64 executableAt;
        uint256 originTxHash;
        bytes data;
    }

    uint256 public immutable ORIGIN_CHAIN_ID;
    address public immutable EXIT;
    uint256 public immutable CRON_TOPIC;
    uint256 public immutable LEAD;
    uint256 public immutable MAX_WAIT;
    uint64 public immutable CALLBACK_GAS;
    uint256 public immutable MAX_ACTIVE;
    uint256 public immutable MAX_REACTIONS;

    mapping(uint256 watchId => Watch) public watches;
    mapping(uint256 watchId => Pending[3]) internal _pending;
    mapping(address vault => uint256[]) internal _vaultWatches;
    uint256[] internal _pendingWatches;
    mapping(bytes32 key => uint256) public filterRefs;

    uint256 public activeWatches;
    uint256 public ticks;
    uint256 public strayEvents;
    uint256 public unknownEvents;

    event WatchSubscribed(uint256 indexed watchId, address indexed vault, uint8 kinds, uint8 mode);
    event WatchRefused(uint256 indexed watchId, uint8 reason);
    event ChangeStored(uint256 indexed watchId, bytes32 indexed dataHash, uint256 executableAt, uint256 originTxHash);
    event ChangeRevoked(uint256 indexed watchId, bytes32 indexed dataHash);
    event ExitRequested(uint256 indexed watchId, uint256 indexed originTxHash, uint8 reason, bytes32 dataHash);
    event WatchClosed(uint256 indexed watchId, uint8 status);
    event FilterOn(bytes32 indexed key);
    event FilterOff(bytes32 indexed key);
    event StrayEvent(uint256 indexed chainId, address indexed source, uint256 indexed topic0, uint256 total);
    event UnknownEvent(uint256 indexed chainId, address indexed source, uint256 indexed topic0, uint256 total);

    /// @param originChainId_ Chain of the vaults and of the exit contract (84532 for Base Sepolia).
    /// @param exit_ The exit (callback) contract; its address is computed before it is deployed.
    /// @param cronTopic_ CRON event used while a change is stored (Cron10 topic for the demo).
    /// @param lead_ Seconds before executableAt at which a stored change is fled.
    /// @param maxWait_ Longest wait, in seconds, the contract pays ticks for; a later change is fled at once.
    /// @param callbackGas_ Gas limit of the exit callback (at least 100,000).
    /// @param maxActive_ Most watches armed at the same time.
    /// @param maxReactions_ Reaction budget of one watch (events about its vault plus ticks while it stores a change).
    constructor(
        uint256 originChainId_,
        address exit_,
        uint256 cronTopic_,
        uint256 lead_,
        uint256 maxWait_,
        uint64 callbackGas_,
        uint256 maxActive_,
        uint256 maxReactions_
    ) payable {
        ORIGIN_CHAIN_ID = originChainId_;
        EXIT = exit_;
        CRON_TOPIC = cronTopic_;
        LEAD = lead_;
        MAX_WAIT = maxWait_;
        CALLBACK_GAS = callbackGas_;
        MAX_ACTIVE = maxActive_;
        MAX_REACTIONS = maxReactions_;
        // Permanent filters on our own exit contract. Counted so they are never treated as strays.
        filterRefs[_key(originChainId_, exit_, WATCH_ARMED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE)] = 1;
        filterRefs[_key(originChainId_, exit_, WATCH_CANCELLED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE)]
        = 1;
        SYSTEM.subscribe(originChainId_, exit_, WATCH_ARMED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(
            originChainId_, exit_, WATCH_CANCELLED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Settles debt to the system contract from this contract's balance. Open to anyone.
    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------------
    // Entry point
    // ------------------------------------------------------------------

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.contractAddress == CRON_SOURCE) {
            if (log_.chainId == block.chainid && log_.topic0 == CRON_TOPIC) _onTick();
            else _unknown(log_);
            return;
        }
        if (log_.chainId != ORIGIN_CHAIN_ID) {
            _unknown(log_);
            return;
        }
        if (log_.contractAddress == EXIT) {
            if (log_.topic0 == WATCH_ARMED_TOPIC && log_.opCode == 4) _onArmed(log_);
            else if (log_.topic0 == WATCH_CANCELLED_TOPIC && log_.opCode == 4) _onCancelled(log_);
            else _unknown(log_);
            return;
        }
        if (log_.topic0 == NoticeKinds.SUBMIT_TOPIC && log_.opCode == 2) _onSubmit(log_);
        else if (log_.topic0 == NoticeKinds.REVOKE_TOPIC && log_.opCode == 3) _onRevoke(log_);
        else _unknown(log_);
    }

    // ------------------------------------------------------------------
    // Handlers
    // ------------------------------------------------------------------

    function _onArmed(LogRecord calldata log_) internal {
        uint256 id = log_.topic1;
        address vault = address(uint160(log_.topic3));
        (uint8 kinds, uint8 mode,) = abi.decode(log_.data, (uint8, uint8, uint256));
        Watch storage w = watches[id];
        if (w.status != ST_NONE) return; // the same event delivered twice
        uint8 refusal;
        if (kinds == 0 || kinds & ~NoticeKinds.ALL != 0) refusal = REFUSE_BAD_KINDS;
        else if (mode > MODE_IF_PENDING) refusal = REFUSE_BAD_MODE;
        else if (activeWatches >= MAX_ACTIVE) refusal = REFUSE_TOO_MANY_WATCHES;
        else if (_vaultWatches[vault].length >= MAX_WATCHES_PER_VAULT) refusal = REFUSE_VAULT_FULL;
        if (refusal != 0) {
            w.status = ST_REFUSED;
            emit WatchRefused(id, refusal);
            return;
        }
        w.vault = vault;
        w.kinds = kinds;
        w.mode = mode;
        w.status = ST_ARMED;
        activeWatches += 1;
        _vaultWatches[vault].push(id);
        bytes4[] memory sels = NoticeKinds.selectorsOf(kinds);
        for (uint256 i = 0; i < sels.length; i++) {
            _submitFilter(vault, sels[i], true);
        }
        if (mode == MODE_IF_PENDING) _revokeFilter(vault, true);
        emit WatchSubscribed(id, vault, kinds, mode);
    }

    function _onCancelled(LogRecord calldata log_) internal {
        uint256 id = log_.topic1;
        if (watches[id].status == ST_ARMED) _close(id, ST_CANCELLED);
    }

    function _onSubmit(LogRecord calldata log_) internal {
        address vault = log_.contractAddress;
        if (filterRefs[_submitKey(vault, log_.topic1)] == 0) {
            _stray(ORIGIN_CHAIN_ID, vault, NoticeKinds.SUBMIT_TOPIC, log_.topic1, REACTIVE_IGNORE);
            return;
        }
        uint8 kind = NoticeKinds.kindOf(NoticeKinds.topicSelector(log_.topic1));
        (bytes memory data, uint256 executableAt) = abi.decode(log_.data, (bytes, uint256));
        uint256[] memory ids = _vaultWatches[vault];
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            Watch storage w = watches[id];
            if (w.status != ST_ARMED || w.kinds & kind == 0) continue;
            if (w.mode == MODE_NOW) {
                _fire(id, data, log_.txHash, R_SCHEDULED);
                continue;
            }
            w.reactions += 1;
            uint8 reason = _reasonNotToWait(w, data.length, executableAt);
            if (reason != 0) _fire(id, data, log_.txHash, reason);
            else _store(id, w, data, executableAt, log_.txHash);
        }
    }

    function _onRevoke(LogRecord calldata log_) internal {
        address vault = log_.contractAddress;
        if (filterRefs[_revokeKey(vault)] == 0) {
            _stray(ORIGIN_CHAIN_ID, vault, NoticeKinds.REVOKE_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE);
            return;
        }
        bytes32 h = keccak256(abi.decode(log_.data, (bytes)));
        uint256[] memory ids = _vaultWatches[vault];
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            Watch storage w = watches[id];
            if (w.status != ST_ARMED || w.mode != MODE_IF_PENDING) continue;
            w.reactions += 1;
            if (_removePending(id, w, h)) emit ChangeRevoked(id, h);
        }
    }

    function _onTick() internal {
        if (filterRefs[_cronKey()] == 0) {
            _stray(block.chainid, CRON_SOURCE, CRON_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE);
            return;
        }
        ticks += 1;
        uint256[] memory ids = _pendingWatches;
        bool fired;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            Watch storage w = watches[id];
            if (w.status != ST_ARMED || w.pendingCount == 0) continue;
            w.reactions += 1;
            if (fired) continue; // at most one exit per tick (gas cap per reactive transaction)
            uint256 j = _earliest(id, w.pendingCount);
            Pending storage p = _pending[id][j];
            uint8 reason;
            if (w.reactions > MAX_REACTIONS) reason = R_BUDGET;
            else if (uint256(p.executableAt) <= block.timestamp + LEAD) reason = R_DEADLINE;
            if (reason != 0) {
                bytes memory data = p.data;
                uint256 originTxHash = p.originTxHash;
                _fire(id, data, originTxHash, reason);
                fired = true;
            }
        }
    }

    function _unknown(LogRecord calldata log_) internal {
        unknownEvents += 1;
        emit UnknownEvent(log_.chainId, log_.contractAddress, log_.topic0, unknownEvents);
    }

    /// @dev An event for a filter whose count is 0: the earlier unsubscribe did not take. Count it and send the exact
    ///      unsubscribe again (topic3 is always "any" in our filters).
    function _stray(uint256 chainId_, address source_, uint256 topic0_, uint256 topic1_, uint256 topic2_) internal {
        strayEvents += 1;
        emit StrayEvent(chainId_, source_, topic0_, strayEvents);
        SYSTEM.unsubscribe(chainId_, source_, topic0_, topic1_, topic2_, REACTIVE_IGNORE);
    }

    // ------------------------------------------------------------------
    // Watch state
    // ------------------------------------------------------------------

    function _reasonNotToWait(Watch storage w_, uint256 dataLength_, uint256 executableAt_)
        internal
        view
        returns (uint8)
    {
        if (w_.reactions > MAX_REACTIONS) return R_BUDGET;
        if (executableAt_ <= block.timestamp + LEAD) return R_TOO_SOON;
        if (executableAt_ > block.timestamp + MAX_WAIT) return R_WAIT_TOO_LONG;
        if (dataLength_ > MAX_DATA_LENGTH) return R_DATA_TOO_LONG;
        if (w_.pendingCount >= MAX_PENDING) return R_PENDING_FULL;
        return 0;
    }

    function _store(uint256 id_, Watch storage w_, bytes memory data_, uint256 executableAt_, uint256 originTxHash_)
        internal
    {
        bytes32 h = keccak256(data_);
        uint8 n = w_.pendingCount;
        for (uint256 j = 0; j < n; j++) {
            if (_pending[id_][j].dataHash == h) return; // the same change delivered twice
        }
        Pending storage p = _pending[id_][n];
        p.dataHash = h;
        p.executableAt = uint64(executableAt_); // executableAt_ <= now + MAX_WAIT, checked before
        p.originTxHash = originTxHash_;
        p.data = data_;
        w_.pendingCount = n + 1;
        if (n == 0) {
            _pendingWatches.push(id_);
            if (_pendingWatches.length == 1) _cronFilter(true);
        }
        emit ChangeStored(id_, h, executableAt_, originTxHash_);
    }

    function _removePending(uint256 id_, Watch storage w_, bytes32 h_) internal returns (bool) {
        uint8 n = w_.pendingCount;
        for (uint256 j = 0; j < n; j++) {
            if (_pending[id_][j].dataHash != h_) continue;
            uint256 last = n - 1;
            if (j != last) {
                Pending storage dst = _pending[id_][j];
                Pending storage src = _pending[id_][last];
                dst.dataHash = src.dataHash;
                dst.executableAt = src.executableAt;
                dst.originTxHash = src.originTxHash;
                dst.data = src.data;
            }
            delete _pending[id_][last];
            w_.pendingCount = uint8(last);
            if (last == 0) _dropPendingWatch(id_);
            return true;
        }
        return false;
    }

    function _earliest(uint256 id_, uint8 n_) internal view returns (uint256 best) {
        uint64 at = _pending[id_][0].executableAt;
        for (uint256 j = 1; j < n_; j++) {
            if (_pending[id_][j].executableAt < at) {
                at = _pending[id_][j].executableAt;
                best = j;
            }
        }
    }

    function _dropPendingWatch(uint256 id_) internal {
        uint256 len = _pendingWatches.length;
        for (uint256 i = 0; i < len; i++) {
            if (_pendingWatches[i] != id_) continue;
            _pendingWatches[i] = _pendingWatches[len - 1];
            _pendingWatches.pop();
            if (len == 1) _cronFilter(false);
            return;
        }
    }

    /// @dev Asks the network for the exit callback, then closes the watch.
    function _fire(uint256 id_, bytes memory data_, uint256 originTxHash_, uint8 reason_) internal {
        bytes memory payload = abi.encodeCall(INoticeExit.exit, (address(0), id_, data_, originTxHash_, reason_));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: ORIGIN_CHAIN_ID, recipient: EXIT, gasLimit: CALLBACK_GAS, payload: payload
            })
        );
        emit ExitRequested(id_, originTxHash_, reason_, keccak256(data_));
        _close(id_, ST_EXITED);
    }

    /// @dev Releases every filter the watch holds, forgets its stored changes and takes it off its vault's list.
    function _close(uint256 id_, uint8 status_) internal {
        Watch storage w = watches[id_];
        address vault = w.vault;
        bytes4[] memory sels = NoticeKinds.selectorsOf(w.kinds);
        for (uint256 i = 0; i < sels.length; i++) {
            _submitFilter(vault, sels[i], false);
        }
        if (w.mode == MODE_IF_PENDING) _revokeFilter(vault, false);
        uint8 n = w.pendingCount;
        if (n > 0) {
            for (uint256 j = 0; j < n; j++) {
                delete _pending[id_][j];
            }
            w.pendingCount = 0;
            _dropPendingWatch(id_);
        }
        uint256[] storage list = _vaultWatches[vault];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i] != id_) continue;
            list[i] = list[len - 1];
            list.pop();
            break;
        }
        activeWatches -= 1;
        w.status = status_;
        emit WatchClosed(id_, status_);
    }

    // ------------------------------------------------------------------
    // Reference-counted filters. Subscribe on 0 -> 1, unsubscribe on 1 -> 0, always with the same six arguments.
    // ------------------------------------------------------------------

    function _key(uint256 c_, address a_, uint256 t0_, uint256 t1_, uint256 t2_, uint256 t3_)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(c_, a_, t0_, t1_, t2_, t3_));
    }

    function _submitKey(address vault_, uint256 selectorTopic_) internal view returns (bytes32) {
        return _key(
            ORIGIN_CHAIN_ID, vault_, NoticeKinds.SUBMIT_TOPIC, selectorTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function _revokeKey(address vault_) internal view returns (bytes32) {
        return _key(ORIGIN_CHAIN_ID, vault_, NoticeKinds.REVOKE_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _cronKey() internal view returns (bytes32) {
        return _key(block.chainid, CRON_SOURCE, CRON_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _submitFilter(address vault_, bytes4 selector_, bool on_) internal {
        _filter(
            ORIGIN_CHAIN_ID,
            vault_,
            NoticeKinds.SUBMIT_TOPIC,
            NoticeKinds.selectorTopic(selector_),
            REACTIVE_IGNORE,
            on_
        );
    }

    function _revokeFilter(address vault_, bool on_) internal {
        _filter(ORIGIN_CHAIN_ID, vault_, NoticeKinds.REVOKE_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, on_);
    }

    function _cronFilter(bool on_) internal {
        _filter(block.chainid, CRON_SOURCE, CRON_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, on_);
    }

    function _filter(uint256 c_, address a_, uint256 t0_, uint256 t1_, uint256 t2_, bool on_) internal {
        bytes32 k = _key(c_, a_, t0_, t1_, t2_, REACTIVE_IGNORE);
        uint256 refs = filterRefs[k];
        if (on_) {
            filterRefs[k] = refs + 1;
            if (refs == 0) {
                SYSTEM.subscribe(c_, a_, t0_, t1_, t2_, REACTIVE_IGNORE);
                emit FilterOn(k);
            }
        } else {
            if (refs == 0) return;
            filterRefs[k] = refs - 1;
            if (refs == 1) {
                SYSTEM.unsubscribe(c_, a_, t0_, t1_, t2_, REACTIVE_IGNORE);
                emit FilterOff(k);
            }
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function vaultWatches(address vault_) external view returns (uint256[] memory) {
        return _vaultWatches[vault_];
    }

    function pendingWatchIds() external view returns (uint256[] memory) {
        return _pendingWatches;
    }

    function pendingOf(uint256 id_, uint256 j_) external view returns (Pending memory) {
        return _pending[id_][j_];
    }

    function submitFilterRefs(address vault_, bytes4 selector_) external view returns (uint256) {
        return filterRefs[_submitKey(vault_, NoticeKinds.selectorTopic(selector_))];
    }

    function revokeFilterRefs(address vault_) external view returns (uint256) {
        return filterRefs[_revokeKey(vault_)];
    }

    function cronFilterRefs() external view returns (uint256) {
        return filterRefs[_cronKey()];
    }
}
