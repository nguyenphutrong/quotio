import { fetchModelCatalog, setEnabledModels, syncProviderModels } from './api';

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

await fetchModelCatalog(request);
await setEnabledModels(request, 'anthropic', ['claude-sonnet-4-5']);
await setEnabledModels(request, 'openai', null);
await syncProviderModels(request, 'anthropic');

assert(calls[0]?.path === '/models/catalog', 'catalog should use models path');

assert(
  calls[1]?.path === '/providers/anthropic/enabled-models',
  'enabled models should target provider',
);
assert(calls[1]?.init?.method === 'PUT', 'enabled models should PUT');
assertJsonEqual(
  JSON.parse(String(calls[1]?.init?.body)),
  { models: ['claude-sonnet-4-5'] },
  'enabled models should send selected models',
);

assert(
  calls[2]?.path === '/providers/openai/enabled-models',
  'reset enabled models should target provider',
);
assertJsonEqual(
  JSON.parse(String(calls[2]?.init?.body)),
  { models: null },
  'reset enabled models should send null model list',
);

assert(
  calls[3]?.path === '/providers/anthropic/models/sync',
  'sync should target provider models sync',
);
assert(calls[3]?.init?.method === 'POST', 'sync should POST');
