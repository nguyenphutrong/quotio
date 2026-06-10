import {
  defaultAdvancedProxySettings,
  fetchAdvancedProxySettings,
  normalizeAdvancedProxySettings,
  updateAdvancedProxySetting,
  validateProxyUrl,
} from './advanced-proxy-api';

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
  const normalized = normalizeAdvancedProxySettings(
    {
      debug: true,
      'proxy-url': 'socks5://127.0.0.1:1080',
      'request-retry': 5,
      'max-retry-interval': 60,
      'logging-to-file': false,
      'request-log': true,
      'quota-exceeded': {
        'switch-project': false,
        'switch-preview-model': true,
      },
    },
    { strategy: 'fill-first' },
  );
  assertJsonEqual(
    normalized,
    {
      proxyUrl: 'socks5://127.0.0.1:1080',
      routingStrategy: 'fill-first',
      switchProject: false,
      switchPreviewModel: true,
      requestRetry: 5,
      maxRetryInterval: 60,
      loggingToFile: false,
      requestLog: true,
      debugMode: true,
    },
    'normalizer should map cpa++ kebab-case config',
  );

  assertJsonEqual(
    normalizeAdvancedProxySettings({}),
    defaultAdvancedProxySettings,
    'normalizer should use Swift defaults for missing config',
  );

  const readPaths: string[] = [];
  const fetched = await fetchAdvancedProxySettings(async <T>(path: string) => {
    readPaths.push(path);
    if (path === '/config') {
      return { 'request-retry': 2 } as T;
    }
    if (path === '/routing/strategy') {
      return { strategy: 'fill-first' } as T;
    }
    throw new Error(`unexpected path ${path}`);
  });
  assertJsonEqual(
    readPaths.sort(),
    ['/config', '/routing/strategy'],
    'fetch should read config and routing strategy',
  );
  assert(fetched.requestRetry === 2, 'fetch should include config values');
  assert(
    fetched.routingStrategy === 'fill-first',
    'fetch should include routing strategy',
  );

  const mutationCalls: Array<{ path: string; init?: RequestInit }> = [];
  const request = async <T>(path: string, init?: RequestInit) => {
    mutationCalls.push({ path, init });
    return undefined as T;
  };

  await updateAdvancedProxySetting(
    request,
    'proxyUrl',
    '  http://127.0.0.1:8080  ',
  );
  await updateAdvancedProxySetting(request, 'proxyUrl', '');
  await updateAdvancedProxySetting(request, 'routingStrategy', 'round-robin');
  await updateAdvancedProxySetting(request, 'switchProject', false);
  await updateAdvancedProxySetting(request, 'switchPreviewModel', true);
  await updateAdvancedProxySetting(request, 'requestRetry', 4);
  await updateAdvancedProxySetting(request, 'maxRetryInterval', 45);
  await updateAdvancedProxySetting(request, 'loggingToFile', false);
  await updateAdvancedProxySetting(request, 'requestLog', true);
  await updateAdvancedProxySetting(request, 'debugMode', true);

  assertJsonEqual(
    mutationCalls.map((call) => [call.path, call.init?.method]),
    [
      ['/proxy-url', 'PUT'],
      ['/proxy-url', 'DELETE'],
      ['/routing/strategy', 'PUT'],
      ['/quota-exceeded/switch-project', 'PATCH'],
      ['/quota-exceeded/switch-preview-model', 'PATCH'],
      ['/request-retry', 'PUT'],
      ['/max-retry-interval', 'PUT'],
      ['/logging-to-file', 'PUT'],
      ['/request-log', 'PUT'],
      ['/debug', 'PUT'],
    ],
    'mutations should use cpa++ management endpoints',
  );
  assertJsonEqual(
    JSON.parse(String(mutationCalls[0]?.init?.body)),
    { value: 'http://127.0.0.1:8080' },
    'proxy url mutation should trim input',
  );

  assert(validateProxyUrl(''), 'empty proxy URL should be allowed');
  assert(
    validateProxyUrl('socks5h://127.0.0.1:1080'),
    'socks5h proxy URL should be allowed',
  );
  assert(
    !validateProxyUrl('ftp://127.0.0.1'),
    'unsupported proxy protocol should be rejected',
  );
  assert(!validateProxyUrl('not a url'), 'invalid URL should be rejected');
}

await run();
