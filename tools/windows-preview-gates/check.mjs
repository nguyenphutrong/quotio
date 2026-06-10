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
const mainWindowXaml = readProjectFile('apps/windows-host/MainWindow.xaml');
const windowsAgentAdapter = readProjectFile(
  'apps/windows-host/WindowsAgentAdapter.cs',
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
  supportsTrayBehavior: 'true',
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

function assertNotContains(sourceName, sourceText, rejectedText) {
  if (sourceText.includes(rejectedText)) {
    throw new Error(`${sourceName} contains stale text: ${rejectedText}`);
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
  'ApplyAppearance(preferencesStore.Load().Appearance);',
  'ExtendsContentIntoTitleBar = true;',
  'SetTitleBar(TitleBarDragRegion);',
  'presenter.State == OverlappedPresenterState.Minimized',
  'placement.IsMaximized',
  'presenter.Maximize();',
  'State: OverlappedPresenterState.Maximized',
  'ConfigureWebViewStartupBackground();',
  '"WEBVIEW2_DEFAULT_BACKGROUND_COLOR"',
  '"0x00000000"',
  'DesktopWebView.DefaultBackgroundColor = Colors.Transparent;',
  'core.Settings.AreDefaultContextMenusEnabled = true;',
  'preferencesStore.Load().CloseToTray',
  'core.Settings.AreDevToolsEnabled = IsDebugHost();',
  'core.WebMessageReceived += bridge.OnWebMessageReceived;',
  'core.NavigationCompleted += OnWebViewNavigationCompleted;',
  'ShouldOpenInitialSetupLanding()',
  "history.replaceState({}, '', '/settings#",
  'await core.AddScriptToExecuteOnDocumentCreatedAsync(',
  'bridge.CreateBootstrapScript(DesktopUiSource.Bootstrap(config, preferencesStore))',
  'DesktopWebView.Source = source;',
  'DesktopWebView.CoreWebView2?.CanGoBack == true',
  'DesktopWebView.CoreWebView2?.Reload();',
  "history.pushState({}, '', '/settings');",
  'root.RequestedTheme = appearance switch',
  '"light" => ElementTheme.Light',
  '"dark" => ElementTheme.Dark',
  '_ => ElementTheme.Default',
  'ApplyAppearance',
]);
assertAllContain(
  'Windows bridge appearance sync',
  readProjectFile('apps/windows-host/DesktopBridge.cs'),
  [
    'Action<string>? applyAppearance = null',
    'this.applyAppearance = applyAppearance ?? (_ => { });',
    'var updatedPreferences = preferencesStore.Update(preferences, config);',
    'applyAppearance(updatedPreferences.Appearance);',
  ],
);
assertAllContain(
  'Windows bridge native settings affordances',
  readProjectFile('apps/windows-host/DesktopBridge.cs'),
  [
    'IsAllowedExternalUri(url)',
    '"ms-settings:startupapps"',
    '["launchAtLoginCanOpenSystemSettings"] = true',
    '["closeToTray"] = preferences.CloseToTray',
    '["quotaAlertThreshold"] = preferences.QuotaAlertThreshold',
    '["quotaDisplayMode"] = preferences.QuotaDisplayMode',
    '["quotaDisplayStyle"] = preferences.QuotaDisplayStyle',
    '["resetTimeDisplayMode"] = preferences.ResetTimeDisplayMode',
    '["refreshCadence"] = preferences.RefreshCadence',
  ],
);
assertAllContain(
  'Windows native preferences quota display persistence',
  readProjectFile('apps/windows-host/WindowsNativePreferencesStore.cs'),
  [
    'public bool CloseToTray { get; set; } = true;',
    'state.CloseToTray = closeToTray;',
    'public int QuotaAlertThreshold { get; set; } = 20;',
    'public string QuotaDisplayMode { get; set; } = "used";',
    'public string QuotaDisplayStyle { get; set; } = "card";',
    'public string ResetTimeDisplayMode { get; set; } = "relative";',
    'public string RefreshCadence { get; set; } = "10min";',
    'quotaAlertThreshold is 10 or 20 or 30 or 50',
    'quotaDisplayMode == "used" || quotaDisplayMode == "remaining"',
    'quotaDisplayStyle == "card" || quotaDisplayStyle == "lowestBar" || quotaDisplayStyle == "ring"',
    'resetTimeDisplayMode == "relative" || resetTimeDisplayMode == "absolute"',
    'refreshCadence == "manual"',
  ],
);
for (const rejectedText of [
  'Windows preview supports',
  'this preview build',
  'not implemented yet',
]) {
  assertNotContains(
    'Windows agent adapter copy',
    windowsAgentAdapter,
    rejectedText,
  );
}
assertAllContain(
  'Desktop settings Windows tray behavior',
  readProjectFile('apps/desktop-ui/src/features/settings/settings-page.tsx'),
  [
    'bootstrap.capabilities.supportsTrayBehavior',
    "t('settings.native.fields.closeToTray')",
    "t('settings.native.hints.closeToTray')",
    "void savePreference('closeToTray', checked)",
  ],
);
assertAllContain(
  'Desktop settings native startup affordance',
  readProjectFile('apps/desktop-ui/src/features/settings/settings-page.tsx'),
  [
    "await openExternal('ms-settings:startupapps');",
    'preferences?.launchAtLoginCanOpenSystemSettings',
    "t('settings.native.actions.openStartupSettings')",
  ],
);
assertAllContain(
  'Desktop settings Windows setup surface',
  readProjectFile('apps/desktop-ui/src/features/settings/settings-page.tsx'),
  [
    "const REMOTE_CONNECTION_PANEL_ID = 'remote-management-connection';",
    "bootstrap.platform === 'windows'",
    '!bootstrap.capabilities.supportsNativeOnboarding',
    "t('settings.native.setup.title')",
    'scrollToRemoteConnection',
    'id={REMOTE_CONNECTION_PANEL_ID}',
    'remoteConfigurationVersion',
    'onConfigurationChanged',
    'setRemoteConfigurationVersion((version) => version + 1)',
    'window.location.hash !==',
    'REMOTE_CONNECTION_PANEL_ID}`',
    'getElementById(REMOTE_CONNECTION_PANEL_ID)',
  ],
);
assertAllContain('Windows native command strip', mainWindowXaml, [
  'x:Name="NativeTitleBar"',
  'x:Name="TitleBarDragRegion"',
  'x:Name="BackButton"',
  'x:Name="RefreshButton"',
  'x:Name="SettingsButton"',
  'Segoe MDL2 Assets',
  '<controls:WebView2',
  'Grid.Row="1"',
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
  'windows-update-channel.txt',
  'quotio-windows-installer.manifest.json',
  'updateChannelFile = "windows-update-channel.txt"',
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
