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
       gas, if the page names it, is not negative and at most 8,000,000; at most 12 transactions in one walk;
     - the target is the demo dollar, the vault maker or the exit contract of deployments/NAME.json in this checkout
       (never addresses read from the page), or the walk's one vault. That is the vault in the VaultCreated log of the
       create() this walk signed, taken from its receipt as every endpoint gives it (status 1, from the walk address to
       the maker) and only when the maker's lastVaultOf(walk address) is that same vault on every endpoint; if that
       cannot be established the walk fails with no vault at all. Until then it is the maker's lastVaultOf(walk
       address), read once at the start (an earlier visit's vault, for the resume and old-vault paths). A walk has one
       vault at a time: once create() is signed, the earlier vault is no target any more. The maker's isVault(vault)
       must answer true by our own eth_call. A vault someone else made, the deployment's smoke vault included, is
       never a target;
     - the call is one of these, with these arguments, and the call data is exactly the standard ABI encoding of them:
         demo dollar   mint(address,uint256) to the walk address; approve(address,uint256) for the walk's vault
         vault maker   create()
         walk's vault  deposit(uint256,address) for the walk address;
                       approve(address,uint256) for the exit contract;
                       submit(bytes), only while the vault's curator() is the walk address, of the one call the page
                       builds for the chosen kind, itself in exact standard encoding:
                         adapter    addAdapter(address), the address holding no code
                         allocator  setIsAllocator(address,true), the address holding no code
                         timelock   decreaseTimelock(bytes4,uint256) of addAdapter, setIsAllocator, increaseAbsoluteCap
                                    or increaseRelativeCap, to at least 1 second and less than the maker's TIMELOCK()
                         cap        increaseAbsoluteCap(bytes,uint256), a 32-byte id, a cap of 1 unit to 1,000,000
                                    demo dollars
                       redeem(uint256,address,address) from and to the walk address
         exit contract arm(address,uint8,uint8,uint256) on the walk's vault with exactly the chosen kinds and mode;
                       cancel(uint256) of the walk address's own active watch on the walk's vault
     - the order is the page's own: create(), the vault deposit, arm and submit are each signed once at most; redeem
       and cancel (the page's "withdraw and start over" on an earlier visit's vault) only before any of those four;
       submit only after the arm; create() not after the walk's deposit; after the arm nothing but that one submit.
   Every chain read behind a yes (lastVaultOf, isVault, curator(), the watch of a cancel, no code at an address,
   TIMELOCK(), the receipt of the walk's create(), each send as mined) is asked of every Base Sepolia endpoint the walk
   knows, and all must give the same answer; an endpoint that does not answer, or two that differ, is a no.
   Signing mirrors scripts/chain.sh send_as: cast send with the function signature and the decoded arguments, for
   chain 84532 whatever the endpoint says (--chain), then the receipt must say success, and the transaction cast
   printed, as every endpoint gives it, must carry exactly the call data the page asked for, from the walk address, on
   chain 84532, at the nonce cast was given. Until that holds the printed hash is not taken as the send (the record
   says hashConfirmed false and the walk fails; after a create() the walk has no vault). Before each send
   the walk address's next nonce is read from the sending endpoint, waited for (15 s at most) until it is past the
   nonce of the walk's last mined send, and cast is given (--nonce) the highest of it and the 'latest' count of every
   Base Sepolia endpoint (the highest, not one answer all agree on: an endpoint may be a block behind); a nonce or a
   count that cannot be read, from any one of them, refuses the send and fails the walk.
   The intent (call, target, nonce) is printed before cast starts, and with --out a running result
   (result "running") is written before and after each send. When cast does not report a mined transaction (it exits
   with an error, or does not finish in 240 s), the request still goes into the record, with status "unknown", that
   nonce and any transaction hash cast printed; the walk fails, and at the end the nonce is read again: a nonce that
   moved shows the broadcast, one that did not move leaves it unknown (a queued or dropped broadcast is not ruled out).
   A hash cast printed is taken as that request only when every endpoint gives it as that call from the walk address
   at that nonce.
   Limits: these checks assume at least one Base Sepolia endpoint answers honestly, since the same lie from all of them
   cannot be told apart. The key is on cast's command line and in this process's environment for the length of the
   job, which is why the page never runs in an unsandboxed browser next to it. An honest walk can still end red in
   these ways, left as they are: in the states 'deposited' and 'armed' the driver presses once per visit, so a page
   that draws the same state again without starting the step leaves the walk to time out; an endpoint that does not
   answer the chain id question at start-up ends the run before a result file exists (nothing is signed by then);
   and a page that reaches 'deposited' with a deposit made before this walk can have the walk sign an arm and a
   submit and then fail on its own end check (red, never ok). Two more come from failing closed: a Base Sepolia
   endpoint that gives no transaction count for the 15 s before a send refuses that send, and one that sees blocks
   more than about 30 s late fails the read-back of the first send. An endpoint that is only slower or a few blocks
   behind costs waiting, about its lag per send.
   The key is read once from the WALK_KEY environment variable and removed from process.env (so from the environment
   Chrome and cast are started with; the process's own initial environment keeps it, as said above); cast gets it as
   an argument of a process started without a shell, and no command line is printed. Every
   cast error message (cast's stderr, and the transaction hashes taken from what cast printed) and the status cast
   printed are scrubbed of the key before they are shown or searched; of cast's other output only a hash and a block
   number that read as such are used. In Actions the workflow masks key B (scripts/chain.sh
   derive_key_b); key A is the TESTNET_KEY secret, masked by GitHub.

   The walk. Open the page, check that its states and buttons are the ones driven here and that its contracts are
   those of the deployment, connect, deposit (make the vault, get demo dollars, approve, deposit), set the watch to the
   chosen kinds and mode and turn it on, act as the curator and schedule the change, and wait for the page's end
   state "returned" (the deposit came back). The page is driven by its state id (#state[data-state]) and its buttons
   ([data-a]), not by visible text; what is read from the page is kept only as plain strings. Then the page is not
   trusted: the three transactions it shows are read by receipt from the public endpoints, and the walk checks status
   1, that the Submit is the one it signed, the links by watch id and by the Submit hash (ExitRequested on Lasna,
   WatchEnded on Base Sepolia, each found by the watch id), the token transfer from the vault to the walk address equal
   to the redeemed assets, the seconds from block times, that the exit landed before the change could run, that the
   shares and the watch are gone, that the walk signed exactly one deposit, one arm and one submit, all on the one
   vault, and that the exit returned what that deposit moved into the vault (its own Transfer log), less at most one
   unit of rounding. The Base Sepolia receipts, block times and balances of this check are read from every Base
   Sepolia endpoint and must be the same on all (status, block, sender, target and logs; the balances at one block
   number); Reactive Lasna has one public endpoint.
   Failure: any error state of the page, any console error, uncaught exception or policy violation, any refused
   request, no end state within the timeout (default 480 s; every page call and loop of the driver stops at it, except
   the wait for the balances before the change, which is not cut short, but nothing is pressed after it once the
   timeout has passed), a
   watch step with more than 8 kind boxes, a box bit other than 1, 2, 4 or 8 or one bit twice, or no balances before
   the change at a block not below the arm's (read before the change is scheduled). On failure the state id and the
   visible text are printed and a screenshot is taken. A browser-level error about one of the page's public endpoints
   (failed to load, rate-limited, blocked by its CORS answer) is recorded, not failed: the page is built to retry
   those. A policy violation, or one of the page's own files failing to load, does fail the walk. Once the walk has
   failed or the page has reached its end state nothing more is signed: a later request is refused and fails the
   walk, and a transaction cast is still sending is waited for and recorded before the receipts are checked and the
   result is decided.
   A live walk opens only the hosted page (https://bongbongcrypto.github.io/notice-period/..., no "." or ".." path
   segment), and fails when the browser leaves that path. The browser runs with its sandbox. If it will not start
   with it, a live walk fails: the processes around the browser hold the key, so the page is never run unsandboxed
   there. A dry walk, which has no key, starts the browser again without the sandbox and records browserSandbox false.

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
/* What the signer lets the curator's submit carry, per kind: the one call the page builds (docs/run.js changeFor).
   KIND_SIGS above is the wider list the receipt check accepts for a kind (a recorded run may hold either cap call). */
const SUBMIT_SIG = {
  adapter: 'addAdapter(address)',
  timelock: 'decreaseTimelock(bytes4,uint256)',
  allocator: 'setIsAllocator(address,bool)',
  cap: 'increaseAbsoluteCap(bytes,uint256)',
};
/* The curator actions whose waiting period the page's "shorter waiting period" change names. */
const TIMELOCK_TARGETS = ['addAdapter(address)', 'setIsAllocator(address,bool)', 'increaseAbsoluteCap(bytes,uint256)',
  'increaseRelativeCap(bytes,uint256)'];
/* The demo cap the page schedules is 1,000,000 demo dollars (docs/config.js amounts.capIncrease): nothing above it. */
const MAX_CAP = 10n ** 12n;
const SIG_CREATE = 'create()';
const SIG_DEPOSIT = 'deposit(uint256,address)';
const SIG_ARM = 'arm(address,uint8,uint8,uint256)';
const SIG_SUBMIT = 'submit(bytes)';
/* Signed once at most in a walk. */
const ONCE = [SIG_CREATE, SIG_DEPOSIT, SIG_ARM, SIG_SUBMIT];
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
/* An address under the hosted page's path, as a browser reads it. */
function underLive(u) {
  let p;
  try { p = new URL(u); } catch (e) { return false; }
  return p.origin === LIVE_ORIGIN && p.pathname.startsWith(LIVE_PATH);
}
/* The address a live walk may be given: the pattern above, no "." or ".." path segment (a browser resolves those to
   another path of the same host), and nothing a browser would rewrite. */
function isLiveUrl(u) {
  if (typeof u !== 'string' || !LIVE_URL.test(u)) return false;
  if (u.split('/').some((seg) => seg === '.' || seg === '..')) return false;
  let p;
  try { p = new URL(u); } catch (e) { return false; }
  return p.href === u && underLive(u);
}
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
    if (!o.dry && !isLiveUrl(o.url)) die(`a live walk opens only the hosted page (${LIVE_ORIGIN}${LIVE_PATH}, no "." or ".." path segment)`);
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

/* Retries until fn returns a value other than null/undefined, or the time is up (asked once when ms is 0). */
async function until(fn, ms, every = 1500) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v !== null && v !== undefined) return v;
    if (Date.now() >= end) return null;
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

/* ---------- reads that every Base Sepolia endpoint must answer alike ---------- */

/* Every Base Sepolia endpoint the walk knows (the sending one and the two public ones), each once. */
const BASE_ALL = [BASE_SEND, ...BASE_READ].filter((u, i, all) => all.findIndex((x) => x.replace(/\/+$/, '') === u.replace(/\/+$/, '')) === i);
/* How long a read behind a yes waits for the endpoints to agree (one of them can be a block behind), and how often
   it asks. policyFor() shortens both for the signer test. */
let READ_WAIT = 12000;
let READ_EVERY = 2000;
/* The longer waits of a live walk, in ms: a receipt alike on every endpoint, the next nonce past the last mined send,
   a mined transaction read back, the balances before the change at a block not below the arm's, one balance at a
   pinned block. The signer test sets them all to 0 (asked once). */
const WAIT = { receipt: 60000, nonce: 15000, readBack: 30000, baseline: 60000, balance: 6000 };

/* One answer, asked of every endpoint. { value } only when all answered without an error and what pick() takes from
   their results is the same; { error } otherwise. An endpoint that does not answer is never outvoted or skipped. */
async function agreed(method, params, pick = (x) => x) {
  const answers = await Promise.all(BASE_ALL.map((u) => rpc(u, method, params)));
  const seen = [];
  for (const r of answers) {
    if (!r || r.error) return { error: `an endpoint did not answer ${method}` };
    let v;
    try { v = pick(r.result); } catch (e) { return { error: `an answer to ${method} could not be read` }; }
    seen.push(JSON.stringify(v === undefined ? null : v));
  }
  if (seen.some((x) => x !== seen[0])) return { error: `the endpoints disagree on ${method}` };
  return { value: JSON.parse(seen[0]) };
}

/* agreed(), asked again until ok(value) holds or the time is up; null then. */
async function agreedUntil(method, params, pick, ok, ms = READ_WAIT, every = READ_EVERY) {
  return until(async () => {
    const a = await agreed(method, params, pick);
    return !a.error && ok(a.value) ? a.value : null;
  }, ms, every);
}

/* eth_call whose 32-byte answer is the same on every endpoint and passes ok(), as a number; null when that does not
   come in time. */
async function uintAgreed(to, data, { block = 'latest', ms = READ_WAIT, ok = () => true } = {}) {
  const v = await agreedUntil('eth_call', [{ to, data }, block], (x) => (typeof x === 'string' && /^0x[0-9a-fA-F]{64,}$/.test(x) ? lower(x.slice(0, 66)) : null),
    (x) => x !== null && ok(BigInt(x)), ms);
  return v === null ? null : BigInt(v);
}

/* The parts of a receipt the checks use, in one spelling, so two endpoints can be compared (each adds fields of its own). */
function receiptView(r) {
  if (!r || typeof r !== 'object') return null;
  return { status: lower(r.status), blockHash: lower(r.blockHash), blockNumber: lower(r.blockNumber), transactionHash: lower(r.transactionHash),
    from: lower(r.from), to: lower(r.to),
    logs: (Array.isArray(r.logs) ? r.logs : []).map((l) => ({ address: lower(l.address), topics: (Array.isArray(l.topics) ? l.topics : []).map(lower), data: lower(l.data) })) };
}

/* The parts of a transaction the read-back uses, in one spelling (numbers as plain hex), so two endpoints can be
   compared. null for no transaction. */
function txView(t) {
  if (!t || typeof t !== 'object') return null;
  const num = (x) => { try { return x === undefined || x === null ? null : '0x' + BigInt(x).toString(16); } catch (e) { return null; } };
  return { hash: lower(t.hash), input: lower(t.input), to: lower(t.to), from: lower(t.from), value: num(t.value), chainId: num(t.chainId), nonce: num(t.nonce) };
}

/* A Base Sepolia transaction that every endpoint gives alike; null when they do not within the time (ms 0: asked once). */
async function txAgreed(hash, ms = WAIT.readBack) {
  return agreedUntil('eth_getTransactionByHash', [hash], txView, (v) => v !== null, ms, 1500);
}

/* A Base Sepolia receipt that every endpoint gives alike; null when they do not within the time. */
async function receiptAgreed(hash, ms = WAIT.receipt) {
  return agreedUntil('eth_getTransactionReceipt', [hash], receiptView, (v) => v !== null, ms, 1500);
}

/* The time of a Base Sepolia block, the same on every endpoint, and only if it is the block with that hash. */
async function blockTsAgreed(number, blockHash) {
  const b = await agreedUntil('eth_getBlockByNumber', [number, false], (x) => (x ? { hash: lower(x.hash), timestamp: lower(x.timestamp) } : null),
    (v) => v !== null, 30000, 1500);
  if (!b || !same(b.hash, blockHash)) return null;
  return Number(BigInt(b.timestamp));
}

/* A block number every endpoint has reached (the lowest of their heads), not below atLeast: balances are read at it,
   so every endpoint is asked about the same state. null when the heads cannot be read or stay below atLeast. */
async function pinnedBlock(atLeast = 0, ms = 20000) {
  return until(async () => {
    const heads = await Promise.all(BASE_ALL.map((u) => rpc(u, 'eth_blockNumber', [])));
    if (heads.some((h) => !h || h.error || !/^0x[0-9a-fA-F]+$/.test(h.result || ''))) return null;
    const n = Math.min(...heads.map((h) => Number(BigInt(h.result))));
    return n >= atLeast ? n : null;
  }, ms, 1000);
}
const blockHex = (n) => '0x' + BigInt(n).toString(16);

/* ---------- the walk's record ---------- */

const W = {
  result: 'running', dry: false, failure: null, states: [], stateLog: [], requests: {}, refused: [], unsupported: [],
  sent: [], dryRequests: [], consoleErrors: [], warnings: [], networkErrors: [], screenshots: [], checks: [],
  connected: false, notes: [], inFlight: null,
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

/* The text with the key taken out, whole. */
function redact(text) {
  let t = String(text || '');
  if (KEY) {
    const bare = strip0x(KEY).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (bare) t = t.replace(new RegExp(bare, 'gi'), '***');
  }
  return t;
}
function scrub(text) { return redact(text).slice(-1500); }

function runCast(argv, timeoutMs) {
  return new Promise((done) => {
    let out = '';
    let err = '';
    let finished = false;
    let child;
    const finish = (code, note) => {
      if (finished) return;
      finished = true;
      /* a note of ours (cast could not start, or was stopped) goes in front of what cast itself said, which is kept */
      done({ code, out, err: scrub(note ? `${note}${err ? `: ${err}` : ''}` : err) });
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

/* Transaction hashes in what cast printed, the ones it names as such first. The key is taken out before the search:
   it has the same shape as a hash. */
function hashesIn(text) {
  const t = redact(text);
  const named = [...t.matchAll(/"transactionHash"\s*:\s*"(0x[0-9a-fA-F]{64})"/g)].map((m) => lower(m[1]));
  const any = [...t.matchAll(/0x[0-9a-fA-F]{64}(?![0-9a-fA-F])/g)].map((m) => lower(m[0]));
  return [...new Set([...named, ...any])].slice(0, 6);
}

/* The calls the signer allows, per target class. check() returns true, or a reason to refuse.
   recovery: part of the page's "withdraw and start over" on an earlier visit's vault, signed only before the walk's
   own run. ownWatch: the argument that must be the walk address's active watch on the walk's vault. change: the
   bytes argument is a curator change, held to changeAllowed(). */
function callTable(ctx) {
  const toMe = (a) => same(a, ctx.me);
  return {
    token: {
      'mint(address,uint256)': { label: 'get demo dollars', check: (a) => toMe(a[0]) || 'mints to another address' },
      'approve(address,uint256)': { label: 'let the vault take the demo dollars', vaultArg: 0 },
    },
    maker: { [SIG_CREATE]: { label: 'make a vault' } },
    vault: {
      [SIG_DEPOSIT]: { label: 'deposit', check: (a) => toMe(a[1]) || 'the shares would go to another address' },
      'approve(address,uint256)': { label: 'allow the exit contract to redeem the shares', check: (a) => same(a[0], DEP.exit) || 'approves a spender other than the exit contract' },
      [SIG_SUBMIT]: { label: 'schedule the change as the curator', curator: true, change: 0 },
      'redeem(uint256,address,address)': { label: 'withdraw', recovery: true, check: (a) => (toMe(a[1]) && toMe(a[2])) || 'redeems to or from another address' },
    },
    exit: {
      [SIG_ARM]: { label: 'turn the watch on', vaultArg: 0,
        check: (a) => (Number(a[1]) === ctx.watchKinds && Number(a[2]) === ctx.mode) ||
          `arms kinds ${a[1]} mode ${a[2]}; this walk asked for kinds ${ctx.watchKinds} mode ${ctx.mode}` },
      'cancel(uint256)': { label: 'turn the watch off', recovery: true, ownWatch: 0 },
    },
  };
}

/* The one vault this walk may sign on: the vault its own create() made, and until then the walk address's last vault
   from the maker (read once at the start, the same on every endpoint). Listed by the maker is necessary, not enough:
   the maker makes a vault for anyone. */
let OWN = null;
function setOwn(addr) { OWN = /^0x[0-9a-fA-F]{40}$/.test(addr || '') && !same(addr, ZERO_ADDR) ? lower(addr) : null; }
const isOwn = (addr) => OWN !== null && lower(addr) === OWN;

/* The vault's curator() is the walk address: one well-formed address word (exactly 32 bytes, the upper 12 zero), the
   same on every endpoint, and that address the walk address. Anything else is a no. */
async function curatorIsMe(vault) {
  const v = await agreedUntil('eth_call', [{ to: vault, data: sel('curator()') }, 'latest'],
    (x) => (typeof x === 'string' && /^0x0{24}[0-9a-fA-F]{40}$/.test(x) ? lower(x) : null),
    (x) => x !== null && same(topicAddr(x), ME));
  return v !== null;
}

/* The vault the walk's own create() made, only as every endpoint gives it: the create's receipt alike from all, with
   status 1, its hash, sent by the walk address to the maker, exactly one VaultCreated log of the maker for the walk
   address with a well-formed vault topic; and the maker's lastVaultOf(walk address) that same vault on every
   endpoint. { vault } or { why }. The logs cast printed are never used for this; the hash is the one cast printed,
   asked for only once every endpoint has given it as this walk's create() at the nonce cast was given. */
async function createdVault(hash) {
  const rc = await receiptAgreed(hash);
  if (!rc) return { why: 'its receipt was not given alike by every endpoint' };
  if (rc.status !== '0x1' || !same(rc.transactionHash, hash) || !same(rc.from, ME) || !same(rc.to, DEP.maker)) {
    return { why: `its receipt says status ${rc.status}, hash ${rc.transactionHash}, ${rc.from} -> ${rc.to}` };
  }
  const tCreated = topic('VaultCreated(address,address)');
  const addrTopic = (t) => /^0x0{24}[0-9a-f]{40}$/.test(t || '');
  const made = rc.logs.filter((l) => same(l.address, DEP.maker) && l.topics[0] === tCreated && addrTopic(l.topics[2]) && same(topicAddr(l.topics[2]), ME));
  if (made.length !== 1) return { why: `its receipt holds ${made.length} VaultCreated logs of the maker for the walk address` };
  if (!addrTopic(made[0].topics[1]) || same(topicAddr(made[0].topics[1]), ZERO_ADDR)) return { why: 'the VaultCreated log names no vault address' };
  const vault = topicAddr(made[0].topics[1]);
  const last = await uintAgreed(DEP.maker, sel('lastVaultOf(address)') + addrWord(ME), { ms: READ_WAIT * 2, ok: (n) => n === BigInt(vault) });
  if (last === null) return { why: `the maker's lastVaultOf(walk address) was not ${vault} on every endpoint` };
  return { vault };
}

const vaultCache = new Map();
async function isVault(addr) {
  const a = lower(addr);
  if (vaultCache.get(a) === true) return true;
  /* a vault made a moment ago can read as unknown on a lagging endpoint: asked again for a while. Yes only when
     every endpoint says yes. */
  const yes = await uintAgreed(DEP.maker, sel('isVault(address)') + addrWord(a), { ok: (n) => n === 1n });
  if (yes === 1n) vaultCache.set(a, true);
  return yes === 1n;
}

/* No code at the address, on every endpoint. */
async function noCode(addr) {
  const v = await agreedUntil('eth_getCode', [addr, 'latest'], (x) => (typeof x === 'string' ? lower(x) : null), (x) => x !== null);
  return v === '0x';
}

/* The waiting period the maker gives its vaults, in seconds (the page shortens to less than this); null if unread. */
let makerTimelock = null;
async function timelockOfMaker() {
  if (makerTimelock === null) makerTimelock = await uintAgreed(DEP.maker, sel('TIMELOCK()'));
  return makerTimelock;
}

/* The change inside submit(bytes): the one call the page builds for the chosen kind (docs/run.js changeFor), in exact
   standard encoding, with its arguments held to what that call needs. Returns true, or a reason to refuse. */
async function changeAllowed(inner, ctx) {
  const sig = SUBMIT_SIG[ctx.kind];
  const hex = strip0x(inner);
  if (hex.length < 8 || `0x${hex.slice(0, 8)}` !== sel(sig)) return `schedules 0x${hex.slice(0, 8)}, not the ${ctx.kind} change ${sig}`;
  const types = typesOf(sig);
  let a;
  try { a = decodeArgs(types, hex.slice(8)); } catch (e) { return `${sig}: ${e.message}`; }
  if (encodeArgs(types, a) !== hex.slice(8)) return `${sig}: the change is not the standard encoding of its arguments`;
  if (ctx.kind === 'adapter' || ctx.kind === 'allocator') {
    if (ctx.kind === 'allocator' && a[1] !== true) return `${sig}: takes an allocator away; the page only adds one`;
    if (!(await noCode(a[0]))) return `${sig}: ${a[0]} holds code, or was not read as empty on every endpoint`;
    return true;
  }
  if (ctx.kind === 'timelock') {
    if (!TIMELOCK_TARGETS.map(sel).includes(a[0])) return `${sig}: ${a[0]} is not one of the four watched curator actions`;
    const limit = await timelockOfMaker();
    if (limit === null) return `${sig}: the maker's TIMELOCK() was not read alike on every endpoint`;
    if (a[1] < 1n || a[1] >= limit) return `${sig}: a waiting period of ${a[1]} s; the page asks for 1 to ${limit - 1n}`;
    return true;
  }
  if (strip0x(a[0]).length !== 64) return `${sig}: the id is ${strip0x(a[0]).length / 2} bytes, not 32`;
  if (a[1] < 1n || a[1] > MAX_CAP) return `${sig}: a cap of ${a[1]}; the page asks for at most ${MAX_CAP}`;
  return true;
}

const signed = (sig) => W.sent.some((s) => s.sig === sig);

/* Returns { ok: true, cls, sig, args, label } or { ok: false, why }. */
async function policy(tx) {
  if (!tx || typeof tx !== 'object') return { ok: false, why: 'no transaction object' };
  if (!same(tx.from, ME)) return { ok: false, why: `from ${tx.from} is not the walk address` };
  if (tx.chainId !== undefined && lower(tx.chainId) !== BASE_HEX && Number(tx.chainId) !== BASE_ID) return { ok: false, why: `chain ${tx.chainId} is not Base Sepolia` };
  if (tx.value !== undefined && tx.value !== null) {
    let value;
    try { value = BigInt(tx.value); } catch (e) { return { ok: false, why: 'the value is not a number' }; }
    if (value !== 0n) return { ok: false, why: 'the transaction carries value' };
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(tx.to || '')) return { ok: false, why: 'no target address (contract creation is never signed)' };
  const data = tx.data || tx.input;
  if (!/^0x([0-9a-fA-F]{2}){4,}$/.test(data || '')) return { ok: false, why: 'no call data' };
  let gas = null;
  if (tx.gas !== undefined && tx.gas !== null) {
    try { gas = BigInt(tx.gas); } catch (e) { return { ok: false, why: 'the gas limit is not a number' }; }
    if (gas < 0n || gas > MAX_GAS) return { ok: false, why: `gas ${gas} is not between 0 and ${MAX_GAS}` };
  }
  if (W.sent.length + W.dryRequests.length >= MAX_SENDS) return { ok: false, why: `more than ${MAX_SENDS} transactions in one walk` };
  const ctx = { me: ME, kind: OPT.kind, mode: OPT.mode, watchKinds: WATCH_KINDS[OPT.kind] };
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
  /* one of each, in the page's own order (a send cast did not report counts as signed) */
  if (ONCE.includes(sig) && signed(sig)) return { ok: false, why: `a second ${sig} in one walk` };
  if (rule.recovery && ONCE.some(signed)) return { ok: false, why: `${sig} after the walk's own run began (the page withdraws an earlier visit's deposit before it)` };
  if (sig === SIG_SUBMIT && !signed(SIG_ARM)) return { ok: false, why: `${sig} before the watch is on` };
  if (sig !== SIG_SUBMIT && signed(SIG_ARM)) return { ok: false, why: `${sig} after the watch was turned on (only the curator's one submit follows)` };
  if (sig === SIG_CREATE && signed(SIG_DEPOSIT)) return { ok: false, why: 'create() after the walk\'s deposit' };
  if (rule.vaultArg !== undefined && !(isOwn(args[rule.vaultArg]) && (await isVault(args[rule.vaultArg])))) {
    return { ok: false, why: `${sig}: ${args[rule.vaultArg]} is not this walk's own listed vault` };
  }
  if (rule.check) {
    const r = rule.check(args);
    if (r !== true) return { ok: false, why: `${sig}: ${r}` };
  }
  if (rule.ownWatch !== undefined) {
    /* only the walk address's own active watch on the walk's vault: the one the page's "withdraw and start over" ends */
    const id = OWN === null ? null : await uintAgreed(DEP.exit, sel('activeWatchOf(address,address)') + addrWord(ME) + addrWord(OWN));
    if (id === null || id === 0n || id !== args[rule.ownWatch]) {
      return { ok: false, why: `${sig}: watch ${args[rule.ownWatch]} is not the walk address's active watch on its own vault` };
    }
  }
  if (rule.change !== undefined) {
    const r = await changeAllowed(args[rule.change], ctx);
    if (r !== true) return { ok: false, why: `${sig}: ${r}` };
  }
  if (rule.curator && !(await curatorIsMe(tx.to))) return { ok: false, why: `${sig}: the walk address is not the curator of ${tx.to}` };
  return { ok: true, cls, sig, types, args, label: rule.label, data: lower(data), to: lower(tx.to), gas };
}

const refuse = (code, message) => ({ ok: false, error: { code, message } });

function refuseStopped(what) {
  W.refused.push({ at: secs(), method: 'eth_sendTransaction', why: W.failure ? 'the walk had already failed' : 'the walk had ended' });
  if (!W.failure) fail(`the page asked to sign ${what} after the walk ended`);
  return refuse(4001, 'Refused: the walk has stopped');
}

/* The walk address's transaction count as the sending endpoint gives it ('pending': the next nonce, transactions not
   yet mined included); null when it could not be read. */
async function nonceOf(tag) {
  const r = await rpc(BASE_SEND, 'eth_getTransactionCount', [ME, tag]);
  try { return r.error ? null : Number(BigInt(r.result)); } catch (e) { return null; }
}

/* The walk address's 'latest' transaction count from every Base Sepolia endpoint, the highest of them (they may be a
   block apart); null when any of them gives no readable count. */
async function latestEverywhere() {
  const answers = await Promise.all(BASE_ALL.map((u) => rpc(u, 'eth_getTransactionCount', [ME, 'latest'])));
  const counts = answers.map((r) => { try { return r.error ? null : Number(BigInt(r.result)); } catch (e) { return null; } });
  return counts.every((n) => Number.isSafeInteger(n) && n >= 0) ? Math.max(...counts) : null;
}

/* The nonce the next send takes: the sending endpoint's pending count, once it is at least one more than the nonce of
   the last send this walk recorded as mined (a lagging endpoint would hand out a used one), and every endpoint's
   'latest' count has been read, asked again for 15 s at most; then the highest of that pending count and those counts
   (a sending endpoint alone could name the nonce of an earlier transaction of the walk address). { nonce } or { why }. */
async function nextNonce() {
  const used = W.sent.filter((s) => s.hash && Number.isInteger(s.nonce)).map((s) => s.nonce + 1);
  const floor = used.length ? Math.max(...used) : 0;
  let last = null;
  let top = null;
  const n = await until(async () => {
    [last, top] = await Promise.all([nonceOf('pending'), latestEverywhere()]);
    return last !== null && last >= floor && top !== null ? Math.max(last, top) : null;
  }, WAIT.nonce, 1500);
  if (n !== null) return { nonce: n };
  return { why: last === null ? 'the next nonce of the walk address could not be read'
    : last < floor ? `the next nonce read is ${last}, not past ${floor - 1}, the nonce of this walk's last mined send`
      : 'the transaction count of the walk address could not be read from every Base Sepolia endpoint' };
}

/* Why the transaction as mined is not the one asked for, or null when it is: the page's call data, target and
   sender, no value, on Base Sepolia, at the nonce cast was given, and (hash given) under that hash. */
function minedDiffers(mined, p, nonce, hash = null) {
  if (!mined || typeof mined !== 'object') return 'could not be read back';
  if (hash !== null && !same(mined.hash, hash)) return `as mined is given under another hash (${oneLine(mined.hash).slice(0, 66)})`;
  const num = (x) => { try { return x === undefined || x === null ? null : BigInt(x); } catch (e) { return null; } };
  if (lower(mined.input) !== p.data || !same(mined.to, p.to) || !same(mined.from, ME) || num(mined.value) !== 0n) return 'as mined differs from the page\'s request';
  if (num(mined.chainId) !== BigInt(BASE_ID)) return `as mined is not a Base Sepolia transaction (chain id ${oneLine(mined.chainId)})`;
  if (num(mined.nonce) !== BigInt(nonce)) return `as mined has nonce ${oneLine(mined.nonce)}, not ${nonce}, the one cast was given`;
  return null;
}

/* What the nonce after the walk says of a send cast did not report (signed at nonce, the account's count now top). */
function broadcastOf(nonce, top) {
  if (nonce === null || nonce === undefined || top === null || top < 0) return 'not known: the nonce could not be read';
  return top > nonce ? 'yes: the nonce moved past the one given to cast'
    : 'inconclusive: the nonce did not move: not mined so far, a queued or dropped broadcast cannot be ruled out';
}

/* The cast runner. Only the signer test replaces it (signerFor), with a function that starts nothing. */
let castRunner = (argv, timeoutMs) => runCast(argv, timeoutMs);

/* With an out directory: the record so far, written as the result with result "running" (a job stopped from outside
   still leaves it, and the job summary shows it). The intent of a send in flight is in it; the key never is. */
function writeRunning() {
  if (!OPT || !OPT.out || OPT.dry) return;
  try {
    const res = bareResult(W.failure, 'running');
    writeFileSync(join(OPT.out, 'result.json'), JSON.stringify(res, null, 2) + '\n');
    writeFileSync(join(OPT.out, 'summary.md'), summaryMd(res));
  } catch (e) { /* the final result is written at the end */ }
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
  /* the nonce this send takes, read first and given to cast: if cast does not report back, the record still says
     what to look for */
  const nn = await nextNonce();
  /* checked again after the last wait: from here to the start of cast nothing is awaited */
  if (W.failure || W.stopped) return refuseStopped(p.sig);
  if (nn.why) {
    W.refused.push({ at: secs(), method: 'eth_sendTransaction', why: nn.why });
    fail(`refused ${p.sig}: ${nn.why}`);
    return refuse(4001, 'Refused by the walk signer');
  }
  const nonce = nn.nonce;
  /* --chain: cast signs for Base Sepolia whatever chain the endpoint claims to be at that moment */
  const argv = ['send', '--json', '--rpc-url', BASE_SEND, '--chain', String(BASE_ID), '--private-key', KEY, '--nonce', String(nonce),
    p.to, p.sig, ...p.types.map((t, i) => castArg(t, p.args[i]))];
  if (p.gas) argv.push('--gas-limit', p.gas.toString());
  const args = p.args.map((a) => lower(String(a)));
  log(`signing ${p.label}: ${p.sig} to ${p.to} nonce ${nonce}`);
  W.inFlight = { at: secs(), label: p.label, sig: p.sig, to: p.to, args, nonce };
  writeRunning();
  const r = await castRunner(argv, 240000);
  W.inFlight = null;
  const rec = r.code === 0 ? lastJson(r.out) : null;
  const hash = rec && /^0x[0-9a-fA-F]{64}$/.test(rec.transactionHash || '') ? lower(rec.transactionHash) : null;
  const entry = { at: secs(), label: p.label, sig: p.sig, to: p.to, args, nonce };
  if (!hash) {
    /* cast reported no mined transaction. It may have broadcast one all the same (its receipt wait failed, or it was
       stopped at the time limit): the request goes into the record as unknown, with the nonce and any hash cast
       printed, and closeSends() reads the nonce again at the end. */
    Object.assign(entry, { hash: null, status: 'unknown', castExit: r.code });
    const printed = hashesIn(`${r.out}\n${r.err}`);
    if (printed.length) entry.hashesPrinted = printed;
    Object.defineProperty(entry, 'data', { value: p.data, enumerable: false });
    W.sent.push(entry);
    fail(`cast send reported no mined transaction for ${p.sig} (exit ${r.code}); recorded as unknown, nonce ${nonce}: ${r.err.trim().split('\n').slice(-3).join(' | ')}`);
    writeRunning();
    return refuse(-32603, 'The transaction could not be sent');
  }
  const status = redact(String(rec.status)).slice(0, 16);
  Object.assign(entry, { hash, status, block: rec.blockNumber ? Number(BigInt(rec.blockNumber)) : null });
  W.sent.push(entry);
  writeRunning();
  if (!['1', '0x1', 'true'].includes(lower(status))) fail(`${p.sig} was mined and failed (status ${status}, ${hash})`);
  /* the transaction cast printed, as every endpoint gives it, must carry exactly what the page asked for, from the
     walk address, on Base Sepolia, at the nonce cast was given: the sending endpoint alone could hand cast the hash
     of another transaction (an earlier create() of the walk address has the same call data). Until it does, the
     hash is not taken as this send. */
  const mined = await txAgreed(hash);
  const differs = mined === null ? 'could not be read back alike from every endpoint' : minedDiffers(mined, p, nonce, hash);
  entry.hashConfirmed = !differs;
  if (differs) fail(`${hash} ${differs}`);
  entry.logs = (rec.logs || []).map((l) => ({ address: lower(l.address), topics: (l.topics || []).map(lower), data: lower(l.data) }));
  /* from here the vault this walk's own create() made is its one vault: the earlier visit's vault is no target any
     more, and nothing the page says can add one. The vault is taken from the receipt as every endpoint gives it and
     must be the maker's lastVaultOf(walk address) on every endpoint; until that is established there is none, and
     it is not sought at all for a hash that is not this create() as every endpoint gives it. */
  if (p.cls === 'maker' && p.sig === SIG_CREATE) {
    setOwn(null);
    const made = differs ? { why: 'its hash is not this create() on every endpoint' } : await createdVault(hash);
    setOwn(made.vault || null);
    if (!made.vault) fail(`${hash}: the vault of this create() could not be established (${made.why}); the walk has no vault of its own`);
  }
  writeRunning();
  log(`sent ${p.label}: ${hash} status ${status}`);
  return { ok: true, result: hash };
}

/* After the walk: the walk address's nonce again, and what became of a send cast did not report. Returns the nonce
   record for the result. A nonce that moved further than the record holds sends fails the walk. */
async function closeSends() {
  if (OPT.dry || W.nonceStart === undefined) return null;
  const latest = await nonceOf('latest');
  const pending = await nonceOf('pending');
  const top = [latest, pending].filter((n) => n !== null).reduce((a, b) => Math.max(a, b), -1);
  for (const s of W.sent.filter((x) => x.status === 'unknown')) {
    s.nonceAfter = top < 0 ? null : top;
    s.broadcast = broadcastOf(s.nonce, top);
    /* a printed hash is this request only when every endpoint gives it as this call from the walk address at the
       nonce cast was given (asked once); no agreement leaves the word the nonce gave, and the hash is listed as not
       confirmed (an endpoint did not answer, or the endpoints differ, for example one knows a pending transaction) */
    for (const h of s.hashesPrinted || []) {
      const t = await agreed('eth_getTransactionByHash', [h], txView);
      if (t.error) {
        s.hashesUnconfirmed = [...(s.hashesUnconfirmed || []), h];
        continue;
      }
      if (minedDiffers(t.value, { data: s.data, to: s.to }, s.nonce, h)) continue;
      const rc = await agreed('eth_getTransactionReceipt', [h], receiptView);
      s.hash = h;
      s.receiptStatus = rc.error ? 'not known: the endpoints did not give one receipt' : rc.value ? rc.value.status : 'no receipt yet';
      s.broadcast = 'yes: the transaction cast printed is this request on every endpoint';
      break;
    }
    log(`send not reported by cast: ${s.sig} nonce ${s.nonce}, broadcast ${s.broadcast}${s.hash ? `, ${s.hash}` : ''}`);
  }
  if (W.nonceStart !== null && latest !== null && latest - W.nonceStart > W.sent.length) {
    fail(`the walk address sent ${latest - W.nonceStart} transactions during the walk; the record holds ${W.sent.length}`);
  }
  return { atStart: W.nonceStart, atEnd: latest, pendingAtEnd: pending, recorded: W.sent.length };
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

/* While the page is driven (drive, and the dry check after it): the walk's own time limit. The driver's loops stop at
   it (the wait for the balances before the change runs to its own end, and nothing is pressed after it), and its page
   calls wait at most 5 s past it, so the walk's timeout fires well before the job's. Infinity otherwise (the wallet's
   replies and the screenshots never use it). */
let DEADLINE = Infinity;
const overDeadline = () => Date.now() > DEADLINE;
const pageWait = () => Math.max(2000, Math.min(60000, DEADLINE - Date.now() + 5000));

async function evalPage(expression) {
  const r = await tab('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, pageWait());
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
    case 'Page.frameNavigated': {
      /* a live walk serves its wallet to the hosted page only: the main frame may not go anywhere else */
      const f = p.frame || {};
      if (!f.parentId && OPT && !OPT.dry && f.url && f.url !== 'about:blank' && !underLive(f.url)) {
        fail(`the browser left the hosted page for ${oneLine(f.url).slice(0, 200)}`);
      }
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

/* The snapshot as plain strings and booleans, whatever the page put there: its values are used in text after the walk,
   and an object that cannot be turned into a string must not stop the result from being written. */
function cleanSnap(s) {
  const str = (v, n) => (typeof v === 'string' ? v.slice(0, n) : '');
  if (!s || typeof s !== 'object' || typeof s.state !== 'string' || !s.state) return null;
  const acts = (Array.isArray(s.acts) ? s.acts : []).filter((x) => x && typeof x === 'object' && typeof x.a === 'string')
    .slice(0, 40).map((x) => ({ a: x.a.slice(0, 60), off: x.off === true }));
  return { state: s.state.slice(0, 60), cls: str(s.cls, 200), head: str(s.head, 300), text: str(s.text, 1500), acts };
}

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
    await tab('Input.dispatchMouseEvent', { type: 'mouseMoved', x: r.x, y: r.y }, pageWait());
    await tab('Input.dispatchMouseEvent', { type: 'mousePressed', x: r.x, y: r.y, button: 'left', clickCount: 1 }, pageWait());
    await tab('Input.dispatchMouseEvent', { type: 'mouseReleased', x: r.x, y: r.y, button: 'left', clickCount: 1 }, pageWait());
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

/* Why the kind boxes the page shows cannot be the watch step's, or null: at most 8 (the page reads one more at most),
   each of bit 1, 2, 4 or 8, no bit twice. */
function boxProblem(list) {
  if (!Array.isArray(list)) return 'the kind boxes could not be read';
  if (list.length > 8) return 'the watch step shows more than 8 kind boxes';
  const seen = new Set();
  for (const b of list) {
    const bit = b && typeof b === 'object' ? b.bit : undefined;
    if (![1, 2, 4, 8].includes(bit)) return `a kind box has bit ${oneLine(bit).slice(0, 20)}, not 1, 2, 4 or 8`;
    if (seen.has(bit)) return `two kind boxes have bit ${bit}`;
    seen.add(bit);
  }
  return null;
}

async function configureWatch() {
  const want = WATCH_KINDS[OPT.kind];
  const late = () => { fail(`no end state within ${OPT.timeout} s (while setting the kind boxes)`); return false; };
  const modeSel = await findFirst(MODE_SELECTORS(OPT.mode));
  if (OPT.mode === 1 && !modeSel) { fail('the page offers no control for "leave if still pending" (mode 1); this walk cannot choose it'); return false; }
  if (modeSel) {
    const on = await evalPage(`(() => { const e = document.querySelector(${JSON.stringify(modeSel)}); return e.type === 'radio' || e.type === 'checkbox' ? e.checked : e.getAttribute('aria-pressed') === 'true'; })()`);
    if (!on && !(await clickSel(modeSel))) { fail(`could not choose mode ${OPT.mode}`); return false; }
  }
  /* nine at most are read: more than 8 fails the walk whatever the page holds */
  const boxes = async () => {
    const l = await evalPage(`Array.prototype.slice.call(document.querySelectorAll('#state input[data-bit]'), 0, 9).map((b) => ({ bit: Number(b.getAttribute('data-bit')), checked: b.checked === true, disabled: b.disabled === true }))`);
    const why = boxProblem(l);
    if (why) { fail(`the watch step cannot be set: ${why}`); return null; }
    return l;
  };
  let list = await boxes();
  if (!list) return false;
  if (!list.length) { fail('the watch step shows no kind boxes (input[data-bit])'); return false; }
  /* tick first, untick after: with no kind ticked the page disables "Turn the watch on" */
  for (const pass of [true, false]) {
    for (const b of list) {
      if (overDeadline()) return late();
      const on = (want & b.bit) !== 0;
      if (on !== pass || b.checked === on) continue;
      if (b.disabled) { fail(`the page locks the box of kind ${b.bit}; this walk needs kinds ${want}`); return false; }
      await clickSel(`#state input[data-bit="${b.bit}"]`);
      await sleep(150);
    }
    if (overDeadline()) return late();
    list = await boxes();
    if (!list) return false;
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

/* Balances the checks compare: read at one block number that every endpoint has reached, the same answer from all. */
async function balancesAt(vault, atLeast = 0, ms = 20000) {
  const n = await pinnedBlock(atLeast, ms);
  if (n === null) return { block: null, token: null, shares: null, watch: null };
  const at = { block: blockHex(n), ms: WAIT.balance };
  const token = await uintAgreed(DEP.token, sel('balanceOf(address)') + addrWord(ME), at);
  const shares = vault ? await uintAgreed(vault, sel('balanceOf(address)') + addrWord(ME), at) : null;
  const watch = vault ? await uintAgreed(DEP.exit, sel('activeWatchOf(address,address)') + addrWord(ME) + addrWord(vault), at) : null;
  return { block: n, token, shares, watch };
}

/* The balances before the change: read at a block not below the block of this walk's arm (its receipt alike from
   every endpoint), so they hold the walk's own deposit and arm; asked again for 60 s at most. { block, token, shares,
   watch, armBlock } or { why }: the walk then stops before the change is scheduled. */
async function armBaseline(vault) {
  const armSent = W.sent.filter((x) => x.sig === SIG_ARM && x.hash)[0];
  if (!armSent) return { why: 'this walk has no mined arm in its record' };
  const rc = await receiptAgreed(armSent.hash);
  if (!rc || rc.status !== '0x1' || !/^0x[0-9a-f]+$/.test(rc.blockNumber)) return { why: `the arm ${armSent.hash} has no successful receipt alike on every endpoint` };
  const armBlock = Number(BigInt(rc.blockNumber));
  const b = await balancesAt(vault, armBlock, WAIT.baseline);
  if (b.block === null || b.block < armBlock || b.token === null || b.shares === null) {
    return { why: `no balances alike on every endpoint at a block not below the arm's block ${armBlock} (block ${b.block}, demo dollars ${b.token}, shares ${b.shares})` };
  }
  return { ...b, armBlock };
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
  'run-still-on', 'run-no-exit', 'run-no-return', 'vault-set-aside']);

/* Returns 'returned', 'dry-ok', or null on failure. */
async function drive() {
  const deadline = Date.now() + OPT.timeout * 1000;
  DEADLINE = deadline;
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
    try { s = cleanSnap(await evalPage(SNAP)); } catch (e) { await sleep(500); continue; }
    if (!s) { await sleep(400); continue; }
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
          W.vault = OWN;
          /* the baseline is read at or after the arm's block, or the walk stops here, before the change is scheduled */
          const before = await armBaseline(W.vault);
          if (before.why) { fail(`no balances before the change: ${before.why}`); return null; }
          /* the wait for the balances is not cut short, but nothing is pressed after it once the deadline passed */
          if (overDeadline()) { fail(`no end state within ${OPT.timeout} s (while reading the balances before the change)`); return null; }
          W.tokenBefore = before.token;
          W.sharesBefore = before.shares;
          W.beforeBlock = before.block;
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
    /* only three well-formed hashes count, whatever else the page returns */
    const ok = (x) => typeof x === 'string' && /^0x[0-9a-f]{64}$/.test(x);
    return h && ok(h.h1) && ok(h.h2) && ok(h.h3) ? { h1: h.h1, h2: h.h2, h3: h.h3 } : null;
  }, 90000, 2000);
}

/* ---------- the independent check (receipts, not the page) ---------- */

async function verifyRun(v) {
  const checks = [];
  const out = { checks };
  const check = (name, ok, detail) => { checks.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) }); return !!ok; };
  /* Base Sepolia: the same receipt from every endpoint. Reactive Lasna has one public endpoint. */
  const [r1, r3] = [await receiptAgreed(v.h1), await receiptAgreed(v.h3)];
  const r2 = await receipt([LASNA_RPC], v.h2);
  if (!check('three receipts read (the two on Base Sepolia alike from every endpoint)', r1 && r2 && r3, `${!!r1} ${!!r2} ${!!r3}`)) return out;
  out.block3 = Number(BigInt(r3.blockNumber));
  const watchIs = (t) => { try { return BigInt(t) === BigInt(v.watchId); } catch (e) { return false; } };
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
  /* one Submit fires every watch on the vault in one reactive transaction: this watch's log is found by its id */
  const ex = (r2.logs || []).find((l) => same(l.address, DEP.reactive) && lower(l.topics[0]) === tExit && watchIs(l.topics[1]));
  if (check('2. Reactive: ExitRequested of NoticeReactive for the watch', ex, `watch ${v.watchId}`)) {
    check('2. Reactive: names the Submit as its origin', same(ex.topics[2], v.h1), ex.topics[2]);
    out.exitReason = Number(dataWord(ex.data, 0));
  }
  check('3. Exit: status 1', r3.status === '0x1', r3.status);
  const tEnded = topic('WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)');
  const end = (r3.logs || []).find((l) => same(l.address, DEP.exit) && lower(l.topics[0]) === tEnded && watchIs(l.topics[1]));
  if (check('3. Exit: WatchEnded of NoticeExit for the watch', end, `watch ${v.watchId}`)) {
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
  const t1 = await blockTsAgreed(r1.blockNumber, r1.blockHash);
  const t2 = await blockTs([LASNA_RPC], r2.blockNumber);
  const t3 = await blockTsAgreed(r3.blockNumber, r3.blockHash);
  if (check('block times read (Base Sepolia: the blocks of the receipts, alike from every endpoint)', t1 !== null && t2 !== null && t3 !== null)) {
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
  const r = await receiptAgreed(armTx);
  if (!r || r.status !== '0x1') return null;
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
  for (const [u, want] of [...BASE_ALL.map((x) => [x, BASE_ID]), [LASNA_RPC, LASNA_ID]]) {
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
  /* the walk address's own earlier vault (the page resumes or empties it), read once, before the page says anything,
     and only as every endpoint gives it */
  const last = await uintAgreed(DEP.maker, sel('lastVaultOf(address)') + addrWord(ME), { ms: 20000 });
  if (last === null || last >> 160n !== 0n) die('the Base Sepolia endpoints did not give one lastVaultOf for the walk address');
  if (last !== 0n) {
    setOwn('0x' + last.toString(16).padStart(40, '0'));
    log(`the walk address's last vault from the maker: ${OWN}`);
  }
  /* the next nonce before the walk: at the end the nonce is read again and compared with the record of sends */
  if (!OPT.dry) W.nonceStart = await nonceOf('pending');
  const bal = await rpcAny(BASE_READ, 'eth_getBalance', [ME, 'latest']);
  const eth = bal && bal.result ? BigInt(bal.result) : null;
  log(`walk address ${ME}${OPT.dry ? ' (dry: nothing is signed)' : ''}; Base Sepolia balance ${eth === null ? 'unknown' : (Number(eth) / 1e18).toFixed(6)} ETH`);

  const res = { result: 'failed', dry: OPT.dry, url: OPT.url, deployment: DEP.name, key: OPT.key, address: ME, kind: OPT.kind,
    mode: OPT.mode, watchKinds: WATCH_KINDS[OPT.kind], startedAt: new Date(t0).toISOString() };
  let shot = null;
  let chrome = await launchChrome(OPT.browser, false);
  res.browserSandbox = true;
  if (chrome.error && OPT.dry) {
    /* a dry walk holds no key: it may run the page without the browser's sandbox, and says so */
    W.notes.push(`browser with its sandbox: ${chrome.error}; started again without it`);
    res.browserSandbox = false;
    try { rmSync(chrome.profile, { recursive: true, force: true }); } catch (e) { /* busy */ }
    chrome = await launchChrome(OPT.browser, true);
  } else if (chrome.error) {
    /* a live walk never does: the processes around the browser hold the key */
    res.browserSandbox = null;
    chrome.error = `the browser did not start with its sandbox, and a live walk does not run the page without it: ${chrome.error}`;
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
        res.walletSeen = (await evalPage(`!!(window.ethereum && window.ethereum.isPageWalk)`)) === true;
        if (!OPT.dry) {
          /* where the browser itself says the tab is (not the page's own word): still under the hosted page */
          const nav = await tab('Page.getNavigationHistory');
          const at = nav && Array.isArray(nav.entries) && nav.entries[nav.currentIndex] ? String(nav.entries[nav.currentIndex].url || '') : '';
          if (!underLive(at)) fail(`the browser is at ${oneLine(at).slice(0, 200)}, not under the hosted page`);
        }
        await screenshot('loaded');
        if (!W.failure && (await checkPage())) {
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
          /* the page is no longer driven: its later reads have their own limits */
          DEADLINE = Infinity;
          if (end === 'returned') {
            await screenshot('returned', true);
            res.returnedText = W.last && W.last.text;
            const hashes = await ledgerHashes();
            res.page = hashes;
            if (!hashes) fail('the page did not show all three transactions within 90 s of "returned"');
            else {
              const armSent = W.sent.filter((x) => x.sig === SIG_ARM && x.hash)[0];
              const submitSent = W.sent.filter((x) => x.sig === SIG_SUBMIT && x.hash)[0];
              const arm = armSent ? await armFacts(armSent.hash, ME) : null;
              if (!arm) fail('no WatchArmed in the arm transaction this walk signed');
              else if (!submitSent) fail('this walk signed no submit');
              else {
                res.vault = arm.vault;
                res.watchId = arm.watchId;
                res.arm = arm;
                /* the walk has one vault (the signer's): the watch, the deposit and the submit are all on it */
                if (!OWN || !same(arm.vault, OWN)) fail(`the watch is on ${arm.vault}, the walk's vault is ${OWN}`);
                if (arm.kinds !== WATCH_KINDS[OPT.kind] || arm.mode !== OPT.mode) fail(`WatchArmed says kinds ${arm.kinds} mode ${arm.mode}`);
                const v = await verifyRun({ ...hashes, submitHash: submitSent.hash, owner: ME, curator: ME, vault: arm.vault,
                  watchId: arm.watchId, shares: arm.maxShares, kind: OPT.kind });
                const check = (name, ok, detail) => v.checks.push({ name, ok: !!ok, detail: String(detail) });
                const haveBefore = W.tokenBefore !== null && W.tokenBefore !== undefined;
                /* The balances after the exit, at one block number that every endpoint has reached and that is not
                   before the exit's block, the same answer from every endpoint; read again for 20 s at most until
                   they fit the exit (an endpoint can be behind). */
                let after = { block: null, token: null, shares: null, watch: null };
                await until(async () => {
                  after = await balancesAt(arm.vault, v.block3 || 0);
                  const gained = haveBefore && after.token !== null && v.assets !== undefined ? after.token - W.tokenBefore === BigInt(v.assets) : true;
                  return after.shares === 0n && after.watch === 0n && gained ? true : null;
                }, 20000, 2000);
                check('after: no shares left in the vault', after.shares === 0n, after.shares);
                check('after: no watch left on the vault', after.watch === 0n, after.watch);
                /* a balance that could not be read alike from every endpoint is a failed check, never a skipped one */
                const haveTokens = haveBefore && after.token !== null && v.assets !== undefined;
                check('after: the wallet gained exactly the redeemed assets', haveTokens && after.token - W.tokenBefore === BigInt(v.assets),
                  haveTokens ? `${W.tokenBefore} -> ${after.token}` : `not read (before ${W.tokenBefore}, after ${after.token})`);
                /* one of each, all on the one vault: the signer refuses a second, and the record is checked for it too */
                const count = (sig) => W.sent.filter((x) => x.sig === sig).length;
                check('this walk signed one create() at most, and exactly one deposit, one arm and one submit',
                  count(SIG_CREATE) <= 1 && count(SIG_DEPOSIT) === 1 && count(SIG_ARM) === 1 && count(SIG_SUBMIT) === 1,
                  `${count(SIG_CREATE)} create, ${count(SIG_DEPOSIT)} deposit, ${count(SIG_ARM)} arm, ${count(SIG_SUBMIT)} submit`);
                const dep = W.sent.filter((x) => x.sig === SIG_DEPOSIT)[0];
                check('the deposit and the submit this walk signed went to the watched vault',
                  dep && same(dep.to, arm.vault) && same(submitSent.to, arm.vault), `deposit ${dep ? dep.to : 'none'}, submit ${submitSent.to}`);
                const shares = BigInt(arm.maxShares);
                check('the shares held before the change equal the watch\'s maxShares and the shares redeemed',
                  W.sharesBefore !== null && W.sharesBefore !== undefined && W.sharesBefore === shares && v.shares !== undefined && BigInt(v.shares) === shares,
                  `held ${W.sharesBefore}, watch ${shares}, redeemed ${v.shares}`);
                /* what the deposit paid: its own Transfer log of the demo dollar, from the walk address to the vault */
                const depRc = dep && dep.hash ? await receiptAgreed(dep.hash) : null;
                const tTransfer = topic('Transfer(address,address,uint256)');
                const paidLog = depRc && depRc.status === '0x1' ? depRc.logs.find((l) => same(l.address, DEP.token) && l.topics[0] === tTransfer &&
                  same(topicAddr(l.topics[1] || ''), ME) && same(topicAddr(l.topics[2] || ''), arm.vault)) : null;
                const paid = paidLog ? dataWord(paidLog.data, 0) : null;
                check('the deposit moved the demo dollars it names from the walk address into the vault', paid !== null && paid === BigInt(dep.args[0]),
                  paid === null ? 'no such Transfer log in the deposit' : `moved ${paid}, named ${dep.args[0]}`);
                check('the exit returned the deposit, less at most one unit of rounding', paid !== null && v.assets !== undefined && BigInt(v.assets) + 1n >= paid,
                  `deposited ${paid}, returned ${v.assets}`);
                res.readBlocks = { before: W.beforeBlock === undefined ? null : W.beforeBlock, after: after.block };
                const tokenAfter = after.token;
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
    DEADLINE = Infinity;
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
  /* the nonce again, and what became of a send cast did not report (can fail the walk) */
  res.nonce = await closeSends().catch(() => null);
  /* the dry walk passes only with the wallet seen, one rejected confirmation and nothing else wrong */
  if (OPT.dry && res.result === 'ok' && (!res.walletSeen || !W.connected || W.failure)) res.result = 'failed';
  if (W.failure) res.result = 'failed';
  Object.assign(res, {
    failure: W.failure, finalState: W.last ? W.last.state : null, finalHead: W.last ? W.last.head : null,
    finalText: res.result === 'ok' ? undefined : (W.last ? W.last.text : null),
    endedAt: new Date().toISOString(), seconds: secs(), states: W.states, stateLog: W.stateLog, walletRequests: W.requests,
    sent: W.sent.map(({ logs, ...rest }) => rest), refused: W.refused, unsupported: W.unsupported, dryRequests: W.dryRequests,
    consoleErrors: W.consoleErrors, warnings: W.warnings, networkErrors: W.networkErrors, notes: W.notes,
    screenshots: W.screenshots.map((f) => f.split(/[\\/]/).pop()), pageConfig: W.page, ownVault: OWN,
  });
  /* A transaction cast was still sending is in the record (W.sent and W.failure were read after signChain). The
     result is written first; nothing printed after it can keep it from being written. */
  try { emit(res, shot); } catch (e) { emit(bareResult(`the result could not be written in full: ${scrub(e && e.message)}`), null); }
  try {
    if (res.result !== 'ok' && W.last) {
      log(`page state at the end: ${W.last.state} | ${W.last.head}`);
      console.log(String(W.last.text || '').split('\n').map((l) => `  | ${oneLine(l)}`).join('\n'));
    }
  } catch (e) { /* diagnostics only */ }
  if (CDP) {
    await CDP.send('Browser.close', {}, undefined, 5000).catch(() => {});
    CDP.close();
  }
  if (chrome && chrome.proc) { try { chrome.proc.kill(); } catch (e) { /* gone */ } }
  await sleep(1000);
  if (chrome && chrome.profile) { try { rmSync(chrome.profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 }); } catch (e) { /* the browser may still hold it */ } }
  return res.result === 'ok' ? 0 : 1;
}

/* The least a failed walk leaves behind, and the running record (writeRunning): what was sent and refused, and the
   send in flight, in plain values only. */
function bareResult(failure, result = 'failed') {
  const plain = (list) => list.map((x) => { try { return JSON.parse(JSON.stringify(x, (k, v) => (k === 'logs' ? undefined : (typeof v === 'bigint' ? v.toString() : v)))); } catch (e) { return null; } });
  return { result, dry: !!(OPT && OPT.dry), url: OPT ? OPT.url : null, deployment: DEP ? DEP.name : null, key: OPT ? OPT.key : null,
    address: ME, kind: OPT ? OPT.kind : null, mode: OPT ? OPT.mode : null, watchKinds: OPT ? WATCH_KINDS[OPT.kind] : null,
    failure: failure ? oneLine(failure) : null, sent: plain(W.sent), inFlight: W.inFlight ? plain([W.inFlight])[0] : null,
    refused: plain(W.refused), states: plain(W.states), ownVault: OWN, endedAt: new Date().toISOString(), seconds: secs() };
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
   address and its one vault (ownVault, as if made by this walk), and nothing is sent (dry). The chain reads behind a
   yes are asked once, without the wait for a lagging endpoint; the test answers them itself (it replaces fetch), and
   it puts what counts as already signed into record.sent. The longer waits are set to 0 too; waits is that table, for
   a test of a wait itself. */
export function policyFor(opt, deploymentName, address, ownVault = null) {
  OPT = { deployment: deploymentName, key: 'b', kind: 'adapter', mode: 0, timeout: 480, ...opt, dry: true };
  DEP = loadDeployment(deploymentName);
  ME = lower(address);
  KEY = null;
  setOwn(Array.isArray(ownVault) ? ownVault[0] : ownVault);
  vaultCache.clear();
  makerTimelock = null;
  READ_WAIT = 0;
  READ_EVERY = 1;
  for (const k of Object.keys(WAIT)) WAIT[k] = 0;
  return { policy, walletRequest, record: W, keccak256, encodeArgs, decodeArgs, sel, topic, isLiveUrl, cleanSnap, hashesIn,
    endpoints: BASE_ALL.slice(), createdVault, armBaseline, boxProblem, broadcastOf, minedDiffers, ownVault: () => OWN, waits: WAIT };
}

/* For a test of the signing path itself (the nonce, the stop checks, the read-back, the create's vault): as
   policyFor, but not dry, with cast replaced by cast(argv, timeoutMs), a function of the test that returns
   { code, out, err } and starts nothing ('process': the real cast process, CAST_BIN, for a stand-in of cast), and
   with key, a placeholder string that is no key, in place of WALK_KEY. out, when given, is the directory of the
   running result. Returns sendTransaction and closeSends with the policyFor tools. */
export function signerFor(opt, deploymentName, address, ownVault, { key, cast, out } = {}) {
  if (typeof cast !== 'function' && cast !== 'process') throw new Error('signerFor needs a cast function of the test');
  if (typeof key !== 'string' || /^(0x)?[0-9a-fA-F]{64}$/.test(key.trim())) throw new Error('signerFor takes a placeholder, never a key');
  const tools = policyFor(opt, deploymentName, address, ownVault);
  OPT.dry = false;
  OPT.out = out;
  KEY = key;
  castRunner = cast === 'process' ? (argv, timeoutMs) => runCast(argv, timeoutMs) : cast;
  W.failure = null;
  W.stopped = false;
  W.inFlight = null;
  W.nonceStart = undefined;
  for (const k of ['sent', 'refused', 'dryRequests']) W[k].length = 0;
  return { ...tools, sendTransaction, closeSends };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((code) => process.exit(code), (e) => {
    const msg = scrub(e && e.message);
    console.error(`page-walk: ${msg}`);
    /* a walk that stopped on an error of this script still leaves its record of sends */
    try { if (OPT && OPT.out && !OPT.verifyRecord) emit(bareResult(`walk error: ${msg}`), null); } catch (e2) { /* nothing more to try */ }
    process.exit(1);
  });
}
