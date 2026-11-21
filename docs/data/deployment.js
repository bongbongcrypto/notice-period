// Written by scripts/stamp.py from deployments/2026-11-18.json; never edit by hand.
window.NP_DEPLOYMENT = {
  "contracts": {
    "callbackProxy": "0x476F44b11F5C942c58f4c8E3d0300E5710743585",
    "exit": "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8",
    "factory": "0xFFc96A898AF31e2ED652A8A0C0E90584999093CD",
    "reactive": "0x00E4996c7255B919B619902E1Ac4b254D3c3f014",
    "token": "0x2690DF70a37939c582a800f32FFEE52ec40d150B"
  },
  "healthMinFloat": "2",
  "name": "2026-11-18",
  "operators": [
    "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4"
  ],
  "origin": {
    "chainId": 84532,
    "name": "Base Sepolia"
  },
  "reactive": {
    "chainId": 5318007,
    "name": "Reactive Lasna"
  },
  "rules": {
    "leaveNowExpires": true,
    "timedArmsPerDay": null,
    "timedCap": null,
    "vaultSource": "demo"
  },
  "values": {
    "ARMS_PER_ADDRESS_PER_DAY": 2,
    "ARMS_PER_DAY": 10,
    "CALLBACK_GAS": 600000,
    "LEAD": 120,
    "LIFETIME": 86400,
    "MAX_ACTIVE": 8,
    "MAX_REACTIONS": 80,
    "MAX_WAIT": 900,
    "VAULT_TIMELOCK": 180
  }
};
