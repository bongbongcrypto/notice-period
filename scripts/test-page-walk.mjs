#!/usr/bin/env node
/* The page walk's signer rules (scripts/page-walk.mjs policyFor), tested with no key, no browser and no network.
   Only requests whose answer needs no chain read are used: calls to the demo dollar, the vault maker and the exit
   contract of deployments/2026-11-22.json, and calls on or for vaults that are not this walk's own, which are refused
   before anything is read. Usage: node scripts/test-page-walk.mjs */

import { policyFor } from './page-walk.mjs';

const ME = '0x' + '1'.repeat(40);
const OTHER = '0x' + '2'.repeat(40);
const { policy, walletRequest, record, encodeArgs, sel } = policyFor({ kind: 'adapter', mode: 0 }, '2026-11-22', ME);

/* the contracts of the deployment file, never of the page */
const dep = JSON.parse((await import('node:fs')).readFileSync(new URL('../deployments/2026-11-22.json', import.meta.url), 'utf8'));
const C = dep.contracts;
const SMOKE = dep.smokeVault.address;

const call = (sig, types, values) => sel(sig) + encodeArgs(types, values);
const tx = (to, data, extra = {}) => ({ from: ME, to, data, ...extra });

const cases = [
  ['make a vault', tx(C.maker, sel('create()')), true],
  ['mint demo dollars to the walk address', tx(C.token, call('mint(address,uint256)', ['address', 'uint256'], [ME, 100000000n])), true],
  ['turn a watch off', tx(C.exit, call('cancel(uint256)', ['uint256'], [9n])), true],
  ['mint to another address', tx(C.token, call('mint(address,uint256)', ['address', 'uint256'], [OTHER, 1n])), false],
  ['token transfer', tx(C.token, call('transfer(address,uint256)', ['address', 'uint256'], [OTHER, 1n])), false],
  ['token approve for the smoke vault (not this walk\'s)', tx(C.token, call('approve(address,uint256)', ['address', 'uint256'], [SMOKE, 1n])), false],
  ['token approve for the exit contract', tx(C.token, call('approve(address,uint256)', ['address', 'uint256'], [C.exit, 1n])), false],
  ['arm on the smoke vault (not this walk\'s)', tx(C.exit, call('arm(address,uint8,uint8,uint256)', ['address', 'uint8', 'uint8', 'uint256'], [SMOKE, 7n, 0n, 1n])), false],
  ['deposit into the smoke vault (not this walk\'s)', tx(SMOKE, call('deposit(uint256,address)', ['uint256', 'address'], [1n, ME])), false],
  ['submit on a vault that is not this walk\'s', tx(SMOKE, call('submit(bytes)', ['bytes'], [call('addAdapter(address)', ['address'], [OTHER])])), false],
  ['a call to an address that is no contract of the deployment', tx(OTHER, sel('create()')), false],
  ['a maker call other than create', tx(C.maker, call('isVault(address)', ['address'], [SMOKE])), false],
  ['value attached', tx(C.maker, sel('create()'), { value: '0x1' }), false],
  ['from another address', { ...tx(C.maker, sel('create()')), from: OTHER }, false],
  ['another chain', tx(C.maker, sel('create()'), { chainId: '0x1' }), false],
  ['gas above the limit', tx(C.maker, sel('create()'), { gas: '0x7a1201' }), false],
  ['contract creation (no target)', { from: ME, data: sel('create()') }, false],
  ['bytes after the arguments', tx(C.maker, sel('create()') + '00'.repeat(32)), false],
  ['dirty bits in an address argument', tx(C.token, sel('mint(address,uint256)') + 'ff'.repeat(12) + ME.slice(2) + '0'.repeat(63) + '1'), false],
];

let bad = 0;
for (const [name, t, want] of cases) {
  const p = await policy(t);
  const ok = p.ok === want;
  if (!ok) bad += 1;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${want ? 'signs  ' : 'refuses'} ${name}${p.ok ? '' : `: ${p.why}`}`);
}

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
  const ok = got === code;
  if (!ok) bad += 1;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${m} ${JSON.stringify(params)} answered ${got || 'ok'}`);
}
if (!record.failure) { bad += 1; console.log('FAIL a refused wallet method did not fail the walk'); }

console.log(bad ? `${bad} signer checks failed` : `signer checks passed (${cases.length} transactions, ${methods.length} wallet methods)`);
process.exit(bad ? 1 : 0);
