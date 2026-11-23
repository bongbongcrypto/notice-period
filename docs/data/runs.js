/* Recorded runs: real transactions read from the public RPC endpoints of Base Sepolia and Reactive Lasna
   at the time in readAt. The page re-reads every receipt before it calls a run checked.
   Written by scripts/runs.py --write from records/; never edit by hand. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  NP.recorded = {
    "readAt": "2026-11-23T04:30:46Z",
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
      },
      {
        "id": 3,
        "mode": 0,
        "kinds": 7,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0x759e82f008952992e7C43E12b54F589F5cb16fB5",
        "selector": "0x5c1a1a4f",
        "execAt": 1795340776,
        "armTx": "0x876ef18d3a035dfbbbd23ffac090854e00e0de7ea154106870f6769d53dfd1f7",
        "armTs": 1795340577,
        "subTx": "0x30087eb3d5e610dbced6d5fecd859dc12bcee2c063910097517602e0b1fc2f49",
        "subTs": 1795340576,
        "r1": {
          "hash": "0x4fa102311a96226837e5f07850028f40edc472d33d89a6b7d25f727e174616ce",
          "block": 62093636,
          "ts": 1795340596
        },
        "r2": {
          "hash": "0x06f32120122d36b696c2d80d9ebaef67b36de0dad0e88cfbf00846465742cc82",
          "block": 8964748,
          "ts": 1795340595,
          "refTx": "0x4fa102311a96226837e5f07850028f40edc472d33d89a6b7d25f727e174616ce",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0xd221d597fa2de2284414b979375a4d1c0dfb3865f8c8251fa4e5e58fc0c68e48",
          "block": 62093644,
          "ts": 1795340597,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000000000000000",
          "assets": "100000000"
        },
        "exit": "0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca",
        "reactive": "0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32"
      },
      {
        "id": 4,
        "mode": 0,
        "kinds": 7,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0xCcEF7A5feeFb336628fD44f2Eb54f95022558fFa",
        "selector": "0xb192a84a",
        "execAt": 1795340837,
        "armTx": "0xe3c497267942738930397ee75c6edc8387771ed02ee5232d333dbd1d5bf8573b",
        "armTs": 1795340638,
        "subTx": "0x4f1dac430689d5e869f6c801d075580ac714abe828daa7336fe897a6c170656f",
        "subTs": 1795340637,
        "r1": {
          "hash": "0xb2f3b82017938a457a5dd5957cef1e4e54c5a92c400fbba2f6853964a8fbaffb",
          "block": 62093945,
          "ts": 1795340657
        },
        "r2": {
          "hash": "0xf418f45b402d158c4253c0fc01c581fc851664947a4833159acd6abb3f669fea",
          "block": 8964807,
          "ts": 1795340657,
          "refTx": "0xb2f3b82017938a457a5dd5957cef1e4e54c5a92c400fbba2f6853964a8fbaffb",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0xde051159cc4782505f1834624cd1ff4c783c0e4d4348d535d0896bf625773521",
          "block": 62093955,
          "ts": 1795340659,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000000000000000",
          "assets": "100000000"
        },
        "exit": "0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca",
        "reactive": "0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32"
      },
      {
        "id": 5,
        "mode": 0,
        "kinds": 7,
        "owner": "0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19",
        "vault": "0x28EdE8C0ED37233e2A55D50Ee843ACb2defFF06A",
        "selector": "0x60d54d41",
        "execAt": 1795340962,
        "armTx": "0xb235e50c295082d6553d996c47bd9d52460f5455eb03cf8018a8cd62f032f723",
        "armTs": 1795340704,
        "subTx": "0x4e27decf369d10575aa39748e84414c06360f67fc62320daa3a052300cd7ce14",
        "subTs": 1795340703,
        "r1": {
          "hash": "0x6e0edc92588549cdc8854ce32501f4602eb0654bcc384432a66841794497a633",
          "block": 62094567,
          "ts": 1795340782
        },
        "r2": {
          "hash": "0x0dd6304d6a037393516f8cb1c7d4bd52e6d2c6ba008c8068be5b3dc274c3a4b1",
          "block": 8964923,
          "ts": 1795340781,
          "refTx": "0x6e0edc92588549cdc8854ce32501f4602eb0654bcc384432a66841794497a633",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0xdea82586747b2f21766e4e5831a5acd4b7a0247bea6c448d4234ae231f752a93",
          "block": 62094572,
          "ts": 1795340783,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000000000000000",
          "assets": "100000000"
        },
        "exit": "0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca",
        "reactive": "0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32"
      },
      {
        "id": 6,
        "mode": 1,
        "kinds": 7,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0x0fdd52c05868a0E12896A4FA7992D6Cb4E2D2897",
        "selector": "0x60d54d41",
        "execAt": 1795341033,
        "armTx": "0x34c2cb90f4569905728a692bd6024af721509fe6e32b1cb0619b0350e4513d9b",
        "armTs": 1795340834,
        "subTx": "0x08de4181cdbe20efbc278a50bac2e21e60baa407a6eb7ebccb89027e66e42176",
        "subTs": 1795340834,
        "r1": {
          "hash": "0x9b56fa046d73aaccb548b72993f443d6e248928c136f4b0d0c9e32cd10d52bfb",
          "block": 62094923,
          "ts": 1795340853
        },
        "r2": {
          "hash": "0x14235447a26e0eb8da3bd05412d0055e9cf64797b6874e9344f342e70cf0f975",
          "block": 8965051,
          "ts": 1795340916,
          "refTx": "0x3b74c7b8af23a27a02f2a1ad884f9dc181113899f39e21601f58646a5720254e",
          "refChainId": "0x512577",
          "reason": 2
        },
        "r3": {
          "hash": "0x5b28027a2cf02ae7d5b0aca870acd092925e7596e3c30dea46bc05909120a4eb",
          "block": 62095249,
          "ts": 1795340918,
          "outcome": 0,
          "reason": 2,
          "shares": "100000000000000000000",
          "assets": "100000000"
        },
        "exit": "0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca",
        "reactive": "0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32"
      },
      {
        "id": 9,
        "mode": 1,
        "kinds": 7,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0x1927A694bFCEE108c9015b122D79faB0d6805093",
        "selector": "0x5c1a1a4f",
        "execAt": 1795399715,
        "armTx": "0xafdd5769282baafe0bec1dcc9d66b79f03217d126290388874c5d435dfcc95c5",
        "armTs": 1795399516,
        "subTx": "0x2c14cd75073d1c8a30dec37edf1c3bb5195832dd6235193c5800cf4d53a400cc",
        "subTs": 1795399515,
        "r1": {
          "hash": "0xb28dd039c4677ebbf82ab16db773dbc0beb417bd355efc6e40db31dcb21ae089",
          "block": 62388331,
          "ts": 1795399535
        },
        "r2": {
          "hash": "0x3283ace2058d53ad2f8c00008a17e9ecb8fe3b52f01155f6a49fdc024fbb546a",
          "block": 9020291,
          "ts": 1795399596,
          "refTx": "0x897cc2823d799ed70086455dd2cad5914b95af49ea30ae33b1d2e74c5e8bc6c3",
          "refChainId": "0x512577",
          "reason": 2
        },
        "r3": {
          "hash": "0x87553a4a5428ed035d68f8981e7f4945057eb2efc3848ab8fe025ad7c67b078f",
          "block": 62388646,
          "ts": 1795399598,
          "outcome": 0,
          "reason": 2,
          "shares": "100000000000000000000",
          "assets": "100000000"
        },
        "exit": "0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca",
        "reactive": "0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32"
      },
      {
        "id": 10,
        "mode": 1,
        "kinds": 7,
        "owner": "0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19",
        "vault": "0xE8B6E086e1a8143041dA2962bD89eA5C8CDc6074",
        "selector": "0xb192a84a",
        "execAt": 1795399845,
        "armTx": "0x4f83ec60e9db49e7910c1bf41dc4c9537ef23502e2aebfce5a5c3f333499b33b",
        "armTs": 1795399646,
        "subTx": "0x885ac0b6ba9e79f7adc866c02980d1b5fbf705262fe7f851cebfda587731354f",
        "subTs": 1795399646,
        "r1": {
          "hash": "0x23273662123154ee91789ba32336500da3a19d87fa9b6be5d0b7dfb3d0a2527d",
          "block": 62388983,
          "ts": 1795399665
        },
        "r2": {
          "hash": "0x5c58356b74abedcb3c1b4063b7c8b27f5241c913b45ca0d08b4118cbefb192a0",
          "block": 9020421,
          "ts": 1795399733,
          "refTx": "0x0d32c93575c42ad8ce6646595e722ad60daca6c0c1031f2b68d8335a448aef23",
          "refChainId": "0x512577",
          "reason": 2
        },
        "r3": {
          "hash": "0xd5fb0d552aceccc3fd867c112cd279f2abbb1d5780e2b50d17885446f5f95aac",
          "block": 62389331,
          "ts": 1795399735,
          "outcome": 0,
          "reason": 2,
          "shares": "100000000000000000000",
          "assets": "100000000"
        },
        "exit": "0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca",
        "reactive": "0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32"
      },
      {
        "id": 11,
        "mode": 0,
        "kinds": 15,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0x8740a3480daDf44B4a89135B0C4Fb42584011706",
        "selector": "0xf6f98fd5",
        "execAt": 1795399970,
        "armTx": "0xb66ba6201ad24afe3b58c9650dfe94f24e9fb3ca47b4cc63b2d46c69d21cd5dc",
        "armTs": 1795399771,
        "subTx": "0x74fb5aac539b142c067a18a7332963937ac9e3cafac98fb9063c4f5085c0779e",
        "subTs": 1795399770,
        "r1": {
          "hash": "0xa6a052929d70b601b4545a2e9a69d1e71fd4e3f74c0b88eb381d7085c9d1d4f2",
          "block": 62389608,
          "ts": 1795399790
        },
        "r2": {
          "hash": "0x5e04016fd5c3605adc92e24fa88d3ee5315bc56247db96ea5d0d2fc9d7a134cb",
          "block": 9020475,
          "ts": 1795399789,
          "refTx": "0xa6a052929d70b601b4545a2e9a69d1e71fd4e3f74c0b88eb381d7085c9d1d4f2",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0x67d48fdeb74b26619f44f839e067b57d73d8f7aa3c9bcfb30665fdece41a37a5",
          "block": 62389614,
          "ts": 1795399791,
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
