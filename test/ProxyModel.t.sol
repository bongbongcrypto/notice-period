// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { MockCallbackProxy } from "./mocks/MockCallbackProxy.sol";
import { HelloCallback } from "../src/hello/HelloCallback.sol";

/// @notice Ties the mock proxy's gas model to the real Base Sepolia callback proxy
///         (0x476F44b11F5C942c58f4c8E3d0300E5710743585, implementation 0x49E4AC6954E39c006B0a31955A26a9655c7CE059).
/// @dev Every number below was read on 2026-11-18 with eth_simulateV1 on sepolia.base.org: the operator's real
///      deliverCallback calldata (or the same encoding with another payload) sent to the proxy at the given gas limit,
///      with the recipient's code replaced by a probe that logs gasleft() on entry. "Forwarded" is that value + 2.
///      The hello points replay delivery 0xd6559e81729f0ea110ff4ea560450543225402f08d9c2cae433e618fd9a1bc89 (state of
///      block 60093476); the 0xff points use block 60194829. The mock may forward less than the real proxy (it is a
///      bound), never more, and it must refuse wherever the real proxy refused.
contract ProxyModelTest is Test {
    MockCallbackProxy internal proxy;

    /// @dev HelloCallback of the first testnet deployment, the recipient in every measured point.
    address internal constant RECIPIENT = 0x54f731519464f60Eaf3F609fFA9a8B1F5Db06005;
    /// @dev HelloReactive of the first testnet deployment, the requester the network injected.
    address internal constant REQUESTER = 0xf58b0e6E91C08F05B30cB790927Ba6321D88426b;
    /// @dev The mock bound stays within this much below the measured value.
    uint256 internal constant SLACK = 600;

    function setUp() public {
        proxy = new MockCallbackProxy();
    }

    /// @dev The pong payload of the first hello loop, exactly as delivered (first argument already injected).
    function _helloPayload() internal pure returns (bytes memory) {
        return abi.encodeCall(
            HelloCallback.pong,
            (
                REQUESTER,
                0x55c88b941dc7ed936803f9b8745a392706716a163d177b12b91f2fef58e9975c,
                0x6afc9e92,
                0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4
            )
        );
    }

    /// @dev n bytes of 0xff, with the first argument word set to the requester as the network does.
    function _ffPayload(uint256 n_) internal pure returns (bytes memory p) {
        p = new bytes(n_);
        for (uint256 i = 0; i < n_; i++) {
            p[i] = 0xff;
        }
        for (uint256 i = 4; i < 16; i++) {
            p[i] = 0x00;
        }
        bytes20 who = bytes20(REQUESTER);
        for (uint256 i = 0; i < 20; i++) {
            p[16 + i] = who[i];
        }
    }

    function _near(uint256 gasLimit_, bytes memory payload_, uint256 measured_) internal view {
        uint256 got = proxy.forwardedGas(gasLimit_, RECIPIENT, payload_);
        assertLe(got, measured_, "the mock must never forward more than the real proxy");
        assertGe(got + SLACK, measured_, "the mock bound is too far below the real proxy");
    }

    function _refused(uint256 gasLimit_, bytes memory payload_) internal {
        vm.expectPartialRevert(MockCallbackProxy.InsufficientGas.selector, address(proxy));
        proxy.forwardedGas(gasLimit_, RECIPIENT, payload_);
    }

    function test_hello_payload_matches_the_delivered_bytes() public pure {
        bytes memory p = _helloPayload();
        assertEq(p.length, 132);
        assertEq(bytes4(p), bytes4(0x592ca090), "pong selector as seen in the delivery calldata");
    }

    /// @dev The failed hello delivery: at 200,000 pong got 23,253 gas and ran out (CallbackFailure on chain).
    function test_hello_points_match_the_real_proxy() public {
        bytes memory p = _helloPayload();
        _refused(150_000, p);
        _near(200_000, p, 23_253);
        _near(245_000, p, 67_549);
        _near(250_000, p, 72_471);
        _near(300_000, p, 121_690);
        _near(400_000, p, 220_128);
        _near(600_000, p, 417_003);
        _near(800_000, p, 613_878);
    }

    /// @dev Payload sizes around the exit callback: 260 bytes (selector-only change) and 484 bytes (a stored change
    ///      of the full 256 bytes), plus a short and a long one.
    function test_payload_size_points_match_the_real_proxy() public {
        bytes memory p36 = _ffPayload(36);
        _refused(160_000, p36);
        _near(180_000, p36, 4671);
        _near(300_000, p36, 122_796);
        _near(600_000, p36, 418_109);

        bytes memory p260 = _ffPayload(260);
        _refused(160_000, p260);
        _near(180_000, p260, 992);
        _near(300_000, p260, 119_117);
        _near(600_000, p260, 414_430);

        bytes memory p484 = _ffPayload(484);
        _refused(160_000, p484);
        _refused(180_000, p484);
        _near(300_000, p484, 115_461);
        _near(600_000, p484, 410_773);

        bytes memory p2000 = _ffPayload(2000);
        _refused(160_000, p2000);
        _refused(180_000, p2000);
        _near(300_000, p2000, 90_746);
        _near(600_000, p2000, 386_058);
    }

    /// @dev The proxy's share does not depend on the limit: each extra 64 gas of limit gives the recipient 63.
    function test_forwarded_gas_grows_63_of_64() public view {
        bytes memory p = _helloPayload();
        uint256 a = proxy.forwardedGas(300_000, RECIPIENT, p);
        uint256 b = proxy.forwardedGas(300_000 + 64_000, RECIPIENT, p);
        assertEq(b - a, 63_000);
    }

    /// @dev A zero limit is not "no limit" on the network path: it cannot be sent either.
    function test_zero_limit_refused_on_the_network_path() public {
        address r = address(new HelloCallbackStub());
        vm.expectPartialRevert(MockCallbackProxy.BelowIntrinsicGas.selector, address(proxy));
        proxy.deliverWithGas(r, _helloPayload(), REQUESTER, 0);
    }

    /// @dev A limit below the delivery's own intrinsic gas cannot even be sent.
    function test_limit_below_intrinsic_refused() public {
        vm.expectPartialRevert(MockCallbackProxy.BelowIntrinsicGas.selector, address(proxy));
        proxy.forwardedGas(21_000, RECIPIENT, _helloPayload());
    }
}

/// @dev Any contract with code; the zero-limit test never reaches it.
contract HelloCallbackStub {
    fallback() external { }
}
