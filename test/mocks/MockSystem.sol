// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title MockSystem
/// @notice Stand-in for the Reactive system contract (etched at 0x8888...8888 in tests and in the anvil dry run).
/// @dev Written from the documented behaviour, not from the network's code:
///      - a subscription is a set of six criteria; chainId 0 or contract 0 means any, REACTIVE_IGNORE means any topic;
///      - identical subscriptions behave as one;
///      - unsubscribe removes only an exact match of all six criteria and is silent otherwise;
///      - a log reaches react() only if it matches an active subscription of that contract;
///      - a revert inside react() is caught (the network bills it and emits ReactiveContractReverted).
contract MockSystem {
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    struct Sub {
        address subscriber;
        uint256 chainId;
        address source;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    struct Callback {
        address sender;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Sub[] internal _subs;
    mapping(bytes32 key => uint256 indexPlusOne) internal _index;
    Callback[] internal _callbacks;

    uint256 public subscribeCalls;
    uint256 public unsubscribeCalls;
    uint256 public silentMisses;
    uint256 public reverts;
    uint256 public delivered;

    event CallbackRequest(
        uint256 indexed chainId,
        address indexed sender,
        address indexed recipient,
        ISystemContract.CallbackVersion version,
        bytes configuration
    );
    event ReactiveContractReverted(address indexed target, bytes reason);

    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256 chainId_, address source_, uint256 t0_, uint256 t1_, uint256 t2_, uint256 t3_)
        external
    {
        subscribeCalls += 1;
        bytes32 key = keccak256(abi.encode(msg.sender, chainId_, source_, t0_, t1_, t2_, t3_));
        uint256 i = _index[key];
        if (i == 0) {
            _subs.push(Sub(msg.sender, chainId_, source_, t0_, t1_, t2_, t3_, true));
            _index[key] = _subs.length;
        } else {
            _subs[i - 1].active = true;
        }
    }

    function unsubscribe(uint256 chainId_, address source_, uint256 t0_, uint256 t1_, uint256 t2_, uint256 t3_)
        external
    {
        unsubscribeCalls += 1;
        bytes32 key = keccak256(abi.encode(msg.sender, chainId_, source_, t0_, t1_, t2_, t3_));
        uint256 i = _index[key];
        if (i == 0 || !_subs[i - 1].active) {
            silentMisses += 1;
            return;
        }
        _subs[i - 1].active = false;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) public {
        _callbacks.push(Callback(msg.sender, config_.chainId, config_.recipient, config_.gasLimit, config_.payload));
        emit CallbackRequest(
            config_.chainId, msg.sender, config_.recipient, ISystemContract.CallbackVersion.V_1_0, abi.encode(config_)
        );
    }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory config_) external {
        requestCallbackV_1_0(abi.decode(config_, (ISystemContract.CallbackConfiguration_V_1_0)));
    }

    // ---- views for tests ----

    function isActive(
        address subscriber_,
        uint256 chainId_,
        address source_,
        uint256 t0_,
        uint256 t1_,
        uint256 t2_,
        uint256 t3_
    ) external view returns (bool) {
        uint256 i = _index[keccak256(abi.encode(subscriber_, chainId_, source_, t0_, t1_, t2_, t3_))];
        return i != 0 && _subs[i - 1].active;
    }

    function activeCount(address subscriber_) external view returns (uint256 n) {
        for (uint256 i = 0; i < _subs.length; i++) {
            if (_subs[i].active && _subs[i].subscriber == subscriber_) n++;
        }
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 i_) external view returns (Callback memory) {
        return _callbacks[i_];
    }

    function matches(address subscriber_, IReactive.LogRecord calldata log_) public view returns (bool) {
        for (uint256 i = 0; i < _subs.length; i++) {
            Sub storage s = _subs[i];
            if (!s.active || s.subscriber != subscriber_) continue;
            if (s.chainId != 0 && s.chainId != log_.chainId) continue;
            if (s.source != address(0) && s.source != log_.contractAddress) continue;
            if (s.topic0 != IGNORE && s.topic0 != log_.topic0) continue;
            if (s.topic1 != IGNORE && s.topic1 != log_.topic1) continue;
            if (s.topic2 != IGNORE && s.topic2 != log_.topic2) continue;
            if (s.topic3 != IGNORE && s.topic3 != log_.topic3) continue;
            return true;
        }
        return false;
    }

    // ---- delivery ----

    /// @notice Delivers the log only if the target holds a matching active subscription.
    function deliver(address target_, IReactive.LogRecord calldata log_) external returns (bool) {
        if (!matches(target_, log_)) return false;
        _call(target_, log_);
        return true;
    }

    /// @notice Delivers the log whatever the subscriptions say: models a stray event after a silent unsubscribe.
    function forceDeliver(address target_, IReactive.LogRecord calldata log_) external {
        _call(target_, log_);
    }

    function _call(address target_, IReactive.LogRecord calldata log_) internal {
        delivered += 1;
        (bool ok, bytes memory ret) = target_.call(abi.encodeCall(IReactive.react, (log_)));
        if (!ok) {
            reverts += 1;
            emit ReactiveContractReverted(target_, ret);
        }
    }
}
