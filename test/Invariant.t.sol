// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { NoticeSetup } from "./utils/NoticeSetup.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { NoticeKinds } from "../src/lib/NoticeKinds.sol";

/// @notice Random sequences of visitor, curator, clock and attacker actions against the whole simulated system.
/// @dev Three visitors, each the curator of one vault (the demo's "one vault per visitor"), plus one attacker that
///      owns nothing. Every action lets the simulated network deliver what it caused.
contract NoticeHandler is NoticeSetup {
    address internal constant ATTACKER = address(0xBAD);

    address[3] public actors;
    DemoVault[3] public vaults;
    mapping(address actor => uint256) public minted;
    mapping(uint256 vaultIndex => bytes[]) internal _scheduled;

    uint256 public ghostBreaches; // an attack call that succeeded
    uint256 public ghostExpectedFailedCallbacks; // forged deliveries, each must fail
    uint256 public ghostOps; // actions that can round (each leaves at most 1 unit of an asset to other holders)
    uint256 internal _salt;

    constructor() {
        _deploy();
        actors = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            vaults[i] = _newVault(actors[i]);
        }
        _drainLogs();
    }

    /// @dev Log recording is restarted at each action so it never depends on the fuzzer keeping cheatcode state
    ///      between calls (every action pumps all logs it causes, so nothing is left to lose).
    modifier recorded() {
        vm.recordLogs();
        _;
    }

    // ------------------------------------------------------------------
    // Visitor actions
    // ------------------------------------------------------------------

    function deposit(uint256 who_, uint256 amount_) external recorded {
        uint256 i = who_ % 3;
        amount_ = bound(amount_, 1, 1_000e6);
        minted[actors[i]] += amount_;
        ghostOps += 1;
        _deposit(actors[i], vaults[i], amount_);
        _pump(address(reactive));
    }

    function arm(uint256 who_, uint8 kinds_, bool pending_, uint256 maxShares_) external recorded {
        uint256 i = who_ % 3;
        uint8 kinds = uint8(bound(kinds_, 1, NoticeKinds.ALL));
        uint256 cap = maxShares_ % 4 == 0 ? type(uint256).max : bound(maxShares_, 1, 2_000e6);
        address a = actors[i];
        _approveExit(a, vaults[i], maxShares_ % 3 == 0 ? cap / 2 + 1 : type(uint256).max);
        vm.prank(a);
        try exitC.arm(address(vaults[i]), kinds, pending_ ? 1 : 0, cap) { } catch { }
        _pump(address(reactive));
    }

    /// @notice A visitor also deposits into another visitor's vault and arms a watch there (several depositors
    ///         per vault, so an exit that paid the wrong owner would show).
    function crossArm(uint256 who_, uint256 target_, uint256 amount_, bool pending_) external recorded {
        uint256 i = who_ % 3;
        uint256 t = (i + 1 + target_ % 2) % 3;
        amount_ = bound(amount_, 1, 1_000e6);
        minted[actors[i]] += amount_;
        ghostOps += 1;
        _deposit(actors[i], vaults[t], amount_);
        _approveExit(actors[i], vaults[t], type(uint256).max);
        vm.prank(actors[i]);
        try exitC.arm(address(vaults[t]), NoticeKinds.DEFAULT, pending_ ? 1 : 0, type(uint256).max) { } catch { }
        _pump(address(reactive));
    }

    /// @notice Anyone tries to end a watch armed at least LIFETIME ago (only a timer watch can expire).
    function expireOne(uint256 id_) external recorded {
        uint256 next = exitC.nextWatchId();
        if (next == 1) return;
        uint256 id = bound(id_, 1, next - 1);
        try exitC.expire(id) { } catch { }
        _pump(address(reactive));
    }

    function cancel(uint256 who_) external recorded {
        uint256 i = who_ % 3;
        uint256 id = exitC.activeWatchOf(actors[i], address(vaults[i]));
        if (id == 0) return;
        vm.prank(actors[i]);
        exitC.cancel(id);
        _pump(address(reactive));
    }

    function withdrawAll(uint256 who_) external recorded {
        uint256 i = who_ % 3;
        uint256 shares = vaults[i].balanceOf(actors[i]);
        if (shares == 0) return;
        ghostOps += 1;
        vm.prank(actors[i]);
        try vaults[i].redeem(shares, actors[i], actors[i]) { } catch { }
        _pump(address(reactive));
    }

    // ------------------------------------------------------------------
    // Curator actions (each visitor is the curator of their own vault)
    // ------------------------------------------------------------------

    function schedule(uint256 who_, uint256 kind_) external recorded {
        uint256 i = who_ % 3;
        _salt += 1;
        bytes memory data;
        uint256 k = kind_ % 5;
        if (k == 0) data = _adapterCall(address(uint160(0xA000 + _salt)));
        else if (k == 1) data = _allocatorCall(address(uint160(0xB000 + _salt)));
        else if (k == 2) data = _capCall(_salt * 1e6);
        else if (k == 3) data = _timelockDownCall();
        else data = abi.encodeCall(DemoVault.increaseRelativeCap, (abi.encode("demo-market"), _salt));
        vm.prank(actors[i]);
        try vaults[i].submit(data) {
            _scheduled[i].push(data);
        } catch { }
        _pump(address(reactive));
    }

    /// @notice A curator pads a scheduled call (the ABI decoder ignores the extra bytes, so the call still runs).
    function schedulePadded(uint256 who_, uint256 kind_, uint256 extra_) external recorded {
        uint256 i = who_ % 3;
        _salt += 1;
        bytes memory call_ = kind_ % 2 == 0
            ? _adapterCall(address(uint160(0xC000 + _salt)))
            : _allocatorCall(address(uint160(0xD000 + _salt)));
        bytes memory data = abi.encodePacked(call_, new bytes(bound(extra_, 300, 20_000)));
        vm.prank(actors[i]);
        try vaults[i].submit(data) {
            _scheduled[i].push(data);
        } catch { }
        _pump(address(reactive));
    }

    function revokeOne(uint256 who_, uint256 pick_) external recorded {
        uint256 i = who_ % 3;
        uint256 n = _scheduled[i].length;
        if (n == 0) return;
        uint256 j = pick_ % n;
        bytes memory data = _scheduled[i][j];
        vm.prank(actors[i]);
        try vaults[i].revoke(data) { } catch { }
        _forget(i, j);
        _pump(address(reactive));
    }

    function runDue(uint256 who_, uint256 pick_) external recorded {
        uint256 i = who_ % 3;
        uint256 n = _scheduled[i].length;
        if (n == 0) return;
        uint256 j = pick_ % n;
        (bool ok,) = address(vaults[i]).call(_scheduled[i][j]);
        if (ok || vaults[i].executableAt(_scheduled[i][j]) == 0) _forget(i, j);
        _pump(address(reactive));
    }

    /// @notice Submit and revoke of a kind nobody watches: reaches only "leave if still pending" watches, through
    ///         the vault's one Revoke filter.
    function unwatchedSpam(uint256 who_, uint256 n_) external recorded {
        uint256 i = who_ % 3;
        uint256 n = bound(n_, 1, 30);
        for (uint256 k = 0; k < n; k++) {
            _salt += 1;
            bytes memory d = abi.encodeCall(DemoVault.increaseTimelock, (NoticeKinds.ADD_ADAPTER, 1000 + _salt));
            vm.startPrank(actors[i]);
            try vaults[i].submit(d) {
                vaults[i].revoke(d);
            } catch { }
            vm.stopPrank();
            ghostOps += 1;
            _pump(address(reactive));
        }
    }

    /// @notice A tick asks for an exit; before its callback lands, the curator revokes or runs a scheduled change.
    function raceTick(uint256 who_, uint256 pick_, bool run_, uint256 dt_) external recorded {
        uint256 i = who_ % 3;
        vm.warp(block.timestamp + bound(dt_, 1, 120));
        holdCallbacks = true;
        _tickAndPump();
        uint256 n = _scheduled[i].length;
        if (n > 0) {
            uint256 j = pick_ % n;
            bytes memory data = _scheduled[i][j];
            if (run_) {
                (bool ok,) = address(vaults[i]).call(data);
                if (ok) _forget(i, j);
            } else {
                vm.prank(actors[i]);
                try vaults[i].revoke(data) { } catch { }
                _forget(i, j);
            }
            _pump(address(reactive));
        }
        holdCallbacks = false;
        ghostOps += 1;
        _deliverCallbacks();
        _pump(address(reactive));
    }

    // ------------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------------

    function tick(uint256 dt_) external recorded {
        vm.warp(block.timestamp + bound(dt_, 1, 120));
        _tickAndPump();
    }

    function nextDay() external recorded {
        vm.warp(block.timestamp + 1 days);
        _tickAndPump();
    }

    // ------------------------------------------------------------------
    // Attacker actions: each must fail
    // ------------------------------------------------------------------

    function attackDirectExit(uint256 id_) external recorded {
        uint256 id = bound(id_, 1, exitC.nextWatchId());
        vm.prank(ATTACKER);
        try exitC.exit(address(reactive), id, address(vaults[0]), _adapterCall(ATTACKER), 1, 1) {
            ghostBreaches += 1;
        } catch { }
    }

    function attackForgedRequester(uint256 id_) external recorded {
        uint256 id = bound(id_, 1, exitC.nextWatchId());
        ghostExpectedFailedCallbacks += 1;
        (bool ok,) = proxy.deliver(
            address(exitC), _exitPayload(id, address(vaults[id % 3]), _adapterCall(ATTACKER), 1, 1), ATTACKER
        );
        if (ok) ghostBreaches += 1;
    }

    function attackOtherVault(uint256 who_, uint256 target_) external recorded {
        uint256 i = who_ % 3;
        uint256 t = (i + 1 + target_ % 2) % 3;
        vm.prank(actors[i]);
        try vaults[t].submit(_adapterCall(actors[i])) {
            ghostBreaches += 1;
        } catch { }
    }

    /// @notice A real request of our reactive contract, but naming another vault than the watch's.
    function attackWrongVault(uint256 id_, uint256 v_) external recorded {
        uint256 next = exitC.nextWatchId();
        if (next == 1) return;
        uint256 id = bound(id_, 1, next - 1);
        (,,, uint8 st, address wv,) = exitC.watches(id);
        DemoVault other = vaults[v_ % 3];
        if (st != exitC.STATUS_ACTIVE() || address(other) == wv) return;
        ghostExpectedFailedCallbacks += 1;
        (bool ok,) = proxy.deliver(
            address(exitC), _exitPayload(id, address(other), _adapterCall(ATTACKER), 1, 1), address(reactive)
        );
        if (ok) ghostBreaches += 1;
    }

    function attackArmOnSomeoneElsesShares(uint256 victim_) external recorded {
        uint256 v = victim_ % 3;
        vm.prank(ATTACKER);
        try exitC.arm(address(vaults[v]), NoticeKinds.ALL, 0, type(uint256).max) {
            ghostBreaches += 1;
        } catch { }
        _pump(address(reactive));
    }

    // ------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------

    function exitStatus(uint256 id_) external view returns (uint8) {
        return _status(id_);
    }

    function reactiveStatus(uint256 id_) external view returns (uint8) {
        return _rStatus(id_);
    }

    function exitMode(uint256 id_) external view returns (uint8 m) {
        (,, m,,,) = exitC.watches(id_);
    }

    function reactiveMode(uint256 id_) external view returns (uint8 m) {
        (,, m,,,) = reactive.watches(id_);
    }

    function _forget(uint256 i_, uint256 j_) internal {
        uint256 last = _scheduled[i_].length - 1;
        if (j_ != last) _scheduled[i_][j_] = _scheduled[i_][last];
        _scheduled[i_].pop();
    }

    function getContracts()
        external
        view
        returns (address token_, address exit_, address reactive_, address sys_, address proxy_)
    {
        return (address(token), address(exitC), address(reactive), address(sys), address(proxy));
    }
}

interface IHandlerToken {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IHandlerExit {
    function nextWatchId() external view returns (uint256);
}

interface IHandlerReactive {
    function activeWatches() external view returns (uint256);
    function MAX_ACTIVE() external view returns (uint256);
    function cronFilterRefs() external view returns (uint256);
    function pendingWatchIds() external view returns (uint256[] memory);
    function timedWatches() external view returns (uint256);
}

interface IHandlerCounters {
    function reverts() external view returns (uint256);
    function failed() external view returns (uint256);
    function overGasLimit() external view returns (uint256);
}

contract NoticeInvariantTest is Test {
    NoticeHandler internal h;
    IHandlerToken internal token;
    address internal exitAddr;
    IHandlerReactive internal reactive;
    IHandlerCounters internal sys;
    IHandlerCounters internal proxy;

    // Status numbers, from NoticeExit and NoticeReactive.
    uint8 internal constant EXIT_ENDED = 3;
    uint8 internal constant EXIT_CANCELLED = 2;
    uint8 internal constant EXIT_EXPIRED = 4;
    uint8 internal constant R_ARMED = 1;
    uint8 internal constant R_EXITED = 2;
    uint8 internal constant R_CANCELLED = 3;
    uint8 internal constant R_REFUSED = 4;

    function setUp() public {
        h = new NoticeHandler();
        (address t, address e, address r, address s, address p) = h.getContracts();
        token = IHandlerToken(t);
        exitAddr = e;
        reactive = IHandlerReactive(r);
        sys = IHandlerCounters(s);
        proxy = IHandlerCounters(p);

        bytes4[] memory sels = new bytes4[](19);
        sels[0] = NoticeHandler.deposit.selector;
        sels[1] = NoticeHandler.arm.selector;
        sels[2] = NoticeHandler.cancel.selector;
        sels[3] = NoticeHandler.withdrawAll.selector;
        sels[4] = NoticeHandler.schedule.selector;
        sels[5] = NoticeHandler.revokeOne.selector;
        sels[6] = NoticeHandler.runDue.selector;
        sels[7] = NoticeHandler.tick.selector;
        sels[8] = NoticeHandler.nextDay.selector;
        sels[9] = NoticeHandler.attackDirectExit.selector;
        sels[10] = NoticeHandler.attackForgedRequester.selector;
        sels[11] = NoticeHandler.attackOtherVault.selector;
        sels[12] = NoticeHandler.attackArmOnSomeoneElsesShares.selector;
        sels[13] = NoticeHandler.schedulePadded.selector;
        sels[14] = NoticeHandler.crossArm.selector;
        sels[15] = NoticeHandler.expireOne.selector;
        sels[16] = NoticeHandler.unwatchedSpam.selector;
        sels[17] = NoticeHandler.raceTick.selector;
        sels[18] = NoticeHandler.attackWrongVault.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: sels }));
        targetContract(address(h));
    }

    /// @dev The exit contract never keeps tokens or shares: everything it redeems goes straight to the owner.
    /// @dev Proves the handler path reaches a real exit, so the invariants below are not passing on a dead system.
    function test_handler_sequence_reaches_exit() public {
        h.deposit(0, 100e6);
        h.arm(0, 1, false, 4); // kinds = new adapter, leave now, no cap, allowance max
        h.schedule(0, 0); // the curator schedules a new adapter
        assertEq(h.exitStatus(1), EXIT_ENDED);
        assertEq(h.reactiveStatus(1), R_EXITED);
        assertEq(token.balanceOf(h.actors(0)), 100e6);
        invariant_exit_holds_nothing();
        invariant_tokens_go_only_to_their_owner();
        invariant_both_sides_agree();
        invariant_no_visitor_gains();
    }

    function invariant_exit_holds_nothing() public view {
        assertEq(token.balanceOf(exitAddr), 0);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(h.vaults(i).balanceOf(exitAddr), 0);
        }
    }

    /// @dev Every token is with a visitor or in that visitor's own vault; nobody else ever receives any.
    function invariant_tokens_go_only_to_their_owner() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            address a = h.actors(i);
            DemoVault v = h.vaults(i);
            sum += token.balanceOf(a) + token.balanceOf(address(v));
        }
        assertEq(sum, token.totalSupply(), "tokens appeared outside the visitors and their vaults");
        assertEq(token.balanceOf(address(0xBAD)), 0);
    }

    /// @dev Per visitor: tokens in the wallet plus what the visitor's shares in every vault redeem for never exceed
    ///      what the visitor put in. The vaults earn nothing, so only rounding can add, at most one unit per action
    ///      that rounds (it leaves the remainder to the other holders). An exit that paid one visitor from another's
    ///      shares would break this.
    function invariant_no_visitor_gains() public view {
        for (uint256 i = 0; i < 3; i++) {
            address a = h.actors(i);
            uint256 worth = token.balanceOf(a);
            for (uint256 k = 0; k < 3; k++) {
                DemoVault v = h.vaults(k);
                worth += v.previewRedeem(v.balanceOf(a));
            }
            // each watch exits at most once, and each exit is one more redeem that rounds
            uint256 slack = h.ghostOps() + IHandlerExit(exitAddr).nextWatchId();
            assertLe(worth, h.minted(a) + slack, "a visitor gained");
        }
    }

    function invariant_no_attack_succeeded() public view {
        assertEq(h.ghostBreaches(), 0);
    }

    /// @dev Only forged deliveries fail; every callback our reactive contract asks for goes through.
    function invariant_only_forged_callbacks_fail() public view {
        assertEq(proxy.failed(), h.ghostExpectedFailedCallbacks());
    }

    /// @dev react() never reverts (a revert is billed and leaves state behind on the real network).
    function invariant_react_never_reverts() public view {
        assertEq(sys.reverts(), 0);
    }

    /// @dev Every reaction fits the network's 900,000 gas cap as the mock measures it, padded changes included.
    function invariant_reactions_fit_gas_cap() public view {
        assertEq(sys.overGasLimit(), 0);
    }

    function invariant_active_watches_bounded() public view {
        assertLe(reactive.activeWatches(), reactive.MAX_ACTIVE());
    }

    /// @dev The timer count on Lasna is exactly the number of armed timer ("leave if still pending") watches.
    function invariant_timed_count_matches() public view {
        uint256 next = IHandlerExit(exitAddr).nextWatchId();
        uint256 timed;
        for (uint256 id = 1; id < next; id++) {
            if (h.reactiveStatus(id) == R_ARMED && h.reactiveMode(id) == 1) timed += 1;
        }
        assertEq(reactive.timedWatches(), timed);
    }

    /// @dev Nobody ends a "leave now" watch by expiry, however old it is.
    function invariant_leave_now_never_expired() public view {
        uint256 next = IHandlerExit(exitAddr).nextWatchId();
        for (uint256 id = 1; id < next; id++) {
            if (h.exitMode(id) == 0) assertTrue(h.exitStatus(id) != EXIT_EXPIRED, "a leave-now watch expired");
        }
    }

    /// @dev The CRON subscription exists exactly while some watch stores a pending change.
    function invariant_cron_only_while_pending() public view {
        uint256 pending = reactive.pendingWatchIds().length;
        assertEq(reactive.cronFilterRefs(), pending > 0 ? 1 : 0);
    }

    /// @dev The two sides agree: a watch ended on Base exactly when Lasna asked for its exit, and a watch cancelled on
    ///      Base is cancelled (or was refused) on Lasna.
    function invariant_both_sides_agree() public view {
        uint256 next = IHandlerExit(exitAddr).nextWatchId();
        for (uint256 id = 1; id < next; id++) {
            uint8 e = h.exitStatus(id);
            uint8 r = h.reactiveStatus(id);
            assertEq(e == EXIT_ENDED, r == R_EXITED, "ended on Base iff exit requested on Lasna");
            if (e == EXIT_CANCELLED || e == EXIT_EXPIRED) {
                assertTrue(r == R_CANCELLED || r == R_REFUSED, "cancel or expiry reached Lasna");
            }
        }
    }
}
