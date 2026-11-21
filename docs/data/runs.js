/* Recorded runs: real transactions read from the public RPC endpoints of Base Sepolia and Reactive Lasna
   at the time in readAt. The page re-reads every receipt before it calls a run checked.
   Written by scripts/runs.py --write from records/; never edit by hand. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  NP.recorded = {
    "readAt": "2026-11-21T17:51:10Z",
    "runs": [
      {
        "id": 1,
        "mode": 0,
        "kinds": 7,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0xfD29CE7D91EAA398021b811F3bd55525f6b88c72",
        "selector": "0x60d54d41",
        "execAt": 1794964066,
        "armTx": "0xbb22c74629a41c0b0f5d5aa1755bdedebde9a905bd5a981a4a5f916b85ebb2c1",
        "armTs": 1794963865,
        "subTx": "0x9d183f32d43cb8319aa4a646d327aac360fa303e9ab1f181387eabaf28035f52",
        "subTs": 1794963864,
        "r1": {
          "hash": "0xdd4ce73f5073de51dc3ec51c0e75fc50f01b5753c74f16ca374eb255b3544891",
          "block": 60210090,
          "ts": 1794963886
        },
        "r2": {
          "hash": "0x1a6b032aa7afc9f89e25fdef852bebbffad4ee1b750ba4fd4cc5bb6a5f84aa3e",
          "block": 8613128,
          "ts": 1794963886,
          "refTx": "0xdd4ce73f5073de51dc3ec51c0e75fc50f01b5753c74f16ca374eb255b3544891",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0x7f6456d9b7938e6a205c87a86d0e95ae5e347ec160a39c1e7a7251caebc67b04",
          "block": 60210098,
          "ts": 1794963888,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000",
          "assets": "100000000"
        },
        "exit": "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8",
        "reactive": "0x00E4996c7255B919B619902E1Ac4b254D3c3f014"
      },
      {
        "id": 2,
        "mode": 1,
        "kinds": 7,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0xe14bB093328435562c98f81915e9BD5e6947A207",
        "selector": "0x60d54d41",
        "execAt": 1794964188,
        "armTx": "0x098d29c8c9bd8f6afe390ecf150a638a8bfbb5e69224b5d086e7a76f179955c3",
        "armTs": 1794963985,
        "subTx": "0xfc9cbe8e9c4acd00e683b65243d96f8ae81a3da1d98d3acb8fcee774e14903d6",
        "subTs": 1794963985,
        "r1": {
          "hash": "0x19353d516295390f7ff762d3e3bdfce296fadf95b9d9dffffa435977a6b5a378",
          "block": 60210698,
          "ts": 1794964008
        },
        "r2": {
          "hash": "0x98b822a593a99bf8ab4d085d94f7d77a0986830755a3f15223e3c47023efc530",
          "block": 8613301,
          "ts": 1794964069,
          "refTx": "0x5f49a9babda8cfce6119f96035bae04716de5aa400a749fad14dfabde578106a",
          "refChainId": "0x512577",
          "reason": 2
        },
        "r3": {
          "hash": "0x681bd1f976e0b708c29ffe7639d9a987701bf2f8fc89480ae97e8ace77470b47",
          "block": 60211010,
          "ts": 1794964070,
          "outcome": 0,
          "reason": 2,
          "shares": "100000000",
          "assets": "100000000"
        },
        "exit": "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8",
        "reactive": "0x00E4996c7255B919B619902E1Ac4b254D3c3f014"
      }
    ]
  };
}());
