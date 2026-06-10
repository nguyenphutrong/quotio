import {
  createClientKey,
  deleteClientKey,
  fetchClientKeys,
  updateClientKey,
} from './api';

function assert(condition: boolean, message: string) {
  if (!condition) {
    throw new Error(message);
  }
}

function assertJsonEqual(actual: unknown, expected: unknown, message: string) {
  const actualJson = JSON.stringify(actual);
  const expectedJson = JSON.stringify(expected);
  if (actualJson !== expectedJson) {
    throw new Error(`${message}: expected ${expectedJson}, got ${actualJson}`);
  }
}

const calls: Array<{ path: string; init?: RequestInit }> = [];

async function request<T>(path: string, init?: RequestInit) {
  calls.push({ path, init });
  return undefined as T;
}

await fetchClientKeys(request, {
  status: 'active',
  q: 'demo key',
  sort: 'name',
  order: 'asc',
});
await createClientKey(request, 'Demo Key');
await updateClientKey(request, 'key-1', { status: 'disabled' });
await deleteClientKey(request, 'key-1');

assert(
  calls[0]?.path ===
    '/client-keys?status=active&q=demo+key&sort=name&order=asc',
  'client keys query should preserve filters',
);

assert(calls[1]?.path === '/client-keys', 'create should use client keys path');
assert(calls[1]?.init?.method === 'POST', 'create should POST client key');
assertJsonEqual(
  JSON.parse(String(calls[1]?.init?.body)),
  { name: 'Demo Key' },
  'create should send key name',
);

assert(calls[2]?.path === '/client-keys/key-1', 'update should target key id');
assert(calls[2]?.init?.method === 'PATCH', 'update should PATCH client key');
assertJsonEqual(
  JSON.parse(String(calls[2]?.init?.body)),
  { status: 'disabled' },
  'update should send status payload',
);

assert(calls[3]?.path === '/client-keys/key-1', 'delete should target key id');
assert(calls[3]?.init?.method === 'DELETE', 'delete should DELETE client key');
