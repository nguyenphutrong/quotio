import {
  addVirtualModelEntries,
  buildAvailableTargetsPath,
  createVirtualModel,
  deleteVirtualModel,
  deleteVirtualModelEntry,
  exportVirtualModels,
  fetchAvailableTargets,
  importVirtualModels,
  reorderVirtualModelEntries,
  setVirtualModelsEnabled,
  updateVirtualModel,
} from './api';
import type { RawVirtualModelExportPayload } from './types';

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

const exportPayload: RawVirtualModelExportPayload = {
  enabled: true,
  virtual_models: {
    balanced: {
      entries: [
        { ID: 'entry-1', Target: 'openai/gpt-4.1', Priority: 1 },
        { target: '', priority: 2 },
      ],
    },
  },
};

async function request<T>(path: string, init?: RequestInit) {
  calls.push({ path, init });
  return exportPayload as T;
}

assert(
  buildAvailableTargetsPath('model/id') ===
    '/virtual-models/available-targets?forModel=model%2Fid',
  'available targets path should encode model id',
);

await fetchAvailableTargets(request, 'balanced');
await setVirtualModelsEnabled(request, true);
await createVirtualModel(request, 'balanced');
await updateVirtualModel(request, 'balanced', { disabled: true });
await deleteVirtualModel(request, 'balanced');
await addVirtualModelEntries(request, 'balanced', ['anthropic/claude']);
await deleteVirtualModelEntry(request, 'balanced', 'entry-1');
await reorderVirtualModelEntries(request, 'balanced', ['entry-2', 'entry-1']);
const normalizedExport = await exportVirtualModels(request);
await importVirtualModels(request, exportPayload);

assert(
  calls[0]?.path === '/virtual-models/available-targets?forModel=balanced',
  'fetch available targets should use model query',
);

assert(calls[1]?.path === '/virtual-models', 'toggle should use state path');
assert(calls[1]?.init?.method === 'PATCH', 'toggle should PATCH state');
assertJsonEqual(
  JSON.parse(String(calls[1]?.init?.body)),
  { enabled: true },
  'toggle should send enabled flag',
);

assert(
  calls[2]?.path === '/virtual-models/models',
  'create should use models path',
);
assert(calls[2]?.init?.method === 'POST', 'create should POST model');
assertJsonEqual(
  JSON.parse(String(calls[2]?.init?.body)),
  { name: 'balanced' },
  'create should send model name',
);

assert(
  calls[3]?.path === '/virtual-models/models/balanced',
  'update should target model id',
);
assert(calls[3]?.init?.method === 'PATCH', 'update should PATCH model');
assertJsonEqual(
  JSON.parse(String(calls[3]?.init?.body)),
  { disabled: true },
  'update should send payload',
);

assert(
  calls[4]?.path === '/virtual-models/models/balanced',
  'delete should target model id',
);
assert(calls[4]?.init?.method === 'DELETE', 'delete should DELETE model');

assert(
  calls[5]?.path === '/virtual-models/models/balanced/entries',
  'add entries should target model entries',
);
assert(calls[5]?.init?.method === 'POST', 'add entries should POST');
assertJsonEqual(
  JSON.parse(String(calls[5]?.init?.body)),
  { targets: ['anthropic/claude'] },
  'add entries should send target list',
);

assert(
  calls[6]?.path === '/virtual-models/models/balanced/entries/entry-1',
  'delete entry should target entry id',
);
assert(calls[6]?.init?.method === 'DELETE', 'delete entry should DELETE');

assert(
  calls[7]?.path === '/virtual-models/models/balanced/entries/reorder',
  'reorder should target reorder path',
);
assert(calls[7]?.init?.method === 'POST', 'reorder should POST');
assertJsonEqual(
  JSON.parse(String(calls[7]?.init?.body)),
  { entryIds: ['entry-2', 'entry-1'] },
  'reorder should send entry order',
);

assert(
  calls[8]?.path === '/virtual-models/export',
  'export should use export path',
);
assertJsonEqual(
  normalizedExport.virtual_models.balanced?.entries,
  [
    {
      id: 'entry-1',
      target: 'openai/gpt-4.1',
      priority: 1,
    },
  ],
  'export should normalize valid entries and drop invalid entries',
);

assert(
  calls[9]?.path === '/virtual-models/import',
  'import should use import path',
);
assert(calls[9]?.init?.method === 'POST', 'import should POST payload');
assertJsonEqual(
  JSON.parse(String(calls[9]?.init?.body)).virtual_models.balanced.entries,
  [
    {
      id: 'entry-1',
      target: 'openai/gpt-4.1',
      priority: 1,
    },
  ],
  'import should send normalized payload',
);
