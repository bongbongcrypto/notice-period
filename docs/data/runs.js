/* Recorded runs: real transactions read from the public RPC endpoints of Base Sepolia and Reactive Lasna
   at the time in readAt. The page re-reads every receipt before it calls a run checked.
   Written by scripts/runs.py --write from records/; never edit by hand. */
(function () {
  'use strict';
  var NP = window.NP = window.NP || {};
  NP.recorded = {
    "readAt": "2026-11-22T09:34:31Z",
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
      },
      {
        "id": 3,
        "mode": 0,
        "kinds": 7,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0x5d65405a9106053EC5e9d24F97c5016E28f97D0a",
        "selector": "0x5c1a1a4f",
        "execAt": 1795289693,
        "armTx": "0x75aab56702aa2838f8b72843a954062df4c0b44e4837dc917891b9fe72d0fd50",
        "armTs": 1795289494,
        "subTx": "0xd174390058e4f7ff33cc6406d24a02eb8c55f3fe017dc9bc4dc8e049775253d8",
        "subTs": 1795289493,
        "r1": {
          "hash": "0xb0934f38424d40a15e29813221e2ff5fcaa1d7890270091b79852b7afe4718d9",
          "block": 61838223,
          "ts": 1795289513
        },
        "r2": {
          "hash": "0xd6781732b0ebc3605e4935bbdfff19f099e7734363ee6cc825f32a1469fbd950",
          "block": 8916579,
          "ts": 1795289513,
          "refTx": "0xb0934f38424d40a15e29813221e2ff5fcaa1d7890270091b79852b7afe4718d9",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0xd4e0142294a334290c093c6e55ad4ae121dd3419cc47c5c2f4d05420481aeed2",
          "block": 61838233,
          "ts": 1795289515,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000",
          "assets": "100000000"
        },
        "exit": "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8",
        "reactive": "0x00E4996c7255B919B619902E1Ac4b254D3c3f014"
      },
      {
        "id": 4,
        "mode": 0,
        "kinds": 7,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0x94798b1E041C61ebDFC2924Dab252ce912942A54",
        "selector": "0xb192a84a",
        "execAt": 1795289964,
        "armTx": "0x87cc23e490b83103cfd50032e7c43cd77c92096ae4870429951b1428a0ef603d",
        "armTs": 1795289766,
        "subTx": "0xfb018c06a44cdf6dff3c6d562e59f2bc3b43d2b1087c41bfccbc951117087332",
        "subTs": 1795289765,
        "r1": {
          "hash": "0xcb46ba5b790545fe26a4102d709c24cc2f393ec393565910ce7370176dfc0656",
          "block": 61839579,
          "ts": 1795289784
        },
        "r2": {
          "hash": "0x394f2e9b74612cead05c02972f57f16e3e07d9d88ce6962b36556b7f81f68aeb",
          "block": 8916835,
          "ts": 1795289783,
          "refTx": "0xcb46ba5b790545fe26a4102d709c24cc2f393ec393565910ce7370176dfc0656",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0xfeefba149291d58e5bcb775d74f11e2bb589806288d0511da2c78f75b5fb15b1",
          "block": 61839585,
          "ts": 1795289785,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000",
          "assets": "100000000"
        },
        "exit": "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8",
        "reactive": "0x00E4996c7255B919B619902E1Ac4b254D3c3f014"
      },
      {
        "id": 5,
        "mode": 0,
        "kinds": 7,
        "owner": "0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19",
        "vault": "0x49Fa163CDFa736CE670E0f55AEF8A754d1B10076",
        "selector": "0x60d54d41",
        "execAt": 1795295540,
        "armTx": "0xb22ed73f9ded6234cc78071a5e1ad83c3bb7db8b616348c320a9dc0f53f35a01",
        "armTs": 1795295284,
        "subTx": "0x849aea9c637bdf53152fee734fb1ca701ab6201486dded2d442a204562fec53b",
        "subTs": 1795295283,
        "r1": {
          "hash": "0xcac46e4f8088ebdbb5ba4bd46ec49f79dd1a7bbeec10c5d03844edfd6c8bb252",
          "block": 61867457,
          "ts": 1795295360
        },
        "r2": {
          "hash": "0x9100fdc75b0896b2edfdea8f89aa019d74d4f1666d8bd1aa6b015158730df308",
          "block": 8922104,
          "ts": 1795295359,
          "refTx": "0xcac46e4f8088ebdbb5ba4bd46ec49f79dd1a7bbeec10c5d03844edfd6c8bb252",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0x7d7be1a69c3518a25c63c14ac517eeb350fbbb891c552a911222e9a68ab87932",
          "block": 61867462,
          "ts": 1795295361,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000",
          "assets": "100000000"
        },
        "exit": "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8",
        "reactive": "0x00E4996c7255B919B619902E1Ac4b254D3c3f014"
      },
      {
        "id": 7,
        "mode": 0,
        "kinds": 15,
        "owner": "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
        "vault": "0x2cc62C56d915F2567e9AB6e0d4B596A9A18EFC85",
        "selector": "0xf6f98fd5",
        "execAt": 1795328591,
        "armTx": "0x337de3a9172b0b88c567b1c3193c36a3c8db69d18b63a19f5facbe68d0474279",
        "armTs": 1795328390,
        "subTx": "0x070fdb6c8c9ea2db9937ccd7231d9e1b80fb3d0eb70de8ee5b40c1e033decfe7",
        "subTs": 1795328390,
        "r1": {
          "hash": "0x7066827c63a73722651f68b14ec0552728107040ea8bf0dc316c23a8e76c991f",
          "block": 62032715,
          "ts": 1795328411
        },
        "r2": {
          "hash": "0x02395d2ebc5d87877f40082ac24ae0768b741061e3962a1ec5ab2fd8595271b1",
          "block": 8953254,
          "ts": 1795328411,
          "refTx": "0x7066827c63a73722651f68b14ec0552728107040ea8bf0dc316c23a8e76c991f",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0xf20877f28e574b7eac8341a85afff2dac7b3f38cf9adbd06571d9546fbd48597",
          "block": 62032723,
          "ts": 1795328413,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000",
          "assets": "100000000"
        },
        "exit": "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8",
        "reactive": "0x00E4996c7255B919B619902E1Ac4b254D3c3f014"
      },
      {
        "id": 8,
        "mode": 0,
        "kinds": 7,
        "owner": "0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19",
        "vault": "0x8632dae06601b38F9cEf2c8964EE898FcdFAFa04",
        "selector": "0x60d54d41",
        "execAt": 1795339484,
        "armTx": "0x06e421902f5c3a94e9121b79671a647e8d38c16295c5e5746f1bc3fa5111bea6",
        "armTs": 1795328472,
        "subTx": "0xc3ca17840342cd3c59a3b2eaf5472e5c635581409d5adfc0d0484e645fe1fd40",
        "subTs": 1795328472,
        "r1": {
          "hash": "0x835c238cca37494c9aefea1dc03450ebe83ed1be0f9877751c2850c69c96f855",
          "block": 62087177,
          "ts": 1795339304
        },
        "r2": {
          "hash": "0x833910d12d0f9004679e29a9973e95c4d19ce2e56089dac10024a6e169bd44e0",
          "block": 8963535,
          "ts": 1795339303,
          "refTx": "0x835c238cca37494c9aefea1dc03450ebe83ed1be0f9877751c2850c69c96f855",
          "refChainId": "0x14a34",
          "reason": 1
        },
        "r3": {
          "hash": "0x1ae72fd8c1f51f5198bc03336063a1513d586bff8900118890e17a7c7a92115c",
          "block": 62087185,
          "ts": 1795339305,
          "outcome": 0,
          "reason": 1,
          "shares": "100000000",
          "assets": "100000000"
        },
        "exit": "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8",
        "reactive": "0x00E4996c7255B919B619902E1Ac4b254D3c3f014"
      }
    ]
  };
}());
