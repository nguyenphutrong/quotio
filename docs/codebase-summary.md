# Quotio - Codebase Summary

> **Last Updated**: January 2, 2025  
> **Swift Version**: 6.0  
> **Minimum macOS**: 15.0 (Sequoia)

---

## Table of Contents

1. [Technology Stack](#technology-stack)
2. [Dependencies](#dependencies)
3. [High-Level Module Overview](#high-level-module-overview)
4. [Key Files and Their Purposes](#key-files-and-their-purposes)
5. [Data Flow Overview](#data-flow-overview)
6. [Build and Configuration Files](#build-and-configuration-files)

---

## Technology Stack

| Category | Technology |
|----------|------------|
| **Platform** | macOS 15.0+ (Sequoia) |
| **Language** | Swift 6 with strict concurrency |
| **UI Framework** | SwiftUI |
| **App Framework** | AppKit (for NSStatusBar, NSPasteboard) |
| **Concurrency** | Swift Concurrency (async/await, actors) |
| **State Management** | Observable macro pattern |
| **Package Manager** | Swift Package Manager |
| **Auto-Update** | Sparkle Framework |

### Key Swift 6 Features Used

- **`@Observable`** macro for reactive state
- **`@MainActor`** for UI-bound classes
- **`actor`** for thread-safe services
- **`Sendable`** conformance for cross-actor data
- **`async/await`** for all asynchronous operations

---

## Dependencies

### Third-Party Dependencies

| Dependency | Purpose | Integration |
|------------|---------|-------------|
| **Sparkle** | Auto-update framework | Swift Package Manager |

### System Frameworks

| Framework | Purpose |
|-----------|---------|
| **SwiftUI** | User interface |
| **AppKit** | Menu bar, pasteboard, workspace |
| **Foundation** | Core utilities, networking |
| **ServiceManagement** | Launch services |

### External Binaries

| Binary | Source | Purpose |
|--------|--------|---------|
| **CLIProxyAPI** | GitHub (auto-downloaded) | Local proxy server |

---

## High-Level Module Overview

### Application Layer

```
Quotio/
├── QuotioApp.swift          # App entry point, lifecycle management
└── Info.plist               # App metadata and permissions
```

### Models Layer

```
Quotio/Models/
├── Models.swift             # Core data types (AIProvider, AuthFile, etc.)
├── AgentModels.swift        # CLI agent configuration types
├── AntigravityActiveAccount.swift # Antigravity account model and switch state
├── AppMode.swift            # App mode management (Full/Quota-Only)
└── MenuBarSettings.swift    # Menu bar configuration and persistence
```

### Services Layer

```
Quotio/Services/
├── CLIProxyManager.swift        # Proxy process lifecycle
├── ManagementAPIClient.swift    # HTTP client for proxy API
├── StatusBarManager.swift       # NSStatusBar management
├── StatusBarMenuBuilder.swift   # Native NSMenu builder (menu bar content)
├── NotificationManager.swift    # User notification handling
├── UpdaterService.swift         # Sparkle integration
├── AgentDetectionService.swift  # CLI agent detection
├── AgentConfigurationService.swift # Agent config generation
├── ShellProfileManager.swift    # Shell profile updates
├── DirectAuthFileService.swift  # Direct auth file scanning
├── CLIExecutor.swift            # CLI command execution
├── LanguageManager.swift        # Localization management
├── AntigravityAccountSwitcher.swift  # Account switching orchestrator
├── AntigravityDatabaseService.swift  # SQLite database operations
├── AntigravityProcessManager.swift   # IDE process lifecycle management
├── AntigravityProtobufHandler.swift  # Protobuf encoding/decoding
└── *QuotaFetcher.swift          # Provider-specific quota fetchers (7 files)
```

### ViewModels Layer

```
Quotio/ViewModels/
├── QuotaViewModel.swift         # Main app state container
└── AgentSetupViewModel.swift    # Agent configuration state
```

### Views Layer

```
Quotio/Views/
├── Components/
│   ├── AccountRow.swift         # Account row with switch button
│   ├── AgentCard.swift          # Agent display card
│   ├── AgentConfigSheet.swift   # Agent configuration sheet
│   ├── ProviderIcon.swift       # Provider icon component
│   ├── QuotaCard.swift          # Quota display card
│   ├── QuotaProgressBar.swift   # Progress bar component
│   ├── SidebarView.swift        # Navigation sidebar
│   └── SwitchAccountSheet.swift # Account switch confirmation dialog
└── Screens/
    ├── DashboardScreen.swift    # Main dashboard
    ├── QuotaScreen.swift        # Quota monitoring
    ├── ProvidersScreen.swift    # Provider management
    ├── AgentSetupScreen.swift   # Agent configuration
    ├── APIKeysScreen.swift      # API key management
    ├── LogsScreen.swift         # Log viewer
    └── SettingsScreen.swift     # App settings
```

### Assets

```
Quotio/Assets.xcassets/
├── AppIcon.appiconset/          # App icons (production)
├── AppIconDev.appiconset/       # App icons (development)
├── MenuBarIcons/                # Provider icons for menu bar
├── ProviderIcons/               # Provider logos
└── AccentColor.colorset/        # Accent color definition
```

---

## Key Files and Their Purposes

### Entry Point

| File | Purpose |
|------|---------|
| **QuotioApp.swift** | App entry, scene definition, AppDelegate, ContentView, menu bar orchestration |

### Core Data Types

| File | Key Types | Purpose |
|------|-----------|---------|
| **Models.swift** | `AIProvider`, `ProxyStatus`, `AuthFile`, `UsageStats`, `AppConfig`, `NavigationPage` | Core domain models |
| **AgentModels.swift** | `CLIAgent`, `AgentConfigType`, `ModelSlot`, `AgentStatus`, `AgentConfiguration` | CLI agent types |
| **AppMode.swift** | `AppMode`, `AppModeManager` | Full/Quota-Only mode management |
| **MenuBarSettings.swift** | `MenuBarQuotaItem`, `MenuBarColorMode`, `QuotaDisplayMode`, `MenuBarSettingsManager`, `AppearanceManager` | Menu bar configuration |

### Services

| File | Key Class/Actor | Purpose |
|------|-----------------|---------|
| **CLIProxyManager.swift** | `CLIProxyManager`, `ProxyError`, `AuthCommand` | Proxy binary lifecycle, download, CLI auth commands |
| **ManagementAPIClient.swift** | `ManagementAPIClient`, `APIError` | HTTP requests to proxy management API |
| **StatusBarManager.swift** | `StatusBarManager` | NSStatusItem management, popover handling |
| **NotificationManager.swift** | `NotificationManager` | User notification delivery and management |
| **AgentDetectionService.swift** | `AgentDetectionService` | Find installed CLI agents |
| **AgentConfigurationService.swift** | `AgentConfigurationService` | Generate agent configurations |
| **ShellProfileManager.swift** | `ShellProfileManager` | Update shell profiles (zsh/bash/fish) |

### Quota Fetchers

| File | Provider(s) | Method |
|------|-------------|--------|
| **AntigravityQuotaFetcher.swift** | Antigravity | API calls using auth files |
| **OpenAIQuotaFetcher.swift** | Codex (OpenAI) | API calls using auth files |
| **CopilotQuotaFetcher.swift** | GitHub Copilot | API calls using auth files |
| **ClaudeCodeQuotaFetcher.swift** | Claude | CLI command (`claude usage`) |
| **CursorQuotaFetcher.swift** | Cursor | Browser session/database |
| **CodexCLIQuotaFetcher.swift** | Codex | CLI auth file (`~/.codex/auth.json`) |
| **GeminiCLIQuotaFetcher.swift** | Gemini | CLI auth file (`~/.gemini/oauth_creds.json`) |

### ViewModels

| File | Key Class | Responsibilities |
|------|-----------|------------------|
| **QuotaViewModel.swift** | `QuotaViewModel`, `OAuthState` | Central app state, proxy control, OAuth flow, quota management, menu bar items |
| **AgentSetupViewModel.swift** | `AgentSetupViewModel` | Agent detection, configuration, testing |

---

## Data Flow Overview

### Application Startup Flow

```
1. QuotioApp.init()
   │
   ├─▶ @State viewModel = QuotaViewModel()
   │   └─▶ CLIProxyManager.shared initialized
   │
   ├─▶ Check onboarding status
   │   └─▶ Show ModePickerView if not completed
   │
   └─▶ initializeApp()
       ├─▶ Apply appearance settings
       ├─▶ Mode-based initialization
       │   ├─▶ Full Mode: Start proxy if autoStart enabled
       │   └─▶ Quota-Only: Load direct auth files, fetch quotas
       │
       └─▶ Update status bar
```

### Full Mode Data Flow

```
┌──────────────────┐
│   User Action    │
│ (Start Proxy)    │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ QuotaViewModel   │
│  .startProxy()   │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐       ┌────────────────────┐
│ CLIProxyManager  │──────▶│   CLIProxyAPI      │
│    .start()      │       │   (Binary)         │
└────────┬─────────┘       └────────────────────┘
         │
         ▼
┌──────────────────┐
│ ManagementAPI    │
│    Client        │ ◀─── HTTP requests to localhost:8317
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Auto-Refresh    │ ──── Every 15 seconds
│    Task          │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ UI Updates via   │
│  @Observable     │
└──────────────────┘
```

### Quota Fetching Flow

```
┌──────────────────────────────────────────────────────┐
│                  refreshAllQuotas()                   │
└────────────────────────┬─────────────────────────────┘
                         │
    ┌────────────────────┼────────────────────┐
    │                    │                    │
    ▼                    ▼                    ▼
┌─────────┐        ┌─────────┐         ┌─────────┐
│Antigrav │        │ OpenAI  │         │ Copilot │
│ Fetcher │        │ Fetcher │         │ Fetcher │
└────┬────┘        └────┬────┘         └────┬────┘
    │                   │                    │
    ▼                   ▼                    ▼
┌─────────────────────────────────────────────────┐
│           providerQuotas: [AIProvider:         │
│                 [String: ProviderQuotaData]]   │
└─────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────┐
│           StatusBarManager.updateStatusBar()    │
└─────────────────────────────────────────────────┘
```

### OAuth Authentication Flow

```
┌──────────────┐     ┌───────────────┐     ┌─────────────────┐
│    User      │────▶│ QuotaViewModel │────▶│ Management API  │
│ Clicks Auth  │     │  .startOAuth() │     │ Client          │
└──────────────┘     └───────┬───────┘     └────────┬────────┘
                             │                      │
                             │     GET /xxx-auth-url
                             │◀─────────────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Open Browser   │
                    │   (OAuth URL)   │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Poll Status    │
                    │  (every 2s)     │
                    └────────┬────────┘
                             │
                    Success? ─┴─ Continue polling
                             │
                             ▼
                    ┌─────────────────┐
                    │  Refresh Data   │
                    └─────────────────┘
```

### Agent Configuration Flow

```
┌─────────────────┐     ┌──────────────────────┐
│  AgentSetup     │────▶│ AgentSetupViewModel   │
│   Screen        │     │  .applyConfiguration()│
└─────────────────┘     └──────────┬───────────┘
                                   │
                                   ▼
                       ┌───────────────────────┐
                       │ AgentConfiguration    │
                       │      Service          │
                       └──────────┬────────────┘
                                  │
         ┌────────────────────────┼────────────────────────┐
         │                        │                        │
         ▼                        ▼                        ▼
┌─────────────────┐    ┌─────────────────┐     ┌─────────────────┐
│  Write Config   │    │  Update Shell   │     │   Copy to       │
│   JSON/TOML     │    │    Profile      │     │   Clipboard     │
└─────────────────┘    └─────────────────┘     └─────────────────┘
```

---

## Build and Configuration Files

### Xcode Project

| File/Directory | Purpose |
|----------------|---------|
| **Quotio.xcodeproj/** | Xcode project container |
| **project.pbxproj** | Project settings, targets, build phases |
| **xcschemes/Quotio.xcscheme** | Build scheme configuration |
| **Package.resolved** | Swift Package Manager dependency lock |

### Build Configurations

| File | Purpose |
|------|---------|
| **Config/Debug.xcconfig** | Debug build settings |
| **Config/Release.xcconfig** | Release build settings |
| **Config/Local.xcconfig.example** | Template for local overrides |

### Build Scripts

| Script | Purpose |
|--------|---------|
| **scripts/build.sh** | Build release archive |
| **scripts/release.sh** | Full release workflow |
| **scripts/bump-version.sh** | Version management |
| **scripts/notarize.sh** | Apple notarization |
| **scripts/package.sh** | DMG packaging |
| **scripts/generate-appcast.sh** | Sparkle appcast generation |
| **scripts/config.sh** | Shared configuration |
| **scripts/ExportOptions.plist** | Archive export options |

### App Configuration

| File | Purpose |
|------|---------|
| **Info.plist** | App metadata, permissions, URL schemes |
| **Quotio.entitlements** | Sandbox and capability entitlements |

---

## Runtime File Locations

### Application Support

```
~/Library/Application Support/Quotio/
├── CLIProxyAPI          # Downloaded proxy binary
└── config.yaml          # Proxy configuration
```

### Auth Files Directory

```
~/.cli-proxy-api/
├── gemini-cli-*.json    # Gemini auth files
├── claude-*.json        # Claude auth files
├── codex-*.json         # Codex auth files
├── github-copilot-*.json # Copilot auth files
└── ...                  # Other provider auth files
```

### User Defaults Keys

| Key | Type | Purpose |
|-----|------|---------|
| `proxyPort` | Int | Proxy server port |
| `managementKey` | String | Management API secret key |
| `autoStartProxy` | Bool | Auto-start proxy on launch |
| `appMode` | String | Current app mode |
| `hasCompletedOnboarding` | Bool | Onboarding completion status |
| `menuBarSelectedQuotaItems` | Data | Selected menu bar items (normalized account key) |
| `menuBarMaxItems` | Int | Maximum number of menu bar items to display |
| `menuBarColorMode` | String | Menu bar color mode |
| `showMenuBarIcon` | Bool | Show menu bar icon |
| `menuBarShowQuota` | Bool | Show quota in menu bar |
| `quotaDisplayMode` | String | Quota display mode |
| `loggingToFile` | Bool | Enable file logging |
| `appearanceMode` | String | Light/dark/system mode |
| `quotaAlertThreshold` | Double | Low quota notification threshold |

---

## Localization Structure

```
Quotio/
└── Resources/
    ├── en.lproj/
    │   └── Localizable.strings
    └── vi.lproj/
        └── Localizable.strings
```

### Localization Key Patterns

| Pattern | Example | Usage |
|---------|---------|-------|
| `nav.*` | `nav.dashboard` | Navigation labels |
| `action.*` | `action.startProxy` | Button actions |
| `status.*` | `status.running` | Status indicators |
| `settings.*` | `settings.port` | Settings labels |
| `error.*` | `error.invalidURL` | Error messages |
