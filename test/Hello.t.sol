// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { console } from "forge-std/console.sol";
import { Network } from "./utils/Network.sol";
import { HelloOrigin } from "../src/hello/HelloOrigin.sol";
import { HelloReactive } from "../src/hello/HelloReactive.sol";
import { HelloCallback } from "../src/hello/HelloCallback.sol";

contract HelloTest is Network {
    HelloOrigin internal origin;
    HelloReactive internal reactive;
    HelloCallback internal callback;

    function setUp() public {
        _setUpNetwork();
        origin = new HelloOrigin();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        reactive = new HelloReactive(ORIGIN_CHAIN, address(origin), predicted);
        callback = new HelloCallback(IPayable(payable(address(proxy))), address(reactive));
        assertEq(address(callback), predicted, "predicted callback address");
        _drainLogs();
    }

    function test_ping_topic_matches_event() public pure {
        assertEq(bytes32(HelloOrigin.Ping.selector), keccak256("Ping(address,uint256)"));
    }

    function test_constructor_subscribes_exactly() public view {
        assertTrue(
            sys.isActive(address(reactive), ORIGIN_CHAIN, address(origin), reactive.PING_TOPIC(), IGNORE, IGNORE, IGNORE)
        );
        assertEq(sys.activeCount(address(reactive)), 1);
    }

    function test_full_loop_records_pong() public {
        vm.prank(address(0xBEEF));
        origin.ping(7);
        _pump(address(reactive));
        assertEq(reactive.relayed(), 1);
        assertEq(callback.pongs(), 1);
        assertEq(callback.lastNonce(), 7);
        assertEq(callback.lastOriginTxHash(), lastTxHash);
        assertEq(sys.reverts(), 0);
        assertTrue(proxy.lastOk());
    }

    /// @dev The callback gas limit must leave pong at least twice what it uses once the real proxy keeps its share
    ///      (MockCallbackProxy, measured against the Base Sepolia proxy). Pong runs with its storage cold, as on chain.
    function test_callback_gas_leaves_pong_twice_its_need() public {
        holdCallbacks = true;
        origin.ping(7);
        _pump(address(reactive));
        vm.cool(address(callback));
        _deliverCallbacks();
        console.log("pong: forwarded", proxy.lastForwarded(), "used", proxy.lastUsed());
        assertTrue(proxy.lastOk(), "pong ran within the gas the proxy forwarded");
        assertEq(callback.pongs(), 1);
        assertGe(proxy.lastForwarded(), 2 * proxy.lastUsed(), "at least twice what pong uses");
    }

    function test_callback_payload_reserves_first_argument() public {
        origin.ping(1);
        _pump(address(reactive));
        bytes memory payload = sys.callbackAt(0).payload;
        address firstArg;
        assembly {
            firstArg := mload(add(payload, 36))
        }
        assertEq(firstArg, address(0), "reactive side sends address(0) in the first argument");
        assertEq(sys.callbackAt(0).recipient, address(callback));
        assertEq(sys.callbackAt(0).gasLimit, reactive.CALLBACK_GAS());
        assertEq(sys.callbackAt(0).chainId, ORIGIN_CHAIN);
    }

    // Sibling of test_full_loop_records_pong: same pong, but not through the proxy.
    function test_pong_refuses_direct_caller() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(proxy)));
        callback.pong(address(reactive), 1, 1, address(this));
    }

    // Sibling of test_full_loop_records_pong: through the proxy, but requested by another reactive contract.
    function test_pong_refuses_other_reactive() public {
        bytes memory payload = abi.encodeCall(HelloCallback.pong, (address(0), 1, 1, address(this)));
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(reactive))
        );
        proxy.deliverOrRevert(address(callback), payload, address(0xBAD));
    }

    function test_react_refuses_non_system() public {
        IReactive.LogRecord memory rec;
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        reactive.react(rec);
    }

    function test_unwanted_log_is_counted_not_relayed() public {
        IReactive.LogRecord memory rec;
        rec.chainId = ORIGIN_CHAIN;
        rec.contractAddress = address(0x1234);
        rec.topic0 = reactive.PING_TOPIC();
        rec.opCode = 3;
        sys.forceDeliver(address(reactive), rec);
        assertEq(reactive.ignored(), 1);
        assertEq(reactive.relayed(), 0);
        assertEq(sys.callbackCount(), 0);
        assertEq(sys.reverts(), 0);
    }

    /// @dev Anyone can make the callback contract settle a debt to the proxy from its own fee reserve.
    function test_cover_debt_pays_the_proxy() public {
        vm.deal(address(callback), 1 ether);
        proxy.setDebt(address(callback), 0.25 ether);
        uint256 before = address(proxy).balance;
        vm.prank(address(0xC0FFEE));
        callback.coverDebt();
        assertEq(address(proxy).balance - before, 0.25 ether);
        assertEq(proxy.debt(address(callback)), 0);
        assertEq(address(callback).balance, 0.75 ether);
    }

    function test_reactive_cover_debt_pays_the_system_contract() public {
        vm.deal(address(reactive), 1 ether);
        sys.setDebt(address(reactive), 0.1 ether);
        uint256 before = address(sys).balance;
        vm.prank(address(0xC0FFEE));
        reactive.coverDebt();
        assertEq(address(sys).balance - before, 0.1 ether);
        assertEq(sys.debt(address(reactive)), 0);
        assertEq(address(reactive).balance, 0.9 ether);
    }
}
