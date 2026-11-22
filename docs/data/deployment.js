// Written by scripts/stamp.py from deployments/2026-11-22.json; never edit by hand.
window.NP_DEPLOYMENT = {
  "contracts": {
    "callbackProxy": "0x476F44b11F5C942c58f4c8E3d0300E5710743585",
    "exit": "0xc3451Dc97fBF3ba019524E68939192BEC4b83Fca",
    "maker": "0x373628f4D8edA26E5ced03a4ec76Fa38162f6cC5",
    "morphoFactory": "0xE3a2CEbca662d99D0F279aF13a6bb8c9825D2ea0",
    "reactive": "0xb27F7223B83D3596868EAc0299Ab5B132b0B8D32",
    "token": "0xA73cD0eCA5bda9c98EFdEc8bbc7c32684d36A5D7"
  },
  "healthMinFloat": "4",
  "name": "2026-11-22",
  "operators": [
    "0x46b6d1a62cAf1172D41502e39C78fb8d1a55FbA4",
    "0x616FF5998E3e6AF794881Adf6Fe6cac62Cc29b19"
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
    "leaveNowExpires": false,
    "timedArmsPerDay": 4,
    "timedCap": 8,
    "vaultSource": "maker"
  },
  "values": {
    "ARMS_PER_ADDRESS_PER_DAY": 4,
    "ARMS_PER_DAY": 50,
    "CALLBACK_GAS": 1000000,
    "LEAD": 120,
    "LIFETIME": 86400,
    "MAX_ACTIVE": 1000,
    "MAX_REACTIONS": 16,
    "MAX_TIMED": 8,
    "MAX_WAIT": 200,
    "TIMED_ARMS_PER_DAY": 4,
    "VAULT_TIMELOCK": 180
  }
};
