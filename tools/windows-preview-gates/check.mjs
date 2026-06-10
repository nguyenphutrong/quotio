import { readFileSync } from 'node:fs';

function readProjectFile(relativePath) {
  return readFileSync(
    new URL(`../../${relativePath}`, import.meta.url),
    'utf8',
  );
}

const sourcePath = new URL(
  '../../apps/windows-host/DesktopUiSource.cs',
  import.meta.url,
);
const source = readFileSync(sourcePath, 'utf8');
const mainWindowSource = readProjectFile(
  'apps/windows-host/MainWindow.xaml.cs',
);
const windowsProject = readProjectFile(
  'apps/windows-host/Quotio.Windows.csproj',
);

const expectedFeatures = {
  overview: 'managementBridgeReady',
  providers: 'managementBridgeReady',
  quota: 'managementBridgeReady',
  usage: 'managementBridgeReady',
  virtualModels: 'managementBridgeReady',
  models: 'managementBridgeReady',
  agents: 'localModeEnabled',
  apiKeys: 'managementBridgeReady',
  logs: 'managementBridgeReady',
  settings: 'true',
  about: 'true',
};

const expectedCapabilities = {
  supportsLocalProxy: 'localProxyAvailable',
  supportsProxyControl: 'localModeEnabled',
  supportsPortConfig: 'localModeEnabled',
  supportsCliOAuth: 'localModeEnabled',
  supportsAgentConfig: 'localModeEnabled',
  supportsRemoteConnections: 'true',
  supportsCredentialStorage: 'true',
  supportsManagementBridge: 'managementBridgeReady',
  supportsNativeOnboarding: 'false',
  supportsNativePreferences: 'true',
  supportsAppearanceSync: 'true',
  supportsRequestLogSettings: 'true',
  supportsModelSettings: 'true',
  supportsApiKeyManagement: 'true',
  supportsVirtualModelManagement: 'true',
  supportsUpdates: 'true',
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
    [...match[1].matchAll(/\["([^"]+)"\]\s*=\s*([^,\n]+)/g)].map(
      ([, key, value]) => [key, value.trim()],
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

function assertContains(sourceName, sourceText, requiredText) {
  if (!sourceText.includes(requiredText)) {
    throw new Error(`${sourceName} is missing required text: ${requiredText}`);
  }
}

function assertAllContain(sourceName, sourceText, requiredTexts) {
  for (const requiredText of requiredTexts) {
    assertContains(sourceName, sourceText, requiredText);
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
assertAllContain('Windows desktop bootstrap source', source, [
  'var localProxyAvailable = config.LocalProxyAvailable;',
  'var localModeEnabled = localProxyAvailable && preferences.OperatingMode == "local";',
  'var operatingMode = localModeEnabled ? "local" : "remote";',
  'var managementBridgeReady = localModeEnabled || !string.IsNullOrWhiteSpace(config.ManagementBaseUrl);',
]);
assertAllContain('Windows WebView2 host chrome', mainWindowSource, [
  'SystemBackdrop = new MicaBackdrop();',
  'ConfigureWebViewStartupBackground();',
  '"WEBVIEW2_DEFAULT_BACKGROUND_COLOR"',
  '"0x00000000"',
  'DesktopWebView.DefaultBackgroundColor = Colors.Transparent;',
  'core.Settings.AreDefaultContextMenusEnabled = true;',
  'core.Settings.AreDevToolsEnabled = IsDebugHost();',
  'core.WebMessageReceived += bridge.OnWebMessageReceived;',
  'await core.AddScriptToExecuteOnDocumentCreatedAsync(',
  'bridge.CreateBootstrapScript(DesktopUiSource.Bootstrap(config, preferencesStore))',
  'DesktopWebView.Source = source;',
]);
assertAllContain('Windows MSBuild desktop UI bundle target', windowsProject, [
  '<Target Name="CopyDesktopUi" AfterTargets="Build" Condition="Exists(\'..\\desktop-ui\\dist\\index.html\')">',
  '<DesktopUiFiles Include="..\\desktop-ui\\dist\\**\\*.*" />',
  'DestinationFiles="@(DesktopUiFiles->\'$(OutDir)desktop-ui\\%(RecursiveDir)%(Filename)%(Extension)\')"',
  'SkipUnchangedFiles="true"',
]);

const previewPackageScript = readProjectFile(
  'scripts/package-windows-preview.ps1',
);
const installerPackageScript = readProjectFile(
  'scripts/package-windows-installer.ps1',
);
const multiplatformWorkflow = readProjectFile(
  '.github/workflows/multiplatform.yml',
);
const previewReleaseWorkflow = readProjectFile(
  '.github/workflows/windows-preview-release.yml',
);
const installerReleaseWorkflow = readProjectFile(
  '.github/workflows/windows-installer-release.yml',
);

assertAllContain('Windows preview package script', previewPackageScript, [
  'desktop-ui/index.html',
  'Quotio.Windows.exe',
  'Expand-Archive',
  'requiredFileDetails',
  '$manifestPath = "$zipPath.manifest.json"',
  'crashUploadConfigured = $false',
]);

assertAllContain('Windows installer package script', installerPackageScript, [
  'dotnet publish',
  'desktop-ui/index.html',
  'Quotio.Windows.exe',
  'releases.$Channel.json',
  'setup executable',
  'quotio-windows-installer.manifest.json',
  'signing = ![string]::IsNullOrWhiteSpace($SignTemplate)',
]);

assertAllContain('Multiplatform workflow', multiplatformWorkflow, [
  './scripts/package-windows-preview.ps1',
  './scripts/package-windows-installer.ps1',
  'artifacts/quotio-windows-preview.zip',
  'artifacts/quotio-windows-preview.zip.sha256',
  'artifacts/quotio-windows-preview.zip.manifest.json',
  'artifacts/windows-installer/**',
  'dotnet run --project apps/windows-host-smoke/Quotio.WindowsSmoke.csproj --configuration Release',
]);

assertAllContain('Windows preview release workflow', previewReleaseWorkflow, [
  'windows-preview-*',
  './scripts/package-windows-preview.ps1',
  'artifacts/$' + '{{ env.ARTIFACT_NAME }}',
  'artifacts/$' + '{{ env.ARTIFACT_NAME }}.sha256',
  'artifacts/$' + '{{ env.ARTIFACT_NAME }}.manifest.json',
  'This is an unsigned preview build',
]);

assertAllContain(
  'Windows installer release workflow',
  installerReleaseWorkflow,
  [
    'windows-v*',
    './scripts/package-windows-installer.ps1',
    'artifacts/windows-installer/**',
    'Velopack',
    'Signing is not enabled unless',
  ],
);

console.log(
  'Windows preview route, WebView2 chrome, and packaging gates match the approved matrix',
);
