#!/usr/bin/env node
/* The page's chain reads (docs/rpc.js), tested with no browser and no network: the file runs in a sandbox whose two
   Base Sepolia endpoints, "A" and "B", are played by this test. Checked: an endpoint that answers HTTP 200 with a
   JSON-RPC error in place of a result (a rate limit) sends the read to the next endpoint, for single calls, batches
   and log reads; a revert is the chain's answer and is returned at once, without asking another endpoint; when every
   endpoint refuses, the error is the page's "cannot reach" error, not an unexpected one.
   Usage: node scripts/test-rpc.mjs */

import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const src = readFileSync(new URL('../docs/rpc.js', import.meta.url), 'utf8');

function load(play) {
  const asked = [];
  const window = {
    NP: {
      config: {
        chains: {
          base: { name: 'Base Sepolia', endpoints: [{ url: 'A', maxRange: 50000 }, { url: 'B', maxRange: 100 }] },
          lasna: { name: 'Reactive Lasna', endpoints: [{ url: 'L', maxRange: 30000 }] }
        }
      }
    }
  };
  const ctx = vm.createContext({
    window, Promise, BigInt, Math, JSON, Error, Array, String, Number, Object,
    setTimeout: (f) => setImmediate(f), clearTimeout: () => {},
    performance: { now: () => 0 },
    fetch: () => { throw new Error('the test plays every endpoint: fetch must not be called'); },
    AbortController: class { abort() {} }
  });
  vm.runInContext(src, ctx, { filename: 'docs/rpc.js' });
  const rpc = window.NP.rpc;
  rpc.post = async (url, body) => {
    asked.push(url);
    return play(url, body);
  };
  return { rpc, asked };
}

const one = (body, o) => Object.assign({ jsonrpc: '2.0', id: body.id }, o);
const each = (body, f) => (Array.isArray(body) ? body.map((b) => one(b, f(b))) : one(body, f(body)));
const LIMIT = { code: -32005, message: 'rate limit exceeded' };
const REVERT = { code: 3, message: 'execution reverted', data: '0x08c379a0' };

let failed = 0;
let passed = 0;
async function check(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log('ok   ' + name);
  } catch (e) {
    failed += 1;
    console.log('FAIL ' + name + ': ' + (e && e.message));
  }
}
function same(a, b, what) {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(what + ': ' + JSON.stringify(a) + ' != ' + JSON.stringify(b));
}

await check('a rate-limit error from A sends a single call to B', async () => {
  const { rpc, asked } = load((url, body) => (url === 'A' ? one(body, { error: LIMIT }) : one(body, { result: '0x2a' })));
  same(await rpc.call('base', 'eth_blockNumber', []), '0x2a', 'result');
  same(asked, ['A', 'A', 'B'], 'endpoints asked');
});

await check('a revert is returned from A at once and B is not asked', async () => {
  const { rpc, asked } = load((url, body) => one(body, url === 'A' ? { error: REVERT } : { result: '0x' }));
  let err = null;
  try { await rpc.call('base', 'eth_call', [{ to: '0x1', data: '0x' }, 'latest']); } catch (e) { err = e; }
  if (!err || !err.rpcError) throw new Error('expected the revert as an RPC error, got ' + (err && err.message));
  same(err.data, '0x08c379a0', 'revert data');
  same(asked, ['A'], 'endpoints asked');
});

await check('a revert with code -32000 and the word "reverted" is an answer too', async () => {
  const { rpc, asked } = load((url, body) => one(body, url === 'A' ? { error: { code: -32000, message: 'execution reverted: no' } } : { result: '0x' }));
  const r = await rpc.simulate('base', '0x9', '0x1', '0x');
  same(r.ok, false, 'simulate ok');
  same(asked, ['A'], 'endpoints asked');
});

await check('simulate reads the revert data of a code-3 error', async () => {
  const { rpc } = load((url, body) => one(body, { error: REVERT }));
  const r = await rpc.simulate('base', '0x9', '0x1', '0x');
  same([r.ok, r.data], [false, '0x08c379a0'], 'simulate');
});

await check('a batch answered by one error object from A goes to B', async () => {
  const { rpc, asked } = load((url, body) => (url === 'A' ? { jsonrpc: '2.0', id: null, error: LIMIT } : each(body, () => ({ result: '0x1' }))));
  same(await rpc.batch('base', [['eth_blockNumber', []], ['eth_chainId', []]]), ['0x1', '0x1'], 'results');
  same(asked, ['A', 'A', 'B'], 'endpoints asked');
});

await check('a batch with one refused item from A goes to B', async () => {
  const { rpc, asked } = load((url, body) =>
    url === 'A' ? body.map((b, k) => one(b, k === 1 ? { error: LIMIT } : { result: '0x1' })) : each(body, () => ({ result: '0x2' })));
  same(await rpc.batch('base', [['eth_blockNumber', []], ['eth_chainId', []]]), ['0x2', '0x2'], 'results');
  same(asked, ['A', 'A', 'B'], 'endpoints asked');
});

await check('a batch item that reverts stays an item error, on A', async () => {
  const { rpc, asked } = load((url, body) => body.map((b, k) => one(b, k === 1 ? { error: REVERT } : { result: '0x1' })));
  const r = await rpc.batch('base', [['eth_blockNumber', []], ['eth_call', [{ to: '0x1', data: '0x' }, 'latest']]]);
  same(r[0], '0x1', 'first item');
  same(!!(r[1] && r[1].error), true, 'second item is an error');
  same(asked, ['A'], 'endpoints asked');
});

await check('when every endpoint refuses, the error is "cannot reach Base Sepolia"', async () => {
  const { rpc, asked } = load((url, body) => one(body, { error: LIMIT }));
  let err = null;
  try { await rpc.call('base', 'eth_blockNumber', []); } catch (e) { err = e; }
  if (!err || !err.rpcDown || err.chain !== 'base') throw new Error('expected rpcDown for base, got ' + (err && err.message));
  same(asked, ['A', 'A', 'B', 'B'], 'endpoints asked');
});

await check('a log read refused by A is asked of B in B\'s windows', async () => {
  const { rpc, asked } = load((url, body) => one(body, url === 'A' ? { error: LIMIT } : { result: [{ n: body.params[0].fromBlock }] }));
  const logs = await rpc.getLogs('base', { address: '0x1', topics: [] }, 0, 149);
  same(logs.length, 2, 'two windows of B');
  same(asked, ['A', 'A', 'B', 'B'], 'endpoints asked');
});

await check('a good answer from A is used and B is not asked', async () => {
  const { rpc, asked } = load((url, body) => one(body, { result: url === 'A' ? '0x1' : '0x2' }));
  same(await rpc.call('base', 'eth_blockNumber', []), '0x1', 'result');
  same(asked, ['A'], 'endpoints asked');
});

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
