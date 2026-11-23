#!/usr/bin/env node
/* The page walk's signer rules (scripts/page-walk.mjs policyFor), tested with no key, no browser and no network.
   The chain reads the signer makes behind a yes (the maker's isVault and TIMELOCK, the vault's curator, the code at
   an address, the walk address's active watch) are answered here: fetch is replaced by a function that answers them
   from the table "chain" below, per endpoint, so an endpoint that lies or does not answer can be played too. What
   counts as already signed in a walk is put into record.sent. Addresses are those of deployments/2026-11-22.json.
   The signing path itself (signerFor) runs with cast replaced by a function of this test that starts nothing and a
   placeholder string in place of the key: the nonce read and given to cast, the stop checks after it, the running
   result, the read-back and the vault of the walk's create(). Also tested: the create's vault, the balances before
   the change, the kind boxes of the watch step and the word for an unreported send. The running result goes to a
   temporary directory, removed after.
   Usage: node scripts/test-page-walk.mjs */

import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { policyFor, signerFor } from './page-walk.mjs';

const ME = '0x' + '1'.repeat(40);
const OTHER = '0x' + '2'.repeat(40);
const VAULT = '0x' + '3'.repeat(40); /* this walk's one vault */
const VAULT2 = '0x' + '4'.repeat(40); /* another vault the maker lists (an earlier visit's, or someone else's) */
const EMPTY = '0x' + '5'.repeat(40); /* an address with no code */
const CODE = '0x' + '6'.repeat(40); /* an address with code */
const ID32 = '0x' + '7'.repeat(64);
const low = (s) => String(s).toLowerCase();

/* the contracts of the deployment file, never of the page */
const dep = JSON.parse(readFileSync(new URL('../deployments/2026-11-22.json', import.meta.url), 'utf8'));
const C = dep.contracts;
const SMOKE = dep.smokeVault.address;

const tools = policyFor({ kind: 'adapter', mode: 0 }, '2026-11-22', ME);
const { encodeArgs, sel, topic, record, walletRequest, isLiveUrl, cleanSnap, hashesIn, endpoints, boxProblem, broadcastOf, minedDiffers } = tools;

/* ---------- the chain, as this test tells it ---------- */

const START = () => ({ vaults: [VAULT, VAULT2, SMOKE].map(low), curator: ME, timelock: 180n, watch: 9n, code: { [low(CODE)]: '0x6000' },
  /* curatorWord: the raw curator() answer of every endpoint; lastVault: the maker's lastVaultOf; receipts and txs by
     hash; head: the block number (a function of the endpoint: asked at each read); nonce: the transaction count (null:
     no answer; a function of the endpoint and the tag, 'pending' or 'latest': asked at each read);
     tokens, shares: the walk address's balances */
  curatorWord: null, lastVault: VAULT, receipts: {}, txs: {}, head: 100, nonce: 6, tokens: 5n, shares: 7n,
  /* lie: { host, method, selector?, result }: that endpoint alone gives this answer; down: that endpoint does not answer */
  lie: null, down: null });
let chain = START();
let asked = 0;
const word = (n) => '0x' + BigInt(n).toString(16).padStart(64, '0');

globalThis.fetch = async (url, init) => {
  asked += 1;
  const body = JSON.parse(init.body);
  const reply = (o) => ({ status: 200, text: async () => JSON.stringify({ jsonrpc: '2.0', id: body.id, ...o }) });
  if (chain.down && String(url).includes(chain.down)) throw new Error('unreachable');
  const arg = body.params && body.params[0];
  const selector = body.method === 'eth_call' ? low(arg.data).slice(0, 10) : null;
  if (chain.lie && String(url).includes(chain.lie.host) && body.method === chain.lie.method && (!chain.lie.selector || chain.lie.selector === selector)) {
    return reply({ result: chain.lie.result });
  }
  if (body.method === 'eth_getCode') return reply({ result: chain.code[low(arg)] || '0x' });
  if (body.method === 'eth_getTransactionReceipt') return reply({ result: chain.receipts[low(arg)] || null });
  if (body.method === 'eth_getTransactionByHash') return reply({ result: chain.txs[low(arg)] || null });
  if (body.method === 'eth_blockNumber') return reply({ result: '0x' + (typeof chain.head === 'function' ? chain.head(String(url)) : chain.head).toString(16) });
  if (body.method === 'eth_getTransactionCount') {
    const n = typeof chain.nonce === 'function' ? chain.nonce(String(url), body.params[1]) : chain.nonce;
    return n === null ? reply({ error: { code: -32000, message: 'no count' } }) : reply({ result: '0x' + n.toString(16) });
  }
  if (body.method === 'eth_call') {
    const to = low(arg.to);
    if (to === low(C.maker) && selector === sel('lastVaultOf(address)')) return reply({ result: word(BigInt(chain.lastVault)) });
    if (to === low(C.token) && selector === sel('balanceOf(address)')) return reply({ result: word(chain.tokens) });
    if (chain.vaults.includes(to) && selector === sel('balanceOf(address)')) return reply({ result: word(chain.shares) });
    if (chain.vaults.includes(to) && selector === sel('curator()') && chain.curatorWord) return reply({ result: chain.curatorWord });
    if (to === low(C.maker) && selector === sel('isVault(address)')) return reply({ result: word(chain.vaults.includes('0x' + low(arg.data).slice(34, 74)) ? 1 : 0) });
    if (to === low(C.maker) && selector === sel('TIMELOCK()')) return reply({ result: word(chain.timelock) });
    if (to === low(C.exit) && selector === sel('activeWatchOf(address,address)')) return reply({ result: word(chain.watch) });
    if (chain.vaults.includes(to) && selector === sel('curator()')) return reply({ result: word(BigInt(chain.curator)) });
  }
  return reply({ error: { code: -32601, message: 'not answered by this test' } });
};

/* ---------- transactions ---------- */

const call = (sig, types, values) => sel(sig) + encodeArgs(types, values);
const tx = (to, data, extra = {}) => ({ from: ME, to, data, ...extra });
const submit = (inner) => call('submit(bytes)', ['bytes'], [inner]);
const arm = (vault, kinds, mode) => tx(C.exit, call('arm(address,uint8,uint8,uint256)', ['address', 'uint8', 'uint8', 'uint256'], [vault, kinds, mode, 100n]));
const deposit = (vault, to) => tx(vault, call('deposit(uint256,address)', ['uint256', 'address'], [100000000n, to]));
const addAdapter = (a) => call('addAdapter(address)', ['address'], [a]);
const setAllocator = (a, on) => call('setIsAllocator(address,bool)', ['address', 'bool'], [a, on]);
const shorter = (target, seconds) => call('decreaseTimelock(bytes4,uint256)', ['bytes4', 'uint256'], [target, seconds]);
const capUp = (id, cap) => call('increaseAbsoluteCap(bytes,uint256)', ['bytes', 'uint256'], [id, cap]);
const CREATE = 'create()';
const DEPOSIT = 'deposit(uint256,address)';
const ARM = 'arm(address,uint8,uint8,uint256)';
const SUBMIT = 'submit(bytes)';
const publicnode = 'publicnode';

/* [name, transaction, signs?, { own, sent, kind, mode, chain }]: own = the walk's one vault (none by default), sent =
   the calls already signed in this walk, chain = changes to the table above for this case. */
const cases = [
  /* no vault of its own: the three contracts of the deployment only, and nothing is read from the chain */
  ['make a vault', tx(C.maker, sel(CREATE)), true],
  ['mint demo dollars to the walk address', tx(C.token, call('mint(address,uint256)', ['address', 'uint256'], [ME, 100000000n])), true],
  ['mint to another address', tx(C.token, call('mint(address,uint256)', ['address', 'uint256'], [OTHER, 1n])), false],
  ['token transfer', tx(C.token, call('transfer(address,uint256)', ['address', 'uint256'], [OTHER, 1n])), false],
  ['token approve for the smoke vault (not this walk\'s)', tx(C.token, call('approve(address,uint256)', ['address', 'uint256'], [SMOKE, 1n])), false],
  ['token approve for the exit contract', tx(C.token, call('approve(address,uint256)', ['address', 'uint256'], [C.exit, 1n])), false],
  ['arm on the smoke vault (not this walk\'s)', arm(SMOKE, 7n, 0n), false],
  ['deposit into the smoke vault (not this walk\'s)', deposit(SMOKE, ME), false],
  ['submit on a vault that is not this walk\'s', tx(SMOKE, submit(addAdapter(EMPTY))), false, { sent: [ARM] }],
  ['turn a watch off with no vault of the walk\'s own', tx(C.exit, call('cancel(uint256)', ['uint256'], [9n])), false],
  ['a call to an address that is no contract of the deployment', tx(OTHER, sel(CREATE)), false],
  ['a maker call other than create', tx(C.maker, call('isVault(address)', ['address'], [SMOKE])), false],
  ['value attached', tx(C.maker, sel(CREATE), { value: '0x1' }), false],
  ['a value that is no number', tx(C.maker, sel(CREATE), { value: 'much' }), false],
  ['from another address', { ...tx(C.maker, sel(CREATE)), from: OTHER }, false],
  ['another chain', tx(C.maker, sel(CREATE), { chainId: '0x1' }), false],
  ['gas above the limit', tx(C.maker, sel(CREATE), { gas: '0x7a1201' }), false],
  ['a negative gas limit', tx(C.maker, sel(CREATE), { gas: '-1' }), false],
  ['a gas limit that is no number', tx(C.maker, sel(CREATE), { gas: 'plenty' }), false],
  ['contract creation (no target)', { from: ME, data: sel(CREATE) }, false],
  ['bytes after the arguments', tx(C.maker, sel(CREATE) + '00'.repeat(32)), false],
  ['dirty bits in an address argument', tx(C.token, sel('mint(address,uint256)') + 'ff'.repeat(12) + ME.slice(2) + '0'.repeat(63) + '1'), false],

  /* the walk's one vault: what the page sends, in the page's order */
  ['token approve for the walk\'s vault', tx(C.token, call('approve(address,uint256)', ['address', 'uint256'], [VAULT, 100000000n])), true, { own: VAULT }],
  ['deposit into the walk\'s vault for the walk address', deposit(VAULT, ME), true, { own: VAULT, sent: [CREATE] }],
  ['allow the exit contract to redeem the shares', tx(VAULT, call('approve(address,uint256)', ['address', 'uint256'], [C.exit, 100n])), true, { own: VAULT, sent: [CREATE, DEPOSIT] }],
  ['turn the watch on with the chosen kinds and mode', arm(VAULT, 7n, 0n), true, { own: VAULT, sent: [CREATE, DEPOSIT] }],
  ['schedule a new adapter as the curator, after the arm', tx(VAULT, submit(addAdapter(EMPTY))), true, { own: VAULT, sent: [CREATE, DEPOSIT, ARM] }],
  ['withdraw an earlier visit\'s deposit before the run', tx(VAULT, call('redeem(uint256,address,address)', ['uint256', 'address', 'address'], [100n, ME, ME])), true, { own: VAULT }],
  ['turn the walk address\'s own active watch off before the run', tx(C.exit, call('cancel(uint256)', ['uint256'], [9n])), true, { own: VAULT }],
  ['timelock walk: a shorter waiting period for addAdapter', tx(VAULT, submit(shorter(sel('addAdapter(address)'), 60n))), true, { own: VAULT, kind: 'timelock', sent: [ARM] }],
  ['timelock walk: the shortest and the longest the page asks for', tx(VAULT, submit(shorter(sel('increaseRelativeCap(bytes,uint256)'), 179n))), true, { own: VAULT, kind: 'timelock', sent: [ARM] }],
  ['allocator walk: a new allocator', tx(VAULT, submit(setAllocator(EMPTY, true))), true, { own: VAULT, kind: 'allocator', sent: [ARM] }],
  ['cap walk: the demo cap increase', tx(VAULT, submit(capUp(ID32, 1000000000000n))), true, { own: VAULT, kind: 'cap', sent: [ARM] }],
  ['timelock walk: the watch with its kinds', arm(VAULT, 6n, 0n), true, { own: VAULT, kind: 'timelock' }],
  ['mode 1 walk: the watch with its mode', arm(VAULT, 7n, 1n), true, { own: VAULT, mode: 1 }],

  /* the walk's one vault: arguments */
  ['deposit for another receiver', deposit(VAULT, OTHER), false, { own: VAULT }],
  ['vault mint (the page never sends it)', tx(VAULT, call('mint(uint256,address)', ['uint256', 'address'], [100n, ME])), false, { own: VAULT }],
  ['vault withdraw (the page never sends it)', tx(VAULT, call('withdraw(uint256,address,address)', ['uint256', 'address', 'address'], [100n, ME, ME])), false, { own: VAULT }],
  ['redeem to another address', tx(VAULT, call('redeem(uint256,address,address)', ['uint256', 'address', 'address'], [100n, OTHER, ME])), false, { own: VAULT }],
  ['redeem from another owner', tx(VAULT, call('redeem(uint256,address,address)', ['uint256', 'address', 'address'], [100n, ME, OTHER])), false, { own: VAULT }],
  ['vault approve for a spender other than the exit contract', tx(VAULT, call('approve(address,uint256)', ['address', 'uint256'], [OTHER, 100n])), false, { own: VAULT }],
  ['arm with other kinds', arm(VAULT, 15n, 0n), false, { own: VAULT }],
  ['arm with the other mode', arm(VAULT, 7n, 1n), false, { own: VAULT }],
  ['cancel of a watch that is not the walk address\'s active one', tx(C.exit, call('cancel(uint256)', ['uint256'], [8n])), false, { own: VAULT }],
  ['cancel when the walk address has no active watch', tx(C.exit, call('cancel(uint256)', ['uint256'], [0n])), false, { own: VAULT, chain: { watch: 0n } }],

  /* one vault per walk: another vault the maker lists is no target */
  ['deposit into another vault the maker lists', deposit(VAULT2, ME), false, { own: VAULT, sent: [CREATE] }],
  ['token approve for another vault the maker lists', tx(C.token, call('approve(address,uint256)', ['address', 'uint256'], [VAULT2, 1n])), false, { own: VAULT }],
  ['arm on another vault the maker lists', arm(VAULT2, 7n, 0n), false, { own: VAULT }],
  ['submit on another vault the maker lists', tx(VAULT2, submit(addAdapter(EMPTY))), false, { own: VAULT, sent: [ARM] }],
  ['redeem on another vault the maker lists', tx(VAULT2, call('redeem(uint256,address,address)', ['uint256', 'address', 'address'], [100n, ME, ME])), false, { own: VAULT }],

  /* one of each, in the page's order */
  ['a second create()', tx(C.maker, sel(CREATE)), false, { own: VAULT, sent: [CREATE] }],
  ['a second deposit', deposit(VAULT, ME), false, { own: VAULT, sent: [CREATE, DEPOSIT] }],
  ['a second arm (after arm and cancel)', arm(VAULT, 7n, 0n), false, { own: VAULT, sent: [DEPOSIT, ARM] }],
  ['a second submit', tx(VAULT, submit(addAdapter(EMPTY))), false, { own: VAULT, sent: [DEPOSIT, ARM, SUBMIT] }],
  ['a submit before the watch is on', tx(VAULT, submit(addAdapter(EMPTY))), false, { own: VAULT, sent: [CREATE, DEPOSIT] }],
  ['a cancel after the arm', tx(C.exit, call('cancel(uint256)', ['uint256'], [9n])), false, { own: VAULT, sent: [DEPOSIT, ARM] }],
  ['a redeem after the walk\'s own create()', tx(VAULT, call('redeem(uint256,address,address)', ['uint256', 'address', 'address'], [100n, ME, ME])), false, { own: VAULT, sent: [CREATE] }],
  ['a cancel after the walk\'s own deposit', tx(C.exit, call('cancel(uint256)', ['uint256'], [9n])), false, { own: VAULT, sent: [DEPOSIT] }],
  ['a create() after the arm', tx(C.maker, sel(CREATE)), false, { own: VAULT, sent: [DEPOSIT, ARM] }],
  ['a create() after the walk\'s deposit', tx(C.maker, sel(CREATE)), false, { own: VAULT, sent: [DEPOSIT] }],
  ['a demo dollar mint after the arm', tx(C.token, call('mint(address,uint256)', ['address', 'uint256'], [ME, 1n])), false, { own: VAULT, sent: [DEPOSIT, ARM] }],
  ['a vault approve after the arm', tx(VAULT, call('approve(address,uint256)', ['address', 'uint256'], [C.exit, 0n])), false, { own: VAULT, sent: [DEPOSIT, ARM] }],
  ['a 13th transaction', tx(C.token, call('mint(address,uint256)', ['address', 'uint256'], [ME, 1n])), false, { own: VAULT, sent: Array(12).fill('mint(address,uint256)') }],

  /* the curator's change: the one call of the chosen kind, exactly encoded, with the page's arguments */
  ['a submit of another kind', tx(VAULT, submit(setAllocator(EMPTY, true))), false, { own: VAULT, sent: [ARM] }],
  ['a submit while someone else is the curator', tx(VAULT, submit(addAdapter(EMPTY))), false, { own: VAULT, sent: [ARM], chain: { curator: OTHER } }],
  ['a submit while one endpoint names someone else as the curator', tx(VAULT, submit(addAdapter(EMPTY))), false, { own: VAULT, sent: [ARM], chain: { lie: { host: publicnode, method: 'eth_call', selector: sel('curator()'), result: word(BigInt(OTHER)) } } }],
  ['a submit while the curator word has bits above the address', tx(VAULT, submit(addAdapter(EMPTY))), false, { own: VAULT, sent: [ARM], chain: { curatorWord: '0x' + 'ff'.repeat(12) + ME.slice(2) } }],
  ['a submit while the curator answer is longer than one word', tx(VAULT, submit(addAdapter(EMPTY))), false, { own: VAULT, sent: [ARM], chain: { curatorWord: word(BigInt(ME)) + '00'.repeat(32) } }],
  ['a new adapter with bytes after its argument', tx(VAULT, submit(addAdapter(EMPTY) + 'deadbeef')), false, { own: VAULT, sent: [ARM] }],
  ['a new adapter with 64 bytes after its argument', tx(VAULT, submit(addAdapter(EMPTY) + '00'.repeat(64))), false, { own: VAULT, sent: [ARM] }],
  ['a bare addAdapter selector', tx(VAULT, submit(sel('addAdapter(address)'))), false, { own: VAULT, sent: [ARM] }],
  ['a new adapter with dirty bits in its address', tx(VAULT, submit(sel('addAdapter(address)') + 'ff'.repeat(12) + EMPTY.slice(2))), false, { own: VAULT, sent: [ARM] }],
  ['a new adapter that holds code', tx(VAULT, submit(addAdapter(CODE))), false, { own: VAULT, sent: [ARM] }],
  ['allocator walk: an allocator taken away', tx(VAULT, submit(setAllocator(EMPTY, false))), false, { own: VAULT, kind: 'allocator', sent: [ARM] }],
  ['allocator walk: an allocator that holds code', tx(VAULT, submit(setAllocator(CODE, true))), false, { own: VAULT, kind: 'allocator', sent: [ARM] }],
  ['timelock walk: a waiting period of zero', tx(VAULT, submit(shorter(sel('addAdapter(address)'), 0n))), false, { own: VAULT, kind: 'timelock', sent: [ARM] }],
  ['timelock walk: a waiting period that is not shorter', tx(VAULT, submit(shorter(sel('addAdapter(address)'), 180n))), false, { own: VAULT, kind: 'timelock', sent: [ARM] }],
  ['timelock walk: an action that is not one of the four watched', tx(VAULT, submit(shorter('0x00000000', 60n))), false, { own: VAULT, kind: 'timelock', sent: [ARM] }],
  ['timelock walk: the timelock of decreaseTimelock itself', tx(VAULT, submit(shorter(sel('decreaseTimelock(bytes4,uint256)'), 60n))), false, { own: VAULT, kind: 'timelock', sent: [ARM] }],
  ['cap walk: a relative cap increase (the page never sends it)', tx(VAULT, submit(call('increaseRelativeCap(bytes,uint256)', ['bytes', 'uint256'], [ID32, 1n]))), false, { own: VAULT, kind: 'cap', sent: [ARM] }],
  ['cap walk: an id that is not 32 bytes', tx(VAULT, submit(capUp(EMPTY, 1000000000000n))), false, { own: VAULT, kind: 'cap', sent: [ARM] }],
  ['cap walk: a cap above the demo cap', tx(VAULT, submit(capUp(ID32, 1000000000001n))), false, { own: VAULT, kind: 'cap', sent: [ARM] }],

  /* every endpoint must give the same answer behind a yes */
  ['a vault one endpoint does not list', deposit(VAULT, ME), false, { own: VAULT, chain: { lie: { host: publicnode, method: 'eth_call', selector: sel('isVault(address)'), result: word(0) } } }],
  ['a vault only one endpoint lists', deposit(OTHER, ME), false, { own: OTHER, chain: { lie: { host: publicnode, method: 'eth_call', selector: sel('isVault(address)'), result: word(1) } } }],
  ['a vault read while one endpoint does not answer', deposit(VAULT, ME), false, { own: VAULT, chain: { down: publicnode } }],
  ['an adapter that holds code on one endpoint', tx(VAULT, submit(addAdapter(EMPTY))), false, { own: VAULT, sent: [ARM], chain: { lie: { host: publicnode, method: 'eth_getCode', result: '0x6000' } } }],
  ['an adapter that holds code on all but one endpoint', tx(VAULT, submit(addAdapter(CODE))), false, { own: VAULT, sent: [ARM], chain: { lie: { host: publicnode, method: 'eth_getCode', result: '0x' } } }],
  ['a watch id only one endpoint gives', tx(C.exit, call('cancel(uint256)', ['uint256'], [8n])), false, { own: VAULT, chain: { lie: { host: publicnode, method: 'eth_call', selector: sel('activeWatchOf(address,address)'), result: word(8) } } }],
  ['timelock walk: a longer TIMELOCK() on one endpoint', tx(VAULT, submit(shorter(sel('addAdapter(address)'), 200n))), false, { own: VAULT, kind: 'timelock', sent: [ARM], chain: { lie: { host: publicnode, method: 'eth_call', selector: sel('TIMELOCK()'), result: word(100000) } } }],
];

let bad = 0;
const note = (ok, text) => { if (!ok) bad += 1; console.log(`${ok ? 'ok  ' : 'FAIL'} ${text}`); };

if (endpoints.length < 2 || !endpoints.some((u) => u.includes(publicnode))) note(false, `the signer asks ${endpoints.length} endpoint(s); the cases above play a second one`);

let read = 0;
for (const [name, t, want, o = {}] of cases) {
  const { policy } = policyFor({ kind: o.kind || 'adapter', mode: o.mode || 0 }, '2026-11-22', ME, o.own || null);
  chain = { ...START(), ...(o.chain || {}) };
  record.sent.length = 0;
  (o.sent || []).forEach((sig) => record.sent.push({ sig, hash: '0x' + '0'.repeat(64), status: '1' }));
  const before = asked;
  const p = await policy(t);
  if (asked > before) read += 1;
  note(p.ok === want, `${want ? 'signs  ' : 'refuses'} ${name}${p.ok ? '' : `: ${p.why}`}`);
}
record.sent.length = 0;
chain = START();
note(read > 20, `${read} cases read the chain through the replaced fetch`);

/* the address a live walk may be given */
const urls = [
  ['https://bongbongcrypto.github.io/notice-period/', true],
  ['https://bongbongcrypto.github.io/notice-period/index.html', true],
  ['https://bongbongcrypto.github.io/notice-period/../other-site/', false],
  ['https://bongbongcrypto.github.io/notice-period/a/../../other-site/', false],
  ['https://bongbongcrypto.github.io/notice-period/./', false],
  ['https://bongbongcrypto.github.io/notice-period/..', false],
  ['https://bongbongcrypto.github.io/notice-period/.', false],
  ['https://bongbongcrypto.github.io/other-site/', false],
  ['https://bongbongcrypto.github.io/notice-period', false],
  ['http://bongbongcrypto.github.io/notice-period/', false],
  ['https://bongbongcrypto.github.io.example.org/notice-period/', false],
  ['https://bongbongcrypto.github.io/notice-period/?x=1', false],
];
for (const [u, want] of urls) note(isLiveUrl(u) === want, `${want ? 'walks  ' : 'refuses'} ${u}`);

/* what the page says about itself is kept as plain strings, whatever it returns */
const odd = { toString: null, valueOf: null };
const snap = cleanSnap({ state: 'page-error', cls: odd, head: odd, text: odd, acts: [{ a: 'retry', off: false }, { a: odd, off: odd }, null, 'x'] });
note(snap && snap.state === 'page-error' && snap.head === '' && snap.text === '' && snap.cls === '' && snap.acts.length === 1 && snap.acts[0].a === 'retry',
  'a page snapshot with values that cannot be turned into strings is kept as plain strings');
note(cleanSnap({ state: odd }) === null && cleanSnap(null) === null && cleanSnap('x') === null, 'a page snapshot without a state id of its own is no snapshot');

/* a transaction hash in what cast printed: the named one first, never part of longer hex */
const h1 = '0x' + 'a'.repeat(64);
const h2 = '0x' + 'b'.repeat(64);
const found = hashesIn(`error: receipt wait failed\n{"blockHash":"${h2}","transactionHash":"${h1}"}\ninput 0x${'c'.repeat(136)}`);
note(found.length === 2 && found[0] === h1 && found[1] === h2, 'transaction hashes are found in what cast printed');

const methods = [
  ['personal_sign', [], 4001],
  ['eth_signTypedData_v4', [], 4001],
  ['eth_sendRawTransaction', [], 4001],
  ['wallet_switchEthereumChain', [{ chainId: '0x1' }], 4001],
  ['wallet_watchAsset', [], 4200],
  ['wallet_switchEthereumChain', [{ chainId: '0x14a34' }], 0],
  ['eth_chainId', [], 0],
];
for (const [m, params, code] of methods) {
  const a = await walletRequest(m, params);
  const got = a.ok ? 0 : a.error.code;
  note(got === code, `${m} ${JSON.stringify(params)} answered ${got || 'ok'}`);
}
if (!record.failure) { bad += 1; console.log('FAIL a refused wallet method did not fail the walk'); }

/* ---------- the vault of the walk's own create(), only as every endpoint gives it ---------- */

const hx = (n) => '0x' + BigInt(n).toString(16);
const addrTopic = (a) => '0x' + '0'.repeat(24) + low(a).slice(2);
const H_CREATE = '0x' + 'c1'.repeat(32);
const H_MINT = '0x' + 'd1'.repeat(32);
const H_ARM = '0x' + 'e1'.repeat(32);
const created = (vault, extra = {}) => ({ status: '0x1', blockHash: '0x' + 'bb'.repeat(32), blockNumber: hx(100), transactionHash: H_CREATE, from: ME, to: low(C.maker),
  logs: [{ address: low(C.maker), topics: [topic('VaultCreated(address,address)'), addrTopic(vault), addrTopic(ME)], data: '0x' }], ...extra });
const createCases = [
  ['the create receipt alike on every endpoint and lastVaultOf the same vault', {}, VAULT],
  ['the create receipt that one endpoint gives with another vault', { lie: { host: publicnode, method: 'eth_getTransactionReceipt', result: created(VAULT2) } }, null],
  ['the create receipt that one endpoint does not give', { lie: { host: publicnode, method: 'eth_getTransactionReceipt', result: null } }, null],
  ['a create whose vault is not the maker\'s lastVaultOf', { lastVault: VAULT2 }, null],
  ['a create whose vault one endpoint does not give as lastVaultOf', { lie: { host: publicnode, method: 'eth_call', selector: sel('lastVaultOf(address)'), result: word(BigInt(VAULT2)) } }, null],
  ['a create receipt with status 0', { receipts: { [H_CREATE]: created(VAULT, { status: '0x0' }) } }, null],
  ['a create receipt sent by another address', { receipts: { [H_CREATE]: created(VAULT, { from: OTHER }) } }, null],
  ['a create receipt to another contract', { receipts: { [H_CREATE]: created(VAULT, { to: OTHER }) } }, null],
  ['a create receipt with two VaultCreated logs for the walk address', { receipts: { [H_CREATE]: { ...created(VAULT), logs: [...created(VAULT).logs, ...created(VAULT2).logs] } } }, null],
  ['a create receipt whose vault topic has bits above the address', { receipts: { [H_CREATE]: { ...created(VAULT), logs: [{ ...created(VAULT).logs[0], topics: [topic('VaultCreated(address,address)'), '0x' + 'ff'.repeat(12) + VAULT.slice(2), addrTopic(ME)] }] } } }, null],
];
for (const [name, ch, want] of createCases) {
  const t = policyFor({ kind: 'adapter', mode: 0 }, '2026-11-22', ME, VAULT2);
  chain = { ...START(), receipts: { [H_CREATE]: created(VAULT) }, ...ch };
  const r = await t.createdVault(H_CREATE);
  note(want ? low(r.vault || '') === low(want) : !r.vault && typeof r.why === 'string', `${want ? 'takes  ' : 'refuses'} ${name}${r.why ? `: ${r.why}` : ''}`);
}

/* ---------- the signing path: nonce, stop checks, read-back, running record (cast replaced, nothing started) ---------- */

const PLACEHOLDER = 'placeholder-not-a-key';
const mintTx = tx(C.token, call('mint(address,uint256)', ['address', 'uint256'], [ME, 100000000n]));
const minedAs = (t, nonce, hash) => ({ hash, input: low(t.data), to: low(t.to), from: ME, value: '0x0', chainId: '0x14a34', nonce: hx(nonce) });
const castOk = (hash, logs = []) => ({ code: 0, out: JSON.stringify({ transactionHash: hash, status: '0x1', blockNumber: hx(100), logs }), err: '' });
const out = mkdtempSync(join(tmpdir(), 'np-walk-test-'));
const logged = [];
const realLog = console.log;

/* runs one send with cast replaced; returns what happened */
async function send(name, t, { own = null, ch = {}, mined = [], castReply, before } = {}) {
  const calls = [];
  const seen = { logBeforeCast: false, running: null };
  const s = signerFor({ kind: 'adapter', mode: 0 }, '2026-11-22', ME, own, { key: PLACEHOLDER, out, cast: (argv) => {
    calls.push(argv);
    seen.logBeforeCast = logged.some((l) => /signing /.test(l) && l.includes(`nonce ${argv[argv.indexOf('--nonce') + 1]}`));
    try { seen.running = readFileSync(join(out, 'result.json'), 'utf8'); } catch (e) { seen.running = null; }
    return castReply ? castReply(argv) : castOk(H_MINT);
  } });
  rmSync(join(out, 'result.json'), { force: true });
  chain = { ...START(), txs: { [H_MINT]: minedAs(t, 6, H_MINT) }, ...ch };
  mined.forEach((m) => s.record.sent.push(m));
  if (before) before(s);
  logged.length = 0;
  console.log = (...a) => { logged.push(a.join(' ')); realLog(...a); };
  let ans;
  /* an exception of the signer is a result too (a failed check below), never the end of this test */
  try { ans = await s.sendTransaction(t); } catch (e) { ans = { ok: false, threw: String(e && e.message) }; } finally { console.log = realLog; }
  let after = null;
  try { after = JSON.parse(readFileSync(join(out, 'result.json'), 'utf8')); } catch (e) { after = null; }
  return { ans, calls, seen, after, failure: s.record.failure, refused: s.record.refused.slice(), own: s.ownVault(), sent: s.record.sent.slice() };
}

let r = await send('stop', mintTx, { ch: { nonce: () => { record.stopped = true; return 6; } } });
note(!r.ans.ok && r.calls.length === 0 && r.sent.length === 0, `refuses a send when the walk stops during the nonce read (cast started ${r.calls.length} times)`);
r = await send('fail', mintTx, { ch: { nonce: () => { record.failure = 'a console error meanwhile'; return 6; } } });
note(!r.ans.ok && r.calls.length === 0, `refuses a send when the walk fails during the nonce read (cast started ${r.calls.length} times)`);
r = await send('no nonce', mintTx, { ch: { nonce: null } });
note(!r.ans.ok && r.calls.length === 0 && /nonce/.test(r.failure || '') && r.refused.length === 1, `refuses a send when the next nonce cannot be read: ${r.failure}`);
const minedAt = (n) => ({ sig: 'mint(address,uint256)', hash: '0x' + 'f1'.repeat(32), status: '0x1', nonce: n });
r = await send('lag', mintTx, { mined: [minedAt(6)], ch: { nonce: 6 } });
note(!r.ans.ok && r.calls.length === 0 && /not past 6/.test(r.failure || ''), `refuses a send while the next nonce is not past the last mined send's: ${r.failure}`);
{
  /* an endpoint that catches up within the wait: the first read is the used nonce, the next one is past it */
  let reads = 0;
  r = await send('catch up', mintTx, { mined: [minedAt(6)], ch: { nonce: () => (reads++ < 1 ? 6 : 7), txs: { [H_MINT]: minedAs(mintTx, 7, H_MINT) } },
    before: (t) => { t.waits.nonce = 2500; } });
  const a7 = r.calls[0] || [];
  note(r.ans.ok && !r.failure && a7[a7.indexOf('--nonce') + 1] === '7' && reads >= 2, `waits for the next nonce to pass the last mined send's, then signs at it (--nonce ${a7[a7.indexOf('--nonce') + 1]}, ${reads} reads)`);
}
r = await send('ok', mintTx, { mined: [minedAt(5)], ch: { nonce: 6 } });
const argv = r.calls[0] || [];
const at = argv.indexOf('--nonce');
note(r.ans.ok && !r.failure && r.calls.length === 1 && at > 0 && argv[at + 1] === '6' && at < argv.indexOf(low(C.token)) && argv[argv.indexOf('--private-key') + 1] === PLACEHOLDER,
  `signs at the nonce read, given to cast before the target (--nonce ${argv[at + 1]})`);
note(r.seen.logBeforeCast, 'the intent (call, target, nonce) is printed before cast starts');
let running = null;
try { running = JSON.parse(r.seen.running); } catch (e) { running = null; }
note(running && running.result === 'running' && running.inFlight && running.inFlight.sig === 'mint(address,uint256)' && running.inFlight.nonce === 6 && !r.seen.running.includes(PLACEHOLDER),
  'a running result with the send in flight (and never the key) is written before cast starts');
note(r.after && r.after.result === 'running' && r.after.inFlight === null && r.after.sent.length === 2 && r.after.sent[1].hash === H_MINT && r.after.sent[1].nonce === 6,
  'the running result after the send holds it, with its hash and nonce');
r = await send('nonce differs', mintTx, { ch: { nonce: 6, txs: { [H_MINT]: minedAs(mintTx, 7, H_MINT) } } });
note(r.calls.length === 1 && /nonce 0x7, not 6/.test(r.failure || ''), `fails the walk when the mined transaction has another nonce than the one given to cast: ${r.failure}`);

/* the create(): the vault comes from the receipt every endpoint gives and lastVaultOf, never from what cast printed */
const createTx = tx(C.maker, sel(CREATE));
const castSays = (vault) => () => castOk(H_CREATE, created(vault).logs);
const createRun = (ch) => send('create', createTx, { own: VAULT2, castReply: castSays(OTHER), ch: { receipts: { [H_CREATE]: created(VAULT) }, txs: { [H_CREATE]: minedAs(createTx, 6, H_CREATE) }, ...ch } });
r = await createRun({});
note(r.ans.ok && !r.failure && low(r.own || '') === low(VAULT), `a create() sets the vault every endpoint gives, not the one cast printed (own ${r.own})`);
r = await createRun({ lie: { host: publicnode, method: 'eth_getTransactionReceipt', result: created(VAULT2) } });
note(r.own === null && /could not be established/.test(r.failure || ''), `a create() whose receipt the endpoints do not give alike leaves no vault and fails the walk: ${r.failure}`);
r = await createRun({ lastVault: VAULT2 });
note(r.own === null && /could not be established/.test(r.failure || ''), `a create() whose vault is not lastVaultOf leaves no vault and fails the walk: ${r.failure}`);

/* the hash cast printed is the send only when every endpoint gives it as this call at the nonce cast was given: the
   sending endpoint alone can hand cast the hash of another transaction */
const sendHost = new URL(endpoints[0]).host;
if (sendHost.includes(publicnode) || !endpoints.slice(1).some((u) => u.includes(publicnode))) note(false, `the sending endpoint ${sendHost} must be another one than the publicnode endpoint for the cases below`);
const H_OLD = '0x' + 'a0'.repeat(32);
const H_ONLY = '0x' + 'ff'.repeat(32);
const lastOf = (x) => x.sent[x.sent.length - 1] || {};
r = await createRun({});
note(lastOf(r).hashConfirmed === true, 'a create() every endpoint gives at the nonce cast was given is recorded with hashConfirmed true');
r = await send('earlier create', createTx, { own: VAULT2, castReply: () => castOk(H_OLD, created(VAULT2).logs), ch: { lastVault: VAULT2,
  receipts: { [H_OLD]: created(VAULT2, { transactionHash: H_OLD }) }, txs: { [H_OLD]: minedAs(createTx, 2, H_OLD) },
  lie: { host: sendHost, method: 'eth_getTransactionByHash', result: minedAs(createTx, 6, H_OLD) } } });
note(r.own === null && !!r.failure && lastOf(r).hashConfirmed === false && lastOf(r).hash === H_OLD,
  `a create() whose printed hash is an earlier create (only the sending endpoint gives it the nonce cast was given) leaves no vault and fails the walk (own ${r.own}): ${r.failure}`);
r = await send('hash only the sender knows', mintTx, { castReply: () => castOk(H_ONLY), ch: { lie: { host: sendHost, method: 'eth_getTransactionByHash', result: minedAs(mintTx, 6, H_ONLY) } } });
note(/alike from every endpoint/.test(r.failure || '') && lastOf(r).hashConfirmed === false, `a send whose printed hash only the sending endpoint knows fails the walk: ${r.failure}`);

/* the nonce given to cast is at least every endpoint's 'latest' count: a sending endpoint that names the nonce of the
   walk address's earlier create() would otherwise get that create's hash confirmed by every endpoint as this one */
{
  const H_OLD2 = '0x' + 'a2'.repeat(32);
  r = await send('stale nonce', createTx, { own: VAULT2, castReply: () => castOk(H_OLD2, created(VAULT2).logs), ch: { nonce: (u) => (new URL(u).host === sendHost ? 2 : 6),
    lastVault: VAULT2, receipts: { [H_OLD2]: created(VAULT2, { transactionHash: H_OLD2 }) }, txs: { [H_OLD2]: minedAs(createTx, 2, H_OLD2) } } });
  const given = r.calls.length ? r.calls[0][r.calls[0].indexOf('--nonce') + 1] : null;
  note((given === '6' && r.own === null && !!r.failure && lastOf(r).hashConfirmed !== true) || (r.calls.length === 0 && !!r.failure && r.refused.length === 1),
    `the sending endpoint names nonce 2 while another endpoint's latest count is 6: cast gets --nonce ${given}, never 2, and the earlier create's vault is not taken (own ${r.own}): ${r.failure}`);
}
r = await send('no count', mintTx, { ch: { nonce: (u) => (u.includes(publicnode) ? null : 6) } });
note(!r.ans.ok && r.calls.length === 0 && r.refused.length === 1 && /every Base Sepolia endpoint/.test(r.failure || ''),
  `refuses a send when one endpoint gives no transaction count (cast started ${r.calls.length} times): ${r.failure}`);

/* a send cast did not report: a printed hash is that request only as every endpoint gives it, at its nonce */
async function closeRun(ch, after = {}) {
  const s = signerFor({ kind: 'adapter', mode: 0 }, '2026-11-22', ME, null, { key: PLACEHOLDER, out,
    cast: () => ({ code: 1, out: '', err: `Error: transaction ${H_ONLY} was not mined in time` }) });
  chain = { ...START(), ...ch };
  const realLog2 = console.log;
  console.log = () => {};
  let n = null;
  try {
    await s.sendTransaction(mintTx);
    Object.assign(chain, after);
    s.record.nonceStart = 6;
    n = await s.closeSends();
  } finally { console.log = realLog2; }
  return { entry: lastOf(s.record), n, failure: s.record.failure };
}
let c = await closeRun({ lie: { host: sendHost, method: 'eth_getTransactionByHash', result: minedAs(mintTx, 6, H_ONLY) } }, { nonce: 7 });
note(c.entry.status === 'unknown' && c.entry.hash === null && !/^yes: the transaction cast printed/.test(c.entry.broadcast || '') && (c.entry.hashesUnconfirmed || []).includes(H_ONLY),
  `a printed hash only the sending endpoint gives is not taken as the request (broadcast ${c.entry.broadcast})`);
c = await closeRun({ txs: { [H_ONLY]: minedAs(mintTx, 5, H_ONLY) }, receipts: { [H_ONLY]: { status: '0x1', transactionHash: H_ONLY, from: ME, to: low(C.token), logs: [] } } }, { nonce: 7 });
note(c.entry.hash === null && !/^yes: the transaction cast printed/.test(c.entry.broadcast || ''), `a printed hash of the same call at another nonce is not taken as the request (broadcast ${c.entry.broadcast})`);
c = await closeRun({ txs: { [H_ONLY]: minedAs(mintTx, 6, H_ONLY) }, receipts: { [H_ONLY]: { status: '0x1', transactionHash: H_ONLY, from: ME, to: low(C.token), logs: [] } } }, { nonce: 7 });
note(c.entry.hash === H_ONLY && /^yes: the transaction cast printed/.test(c.entry.broadcast || '') && c.entry.receiptStatus === '0x1',
  `a printed hash every endpoint gives as the request at its nonce is taken (broadcast ${c.entry.broadcast}, receipt ${c.entry.receiptStatus})`);
rmSync(out, { recursive: true, force: true });

/* ---------- what is read from the chain and the page around the signing ---------- */

/* the balances before the change: at a block not below the arm's, as every endpoint gives it */
const armRc = (block) => ({ status: '0x1', blockHash: '0x' + 'aa'.repeat(32), blockNumber: hx(block), transactionHash: H_ARM, from: ME, to: low(C.exit), logs: [] });
const baseline = async (ch, sent = [{ sig: ARM, hash: H_ARM, status: '0x1', nonce: 9 }]) => {
  const t = policyFor({ kind: 'adapter', mode: 0 }, '2026-11-22', ME, VAULT);
  chain = { ...START(), receipts: { [H_ARM]: armRc(100) }, ...ch };
  record.sent.length = 0;
  sent.forEach((x) => record.sent.push(x));
  const b = await t.armBaseline(VAULT);
  record.sent.length = 0;
  return b;
};
let b = await baseline({ head: 100 });
note(!b.why && b.block === 100 && b.armBlock === 100 && b.token === 5n && b.shares === 7n, `reads the baseline at a block not below the arm's (block ${b.block}, arm ${b.armBlock})`);
{
  /* an endpoint that reaches the arm's block within the wait */
  let heads = 0;
  const t = policyFor({ kind: 'adapter', mode: 0 }, '2026-11-22', ME, VAULT);
  t.waits.baseline = 2500;
  chain = { ...START(), receipts: { [H_ARM]: armRc(100) }, head: (u) => (u.includes(publicnode) && heads++ < 1 ? 99 : 100) };
  record.sent.length = 0;
  record.sent.push({ sig: ARM, hash: H_ARM, status: '0x1', nonce: 9 });
  b = await t.armBaseline(VAULT);
  record.sent.length = 0;
  t.waits.baseline = 0;
  note(!b.why && b.block === 100 && heads >= 2, `waits for every endpoint to reach the arm's block (block ${b.block}, ${heads} reads of the lagging one)`);
}
b = await baseline({ head: 100, lie: { host: publicnode, method: 'eth_blockNumber', result: hx(99) } });
note(!!b.why, `no baseline while an endpoint is below the arm's block: ${b.why}`);
b = await baseline({ head: 100, lie: { host: publicnode, method: 'eth_getTransactionReceipt', result: armRc(98) } });
note(!!b.why, `no baseline when the arm's receipt is not alike on every endpoint: ${b.why}`);
b = await baseline({ head: 100 }, []);
note(!!b.why, `no baseline without a mined arm in the record: ${b.why}`);

/* the kind boxes of the watch step */
const box = (bit) => ({ bit, checked: false, disabled: false });
/* [name, list, the reason expected (null: none)] */
const boxCases = [
  ['the page\'s four kind boxes', [1, 2, 4, 8].map(box), null],
  ['nine kind boxes', Array(9).fill(0).map((_, i) => box([1, 2, 4, 8][i % 4])), /more than 8/],
  ['a kind box of bit 16', [box(1), box(16)], /bit 16/],
  ['a kind box of bit 3', [box(1), box(3)], /bit 3/],
  ['a kind box that is not a number', [box(1), box(NaN)], /not 1, 2, 4 or 8/],
  ['two kind boxes of bit 1', [box(1), box(1)], /two kind boxes/],
  ['no list at all', null, /could not be read/],
];
for (const [name, list, want] of boxCases) {
  const why = boxProblem(list);
  note(want === null ? why === null : want.test(why || ''), `${want ? 'refuses' : 'sets   '} ${name}${why ? `: ${why}` : ''}`);
}

/* the word for a send cast did not report, from the nonce after the walk */
note(/^inconclusive: the nonce did not move/.test(broadcastOf(6, 6)) && /^yes/.test(broadcastOf(6, 7)) && /^not known/.test(broadcastOf(null, 7)) && /^not known/.test(broadcastOf(6, -1)),
  'a nonce that did not move leaves the broadcast inconclusive, never "no"');

/* the transaction as mined against the request */
const p0 = { data: low(mintTx.data), to: low(C.token) };
const m0 = minedAs(mintTx, 6, H_MINT);
note(minedDiffers(m0, p0, 6) === null && /nonce/.test(minedDiffers(m0, p0, 5) || '') && /chain/.test(minedDiffers({ ...m0, chainId: '0x1' }, p0, 6) || '') &&
  /differs/.test(minedDiffers({ ...m0, value: '0x1' }, p0, 6) || '') && /differs/.test(minedDiffers({ ...m0, value: undefined }, p0, 6) || '') && /read back/.test(minedDiffers(null, p0, 6) || ''),
  'the transaction as mined must be the request, on Base Sepolia, at the nonce given to cast');

console.log(bad ? `${bad} signer checks failed` : `signer checks passed (${cases.length} transactions, ${urls.length} addresses, ${methods.length} wallet methods, ${createCases.length} create receipts, ${boxCases.length} box lists, the signing path)`);
process.exit(bad ? 1 : 0);
