// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title NoticeKinds
/// @notice Kinds of curator change a depositor can flee, their Morpho Vault V2 selectors, and the V2 event topics.
/// @dev Selectors and topics are checked against keccak256 of the signatures and against DemoVault in the tests.
library NoticeKinds {
    uint8 internal constant ADAPTER = 1; // addAdapter(address)
    uint8 internal constant TIMELOCK_DOWN = 2; // decreaseTimelock(bytes4,uint256)
    uint8 internal constant ALLOCATOR = 4; // setIsAllocator(address,bool)
    uint8 internal constant CAP_UP = 8; // increaseAbsoluteCap(bytes,uint256), increaseRelativeCap(bytes,uint256)
    uint8 internal constant ALL = 15;
    /// @dev Rare kinds only; cap increases are opt-in (SPEC.md section 3).
    uint8 internal constant DEFAULT = 7;

    bytes4 internal constant ADD_ADAPTER = 0x60d54d41;
    bytes4 internal constant DECREASE_TIMELOCK = 0x5c1a1a4f;
    bytes4 internal constant INCREASE_TIMELOCK = 0x47966291;
    bytes4 internal constant SET_IS_ALLOCATOR = 0xb192a84a;
    bytes4 internal constant INCREASE_ABSOLUTE_CAP = 0xf6f98fd5;
    bytes4 internal constant INCREASE_RELATIVE_CAP = 0x2438525b;

    /// @dev Submit(bytes4 indexed selector, bytes data, uint256 executableAt)
    uint256 internal constant SUBMIT_TOPIC = 0x8b18afeb361b83b025999ed5b42f1d90c68aaa5a0fd49c015f04c3b8b81e80eb;
    /// @dev Revoke(address indexed sender, bytes4 indexed selector, bytes data)
    uint256 internal constant REVOKE_TOPIC = 0x70521cf6a7c2458c5ad406081ad7b3bc4afd31b01b586a157a9780fcee6a77cb;
    /// @dev Accept(bytes4 indexed selector, bytes data)
    uint256 internal constant ACCEPT_TOPIC = 0x29aa42fc192ff77ef42105abba283197ac841341e196e417a7fc2784cdc4e5fb;

    /// @notice The kind bit of a selector, or 0 if the selector is not a kind anyone can watch.
    function kindOf(bytes4 selector_) internal pure returns (uint8) {
        if (selector_ == ADD_ADAPTER) return ADAPTER;
        if (selector_ == DECREASE_TIMELOCK) return TIMELOCK_DOWN;
        if (selector_ == SET_IS_ALLOCATOR) return ALLOCATOR;
        if (selector_ == INCREASE_ABSOLUTE_CAP || selector_ == INCREASE_RELATIVE_CAP) return CAP_UP;
        return 0;
    }

    /// @notice The selectors covered by a kind mask, in a fixed order. At most five.
    function selectorsOf(uint8 kinds_) internal pure returns (bytes4[] memory out) {
        uint256 n;
        bytes4[5] memory tmp;
        if (kinds_ & ADAPTER != 0) tmp[n++] = ADD_ADAPTER;
        if (kinds_ & TIMELOCK_DOWN != 0) tmp[n++] = DECREASE_TIMELOCK;
        if (kinds_ & ALLOCATOR != 0) tmp[n++] = SET_IS_ALLOCATOR;
        if (kinds_ & CAP_UP != 0) {
            tmp[n++] = INCREASE_ABSOLUTE_CAP;
            tmp[n++] = INCREASE_RELATIVE_CAP;
        }
        out = new bytes4[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
    }

    /// @notice The topic value of an indexed bytes4: left-aligned in the 32-byte word.
    function selectorTopic(bytes4 selector_) internal pure returns (uint256) {
        return uint256(bytes32(selector_));
    }

    /// @notice The selector held in a topic word (inverse of selectorTopic).
    function topicSelector(uint256 topic_) internal pure returns (bytes4) {
        return bytes4(bytes32(topic_));
    }
}
