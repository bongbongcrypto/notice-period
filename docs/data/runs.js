/* Recorded runs: real transactions read from the public RPC endpoints of Base Sepolia and Reactive Lasna
   at the time in readAt. The page re-reads every receipt before it calls a run checked.
   Written by scripts/runs.py --write from records/; never edit by hand. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  NP.recorded = {
    "readAt": "2026-11-22T10:11:26Z",
    "runs": [
      {
        "id": 1,
        "mode": 0,
        "kinds": 7,
        "owner": "0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19",
        "vault": "0x43b0CED4AF6180eF0251C50454D16EF389D08C23",
        "selector": "0x60d54d41",
        "execAt": 1795340019,
        "armTx": "0xbd72dc7eea5db54ed1072e076b72b77b4a7b099fd85e3a45bab872814d867cc2",
        "armTs": 1795339820,
        "subTx": "0x83a2f145c12fd9138d396f550e32d3dd3934723ea3502db2aef75e79ab04e888",
        "subTs": 1795339819,
        "r1": {
          "hash": "0xc974112485f9350817cb58a35418cc309b7d27b536dfa3da3e4a08eeba9ce783",
          "block": 62089851,
          "ts": 1795339839
        },
        "r2": {
          "hash": "0xf9d98a074ebb38114108434a8704e50e659929c25ab510c0644e35602b4b88a9",
          "block": 8964035,
          "ts": 1795339838,
          "refTx": "0xc974112485f9350817cb58a35418cc309b7d27b536dfa3da3e4a08eeba9ce783",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0x85724300cdc2c5a21cf1f56c58133094f6f07e694644fa1d692368d296e1f549",
          "block": 62089858,
          "ts": 1795339840,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000000000000000",
          "assets": "100000000"
        },
        "exit": "0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca",
        "reactive": "0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32"
      }
    ]
  };
}());
