// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title MockCallbackProxy
/// @notice Stand-in for the callback proxy on the destination chain.
/// @dev Does what the docs and the on-chain reading say the network does: overwrites the first argument of the
///      payload with the address of the reactive contract that requested the callback, then calls the recipient. A
///      failed call does not revert the delivery (the network emits CallbackFailure instead).
///
///      Gas (deliverWithGas with a non-zero limit) follows the real Base Sepolia proxy, measured 2026-11-18 (SPEC.md
///      section 12): the delivery transaction's gas limit is the callback's gasLimit; the stub delegates with 63/64
///      of what is left after the intrinsic gas; the implementation spends about 20,000 before the call, then
///      refuses with InsufficientGas when what is left is not above _extraGas + _maxChargeGas (130,000), else calls
///      the recipient with exactly what is left minus 130,000. The pre-call cost here is an upper bound of the
///      measured one, so the mock forwards a few hundred gas less than the real proxy, never more.
contract MockCallbackProxy {
    /// @dev Live values of the real proxy (`_extraGas()`, `_maxChargeGas()`), read 2026-11-18.
    uint256 public constant EXTRA_GAS = 80_000;
    uint256 public constant MAX_CHARGE_GAS = 50_000;
    /// @dev Upper bound of the implementation's work before the call: measured 19,746 + about 19 per payload word.
    uint256 public constant PRECALL_GAS = 20_000;
    uint256 public constant PRECALL_GAS_PER_WORD = 20;
    /// @dev The chain the real proxy serves (Base Sepolia); only used to size the delivery calldata.
    uint256 public constant DEST_CHAIN_ID = 84532;
    /// @dev `deliverCallback(uint8,bytes)`, the operator's entry point on the real proxy.
    bytes4 public constant DELIVER_SELECTOR = 0x8d1f0fa1;

    uint256 public delivered;
    uint256 public failed;
    bool public lastOk;
    bytes public lastReturn;
    /// @dev Gas the last limited delivery gave the recipient, and how much of it the recipient used.
    uint256 public lastForwarded;
    uint256 public lastUsed;

    /// @dev Debt per contract, set by a test; a payment from the contract settles it (the docs: "pay their debts").
    mapping(address account => uint256) public debt;

    event Delivered(address indexed recipient, address indexed requester, bool ok, bytes ret);

    /// @notice Same arguments as the real proxy's refusal: what was left before the call, and the 130,000 it keeps.
    error InsufficientGas(uint256 remaining, uint256 required);
    /// @notice The transaction carrying the delivery has less gas than its own intrinsic cost.
    error BelowIntrinsicGas(uint256 gasLimit, uint256 intrinsic);
    /// @notice The caller of the mock gave it less gas than the delivery needs (a relay or test setup error).
    error CallerGasTooLow(uint256 left, uint256 needed);

    receive() external payable {
        uint256 d = debt[msg.sender];
        debt[msg.sender] = msg.value >= d ? 0 : d - msg.value;
    }

    function setDebt(address account_, uint256 amount_) external {
        debt[account_] = amount_;
    }

    function deliver(address recipient_, bytes memory payload_, address requester_)
        public
        returns (bool ok, bytes memory ret)
    {
        return deliverWithGas(recipient_, payload_, requester_, 0);
    }

    /// @notice As deliver, with the callback's gas limit (0 = no limit, for unit tests of the callback logic only).
    ///         With a limit the recipient gets what the real proxy would give it (forwardedGas), and a limit too low
    ///         for the proxy's own share reverts the whole delivery as on chain.
    function deliverWithGas(address recipient_, bytes memory payload_, address requester_, uint256 gas_)
        public
        returns (bool ok, bytes memory ret)
    {
        require(payload_.length >= 36, "payload too short");
        assembly {
            // payload_ + 32 is the selector; the first argument word starts 4 bytes later.
            mstore(add(payload_, 36), requester_)
        }
        if (gas_ == 0) {
            (ok, ret) = recipient_.call(payload_);
        } else {
            uint256 fwd = forwardedGas(gas_, recipient_, payload_);
            // The real proxy's call gets exactly fwd; make sure this call can too (EIP-150 keeps 1/64 back).
            uint256 needed = fwd + fwd / 63 + 10_000;
            if (gasleft() < needed) revert CallerGasTooLow(gasleft(), needed);
            lastForwarded = fwd;
            uint256 g0 = gasleft();
            (ok, ret) = recipient_.call{ gas: fwd }(payload_);
            lastUsed = g0 - gasleft();
        }
        delivered += 1;
        if (!ok) failed += 1;
        lastOk = ok;
        lastReturn = ret;
        emit Delivered(recipient_, requester_, ok, ret);
    }

    /// @notice Gas the real proxy gives the recipient of a delivery with gas limit `gasLimit_` and this payload (the
    ///         first argument already set to the requester). Reverts as the real delivery would when the limit is
    ///         too low.
    function forwardedGas(uint256 gasLimit_, address recipient_, bytes memory payload_) public pure returns (uint256) {
        bytes memory input = abi.encodeWithSelector(
            DELIVER_SELECTOR,
            ISystemContract.CallbackVersion.V_1_0,
            abi.encode(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: DEST_CHAIN_ID, recipient: recipient_, gasLimit: uint64(gasLimit_), payload: payload_
                })
            )
        );
        uint256 intrinsic = 21_000;
        for (uint256 i = 0; i < input.length; i++) {
            intrinsic += input[i] == 0 ? 4 : 16;
        }
        if (gasLimit_ <= intrinsic) revert BelowIntrinsicGas(gasLimit_, intrinsic);
        uint256 atImpl = (gasLimit_ - intrinsic) * 63 / 64;
        uint256 pre = PRECALL_GAS + PRECALL_GAS_PER_WORD * ((payload_.length + 31) / 32);
        uint256 overhead = EXTRA_GAS + MAX_CHARGE_GAS;
        uint256 gasInit = atImpl > pre ? atImpl - pre : 0;
        if (gasInit <= overhead) revert InsufficientGas(gasInit, overhead);
        return gasInit - overhead;
    }

    /// @notice Same as deliver, but bubbles the recipient's revert so a test can match the exact error.
    function deliverOrRevert(address recipient_, bytes memory payload_, address requester_) external {
        (bool ok, bytes memory ret) = deliver(recipient_, payload_, requester_);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
