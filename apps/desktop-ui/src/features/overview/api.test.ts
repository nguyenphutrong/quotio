import {
  emptyHealthSnapshot,
  emptyLogsSummary,
  fetchOverviewHealth,
  fetchOverviewLogsSummary,
  fetchOverviewPing,
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
  const paths: string[] = [];
  const result = await fetchOverviewPing(async (path) => {
    paths.push(path);
    return undefined as never;
  });

  assert(result === true, 'overview ping should return true');
  assertJsonEqual(paths, ['/debug'], 'overview ping should use /debug');

  const health = await fetchOverviewHealth(async () => {
    throw new Error('Unsupported endpoint');
  });
  assertJsonEqual(
    health,
    emptyHealthSnapshot,
    'overview health should fall back to an empty snapshot',
  );

  const logsSummary = await fetchOverviewLogsSummary(async () => {
    throw new Error('Unsupported endpoint');
  });
  assertJsonEqual(
    logsSummary,
    emptyLogsSummary,
    'overview logs summary should fall back to zero metrics',
  );
}

await run();
