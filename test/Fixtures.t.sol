// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { Network } from "./utils/Network.sol";
import { RealLogs } from "./fixtures/RealLogs.sol";
import { NoticeReactive } from "../src/NoticeReactive.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice Feeds logs taken from real chains (see fixtures/RealLogs.sol) through our decoding and our react().
contract FixturesTest is Network {
    address internal constant FAKE_EXIT = address(0xE717);
    uint256 internal constant REAL_NOW = 1_794_915_237; // a Lasna block timestamp read on 2026-11-17

    function _armedRecord(uint256 chain_, uint256 id_, address vault_, uint8 kinds_, uint8 mode_)
        internal
        pure
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = chain_;
        r.contractAddress = FAKE_EXIT;
        r.topic0 = uint256(keccak256("WatchArmed(uint256,address,address,uint8,uint8,uint256)"));
        r.topic1 = id_;
        r.topic2 = uint256(uint160(address(0xA11CE)));
        r.topic3 = uint256(uint160(vault_));
        r.opCode = 4;
        r.data = abi.encode(kinds_, mode_, type(uint256).max);
    }

    function _reactiveFor(uint256 originChain_) internal returns (NoticeReactive) {
        return new NoticeReactive(originChain_, FAKE_EXIT, CRON10_TOPIC, 60, 900, 600_000, 8, 80);
    }

    function test_real_morpho_submit_decodes() public pure {
        IReactive.LogRecord memory r = RealLogs.morphoSubmit();
        assertEq(r.topic0, NoticeKinds.SUBMIT_TOPIC);
        assertEq(r.opCode, 2);
        bytes4 sel = NoticeKinds.topicSelector(r.topic1);
        assertEq(sel, NoticeKinds.INCREASE_ABSOLUTE_CAP);
        (bytes memory data, uint256 at) = abi.decode(r.data, (bytes, uint256));
        assertEq(at, 1_795_434_669, "validAt reported by the Morpho API for this change");
        assertEq(bytes4(data), sel);
        assertEq(data.length, 388);
        assertEq(NoticeKinds.kindOf(sel), NoticeKinds.CAP_UP);
    }

    function test_real_submit_drives_leave_now_exit() public {
        _setUpNetwork();
        NoticeReactive reactive = _reactiveFor(8453);
        IReactive.LogRecord memory real = RealLogs.morphoSubmit();
        assertTrue(sys.deliver(address(reactive), _armedRecord(8453, 1, real.contractAddress, NoticeKinds.CAP_UP, 0)));
        assertTrue(sys.deliver(address(reactive), real), "the real log matches the filter the watch created");
        assertEq(sys.callbackCount(), 1);
        assertEq(sys.callbackAt(0).recipient, FAKE_EXIT);
        assertEq(sys.callbackAt(0).chainId, 8453);
        bytes memory payload = sys.callbackAt(0).payload;
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 k = 0; k < args.length; k++) {
            args[k] = payload[k + 4];
        }
        (, uint256 id, bytes memory data, uint256 origin, uint8 reason) =
            abi.decode(args, (address, uint256, bytes, uint256, uint8));
        (bytes memory realData,) = abi.decode(real.data, (bytes, uint256));
        assertEq(id, 1);
        assertEq(data, realData);
        assertEq(origin, real.txHash, "the real origin transaction hash is carried");
        assertEq(reason, reactive.R_SCHEDULED());
        assertEq(sys.reverts(), 0);
    }

    function test_real_submit_in_pending_mode_is_fled_at_once() public {
        _setUpNetwork();
        vm.warp(REAL_NOW);
        NoticeReactive reactive = _reactiveFor(8453);
        IReactive.LogRecord memory real = RealLogs.morphoSubmit();
        sys.deliver(address(reactive), _armedRecord(8453, 1, real.contractAddress, NoticeKinds.CAP_UP, 1));
        assertTrue(sys.deliver(address(reactive), real));
        assertEq(sys.callbackCount(), 1);
        // six days of timelock is far beyond the demo's MAX_WAIT: the contract will not pay ticks for it
        bytes memory payload = sys.callbackAt(0).payload;
        uint8 reason = uint8(uint256(_word(payload, 4)));
        assertEq(reason, reactive.R_WAIT_TOO_LONG());
    }

    function test_real_cron_tick_is_handled() public {
        vm.chainId(5318007);
        _setUpNetwork();
        vm.warp(REAL_NOW);
        NoticeReactive reactive = _reactiveFor(84532);
        address vault = address(0xD3A0);
        sys.deliver(address(reactive), _armedRecord(84532, 1, vault, NoticeKinds.ADAPTER, 1));
        IReactive.LogRecord memory s;
        s.chainId = 84532;
        s.contractAddress = vault;
        s.topic0 = NoticeKinds.SUBMIT_TOPIC;
        s.topic1 = NoticeKinds.selectorTopic(NoticeKinds.ADD_ADAPTER);
        s.opCode = 2;
        s.data = abi.encode(abi.encodeWithSelector(NoticeKinds.ADD_ADAPTER, address(1)), REAL_NOW + 180);
        assertTrue(sys.deliver(address(reactive), s));
        assertEq(reactive.cronFilterRefs(), 1);
        IReactive.LogRecord memory tick = RealLogs.lasnaCron10();
        assertEq(tick.data.length, 0, "real Cron10 carries no data");
        assertTrue(sys.deliver(address(reactive), tick), "the real tick matches our CRON filter");
        assertEq(reactive.ticks(), 1);
        assertEq(sys.callbackCount(), 0, "not due yet");
        assertEq(sys.reverts(), 0);
    }

    /// @dev Reads the 32-byte word `i_` of the ABI arguments of a call payload (after the selector).
    function _word(bytes memory payload_, uint256 i_) internal pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(payload_, 36), mul(i_, 32)))
        }
    }
}
