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

const cpaUnsupportedError = new Error(
  'Unsupported endpoint: requires cpa++ API support',
);

function createLegacyFallbackRequest() {
  const calls: Array<{ path: string; init?: RequestInit }> = [];
  const attemptedLegacy = new Set<string>();

  const fn = async <T>(path: string, init?: RequestInit) => {
    calls.push({ path, init });
    const method = init?.method ?? 'GET';
    const isClientKeysPath = path.startsWith('/client-keys');
    const isFallbackPath = path.startsWith('/api-keys');
    const key = `${method.toUpperCase()}:${path}`;
    if (isClientKeysPath && !isFallbackPath && !attemptedLegacy.has(key)) {
      attemptedLegacy.add(key);
      throw cpaUnsupportedError;
    }

    return undefined as T;
  };

  return { calls, request: fn };
}

const legacyRequest = createLegacyFallbackRequest();
await fetchClientKeys(legacyRequest.request, {
  status: 'active',
  q: '',
  sort: 'name',
  order: 'desc',
});
await createClientKey(legacyRequest.request, 'Migrated Key');
await updateClientKey(legacyRequest.request, 'legacy-key', {
  status: 'disabled',
});
await deleteClientKey(legacyRequest.request, 'legacy-key');

assert(
  legacyRequest.calls[0]?.path ===
    '/client-keys?status=active&sort=name&order=desc',
  'fallback should attempt legacy list path first',
);

assert(
  legacyRequest.calls[1]?.path ===
    '/api-keys?status=active&sort=name&order=desc',
  'fallback should retry list path with api-keys',
);

assert(
  legacyRequest.calls[2]?.path === '/client-keys',
  'fallback create attempt',
);
assert(legacyRequest.calls[3]?.path === '/api-keys', 'fallback create retry');
assert(
  legacyRequest.calls[4]?.path === '/client-keys/legacy-key',
  'fallback update attempt',
);
assert(
  legacyRequest.calls[5]?.path === '/api-keys/legacy-key',
  'fallback update retry',
);
assert(
  legacyRequest.calls[6]?.path === '/client-keys/legacy-key',
  'fallback delete attempt',
);
assert(
  legacyRequest.calls[7]?.path === '/api-keys/legacy-key',
  'fallback delete retry',
);
