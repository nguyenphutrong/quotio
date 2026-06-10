import {
  defaultLoggingSettings,
  emptyLogsList,
  emptyLogsSummary,
  fetchLoggingSettings,
  fetchLogsList,
  fetchLogsSummary,
  updateLoggingSettings,
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

async function run() {
  const summary = await fetchLogsSummary(async () => {
    throw new Error('Unsupported endpoint');
  });
  assertJsonEqual(
    summary,
    emptyLogsSummary,
    'logs summary should fall back to zero metrics',
  );

  const listPaths: string[] = [];
  const list = await fetchLogsList(
    async (path) => {
      listPaths.push(path);
      throw new Error('Unsupported endpoint');
    },
    'cursor-1',
    25,
    ' key-1 ',
  );
  assertJsonEqual(list, emptyLogsList, 'logs list should fall back to empty');
  assertJsonEqual(
    listPaths,
    ['/logs?limit=25&cursor=cursor-1&api_key_id=key-1'],
    'logs list should preserve query parameters',
  );

  const settings = await fetchLoggingSettings(async <T>(path: string) => {
    assert(path === '/request-log', 'settings should use /request-log');
    return { 'request-log': true } as T;
  });
  assertJsonEqual(
    settings,
    { capture_bodies: true },
    'settings should map request-log to capture_bodies',
  );

  const fallbackSettings = await fetchLoggingSettings(async () => {
    throw new Error('Unsupported endpoint');
  });
  assertJsonEqual(
    fallbackSettings,
    defaultLoggingSettings,
    'settings should fall back to disabled request logging',
  );

  const mutationCalls: Array<{ path: string; init?: RequestInit }> = [];
  const updated = await updateLoggingSettings(
    async <T>(path: string, init?: RequestInit) => {
      mutationCalls.push({ path, init });
      return undefined as T;
    },
    true,
  );
  assertJsonEqual(
    updated,
    { capture_bodies: true },
    'mutation should return updated settings',
  );
  assert(mutationCalls.length === 1, 'mutation should make one request');
  assert(
    mutationCalls[0]?.path === '/request-log',
    'mutation should use /request-log',
  );
  assert(
    mutationCalls[0]?.init?.method === 'PATCH',
    'mutation should patch request-log',
  );
  assertJsonEqual(
    JSON.parse(String(mutationCalls[0]?.init?.body)),
    { value: true },
    'mutation should send cpa++ bool payload',
  );
}

await run();
