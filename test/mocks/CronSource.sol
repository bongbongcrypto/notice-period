// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title CronSource
/// @notice Stand-in for the CRON emitter at 0x...fffFfF on Lasna.
/// @dev Shape taken from a real Lasna log read on 2026-11-17 (block 0x82ba22): `number` is an indexed topic and
///      `data` is empty. The docs say `number` arrives in `data`; the chain says otherwise.
contract CronSource {
    event Cron10(uint256 indexed number);

    function tick() external {
        emit Cron10(block.number);
    }
}
