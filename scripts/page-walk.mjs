#!/usr/bin/env node
/* The wallet walk of the hosted page: the guided run, end to end, with a real wallet signature.

     node scripts/page-walk.mjs --url URL --browser CHROME [--deployment NAME] [--key a|b]
                                [--kind adapter|allocator|timelock|cap] [--mode 0|1] [--out DIR] [--timeout SECONDS]
     node scripts/page-walk.mjs --dry --url URL --browser CHROME [--address 0x...] [--allow-other-contracts] [...]
     node scripts/page-walk.mjs --verify-record records/NAME.json [--deployment NAME]

   Run by .github/workflows/page-walk.yml inside the "testnet" environment, where the key comes from. Node 22 or later
   and no dependency: Chrome runs with a fresh profile and is driven over the DevTools protocol with the global
   WebSocket and fetch (as scripts/video-record.mjs does).

   The wallet the page sees. Before any page script runs (Page.addScriptToEvaluateOnNewDocument) the page gets one
   EIP-6963 announced wallet and the same object as window.ethereum. Its request() goes to this script through a
   DevTools binding; nothing the page says is trusted. Answers:
     eth_requestAccounts           the walk address (eth_accounts is empty until then, as with a wallet not yet connected)
     eth_chainId, net_version      Base Sepolia, 84532
     wallet_switchEthereumChain,   only to Base Sepolia; any other chain is refused
       wallet_addEthereumChain
     read methods (READ below)     forwarded to the public Base Sepolia endpoints
     eth_sendTransaction           signed only under the rules below
     every other signing method    refused with code 4001
     any other method              refused with code 4200
   Any refusal fails the walk (in --dry every eth_sendTransaction is refused on purpose, and that alone does not).

   What the signer signs. All of these must hold, or the request is refused with 4001 and the walk fails:
     - from is the walk address; the chain is 84532; value is zero or absent; there is a target and call data;
       gas, if the page names it, is at most 8,000,000; at most 12 transactions in one walk;
     - the target is the demo dollar, the vault maker or the exit contract of deployments/NAME.json in this checkout
       (never addresses read from the page), or the walk's own vault: the vault in the VaultCreated log of a create()
       this walk signed, or the maker's lastVaultOf(walk address) read once at the start (an earlier visit's vault,
       for the resume and old-vault paths); in both cases the maker's isVault(vault) must answer true by our own
       eth_call. A vault someone else made, the deployment's smoke vault included, is never a target;
     - the call is one of these, with these arguments, and the call data is exactly the standard ABI encoding of them:
         demo dollar   mint(address,uint256) to the walk address; approve(address,uint256) for the walk's vault
         vault maker   create()
         walk's vault  deposit(uint256,address) or mint(uint256,address) for the walk address;
                       approve(address,uint256) for the exit contract;
                       submit(bytes) of a change of the chosen kind only, and only while the vault's curator() is the
                       walk address;
                       redeem(uint256,address,address) or withdraw(uint256,address,address) from and to the walk address
         exit contract arm(address,uint8,uint8,uint256) on the walk's vault with exactly the chosen kinds and mode;
                       cancel(uint256)
   Signing mirrors scripts/chain.sh send_as: cast send with the function signature and the decoded arguments, then
   the receipt must say success, and the transaction as mined must carry exactly the call data the page asked for.
   The key is read once from the WALK_KEY environment variable and removed from the environment before Chrome or cast
   starts; cast gets it as an argument of a process started without a shell, and no command line is printed. Every
   cast message is scrubbed of the key before it is shown. In Actions the workflow masks key B (scripts/chain.sh
   derive_key_b); key A is the TESTNET_KEY secret, masked by GitHub.

   The walk. Open the page, check that its states and buttons are the ones driven here and that its contracts are
   those of the deployment, connect, deposit (make the vault, get demo dollars, approve, deposit), set the watch to the
   chosen kinds and mode and turn it on, act as the curator and schedule the change, and wait for the page's end
   state "returned" (the deposit came back). The page is driven by its state id (#state[data-state]) and its buttons
   ([data-a]), not by visible text. Then the page is not trusted: the three transactions it shows are read by receipt
   from the public endpoints, and the walk checks status 1, that the Submit is the one it signed, the links by watch
   id and by the Submit hash (ExitRequested on Lasna, WatchEnded on Base Sepolia), the token transfer from the vault
   to the walk address equal to the redeemed assets, the seconds from block times, that the exit landed before the
   change could run, and that the shares and the watch are gone.
   Failure: any error state of the page, any console error, uncaught exception or policy violation, any refused
   request, or no end state within the timeout (default 480 s). On failure the state id and the visible text are
   printed and a screenshot is taken. A browser-level error about one of the page's public endpoints (failed to load,
   rate-limited, blocked by its CORS answer) is recorded, not failed: the page is built to retry those. A policy
   violation, or one of the page's own files failing to load, does fail the walk. Once the walk has failed or the page
   has reached its end state nothing more is signed: a later request is refused and fails the walk, and a transaction
   cast is still sending is waited for and recorded before the receipts are checked and the result is decided.
   A live walk opens only the hosted page (https://bongbongcrypto.github.io/notice-period/...). If the browser will not
   start with its sandbox, it is started again without it; a live walk then prints a workflow warning and records
   browserSandbox false in its result.

   Output: OUT/result.json, OUT/summary.md, OUT/*.jpg screenshots, and the result JSON on stdout between the lines
   NP-WALK-JSON-BEGIN and NP-WALK-JSON-END. On failure the last screenshot is also printed in base64 on one line
   between NP-WALK-SHOT-BEGIN and NP-WALK-SHOT-END.

   --dry: no key at all. The address is --address (default: the deployment's operator for --key) and every
   eth_sendTransaction is answered with a 4001 rejection after the policy above was evaluated for the report. Passes
   when the page reaches "confirm-rejected" after exactly one confirmation request, which the policy would sign, with
   the page's contracts equal to the deployment's (--allow-other-contracts turns a difference into a note), and, with
   the page's own renderer
   drawing the watch step and the curator step (no chain behind them, nothing pressed that asks the wallet), the box
   setting of every kind gives the page the kinds above and the chosen kind's curator button.
   --verify-record: the receipt checks alone, on a recorded run (no browser, no key). */

import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BASE_ID = 84532;
const BASE_HEX = '0x14a34';
const LASNA_ID = 5318007;
const BASE_READ = ['https://base-sepolia-rpc.publicnode.com', 'https://sepolia.base.org'];
const BASE_SEND = process.env.BASE_RPC || 'https://sepolia.base.org';
const LASNA_RPC = process.env.LASNA_RPC || 'https://lasna-rpc.rnk.dev/';
const CAST = process.env.CAST_BIN || 'cast';
const UA = 'notice-period-page-walk/1';
const MAX_SENDS = 12;
const MAX_GAS = 8000000n;
const ZERO_ADDR = '0x' + '0'.repeat(40);
const KIND_BITS = { adapter: 1, timelock: 2, allocator: 4, cap: 8 };
/* Kinds the watch covers, per kind scheduled. The page's curator buttons are the first covered kind and one other
   (docs/states.js curatorPair): with these, the chosen kind has its own button. Cap uses all four, as loop.yml does. */
const WATCH_KINDS = { adapter: 7, timelock: 6, allocator: 4, cap: 15 };
const KIND_SIGS = {
  adapter: ['addAdapter(address)'],
  timelock: ['decreaseTimelock(bytes4,uint256)'],
  allocator: ['setIsAllocator(address,bool)'],
  cap: ['increaseAbsoluteCap(bytes,uint256)', 'increaseRelativeCap(bytes,uint256)'],
};
const READ = new Set(['eth_blockNumber', 'eth_call', 'eth_estimateGas', 'eth_gasPrice', 'eth_maxPriorityFeePerGas',
  'eth_feeHistory', 'eth_getBalance', 'eth_getCode', 'eth_getTransactionCount', 'eth_getTransactionByHash',
  'eth_getTransactionReceipt', 'eth_getBlockByNumber', 'eth_getBlockByHash', 'eth_getLogs', 'eth_getStorageAt']);
const SIGNING = new Set(['personal_sign', 'eth_sign', 'eth_signTypedData', 'eth_signTypedData_v1', 'eth_signTypedData_v3',
  'eth_signTypedData_v4', 'eth_signTransaction', 'eth_sendRawTransaction', 'wallet_sendCalls', 'wallet_grantPermissions',
  'eth_decrypt', 'eth_getEncryptionPublicKey']);
/* States the walk waits through, and the ids and buttons it relies on (checked on the loaded page before anything). */
const WAIT_STATES = new Set(['connecting', 'checking', 'depositing', 'arming', 'armed-subscribing', 'armed-settling',
  'scheduling', 'scheduled', 'exit-requested', 'recovering']);
const REQUIRED_STATES = ['idle', 'connecting', 'checking', 'step-deposit', 'depositing', 'confirm-rejected', 'deposited',
  'arming', 'armed-subscribing', 'armed-settling', 'armed', 'scheduling', 'scheduled', 'exit-requested', 'returned'];
/* The outside hosts the page reads (its Content-Security-Policy connect-src). */
const OUTSIDE_HOSTS = ['sepolia.base.org', 'base-sepolia-rpc.publicnode.com', 'lasna-rpc.rnk.dev', 'api.morpho.org'];
/* The one page a live walk may open: the project's GitHub Pages site (page-walk.yml checks the same). */
const LIVE_ORIGIN = 'https://bongbongcrypto.github.io';
const LIVE_PATH = '/notice-period/';
const LIVE_URL = /^https:\/\/bongbongcrypto\.github\.io\/notice-period\/[A-Za-z0-9._~\/-]*$/;
const BINDING = 'npWalkWalletRequest';
const VIEW = { width: 1280, height: 900 };

/* ---------- small helpers ---------- */

const t0 = Date.now();
const secs = () => Math.round((Date.now() - t0) / 100) / 10;
const lower = (s) => String(s || '').toLowerCase();
const same = (a, b) => lower(a) === lower(b);
const strip0x = (h) => lower(h).replace(/^0x/, '');
/* Text the page controls (state headings, console lines) goes into the log and the job summary on one line, without
   control characters, so it can never start a line of its own (a "::" workflow command, a markdown block). */
const oneLine = (s) => String(s === undefined || s === null ? '' : s).replace(/[\u0000-\u001f\u007f\u2028\u2029]+/g, ' ');
function log(msg) { console.log(`page-walk [${secs().toFixed(1)} s] ${oneLine(msg)}`); }
function die(msg) { console.error(`page-walk: ${msg}`); process.exit(2); }

/* ---------- Keccak-256 (Node's crypto has SHA-3 only, whose padding differs) ---------- */

const MASK64 = (1n << 64n) - 1n;
const ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]];
const RC = (() => {
  const out = [];
  let r = 1;
  for (let i = 0; i < 24; i += 1) {
    let c = 0n;
    for (let j = 0; j < 7; j += 1) {
      if (r & 1) c |= 1n << BigInt((1 << j) - 1);
      r <<= 1;
      if (r & 0x100) r ^= 0x171;
    }
    out.push(c);
  }
  return out;
})();
const rol = (v, n) => (n === 0 ? v : ((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK64);

function keccakF(s) {
  const C = new Array(5);
  const B = new Array(25);
  for (let round = 0; round < 24; round += 1) {
    for (let x = 0; x < 5; x += 1) C[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20];
    for (let x = 0; x < 5; x += 1) {
      const d = C[(x + 4) % 5] ^ rol(C[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) s[x + y] ^= d;
    }
    for (let x = 0; x < 5; x += 1) for (let y = 0; y < 5; y += 1) B[y + 5 * ((2 * x + 3 * y) % 5)] = rol(s[x + 5 * y], ROT[x][y]);
    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) {
        s[x + 5 * y] = B[x + 5 * y] ^ ((~B[((x + 1) % 5) + 5 * y] & MASK64) & B[((x + 2) % 5) + 5 * y]);
      }
    }
    s[0] ^= RC[round];
  }
}

function keccak256(input) {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : input;
  const rate = 136;
  const padded = new Uint8Array(Math.floor(bytes.length / rate) * rate + rate);
  padded.set(bytes);
  padded[bytes.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const s = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i += 1) {
      let lane = 0n;
      for (let b = 7; b >= 0; b -= 1) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      s[i] ^= lane;
    }
    keccakF(s);
  }
  let out = '0x';
  for (let i = 0; i < 4; i += 1) for (let b = 0; b < 8; b += 1) out += Number((s[i] >> BigInt(8 * b)) & 0xffn).toString(16).padStart(2, '0');
  return out;
}
const sel = (sig) => keccak256(sig).slice(0, 10);
const topic = (sig) => keccak256(sig);

function keccakSelfTest() {
  /* the selector of transfer(address,uint256), known to every ERC-20 tool */
  if (sel('transfer(address,uint256)') !== '0xa9059cbb') die('Keccak-256 self-test failed');
}

/* ---------- ABI (the few shapes the signer allows) ---------- */

const word = (n) => BigInt(n).toString(16).padStart(64, '0');
const addrWord = (a) => strip0x(a).padStart(64, '0');
const typesOf = (sig) => sig.slice(sig.indexOf('(') + 1, -1).split(',').filter(Boolean);

function encodeArgs(types, values) {
  let head = '';
  let tail = '';
  const headBytes = types.length * 32;
  types.forEach((t, i) => {
    const v = values[i];
    if (t === 'bytes') {
      head += word(headBytes + tail.length / 2);
      const hex = strip0x(v);
      tail += word(hex.length / 2) + hex.padEnd(Math.ceil(hex.length / 64) * 64, '0');
    } else if (t === 'address') head += addrWord(v);
    else if (t === 'bool') head += word(v ? 1 : 0);
    else if (t === 'bytes4') head += strip0x(v).padEnd(64, '0');
    else head += word(v);
  });
  return head + tail;
}

/* Decodes the arguments after the selector. Throws on a short, out-of-range or malformed value. */
function decodeArgs(types, hex) {
  const at = (i) => {
    const s = hex.slice(i * 64, i * 64 + 64);
    if (s.length !== 64) throw new Error('call data too short');
    return s;
  };
  return types.map((t, i) => {
    const s = at(i);
    if (t === 'address') {
      if (!/^0{24}/.test(s)) throw new Error(`argument ${i + 1} is not an address`);
      return '0x' + s.slice(24);
    }
    if (t === 'bool') {
      const n = BigInt('0x' + s);
      if (n > 1n) throw new Error(`argument ${i + 1} is not a bool`);
      return n === 1n;
    }
    if (t === 'bytes4') return '0x' + s.slice(0, 8);
    if (t === 'bytes') {
      const off = BigInt('0x' + s);
      if (off % 32n !== 0n || off * 2n + 64n > BigInt(hex.length)) throw new Error(`argument ${i + 1}: bad offset`);
      const o = Number(off) * 2;
      const len = BigInt('0x' + hex.slice(o, o + 64));
      if (len * 2n > BigInt(hex.length - o - 64)) throw new Error(`argument ${i + 1}: bad length`);
      return '0x' + hex.slice(o + 64, o + 64 + Number(len) * 2);
    }
    const n = BigInt('0x' + s);
    const m = /^uint(\d+)$/.exec(t);
    if (!m) throw new Error(`type ${t} not handled`);
    if (n >= 1n << BigInt(m[1])) throw new Error(`argument ${i + 1} is out of range for ${t}`);
    return n;
  });
}

function castArg(t, v) {
  if (t === 'address') return lower(v);
  if (t === 'bool') return v ? 'true' : 'false';
  if (t === 'bytes' || t === 'bytes4') return lower(v);
  return BigInt(v).toString();
}

const dataWord = (data, i) => BigInt('0x' + (strip0x(data).slice(i * 64, i * 64 + 64) || '0'));
const topicAddr = (t) => '0x' + strip0x(t).slice(24);

/* ---------- options and deployment ---------- */

function parseArgs(argv) {
  const o = { deployment: '2026-11-22', key: 'b', kind: 'adapter', mode: 0, timeout: 480, dry: false };
  const need = (i) => { if (i >= argv.length) die(`${argv[i - 1]} needs a value`); return argv[i]; };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--url') o.url = need((i += 1));
    else if (a === '--browser') o.browser = need((i += 1));
    else if (a === '--deployment') o.deployment = need((i += 1));
    else if (a === '--key') o.key = need((i += 1));
    else if (a === '--kind') o.kind = need((i += 1));
    else if (a === '--mode') o.mode = Number(need((i += 1)));
    else if (a === '--out') o.out = resolve(need((i += 1)));
    else if (a === '--timeout') o.timeout = Number(need((i += 1)));
    else if (a === '--address') o.address = need((i += 1));
    else if (a === '--verify-record') o.verifyRecord = resolve(need((i += 1)));
    else if (a === '--dry') o.dry = true;
    else if (a === '--allow-other-contracts') o.allowOtherContracts = true;
    else if (a === '--help' || a === '-h') { console.log('usage: see the header of scripts/page-walk.mjs'); process.exit(0); }
    else die(`unknown argument ${a}`);
  }
  if (!['a', 'b'].includes(o.key)) die('--key must be a or b');
  if (!(o.kind in KIND_BITS)) die('--kind must be adapter, allocator, timelock or cap');
  if (o.mode !== 0 && o.mode !== 1) die('--mode must be 0 or 1');
  if (!Number.isInteger(o.timeout) || o.timeout < 60 || o.timeout > 1500) die('--timeout must be 60 to 1500 seconds');
  if (o.address !== undefined && !/^0x[0-9a-fA-F]{40}$/.test(o.address)) die('--address is not an address');
  if (o.address !== undefined && !o.dry) die('--address is for --dry only; a live walk signs with WALK_KEY');
  if (o.allowOtherContracts && !o.dry) die('--allow-other-contracts is for --dry only');
  if (!o.verifyRecord) {
    if (!o.url || !/^https?:\/\/[A-Za-z0-9.:[\]-]+(\/[^\s]*)?$/.test(o.url)) die('--url must be an http(s) address');
    /* a live walk, with the key, opens only the hosted page; a dry walk may open a local copy */
    if (!o.dry && !LIVE_URL.test(o.url)) die(`a live walk opens only the hosted page (${LIVE_ORIGIN}${LIVE_PATH})`);
    if (!o.browser) die('--browser is required (path of Chrome or Edge)');
  }
  return o;
}

function loadDeployment(name) {
  if (!/^[0-9A-Za-z][0-9A-Za-z-]{0,40}$/.test(name)) die('deployment name: letters, digits and dashes only');
  const path = join(ROOT, 'deployments', `${name}.json`);
  let doc;
  try { doc = JSON.parse(readFileSync(path, 'utf8')); } catch (e) { die(`cannot read deployments/${name}.json`); }
  if (doc.status !== 'deployed') die(`deployments/${name}.json is not a filled deployment`);
  const c = doc.contracts || {};
  const d = { name, token: c.token, maker: c.maker || c.factory, exit: c.exit, reactive: c.reactive,
    smokeVault: doc.smokeVault && doc.smokeVault.address, operators: doc.operators || [] };
  for (const k of ['token', 'maker', 'exit', 'reactive']) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(d[k] || '')) die(`deployments/${name}.json: ${k} is not an address`);
  }
  return d;
}

/* ---------- JSON-RPC (read only) ---------- */

async function rpc(url, method, params, timeoutMs = 20000) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { method: 'POST', signal: ctl.signal,
      headers: { 'content-type': 'application/json', 'user-agent': UA },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
    const text = await res.text();
    let body;
    try { body = JSON.parse(text); } catch (e) { return { error: { code: -32603, message: `HTTP ${res.status}, not JSON` } }; }
    if (body.error) return { error: { code: body.error.code || -32603, message: String(body.error.message || 'RPC error').slice(0, 300), data: body.error.data } };
    return { result: body.result };
  } catch (e) {
    return { error: { code: -32603, message: ctl.signal.aborted ? 'RPC timeout' : 'RPC unreachable' } };
  } finally { clearTimeout(timer); }
}

/* First endpoint that answers without an RPC error. */
async function rpcAny(urls, method, params) {
  let last = null;
  for (const u of urls) {
    const r = await rpc(u, method, params);
    if (!r.error) return r;
    last = r;
  }
  return last;
}

/* Retries until fn returns a value other than null/undefined, or the time is up. */
async function until(fn, ms, every = 1500) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v !== null && v !== undefined) return v;
    if (Date.now() > end) return null;
    await sleep(every);
  }
}

async function receipt(urls, hash, ms = 45000) {
  return until(async () => {
    const r = await rpcAny(urls, 'eth_getTransactionReceipt', [hash]);
    return r && r.result ? r.result : null;
  }, ms);
}

async function blockTs(urls, number) {
  const b = await until(async () => {
    const r = await rpcAny(urls, 'eth_getBlockByNumber', [number, false]);
    return r && r.result ? r.result : null;
  }, 30000);
  return b ? Number(BigInt(b.timestamp)) : null;
}

async function call(urls, to, data) {
  const r = await rpcAny(urls, 'eth_call', [{ to, data }, 'latest']);
  if (!r || r.error || typeof r.result !== 'string') return null;
  return r.result;
}

async function uintOf(urls, to, data) {
  const v = await call(urls, to, data);
  return v && v.length >= 66 ? BigInt(v.slice(0, 66)) : null;
}

/* ---------- the walk's record ---------- */

const W = {
  result: 'running', dry: false, failure: null, states: [], stateLog: [], requests: {}, refused: [], unsupported: [],
  sent: [], dryRequests: [], consoleErrors: [], warnings: [], networkErrors: [], screenshots: [], checks: [],
  connected: false, notes: [],
};
function fail(reason) {
  if (!W.failure) {
    W.failure = oneLine(reason);
    log(`FAIL ${W.failure}`);
  }
}

/* ---------- the signer ---------- */

let KEY = null; /* set once from WALK_KEY; never printed */
let ME = null;
let OPT = null;
let DEP = null;
let signChain = Promise.resolve();

function childEnv() {
  const env = { ...process.env };
  for (const k of ['WALK_KEY', 'DEPLOY_KEY', 'KEY_B', 'TESTNET_KEY', 'RELAY_KEY']) delete env[k];
  return env;
}

function scrub(text) {
  let t = String(text || '');
  if (KEY) {
    const bare = strip0x(KEY);
    t = t.replace(new RegExp(bare, 'gi'), '***');
  }
  return t.slice(-1500);
}

function runCast(argv, timeoutMs) {
  return new Promise((done) => {
    let out = '';
    let err = '';
    let finished = false;
    let child;
    const finish = (code, note) => {
      if (finished) return;
      finished = true;
      done({ code, out, err: scrub(note || err) });
    };
    try {
      child = spawn(CAST, argv, { env: childEnv(), stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true, shell: false });
    } catch (e) {
      finish(-1, 'cast could not start');
      return;
    }
    const timer = setTimeout(() => { try { child.kill('SIGKILL'); } catch (e) { /* gone */ } finish(-1, 'cast did not finish in time'); }, timeoutMs);
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err = (err + d).slice(-8000); });
    /* never print the error object of a failed child: Node puts its full command line there */
    child.on('error', () => { clearTimeout(timer); finish(-1, 'cast could not start'); });
    child.on('close', (code) => { clearTimeout(timer); finish(code); });
  });
}

function lastJson(text) {
  for (let i = text.indexOf('{'); i >= 0; i = text.indexOf('{', i + 1)) {
    try { return JSON.parse(text.slice(i)); } catch (e) { /* not here */ }
  }
  return null;
}

/* The calls the signer allows, per target class. check() returns true, or a reason to refuse. */
function callTable(ctx) {
  const toMe = (a) => same(a, ctx.me);
  return {
    token: {
      'mint(address,uint256)': { label: 'get demo dollars', check: (a) => toMe(a[0]) || 'mints to another address' },
      'approve(address,uint256)': { label: 'let the vault take the demo dollars', vaultArg: 0 },
    },
    maker: { 'create()': { label: 'make a vault' } },
    vault: {
      'deposit(uint256,address)': { label: 'deposit', check: (a) => toMe(a[1]) || 'the shares would go to another address' },
      'mint(uint256,address)': { label: 'deposit (by shares)', check: (a) => toMe(a[1]) || 'the shares would go to another address' },
      'approve(address,uint256)': { label: 'allow the exit contract to redeem the shares', check: (a) => same(a[0], DEP.exit) || 'approves a spender other than the exit contract' },
      'submit(bytes)': { label: 'schedule the change as the curator', curator: true,
        check: (a) => ctx.kindSels.includes(lower(a[0]).slice(0, 10)) || `schedules ${lower(a[0]).slice(0, 10)}, not a ${ctx.kind} change` },
      'redeem(uint256,address,address)': { label: 'withdraw', check: (a) => (toMe(a[1]) && toMe(a[2])) || 'redeems to or from another address' },
      'withdraw(uint256,address,address)': { label: 'withdraw', check: (a) => (toMe(a[1]) && toMe(a[2])) || 'withdraws to or from another address' },
    },
    exit: {
      'arm(address,uint8,uint8,uint256)': { label: 'turn the watch on', vaultArg: 0,
        check: (a) => (Number(a[1]) === ctx.watchKinds && Number(a[2]) === ctx.mode) ||
          `arms kinds ${a[1]} mode ${a[2]}; this walk asked for kinds ${ctx.watchKinds} mode ${ctx.mode}` },
      'cancel(uint256)': { label: 'turn the watch off' },
    },
  };
}

/* The vaults this walk may sign on: the one its own create() made, and the walk address's last vault from the maker
   (read once at the start). Listed by the maker is necessary, not enough: the maker makes a vault for anyone. */
const OWN = new Set();
function addOwn(addr) { if (/^0x[0-9a-fA-F]{40}$/.test(addr || '') && !same(addr, ZERO_ADDR)) OWN.add(lower(addr)); }
const isOwn = (addr) => OWN.has(lower(addr));

/* The vault's curator() is the walk address (asked of the sending endpoint first, like isVault). */
async function curatorIsMe(vault) {
  const yes = await until(async () => {
    for (const u of [BASE_SEND, ...BASE_READ]) {
      const v = await call([u], vault, sel('curator()'));
      if (v && v.length >= 66) return same(topicAddr(v.slice(0, 66)), ME) ? true : false;
    }
    return null;
  }, 12000, 2000);
  return yes === true;
}

const vaultCache = new Map();
async function isVault(addr) {
  const a = lower(addr);
  if (vaultCache.get(a) === true) return true;
  /* a vault made a moment ago can read as unknown on a lagging endpoint: ask the sending endpoint first, retry a while */
  const yes = await until(async () => {
    for (const u of [BASE_SEND, ...BASE_READ]) {
      const v = await call([u], DEP.maker, sel('isVault(address)') + addrWord(a));
      if (v && BigInt(v.slice(0, 66)) === 1n) return true;
    }
    return null;
  }, 12000, 2000);
  if (yes) vaultCache.set(a, true);
  return !!yes;
}

/* Returns { ok: true, cls, sig, args, label } or { ok: false, why }. */
async function policy(tx) {
  if (!tx || typeof tx !== 'object') return { ok: false, why: 'no transaction object' };
  if (!same(tx.from, ME)) return { ok: false, why: `from ${tx.from} is not the walk address` };
  if (tx.chainId !== undefined && lower(tx.chainId) !== BASE_HEX && Number(tx.chainId) !== BASE_ID) return { ok: false, why: `chain ${tx.chainId} is not Base Sepolia` };
  if (tx.value !== undefined && tx.value !== null && BigInt(tx.value) !== 0n) return { ok: false, why: 'the transaction carries value' };
  if (!/^0x[0-9a-fA-F]{40}$/.test(tx.to || '')) return { ok: false, why: 'no target address (contract creation is never signed)' };
  const data = tx.data || tx.input;
  if (!/^0x([0-9a-fA-F]{2}){4,}$/.test(data || '')) return { ok: false, why: 'no call data' };
  if (tx.gas !== undefined && BigInt(tx.gas) > MAX_GAS) return { ok: false, why: `gas ${BigInt(tx.gas)} is above ${MAX_GAS}` };
  if (W.sent.length + W.dryRequests.length >= MAX_SENDS) return { ok: false, why: `more than ${MAX_SENDS} transactions in one walk` };
  const ctx = { me: ME, kind: OPT.kind, mode: OPT.mode, watchKinds: WATCH_KINDS[OPT.kind], kindSels: KIND_SIGS[OPT.kind].map(sel) };
  const table = callTable(ctx);
  let cls = null;
  if (same(tx.to, DEP.token)) cls = 'token';
  else if (same(tx.to, DEP.maker)) cls = 'maker';
  else if (same(tx.to, DEP.exit)) cls = 'exit';
  else if (isOwn(tx.to) && (await isVault(tx.to))) cls = 'vault';
  if (!cls) return { ok: false, why: `target ${tx.to} is not the demo dollar, the maker, the exit contract of deployment ${DEP.name} or this walk's own listed vault` };
  const selector = lower(data).slice(0, 10);
  const sig = Object.keys(table[cls]).find((s) => sel(s) === selector);
  if (!sig) return { ok: false, why: `${cls} call ${selector} is not one the walk signs` };
  const types = typesOf(sig);
  let args;
  try { args = decodeArgs(types, strip0x(data).slice(8)); } catch (e) { return { ok: false, why: `${sig}: ${e.message}` }; }
  if (encodeArgs(types, args) !== strip0x(data).slice(8)) return { ok: false, why: `${sig}: the call data is not the standard encoding of its arguments` };
  const rule = table[cls][sig];
  if (rule.vaultArg !== undefined && !(isOwn(args[rule.vaultArg]) && (await isVault(args[rule.vaultArg])))) {
    return { ok: false, why: `${sig}: ${args[rule.vaultArg]} is not this walk's own listed vault` };
  }
  if (rule.check) {
    const r = rule.check(args);
    if (r !== true) return { ok: false, why: `${sig}: ${r}` };
  }
  if (rule.curator && !(await curatorIsMe(tx.to))) return { ok: false, why: `${sig}: the walk address is not the curator of ${tx.to}` };
  return { ok: true, cls, sig, types, args, label: rule.label, data: lower(data), to: lower(tx.to), gas: tx.gas === undefined ? null : BigInt(tx.gas) };
}

const refuse = (code, message) => ({ ok: false, error: { code, message } });

function refuseStopped(what) {
  W.refused.push({ at: secs(), method: 'eth_sendTransaction', why: W.failure ? 'the walk had already failed' : 'the walk had ended' });
  if (!W.failure) fail(`the page asked to sign ${what} after the walk ended`);
  return refuse(4001, 'Refused: the walk has stopped');
}

async function sendTransaction(tx) {
  /* refused at once, before any read, so the refusal is in the record before the result is decided */
  if (!OPT.dry && (W.failure || W.stopped)) return refuseStopped(`a transaction to ${oneLine(tx && tx.to).slice(0, 42)}`);
  const p = await policy(tx);
  if (OPT.dry) {
    W.dryRequests.push({ at: secs(), to: tx && tx.to, selector: tx && lower(tx.data || '').slice(0, 10), policy: p.ok ? `would sign: ${p.sig} (${p.label})` : `would refuse: ${p.why}` });
    log(`dry: confirmation ${W.dryRequests.length} rejected with 4001 (${p.ok ? `policy would sign ${p.sig}` : `policy would refuse: ${p.why}`})`);
    return refuse(4001, 'Rejected: dry walk, nothing is signed');
  }
  /* once the walk has failed or the page has reached its end state, nothing more is signed; a request after the end
     is itself a failure (the walk's result must not stay green while the page asks for more) */
  if (W.failure || W.stopped) return refuseStopped(p.ok ? p.sig : 'a transaction');
  if (!p.ok) {
    W.refused.push({ at: secs(), method: 'eth_sendTransaction', why: p.why });
    fail(`refused a transaction: ${p.why}`);
    return refuse(4001, 'Refused by the walk signer');
  }
  const argv = ['send', '--json', '--rpc-url', BASE_SEND, '--private-key', KEY, p.to, p.sig, ...p.types.map((t, i) => castArg(t, p.args[i]))];
  if (p.gas) argv.push('--gas-limit', p.gas.toString());
  log(`signing ${p.label}: ${p.sig} on ${p.to}`);
  const r = await runCast(argv, 240000);
  const rec = r.code === 0 ? lastJson(r.out) : null;
  const hash = rec && /^0x[0-9a-fA-F]{64}$/.test(rec.transactionHash || '') ? lower(rec.transactionHash) : null;
  if (!hash) {
    fail(`cast send failed for ${p.sig} (exit ${r.code}): ${r.err.trim().split('\n').slice(-3).join(' | ')}`);
    return refuse(-32603, 'The transaction could not be sent');
  }
  const status = String(rec.status);
  const entry = { at: secs(), label: p.label, sig: p.sig, to: p.to, args: p.args.map((a) => lower(String(a))), hash, status,
    block: rec.blockNumber ? Number(BigInt(rec.blockNumber)) : null };
  W.sent.push(entry);
  if (!['1', '0x1', 'true'].includes(lower(status))) fail(`${p.sig} was mined and failed (status ${status}, ${hash})`);
  /* the transaction as mined must carry exactly what the page asked for */
  const mined = await until(async () => {
    const t = await rpcAny([BASE_SEND, ...BASE_READ], 'eth_getTransactionByHash', [hash]);
    return t && t.result ? t.result : null;
  }, 30000);
  if (!mined) fail(`${hash} could not be read back`);
  else if (lower(mined.input) !== p.data || !same(mined.to, p.to) || !same(mined.from, ME) || BigInt(mined.value) !== 0n) {
    fail(`${hash} as mined differs from the page's request`);
  }
  entry.logs = (rec.logs || []).map((l) => ({ address: lower(l.address), topics: (l.topics || []).map(lower), data: lower(l.data) }));
  /* the vault this walk's own create() made becomes a target; nothing the page says can add one */
  if (p.cls === 'maker' && p.sig === 'create()') {
    const tCreated = topic('VaultCreated(address,address)');
    const made = entry.logs.find((l) => same(l.address, DEP.maker) && l.topics[0] === tCreated && same(topicAddr(l.topics[2] || ''), ME));
    if (made) addOwn(topicAddr(made.topics[1]));
  }
  log(`sent ${p.label}: ${hash} status ${status}`);
  return { ok: true, result: hash };
}

async function walletRequest(method, params) {
  W.requests[method] = (W.requests[method] || 0) + 1;
  const p = Array.isArray(params) ? params : [];
  switch (method) {
    case 'eth_requestAccounts':
      W.connected = true;
      return { ok: true, result: [ME] };
    case 'eth_accounts':
      return { ok: true, result: W.connected ? [ME] : [] };
    case 'eth_chainId':
      return { ok: true, result: BASE_HEX };
    case 'net_version':
      return { ok: true, result: String(BASE_ID) };
    case 'wallet_getPermissions':
      return { ok: true, result: W.connected ? [{ parentCapability: 'eth_accounts' }] : [] };
    case 'wallet_requestPermissions':
      W.connected = true;
      return { ok: true, result: [{ parentCapability: 'eth_accounts' }] };
    case 'wallet_switchEthereumChain':
    case 'wallet_addEthereumChain': {
      const id = p[0] && p[0].chainId;
      if (lower(id) === BASE_HEX) return { ok: true, result: null };
      W.refused.push({ at: secs(), method, why: `chain ${id}` });
      fail(`the page asked the wallet for chain ${id}`);
      return refuse(4001, 'This wallet stays on Base Sepolia');
    }
    case 'eth_sendTransaction': {
      const job = signChain.then(() => sendTransaction(p[0]));
      signChain = job.catch(() => {});
      return job;
    }
    default:
      break;
  }
  if (SIGNING.has(method) || /^eth_sign/.test(method)) {
    W.refused.push({ at: secs(), method, why: 'signing method other than eth_sendTransaction' });
    fail(`the page asked for ${method}`);
    return refuse(4001, 'Refused: this wallet signs eth_sendTransaction only');
  }
  if (READ.has(method)) {
    const r = await rpcAny(BASE_READ, method, p);
    return r.error ? { ok: false, error: { code: r.error.code, message: r.error.message, data: r.error.data } } : { ok: true, result: r.result };
  }
  W.unsupported.push({ at: secs(), method });
  /* the page asks only for the methods above (docs/wallet.js); anything else is refused and fails the walk */
  fail(`the page asked for an unsupported wallet method ${oneLine(method).slice(0, 80)}`);
  return refuse(4200, `Unsupported method ${method}`);
}

/* The script the page gets before its own. Runs in the page; talks to Node only through the binding. */
function walletScript(uuid) {
  const icon = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><rect width="20" height="20" rx="4" fill="#335"/></svg>');
  return `(() => {
  const BINDING = ${JSON.stringify(BINDING)};
  if (typeof window[BINDING] !== 'function' || window.__npWalkWallet) return;
  const pending = new Map();
  const listeners = {};
  let next = 0;
  const provider = {
    isPageWalk: true,
    request(args) {
      if (!args || typeof args.method !== 'string') return Promise.reject(Object.assign(new Error('Invalid request'), { code: -32600 }));
      return new Promise((resolve, reject) => {
        next += 1;
        pending.set(next, { resolve, reject });
        window[BINDING](JSON.stringify({ id: next, method: args.method, params: args.params === undefined ? [] : args.params }));
      });
    },
    on(ev, fn) { (listeners[ev] = listeners[ev] || []).push(fn); return provider; },
    removeListener(ev, fn) { listeners[ev] = (listeners[ev] || []).filter((f) => f !== fn); return provider; },
  };
  Object.defineProperty(window, '__npWalkWallet', { value: Object.freeze({
    reply(id, ok, payload) {
      const p = pending.get(id);
      if (!p) return;
      pending.delete(id);
      if (ok) p.resolve(payload);
      else p.reject(Object.assign(new Error(payload && payload.message || 'Wallet error'), { code: payload && payload.code, data: payload && payload.data }));
    },
  }) });
  window.ethereum = provider;
  const info = Object.freeze({ uuid: ${JSON.stringify(uuid)}, name: 'Page walk wallet', icon: ${JSON.stringify(icon)}, rdns: 'local.page-walk' });
  const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: Object.freeze({ info, provider }) }));
  window.addEventListener('eip6963:requestProvider', announce);
  announce();
})();`;
}

/* ---------- Chrome over the DevTools protocol ---------- */

async function launchChrome(bin, noSandbox) {
  const profile = mkdtempSync(join(tmpdir(), 'np-walk-'));
  const args = [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync',
    '--disable-background-networking', '--disable-component-update', '--disable-default-apps',
    '--mute-audio', '--hide-scrollbars', '--lang=en-US', `--window-size=${VIEW.width},${VIEW.height}`, 'about:blank',
  ];
  if (noSandbox) args.unshift('--no-sandbox');
  let err = '';
  let spawnError = false;
  const proc = spawn(bin, args, { env: childEnv(), stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
  proc.on('error', () => { spawnError = true; });
  proc.stderr.on('data', (d) => { err = (err + d).slice(-4000); });
  const tail = () => err.trim().split('\n').slice(-4).join(' | ');
  const portFile = join(profile, 'DevToolsActivePort');
  const start = Date.now();
  while (Date.now() - start < 30000) {
    if (spawnError) return { error: 'the browser could not start', profile };
    /* exit code 0 is a launcher handing over to the browser it started (Edge on Windows does this): keep waiting
       for the port file; the browser is then closed over the protocol (Browser.close), not by its process */
    if ((proc.exitCode !== null && proc.exitCode !== 0) || proc.signalCode !== null) return { error: `the browser exited (${proc.exitCode ?? proc.signalCode}): ${tail()}`, profile };
    if (existsSync(portFile)) {
      const lines = readFileSync(portFile, 'utf8').split('\n').map((s) => s.trim());
      if (/^\d+$/.test(lines[0] || '') && (lines[1] || '').startsWith('/devtools/browser/')) {
        try {
          const info = await (await fetch(`http://127.0.0.1:${lines[0]}/json/version`)).json();
          if (info.webSocketDebuggerUrl) return { proc, profile, ws: info.webSocketDebuggerUrl, product: info.Browser };
        } catch (e) { /* the port file can precede the listener by a moment */ }
      }
    }
    await sleep(100);
  }
  try { proc.kill('SIGKILL'); } catch (e) { /* gone */ }
  return { error: `the browser did not open its DevTools port within 30 s: ${tail()}`, profile };
}

class Cdp {
  constructor(url) { this.url = url; this.next = 0; this.pending = new Map(); this.listeners = new Set(); }

  open() {
    return new Promise((ok, no) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;
      let opened = false;
      ws.onopen = () => { opened = true; ok(); };
      ws.onerror = () => { if (!opened) no(new Error('DevTools WebSocket failed')); };
      ws.onclose = () => {
        for (const p of this.pending.values()) p.reject(new Error(`DevTools connection closed during ${p.method}`));
        this.pending.clear();
      };
      ws.onmessage = (ev) => this.message(ev.data);
    });
  }

  message(data) {
    const msg = JSON.parse(typeof data === 'string' ? data : Buffer.from(data).toString('utf8'));
    if (msg.id !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
      else p.resolve(msg.result || {});
      return;
    }
    for (const fn of this.listeners) fn(msg);
  }

  send(method, params = {}, sessionId = undefined, timeoutMs = 60000) {
    this.next += 1;
    const id = this.next;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((ok, no) => {
      const timer = setTimeout(() => { this.pending.delete(id); no(new Error(`${method}: no answer in ${timeoutMs / 1000} s`)); }, timeoutMs);
      this.pending.set(id, { method, resolve: (v) => { clearTimeout(timer); ok(v); }, reject: (e) => { clearTimeout(timer); no(e); } });
      this.ws.send(JSON.stringify(payload));
    });
  }

  on(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  close() { try { this.ws.close(); } catch (e) { /* closed */ } }
}

let CDP = null;
let SID = null;
let ORIGIN = '';
const tab = (method, params = {}, timeoutMs = 60000) => CDP.send(method, params, SID, timeoutMs);

async function evalPage(expression) {
  const r = await tab('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(`page evaluation failed: ${(r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text}`);
  return r.result ? r.result.value : undefined;
}

function onEvent(m) {
  if (m.sessionId !== SID) return;
  const p = m.params || {};
  switch (m.method) {
    case 'Runtime.bindingCalled': {
      if (p.name !== BINDING) return;
      let req;
      try { req = JSON.parse(p.payload); } catch (e) { return; }
      if (!req || typeof req.id !== 'number' || typeof req.method !== 'string') return;
      Promise.resolve().then(() => walletRequest(req.method, req.params)).catch((e) => {
        fail(`wallet handler error on ${req.method}: ${scrub(e && e.message)}`);
        return refuse(-32603, 'Internal wallet error');
      }).then((ans) => {
        const payload = ans.ok ? ans.result : ans.error;
        return tab('Runtime.evaluate', { contextId: p.executionContextId,
          expression: `window.__npWalkWallet && window.__npWalkWallet.reply(${req.id}, ${ans.ok ? 'true' : 'false'}, ${JSON.stringify(payload === undefined ? null : payload)})` });
      }).catch(() => { /* the page navigated away */ });
      return;
    }
    case 'Runtime.consoleAPICalled': {
      const text = (p.args || []).map((a) => (a.value !== undefined ? String(a.value) : (a.description || a.type))).join(' ').slice(0, 500);
      if (p.type === 'error' || p.type === 'assert') { W.consoleErrors.push({ at: secs(), text }); fail(`console error: ${text}`); }
      else if (p.type === 'warning') W.warnings.push({ at: secs(), text });
      else if (/^\[notice-period\] state:/.test(text)) W.stateLog.push({ at: secs(), id: text.replace(/^\[notice-period\] state:\s*/, '') });
      return;
    }
    case 'Runtime.exceptionThrown': {
      const d = p.exceptionDetails || {};
      const text = ((d.exception && d.exception.description) || d.text || 'exception').slice(0, 500);
      W.consoleErrors.push({ at: secs(), text });
      fail(`uncaught exception in the page: ${text}`);
      return;
    }
    case 'Log.entryAdded': {
      const e = p.entry || {};
      if (e.level !== 'error') return;
      const item = { at: secs(), source: e.source, text: String(e.text || '').slice(0, 300), url: e.url || '' };
      /* a failed read of one of the page's public endpoints (refused, rate-limited, blocked by its CORS answer) is
         recorded, not failed: the page retries those. A policy violation never counts as one. */
      const outside = (s) => OUTSIDE_HOSTS.some((h) => String(s || '').includes(`https://${h}`));
      if (!['security', 'violation'].includes(e.source) && (outside(item.url) || outside(item.text))) { W.networkErrors.push(item); return; }
      if (e.source === 'network' && item.url && ORIGIN && !item.url.startsWith(ORIGIN)) { W.networkErrors.push(item); return; }
      /* the browser asks for /favicon.ico by itself; the page names its own icon */
      if (e.source === 'network' && item.url === `${ORIGIN}/favicon.ico`) { W.networkErrors.push(item); return; }
      W.consoleErrors.push(item);
      fail(`browser error (${e.source}): ${item.text} ${item.url}`.trim());
      return;
    }
    case 'Page.javascriptDialogOpening':
      tab('Page.handleJavaScriptDialog', { accept: false }).catch(() => {});
      fail(`the page opened a dialog: ${String(p.message || '').slice(0, 200)}`);
      return;
    default:
  }
}

async function screenshot(name, panel = false) {
  if (!OPT.out || !CDP) return null;
  try {
    if (panel) await evalPage(`(() => { const b = document.getElementById('state'); if (b) b.scrollIntoView({ block: 'center' }); })()`).catch(() => {});
    const r = await tab('Page.captureScreenshot', { format: 'jpeg', quality: 60 }, 30000);
    const file = join(OPT.out, `${String(W.screenshots.length + 1).padStart(2, '0')}-${name}.jpg`);
    writeFileSync(file, Buffer.from(r.data, 'base64'));
    W.screenshots.push(file);
    return r.data;
  } catch (e) { W.notes.push(`screenshot ${name} failed: ${e.message}`); return null; }
}

/* ---------- driving the page ---------- */

const SNAP = `(() => {
  const box = document.getElementById('state');
  if (!box) return { state: null };
  const h = box.querySelector('.state-h');
  const acts = Array.prototype.map.call(box.querySelectorAll('[data-a]'), (b) => ({ a: b.getAttribute('data-a'), off: !!b.disabled }));
  return { state: box.getAttribute('data-state'), cls: box.className, head: h ? h.textContent : '', text: (box.innerText || '').slice(0, 1500), acts: acts };
})()`;

async function clickSel(selector) {
  const r = await evalPage(`(() => {
    const el = document.querySelector(${JSON.stringify(selector)});
    if (!el) return { found: false };
    if (el.disabled) return { found: true, disabled: true };
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const b = el.getBoundingClientRect();
    const x = b.left + b.width / 2;
    const y = b.top + b.height / 2;
    const hit = document.elementFromPoint(x, y);
    return { found: true, disabled: false, x: x, y: y, w: b.width, hitOk: !!hit && (hit === el || el.contains(hit) || (el.labels && Array.prototype.some.call(el.labels, (l) => l.contains(hit)))) };
  })()`);
  if (!r || !r.found || r.disabled) return false;
  if (r.w > 0 && r.hitOk) {
    await tab('Input.dispatchMouseEvent', { type: 'mouseMoved', x: r.x, y: r.y });
    await tab('Input.dispatchMouseEvent', { type: 'mousePressed', x: r.x, y: r.y, button: 'left', clickCount: 1 });
    await tab('Input.dispatchMouseEvent', { type: 'mouseReleased', x: r.x, y: r.y, button: 'left', clickCount: 1 });
  } else {
    await evalPage(`document.querySelector(${JSON.stringify(selector)}).click()`);
    W.notes.push(`clicked ${selector} by script (not hit-testable at its centre)`);
  }
  return true;
}

const MODE_SELECTORS = (m) => [`#state input[name="mode"][value="${m}"]`, `#state [data-mode="${m}"]`, `#state [data-a="mode-${m}"]`];

async function findFirst(selectors) {
  for (const s of selectors) {
    if (await evalPage(`!!document.querySelector(${JSON.stringify(s)})`)) return s;
  }
  return null;
}

async function configureWatch() {
  const want = WATCH_KINDS[OPT.kind];
  const modeSel = await findFirst(MODE_SELECTORS(OPT.mode));
  if (OPT.mode === 1 && !modeSel) { fail('the page offers no control for "leave if still pending" (mode 1); this walk cannot choose it'); return false; }
  if (modeSel) {
    const on = await evalPage(`(() => { const e = document.querySelector(${JSON.stringify(modeSel)}); return e.type === 'radio' || e.type === 'checkbox' ? e.checked : e.getAttribute('aria-pressed') === 'true'; })()`);
    if (!on && !(await clickSel(modeSel))) { fail(`could not choose mode ${OPT.mode}`); return false; }
  }
  const boxes = async () => evalPage(`Array.prototype.map.call(document.querySelectorAll('#state input[data-bit]'), (b) => ({ bit: Number(b.getAttribute('data-bit')), checked: b.checked, disabled: b.disabled }))`);
  let list = await boxes();
  if (!list.length) { fail('the watch step shows no kind boxes (input[data-bit])'); return false; }
  /* tick first, untick after: with no kind ticked the page disables "Turn the watch on" */
  for (const pass of [true, false]) {
    for (const b of list) {
      const on = (want & b.bit) !== 0;
      if (on !== pass || b.checked === on) continue;
      if (b.disabled) { fail(`the page locks the box of kind ${b.bit}; this walk needs kinds ${want}`); return false; }
      await clickSel(`#state input[data-bit="${b.bit}"]`);
      await sleep(150);
    }
    list = await boxes();
  }
  const got = list.reduce((acc, b) => acc | (b.checked ? b.bit : 0), 0);
  if (got !== want) { fail(`the kind boxes read ${got} after setting them, not ${want}`); return false; }
  W.watchKinds = want;
  return true;
}

/* Dry only, after the rejected confirmation: the watch step and the curator step are drawn by the page's own
   renderer (NP.run.go) with no chain behind them, and the walk's box setting is run on them for every kind. Nothing
   is pressed that would ask the wallet for anything (no arm, no schedule). */
async function dryUiCheck() {
  const out = {};
  const keep = OPT.kind;
  for (const kind of Object.keys(KIND_BITS)) {
    const want = WATCH_KINDS[kind];
    await evalPage(`(() => { NP.run.state.kinds = 7; NP.run.go('deposited', { shares: '100', pendingLine: '' }); })()`);
    await sleep(200);
    OPT.kind = kind;
    const boxesSet = await configureWatch();
    OPT.kind = keep;
    const pageKinds = await evalPage('NP.run.state.kinds');
    const armOn = await evalPage(`(() => { const b = document.querySelector('#state [data-a="arm"]'); return b ? !b.disabled : null; })()`);
    await evalPage(`NP.run.go('armed', { id: 1, kinds: ${want} })`);
    await sleep(100);
    const button = await evalPage(`(() => { const b = document.querySelector('#state [data-a="schedule-${KIND_BITS[kind]}"]'); return b ? !b.disabled : null; })()`);
    out[kind] = { boxesSet, pageKinds, armEnabled: armOn, scheduleButton: button };
    if (!boxesSet || pageKinds !== want || armOn !== true || button !== true) fail(`dry check of the watch and curator steps for ${kind}: ${JSON.stringify(out[kind])}`);
    if (W.failure) break;
  }
  return out;
}

async function tokenBalance(addr) { return uintOf(BASE_READ, DEP.token, sel('balanceOf(address)') + addrWord(addr)); }

async function walkVault() {
  const made = W.sent.find((s) => s.sig === 'create()' && s.logs);
  if (made) {
    const t = topic('VaultCreated(address,address)');
    const l = made.logs.find((x) => same(x.address, DEP.maker) && x.topics[0] === t && same(topicAddr(x.topics[2]), ME));
    if (l) return topicAddr(l.topics[1]);
  }
  const v = await call(BASE_READ, DEP.maker, sel('lastVaultOf(address)') + addrWord(ME));
  return v ? '0x' + v.slice(26, 66) : null;
}

/* The page's checks of its own: the states, buttons and contracts this walk relies on. */
async function checkPage() {
  const wk = WATCH_KINDS[OPT.kind];
  const info = await evalPage(`(() => {
    const NP = window.NP || {};
    const st = NP.states || {};
    const acts = (id, ctx) => { const d = st[id]; if (!d) return null; const a = typeof d.actions === 'function' ? d.actions(ctx || {}) : d.actions; return (a || []).map((x) => x.a); };
    const c = (NP.config && NP.config.contracts) || {};
    const f = (NP.config && NP.config.flags) || {};
    return { run: !!NP.run, ids: Object.keys(st), idle: acts('idle'), stepDeposit: acts('step-deposit'), deposited: acts('deposited'),
      armed: acts('armed', { kinds: ${wk} }), confirmRejected: acts('confirm-rejected'),
      contracts: { token: c.token || null, maker: c.maker || c.factory || null, exit: c.exit || null, reactive: c.reactive || null },
      flags: { mode1: f.mode1 === undefined ? null : !!f.mode1, unprovenKinds: f.unprovenKinds === undefined ? null : !!f.unprovenKinds } };
  })()`);
  W.page = { contracts: info.contracts, flags: info.flags };
  const problems = [];
  if (!info.run) problems.push('the page script did not start (NP.run missing)');
  const missing = REQUIRED_STATES.filter((s) => !info.ids.includes(s));
  if (missing.length) problems.push(`states missing: ${missing.join(', ')}`);
  if (!(info.idle || []).includes('connect')) problems.push('idle has no "connect" button');
  if (!(info.stepDeposit || []).includes('deposit')) problems.push('step-deposit has no "deposit" button');
  if (!(info.deposited || []).includes('arm')) problems.push('deposited has no "arm" button');
  if (!(info.armed || []).includes(`schedule-${KIND_BITS[OPT.kind]}`)) problems.push(`armed offers no "schedule-${KIND_BITS[OPT.kind]}" button for kinds ${wk}`);
  if (OPT.mode === 1 && info.flags.mode1 === false) problems.push('the page has "leave if still pending" switched off (flags.mode1)');
  if ((wk & 1) === 0 && info.flags.unprovenKinds === false) problems.push(`the page keeps "a new adapter" in every watch (flags.unprovenKinds off), so a ${OPT.kind} walk is not possible`);
  if (problems.length) { fail(`the page cannot be walked as asked: ${problems.join('; ')}`); return false; }
  const diff = ['token', 'maker', 'exit', 'reactive'].filter((k) => !same(info.contracts[k], DEP[k]));
  if (diff.length) {
    const msg = `the page's contracts differ from deployment ${DEP.name}: ${diff.map((k) => `${k} ${info.contracts[k]} (deployment ${DEP[k]})`).join(', ')}`;
    if (OPT.dry && OPT.allowOtherContracts) { W.notes.push(msg); log(`note: ${msg}`); } else { fail(msg); return false; }
  }
  return true;
}

const FAIL_STATES = new Set(['no-wallet', 'no-wallet-phone', 'unsupported-wallet', 'connect-rejected', 'wallet-busy',
  'switch-refused', 'no-gas', 'runs-used-up', 'address-used-up', 'slots-full', 'float-empty', 'would-fail',
  'wallet-error', 'tx-failed', 'vault-tampered', 'deposit-short', 'watch-refused', 'unwatched-wait', 'ignored', 'missed',
  'reactive-timeout', 'callback-slow', 'nothing-to-redeem', 'redeem-failed', 'withdrawn-by-hand', 'watch-off',
  'page-error', 'account-changed', 'framed', 'run-not-yet', 'run-too-old', 'reading-run', 'replay', 'watch-closed',
  'run-still-on', 'run-no-exit']);

/* Returns 'returned', 'dry-ok', or null on failure. */
async function drive() {
  const deadline = Date.now() + OPT.timeout * 1000;
  let last = null;
  let enteredAt = Date.now();
  let acted = false;
  let actedAt = 0;
  let rpcRetries = 0;
  let keepWaits = 0;
  let restarts = 0;
  let unknownSince = null;
  const bit = KIND_BITS[OPT.kind];
  for (;;) {
    if (W.failure) return null;
    if (Date.now() > deadline) { fail(`no end state within ${OPT.timeout} s (last state ${last})`); return null; }
    let s;
    try { s = await evalPage(SNAP); } catch (e) { await sleep(500); continue; }
    if (!s || !s.state) { await sleep(400); continue; }
    if (s.state !== last) {
      W.states.push({ id: s.state, at: secs(), head: s.head });
      log(`state ${s.state}${s.head ? `: ${s.head}` : ''}`);
      last = s.state;
      enteredAt = Date.now();
      acted = false;
      unknownSince = null;
    }
    W.last = s;
    const dwell = (Date.now() - enteredAt) / 1000;
    const enabled = (a) => (s.acts || []).some((x) => x.a === a && !x.off);
    /* act once per visit; again only if the page is still there with the button enabled after 8 s */
    const may = () => !acted || (Date.now() - actedAt > 8000);
    const press = async (a) => {
      if (!may() || !enabled(a)) return false;
      acted = true;
      actedAt = Date.now();
      log(`press ${a}`);
      return clickSel(`#state [data-a="${a}"]`);
    };
    switch (s.state) {
      case 'idle': await press('connect'); break;
      case 'choose-wallet':
        if (may()) {
          acted = true; actedAt = Date.now();
          const ok = await evalPage(`(() => { const b = Array.prototype.find.call(document.querySelectorAll('#state .wallets button'), (x) => x.textContent.trim() === 'Page walk wallet'); if (b) b.click(); return !!b; })()`);
          if (!ok) fail('the wallet chooser does not list the walk wallet');
        }
        break;
      case 'wrong-network': await press('switch'); break;
      case 'step-deposit': await press('deposit'); break;
      case 'confirm-rejected':
        /* a dry walk passes only on one request that the live signer would have signed */
        if (OPT.dry && W.dryRequests.length === 1 && /^would sign: /.test(W.dryRequests[0].policy)) return 'dry-ok';
        if (OPT.dry && W.dryRequests.length === 1) fail(`the page's first confirmation is one the signer refuses (${W.dryRequests[0].policy})`);
        else fail(OPT.dry ? `confirm-rejected after ${W.dryRequests.length} confirmation requests, expected 1` : 'the page shows a rejected confirmation');
        return null;
      case 'deposited':
        if (!acted && dwell > 0.5) {
          acted = true; actedAt = Date.now();
          if (OPT.dry) { fail('reached the watch step in a dry walk'); return null; }
          if (!(await configureWatch())) return null;
          await sleep(300);
          log('press arm');
          if (!(await clickSel('#state [data-a="arm"]'))) { fail('"Turn the watch on" is not clickable after setting the kinds'); return null; }
        }
        break;
      case 'armed':
        if (!acted) {
          acted = true; actedAt = Date.now();
          if (!enabled(`schedule-${bit}`)) { fail(`the curator step offers no enabled "schedule-${bit}" (buttons: ${(s.acts || []).map((x) => x.a).join(', ')})`); return null; }
          W.vault = await walkVault();
          W.tokenBefore = await tokenBalance(ME);
          W.sharesBefore = W.vault ? await uintOf(BASE_READ, W.vault, sel('balanceOf(address)') + addrWord(ME)) : null;
          log(`press schedule-${bit}`);
          await clickSel(`#state [data-a="schedule-${bit}"]`);
        }
        break;
      case 'returned': return 'returned';
      case 'resume':
      case 'old-vault':
        if (OPT.dry) { fail(`${s.state}: this address has a deposit or watch from before; a dry walk needs a clean address`); return null; }
        if (!acted) {
          if (restarts >= 1) { fail(`${s.state} again after one restart`); return null; }
          restarts += 1;
          W.notes.push(`${s.state} at start: pressed withdraw-restart once`);
          await press('withdraw-restart');
        }
        break;
      case 'subscribe-slow':
        if (!acted) {
          if (keepWaits >= 1) { fail('Reactive did not pick up the watch, twice'); return null; }
          keepWaits += 1;
          await press('keep-waiting');
        }
        break;
      case 'rpc-down':
        if (dwell > 10 && may()) {
          if (rpcRetries >= 2) { fail(`rpc-down three times: ${s.head}`); return null; }
          rpcRetries += 1;
          W.notes.push(`rpc-down (${s.head}): pressed retry`);
          await press('retry');
        }
        break;
      default:
        if (WAIT_STATES.has(s.state)) break;
        if (FAIL_STATES.has(s.state) || /kind-(stop|done)/.test(s.cls || '')) { fail(`page state ${s.state}: ${s.head}`); return null; }
        /* an unknown state that waits: give it a minute, then fail */
        if (unknownSince === null) { unknownSince = Date.now(); W.notes.push(`unknown state ${s.state} (${s.cls})`); }
        if (Date.now() - unknownSince > 60000) { fail(`unknown state ${s.state} for 60 s`); return null; }
    }
    await sleep(400);
  }
}

async function ledgerHashes() {
  return until(async () => {
    const h = await evalPage(`(() => {
      const q = (c) => { const a = document.querySelector('#state tr.' + c + ' a.hash'); if (!a) return null; const m = /\\/tx\\/(0x[0-9a-fA-F]{64})/.exec(a.getAttribute('href') || ''); return m ? m[1].toLowerCase() : null; };
      return { h1: q('rec-sched'), h2: q('rec-react'), h3: q('rec-back') };
    })()`).catch(() => null);
    return h && h.h1 && h.h2 && h.h3 ? h : null;
  }, 90000, 2000);
}

/* ---------- the independent check (receipts, not the page) ---------- */

async function verifyRun(v) {
  const checks = [];
  const out = { checks };
  const check = (name, ok, detail) => { checks.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) }); return !!ok; };
  const [r1, r3] = [await receipt(BASE_READ, v.h1), await receipt(BASE_READ, v.h3)];
  const r2 = await receipt([LASNA_RPC], v.h2);
  if (!check('three receipts read', r1 && r2 && r3, `${!!r1} ${!!r2} ${!!r3}`)) return out;
  if (v.submitHash) check('the Submit the page shows is the one this walk signed', same(v.h1, v.submitHash), v.submitHash);
  check('1. Submit: status 1', r1.status === '0x1', r1.status);
  check('1. Submit: sent by the curator to the vault', same(r1.from, v.curator) && same(r1.to, v.vault), `${r1.from} -> ${r1.to}`);
  const tSubmit = topic('Submit(bytes4,bytes,uint256)');
  const sub = (r1.logs || []).find((l) => same(l.address, v.vault) && lower(l.topics[0]) === tSubmit);
  let execAt = null;
  if (check('1. Submit: Submit log of the vault', sub)) {
    const selector = lower(sub.topics[1]).slice(0, 10);
    check(`1. Submit: a ${v.kind} change`, KIND_SIGS[v.kind].map(sel).includes(selector), selector);
    execAt = Number(dataWord(sub.data, 1));
    out.executableAt = execAt;
  }
  check('2. Reactive: status 1', r2.status === '0x1', r2.status);
  const tExit = topic('ExitRequested(uint256,uint256,uint8,bytes32)');
  const ex = (r2.logs || []).find((l) => same(l.address, DEP.reactive) && lower(l.topics[0]) === tExit);
  if (check('2. Reactive: ExitRequested of NoticeReactive', ex)) {
    check('2. Reactive: names the watch', BigInt(ex.topics[1]) === BigInt(v.watchId), BigInt(ex.topics[1]));
    check('2. Reactive: names the Submit as its origin', same(ex.topics[2], v.h1), ex.topics[2]);
    out.exitReason = Number(dataWord(ex.data, 0));
  }
  check('3. Exit: status 1', r3.status === '0x1', r3.status);
  const tEnded = topic('WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)');
  const end = (r3.logs || []).find((l) => same(l.address, DEP.exit) && lower(l.topics[0]) === tEnded);
  if (check('3. Exit: WatchEnded of NoticeExit', end)) {
    check('3. Exit: names the watch', BigInt(end.topics[1]) === BigInt(v.watchId), BigInt(end.topics[1]));
    check('3. Exit: names the Submit as its origin', same(end.topics[2], v.h1), end.topics[2]);
    const outcome = Number(dataWord(end.data, 0));
    out.outcome = outcome;
    out.reason = Number(dataWord(end.data, 1));
    out.shares = dataWord(end.data, 2).toString();
    out.assets = dataWord(end.data, 3).toString();
    check('3. Exit: outcome 0 (redeemed)', outcome === 0, outcome);
    if (v.shares !== null && v.shares !== undefined) check('3. Exit: redeemed every share the watch covered', dataWord(end.data, 2) === BigInt(v.shares), `${out.shares} of ${v.shares}`);
    const tTransfer = topic('Transfer(address,address,uint256)');
    const tr = (r3.logs || []).find((l) => same(l.address, DEP.token) && lower(l.topics[0]) === tTransfer &&
      same(topicAddr(l.topics[1]), v.vault) && same(topicAddr(l.topics[2]), v.owner));
    if (check('3. Exit: demo dollars moved from the vault to the depositor', tr)) {
      check('3. Exit: the amount moved equals the redeemed assets', dataWord(tr.data, 0) === dataWord(end.data, 3), dataWord(tr.data, 0));
    }
  }
  const t1 = await blockTs(BASE_READ, r1.blockNumber);
  const t2 = await blockTs([LASNA_RPC], r2.blockNumber);
  const t3 = await blockTs(BASE_READ, r3.blockNumber);
  if (check('block times read', t1 !== null && t2 !== null && t3 !== null)) {
    out.t1 = t1; out.t2 = t2; out.t3 = t3;
    out.seconds = t3 - t1;
    out.reactiveAfter = t2 - t1;
    check('3. Exit: not older than the Submit', t3 >= t1, `${t3} >= ${t1}`);
    if (execAt !== null) {
      out.noticeLeft = execAt - t3;
      check('3. Exit: landed before the change could run', t3 < execAt, `${t3} < ${execAt}`);
    }
  }
  return out;
}

async function armFacts(armTx, owner) {
  const r = await receipt(BASE_READ, armTx);
  if (!r) return null;
  const t = topic('WatchArmed(uint256,address,address,uint8,uint8,uint256)');
  const l = (r.logs || []).find((x) => same(x.address, DEP.exit) && lower(x.topics[0]) === t && same(topicAddr(x.topics[2]), owner));
  if (!l) return null;
  return { watchId: BigInt(l.topics[1]).toString(), owner: topicAddr(l.topics[2]), vault: topicAddr(l.topics[3]),
    kinds: Number(dataWord(l.data, 0)), mode: Number(dataWord(l.data, 1)), maxShares: dataWord(l.data, 2).toString() };
}

/* ---------- output ---------- */

function summaryMd(res) {
  const L = [];
  L.push(`### Page walk: ${res.result}${res.dry ? ' (dry, nothing signed)' : ''}`);
  L.push('');
  L.push(`Page ${res.url}, deployment ${res.deployment}, key ${res.key} (${res.address}), kind ${res.kind}, mode ${res.mode}, watch kinds ${res.watchKinds}.`);
  /* page-derived text only inside code spans, on one line, without backticks */
  const code = (s) => '`' + oneLine(s).replace(/`/g, "'").slice(0, 600) + '`';
  if (res.failure) { L.push(''); L.push(`Failure: ${code(res.failure)}`); }
  if (res.finalState) L.push(`Last page state: ${code(res.finalState)} (${code(res.finalHead || '')}).`);
  const v = res.verified;
  if (v && res.page && res.page.h1) {
    L.push('');
    L.push('| Record | Chain | Transaction |');
    L.push('|---|---|---|');
    L.push(`| 1. Curator schedules a change (${res.kind}) | Base Sepolia | \`${res.page.h1}\` |`);
    L.push(`| 2. Reactive transaction (ExitRequested) | Lasna | \`${res.page.h2}\` |`);
    L.push(`| 3. Exit (WatchEnded, shares redeemed) | Base Sepolia | \`${res.page.h3}\` |`);
    L.push('');
    if (v.seconds !== undefined) L.push(`Seconds from 1 to 3 (block times): ${v.seconds}; Reactive +${v.reactiveAfter} s; the change could run ${v.noticeLeft} s after the exit.`);
    L.push(`Watch ${res.watchId}, vault ${res.vault}. Checks by receipt: ${v.checks.filter((c) => c.ok).length} of ${v.checks.length} passed.`);
  }
  if (res.dryRequests && res.dryRequests.length) {
    L.push('');
    res.dryRequests.forEach((d, i) => L.push(`Dry confirmation ${i + 1}: ${code(d.policy)}.`));
  }
  L.push('');
  L.push('<details><summary>Result JSON</summary>');
  L.push('');
  L.push('```json');
  /* a backtick in page text must not close the fence: written as its JSON escape, backslash u0060 */
  L.push(JSON.stringify(res, null, 2).replace(/`/g, String.fromCharCode(92) + 'u0060'));
  L.push('```');
  L.push('</details>');
  return L.join('\n') + '\n';
}

function emit(res, shot) {
  const json = JSON.stringify(res, null, 2);
  if (OPT.out) {
    writeFileSync(join(OPT.out, 'result.json'), json + '\n');
    writeFileSync(join(OPT.out, 'summary.md'), summaryMd(res));
  }
  console.log('NP-WALK-JSON-BEGIN');
  console.log(json);
  console.log('NP-WALK-JSON-END');
  if (shot && res.result !== 'ok') {
    console.log('NP-WALK-SHOT-BEGIN jpeg base64');
    console.log(shot);
    console.log('NP-WALK-SHOT-END');
  }
}

/* ---------- modes ---------- */

async function verifyRecordMode() {
  const rec = JSON.parse(readFileSync(OPT.verifyRecord, 'utf8'));
  for (const k of ['exit', 'reactive', 'token']) {
    if (rec[k] && !same(rec[k], DEP[k])) die(`the record's ${k} is not that of deployment ${DEP.name}`);
  }
  const arm = await armFacts(rec.armTx, rec.depositor);
  const res = { check: 'verify-record', record: OPT.verifyRecord.split(/[\\/]/).slice(-2).join('/'), deployment: DEP.name, arm };
  if (!arm) { res.result = 'failed'; res.failure = 'WatchArmed not found in the arm transaction'; }
  else {
    const v = await verifyRun({ h1: rec.hash1, h2: rec.hash2, h3: rec.hash3, submitHash: rec.hash1, owner: rec.depositor,
      curator: rec.curator, vault: arm.vault, watchId: arm.watchId, shares: arm.maxShares, kind: rec.kind });
    const extra = [];
    if (!same(arm.vault, rec.vault)) extra.push('vault differs from the record');
    if (String(arm.watchId) !== String(rec.watchId)) extra.push('watch id differs from the record');
    if (rec.seconds !== undefined && v.seconds !== undefined && v.seconds !== rec.seconds) extra.push(`seconds ${v.seconds}, the record says ${rec.seconds}`);
    res.verified = v;
    const bad = v.checks.filter((c) => !c.ok).map((c) => c.name).concat(extra);
    res.result = bad.length ? 'failed' : 'ok';
    if (bad.length) res.failure = bad.join('; ');
  }
  console.log('NP-WALK-JSON-BEGIN');
  console.log(JSON.stringify(res, null, 2));
  console.log('NP-WALK-JSON-END');
  return res.result === 'ok' ? 0 : 1;
}

async function walkMode() {
  W.dry = OPT.dry;
  if (!OPT.out) OPT.out = mkdtempSync(join(tmpdir(), 'np-walk-out-'));
  mkdirSync(OPT.out, { recursive: true });

  /* chains */
  for (const [u, want] of [[BASE_READ[0], BASE_ID], [BASE_SEND, BASE_ID], [LASNA_RPC, LASNA_ID]]) {
    const r = await rpc(u, 'eth_chainId', []);
    if (r.error || Number(BigInt(r.result)) !== want) die(`endpoint for chain ${want} answers ${r.error ? r.error.message : Number(BigInt(r.result))}`);
  }
  /* the walk address */
  if (OPT.dry) {
    ME = lower(OPT.address || DEP.operators[OPT.key === 'a' ? 0 : 1] || '');
    if (!/^0x[0-9a-f]{40}$/.test(ME)) die('no address for the dry walk (--address, or operators in the deployment)');
  } else {
    /* as scripts/chain.sh reads the secret: surrounding space ignored, 0x optional */
    const bare = strip0x(String(KEY || '').trim());
    if (!/^[0-9a-f]{64}$/.test(bare)) die('WALK_KEY is missing or is not a 32-byte hex key');
    KEY = '0x' + bare;
    const r = await runCast(['wallet', 'address', '--private-key', KEY], 30000);
    const a = (r.out.match(/0x[0-9a-fA-F]{40}/) || [])[0];
    if (r.code !== 0 || !a) die(`could not derive the walk address: ${r.err.trim().split('\n').slice(-1)[0] || 'no address'}`);
    ME = lower(a);
    if (process.env.WALK_ADDRESS && !same(process.env.WALK_ADDRESS, ME)) die('WALK_ADDRESS does not belong to WALK_KEY');
    const opIndex = DEP.operators.findIndex((o) => same(o, ME));
    if (opIndex !== (OPT.key === 'a' ? 0 : 1)) die(`the key is not operator ${OPT.key} of deployment ${DEP.name}`);
  }
  /* the maker answers isVault for its own smoke vault, so the signer's vault rule can say yes at all */
  if (DEP.smokeVault && !(await isVault(DEP.smokeVault))) die('the maker does not list its smoke vault (isVault false or unreadable)');
  /* the walk address's own earlier vault (the page resumes or empties it), read once, before the page says anything */
  const last = await call(BASE_READ, DEP.maker, sel('lastVaultOf(address)') + addrWord(ME));
  if (last && last.length >= 66) {
    const v = topicAddr(last.slice(0, 66));
    if (!same(v, ZERO_ADDR)) { addOwn(v); log(`the walk address's last vault from the maker: ${v}`); }
  }
  const bal = await rpcAny(BASE_READ, 'eth_getBalance', [ME, 'latest']);
  const eth = bal && bal.result ? BigInt(bal.result) : null;
  log(`walk address ${ME}${OPT.dry ? ' (dry: nothing is signed)' : ''}; Base Sepolia balance ${eth === null ? 'unknown' : (Number(eth) / 1e18).toFixed(6)} ETH`);

  const res = { result: 'failed', dry: OPT.dry, url: OPT.url, deployment: DEP.name, key: OPT.key, address: ME, kind: OPT.kind,
    mode: OPT.mode, watchKinds: WATCH_KINDS[OPT.kind], startedAt: new Date(t0).toISOString() };
  let shot = null;
  let chrome = await launchChrome(OPT.browser, false);
  res.browserSandbox = true;
  if (chrome.error) {
    W.notes.push(`browser with its sandbox: ${chrome.error}; started again without it`);
    /* the processes around the browser hold the key in a live walk: running the page unsandboxed is said out loud */
    if (!OPT.dry) console.log(`::warning::the browser did not start with its sandbox (${oneLine(chrome.error).slice(0, 200)}); the live walk runs it with --no-sandbox`);
    res.browserSandbox = false;
    try { rmSync(chrome.profile, { recursive: true, force: true }); } catch (e) { /* busy */ }
    chrome = await launchChrome(OPT.browser, true);
  }
  if (chrome.error) {
    fail(chrome.error);
  } else {
    res.browser = chrome.product;
    try {
      CDP = new Cdp(chrome.ws);
      await CDP.open();
      CDP.on(onEvent);
      const { targetId } = await CDP.send('Target.createTarget', { url: 'about:blank' });
      ({ sessionId: SID } = await CDP.send('Target.attachToTarget', { targetId, flatten: true }));
      await tab('Page.enable');
      await tab('Runtime.enable');
      await tab('Log.enable');
      await tab('Emulation.setDeviceMetricsOverride', { width: VIEW.width, height: VIEW.height, deviceScaleFactor: 1, mobile: false });
      await tab('Runtime.addBinding', { name: BINDING });
      await tab('Page.addScriptToEvaluateOnNewDocument', { source: walletScript(randomUUID()) });
      ORIGIN = new URL(OPT.url).origin;
      log(`open ${OPT.url}`);
      await tab('Page.navigate', { url: OPT.url });
      const ready = await until(async () => {
        const v = await evalPage(`(() => { const b = document.getElementById('state'); return document.readyState === 'complete' && b && b.hasAttribute('data-state') && !!(window.NP && window.NP.run) ? b.getAttribute('data-state') : null; })()`).catch(() => null);
        return v;
      }, 45000, 500);
      if (!ready) fail('the page did not draw its guided run within 45 s');
      else {
        res.walletSeen = await evalPage(`!!(window.ethereum && window.ethereum.isPageWalk)`);
        await screenshot('loaded');
        if (await checkPage()) {
          const end = await drive();
          /* The walk has ended, whatever the outcome: nothing more is signed (a later request fails the walk), and a
             transaction cast is still sending is in the record before the receipts are checked. */
          W.stopped = true;
          await signChain;
          if (end === 'dry-ok') {
            await screenshot('rejected', true);
            res.dryUi = await dryUiCheck();
            if (!W.failure) res.result = 'ok';
          }
          if (end === 'returned') {
            await screenshot('returned', true);
            res.returnedText = W.last && W.last.text;
            const hashes = await ledgerHashes();
            res.page = hashes;
            if (!hashes) fail('the page did not show all three transactions within 90 s of "returned"');
            else {
              const armSent = W.sent.filter((x) => x.sig === 'arm(address,uint8,uint8,uint256)').slice(-1)[0];
              const submitSent = W.sent.filter((x) => x.sig === 'submit(bytes)').slice(-1)[0];
              const arm = armSent ? await armFacts(armSent.hash, ME) : null;
              if (!arm) fail('no WatchArmed in the arm transaction this walk signed');
              else if (!submitSent) fail('this walk signed no submit');
              else {
                W.vault = W.vault || arm.vault;
                res.vault = arm.vault;
                res.watchId = arm.watchId;
                res.arm = arm;
                if (!same(arm.vault, W.vault)) fail(`the watch is on ${arm.vault}, the walk's vault is ${W.vault}`);
                if (arm.kinds !== WATCH_KINDS[OPT.kind] || arm.mode !== OPT.mode) fail(`WatchArmed says kinds ${arm.kinds} mode ${arm.mode}`);
                const v = await verifyRun({ ...hashes, submitHash: submitSent.hash, owner: ME, curator: ME, vault: arm.vault,
                  watchId: arm.watchId, shares: arm.maxShares, kind: OPT.kind });
                const check = (name, ok, detail) => v.checks.push({ name, ok: !!ok, detail: String(detail) });
                /* read until the three agree with the exit (a lagging endpoint can answer one block behind), 20 s at most */
                let sharesAfter = null;
                let watchAfter = null;
                let tokenAfter = null;
                await until(async () => {
                  sharesAfter = await uintOf(BASE_READ, arm.vault, sel('balanceOf(address)') + addrWord(ME));
                  watchAfter = await uintOf(BASE_READ, DEP.exit, sel('activeWatchOf(address,address)') + addrWord(ME) + addrWord(arm.vault));
                  tokenAfter = await tokenBalance(ME);
                  const gained = W.tokenBefore !== null && W.tokenBefore !== undefined && tokenAfter !== null && v.assets !== undefined
                    ? tokenAfter - W.tokenBefore === BigInt(v.assets) : true;
                  return sharesAfter === 0n && watchAfter === 0n && gained ? true : null;
                }, 20000, 2000);
                check('after: no shares left in the vault', sharesAfter === 0n, sharesAfter);
                check('after: no watch left on the vault', watchAfter === 0n, watchAfter);
                /* a balance that could not be read is a failed check, never a skipped one */
                const haveTokens = W.tokenBefore !== null && W.tokenBefore !== undefined && tokenAfter !== null && v.assets !== undefined;
                check('after: the wallet gained exactly the redeemed assets', haveTokens && tokenAfter - W.tokenBefore === BigInt(v.assets),
                  haveTokens ? `${W.tokenBefore} -> ${tokenAfter}` : `not read (before ${W.tokenBefore}, after ${tokenAfter})`);
                /* the returned amount belongs to the deposit this walk signed */
                const dep = W.sent.filter((x) => x.sig === 'deposit(uint256,address)' || x.sig === 'mint(uint256,address)').slice(-1)[0];
                check('the deposit this walk signed went to the watched vault', dep && same(dep.to, arm.vault), dep ? dep.to : 'no deposit signed');
                const shares = BigInt(arm.maxShares);
                check('the shares held before the change equal the watch\'s maxShares and the shares redeemed',
                  W.sharesBefore !== null && W.sharesBefore !== undefined && W.sharesBefore === shares && v.shares !== undefined && BigInt(v.shares) === shares,
                  `held ${W.sharesBefore}, watch ${shares}, redeemed ${v.shares}`);
                if (dep && dep.sig === 'deposit(uint256,address)') {
                  const put = BigInt(dep.args[0]);
                  check('the exit returned the deposit, less at most one unit of rounding', v.assets !== undefined && BigInt(v.assets) + 1n >= put,
                    `deposited ${put}, returned ${v.assets}`);
                }
                res.verified = v;
                res.tokens = { before: W.tokenBefore === undefined || W.tokenBefore === null ? null : W.tokenBefore.toString(), after: tokenAfter === null ? null : tokenAfter.toString() };
                const bad = v.checks.filter((c) => !c.ok);
                if (bad.length) fail(`checks by receipt failed: ${bad.map((c) => `${c.name} (${c.detail})`).join('; ')}`);
                else if (!W.failure) res.result = 'ok';
              }
            }
          }
        }
      }
    } catch (e) {
      fail(`walk error: ${scrub(e && e.message)}`);
    }
    /* nothing more is signed; a send still in flight is recorded (and can fail the walk) before the result is decided */
    W.stopped = true;
    await signChain;
    if (W.failure || res.result !== 'ok') {
      res.result = 'failed';
      shot = await screenshot('end', true);
    }
  }
  W.stopped = true;
  await signChain;
  /* the dry walk passes only with the wallet seen, one rejected confirmation and nothing else wrong */
  if (OPT.dry && res.result === 'ok' && (!res.walletSeen || !W.connected || W.failure)) res.result = 'failed';
  if (W.failure) res.result = 'failed';
  Object.assign(res, {
    failure: W.failure, finalState: W.last ? W.last.state : null, finalHead: W.last ? W.last.head : null,
    finalText: res.result === 'ok' ? undefined : (W.last ? W.last.text : null),
    endedAt: new Date().toISOString(), seconds: secs(), states: W.states, stateLog: W.stateLog, walletRequests: W.requests,
    sent: W.sent.map(({ logs, ...rest }) => rest), refused: W.refused, unsupported: W.unsupported, dryRequests: W.dryRequests,
    consoleErrors: W.consoleErrors, warnings: W.warnings, networkErrors: W.networkErrors, notes: W.notes,
    screenshots: W.screenshots.map((f) => f.split(/[\\/]/).pop()), pageConfig: W.page,
  });
  /* a transaction cast was still sending is in the record (W.sent and W.failure were read after signChain) */
  if (res.result !== 'ok' && W.last) {
    log(`page state at the end: ${W.last.state} | ${W.last.head}`);
    console.log(String(W.last.text || '').split('\n').map((l) => `  | ${l}`).join('\n'));
  }
  emit(res, shot);
  if (CDP) {
    await CDP.send('Browser.close', {}, undefined, 5000).catch(() => {});
    CDP.close();
  }
  if (chrome && chrome.proc) { try { chrome.proc.kill(); } catch (e) { /* gone */ } }
  await sleep(1000);
  if (chrome && chrome.profile) { try { rmSync(chrome.profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 }); } catch (e) { /* the browser may still hold it */ } }
  return res.result === 'ok' ? 0 : 1;
}

async function main() {
  KEY = process.env.WALK_KEY || null;
  delete process.env.WALK_KEY;
  keccakSelfTest();
  OPT = parseArgs(process.argv.slice(2));
  if (OPT.dry || OPT.verifyRecord) KEY = null;
  DEP = loadDeployment(OPT.deployment);
  return OPT.verifyRecord ? verifyRecordMode() : walkMode();
}

/* For a test of the signer's rules without a browser or a key: the rules see this walk's options, deployment,
   address and own vaults (as if made by this walk), and nothing is sent (dry). */
export function policyFor(opt, deploymentName, address, ownVaults = []) {
  OPT = { deployment: deploymentName, key: 'b', kind: 'adapter', mode: 0, timeout: 480, ...opt, dry: true };
  DEP = loadDeployment(deploymentName);
  ME = lower(address);
  KEY = null;
  OWN.clear();
  ownVaults.forEach(addOwn);
  return { policy, walletRequest, record: W, keccak256, encodeArgs, decodeArgs, sel };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((code) => process.exit(code), (e) => {
    console.error(`page-walk: ${scrub(e && e.message)}`);
    process.exit(1);
  });
}
