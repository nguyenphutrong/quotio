import { readFileSync } from 'node:fs';

const sourcePath = new URL(
  '../../apps/windows-host/DesktopUiSource.cs',
  import.meta.url,
);
const source = readFileSync(sourcePath, 'utf8');

const expectedFeatures = {
  overview: true,
  providers: true,
  quota: true,
  usage: true,
  virtualModels: true,
  models: true,
  agents: true,
  apiKeys: true,
  logs: true,
  settings: true,
  about: true,
};

const expectedCapabilities = {
  supportsLocalProxy: true,
  supportsProxyControl: true,
  supportsPortConfig: true,
  supportsCliOAuth: true,
  supportsAgentConfig: false,
  supportsRemoteConnections: false,
  supportsCredentialStorage: false,
  supportsNativeOnboarding: false,
  supportsAppearanceSync: true,
  supportsRequestLogSettings: false,
  supportsModelSettings: false,
  supportsApiKeyManagement: false,
  supportsVirtualModelManagement: false,
};

function readBoolDictionary(name) {
  const match = source.match(
    new RegExp(
      `${name}: new Dictionary<string, bool>\\s*\\{([\\s\\S]*?)\\n\\s*\\}`,
      'm',
    ),
  );
  if (!match) {
    throw new Error(`Could not find ${name} dictionary in DesktopUiSource.cs`);
  }

  return Object.fromEntries(
    [...match[1].matchAll(/\["([^"]+)"\]\s*=\s*(true|false)/g)].map(
      ([, key, value]) => [key, value === 'true'],
    ),
  );
}

function assertExact(name, actual, expected) {
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = Object.keys(expected).sort();
  const missing = expectedKeys.filter((key) => !actualKeys.includes(key));
  const extra = actualKeys.filter((key) => !expectedKeys.includes(key));
  const changed = expectedKeys.filter((key) => actual[key] !== expected[key]);

  if (missing.length || extra.length || changed.length) {
    throw new Error(
      [
        `${name} gate mismatch`,
        missing.length ? `missing: ${missing.join(', ')}` : null,
        extra.length ? `extra: ${extra.join(', ')}` : null,
        changed.length
          ? `changed: ${changed
              .map((key) => `${key}=${actual[key]} expected ${expected[key]}`)
              .join(', ')}`
          : null,
      ]
        .filter(Boolean)
        .join('\n'),
    );
  }
}

assertExact(
  'Windows preview features',
  readBoolDictionary('Features'),
  expectedFeatures,
);
assertExact(
  'Windows preview capabilities',
  readBoolDictionary('Capabilities'),
  expectedCapabilities,
);

console.log(
  'Windows preview route and capability gates match the approved matrix',
);
