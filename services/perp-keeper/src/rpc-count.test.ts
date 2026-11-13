import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RpcCounter, rpcMethods } from './rpc-count.js';

function fakeFetch(status: number, seen: string[]): typeof fetch {
  return async (_input, init) => {
    seen.push(String(init?.body ?? ''));
    return new Response('{}', { status });
  };
}

test('counts calls by host, method and status, and never logs the key in the path', async () => {
  const seen: string[] = [];
  let status = 200;
  const counter = new RpcCounter();
  const counted = counter.wrap((input, init) => fakeFetch(status, seen)(input, init));
  const call = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [] });
  await counted('https://base-mainnet.g.alchemy.com/v2/secret-key', { method: 'POST', body: call });
  await counted('https://base-mainnet.g.alchemy.com/v2/secret-key', {
    method: 'POST',
    body: JSON.stringify([
      { jsonrpc: '2.0', id: 1, method: 'eth_blockNumber' },
      { jsonrpc: '2.0', id: 2, method: 'eth_call' },
    ]),
  });
  status = 429;
  await counted(new URL('https://mainnet.base.org'), { method: 'POST', body: call });

  assert.equal(seen[0], call, 'the body reaches the RPC untouched');
  const [alchemy, publicNode, ...rest] = counter.drain();
  assert.deepEqual(alchemy, {
    host: 'base-mainnet.g.alchemy.com',
    total: 3,
    by_method: 'eth_call:2,eth_blockNumber:1',
    by_status: '200:3',
  });
  assert.deepEqual(publicNode, { host: 'mainnet.base.org', total: 1, by_method: 'eth_call:1', by_status: '429:1' });
  assert.equal(rest.length, 0);
  assert.deepEqual(counter.drain(), [], 'a drain starts a new window');
});

test('a failed request counts as an error and still throws', async () => {
  const counter = new RpcCounter();
  const counted = counter.wrap(async () => {
    throw new Error('ECONNRESET');
  });
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_sendRawTransaction', params: ['0x'] });
  await assert.rejects(counted('https://mainnet.base.org', { method: 'POST', body }), /ECONNRESET/);
  assert.equal(counter.drain()[0]?.by_status, 'error:1');
});

test('traffic that is not JSON-RPC is not counted', async () => {
  const seen: string[] = [];
  const counter = new RpcCounter();
  const counted = counter.wrap(fakeFetch(200, seen));
  await counted('http://markets-service:8080/orders', { method: 'POST', body: '{"market":"cNGN-USDC"}' });
  await counted('http://markets-service:8080/markets');
  await counted('https://hooks.example/alert', { method: 'POST', body: 'plain text' });
  assert.deepEqual(counter.drain(), []);
  assert.deepEqual(rpcMethods('[{"jsonrpc":"2.0"}]'), []);
});
