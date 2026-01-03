# AGENTS.md - Quotio Development Guidelines

**Generated:** 2026-01-03 | **Commit:** 1995a85 | **Branch:** master

## Overview

Native macOS menu bar app (SwiftUI) for managing CLIProxyAPI - local proxy server for AI coding agents. Multi-provider OAuth, quota tracking, CLI tool configuration.

**Stack:** Swift 6, SwiftUI, macOS 15+, Xcode 16+, Sparkle (auto-update)

## Structure

```
Quotio/
├── QuotioApp.swift           # @main entry + AppDelegate + ContentView
├── Models/                   # Enums, Codable structs, settings managers
├── Services/                 # Business logic, API clients, actors (→ AGENTS.md)
├── ViewModels/               # @Observable state (QuotaViewModel, AgentSetupViewModel)
├── Views/Components/         # Reusable UI (→ Views/AGENTS.md)
├── Views/Screens/            # Full-page views
└── Assets.xcassets/          # Icons (provider icons, menu bar icons)
Config/                       # .xcconfig files (Debug/Release/Local)
scripts/                      # Build, release, notarize (→ AGENTS.md)
docs/                         # Architecture docs
```

## Where to Look

| Task | Location | Notes |
|------|----------|-------|
| Add AI provider | `Models/Models.swift` → `AIProvider` enum | Add case + computed properties |
| Add quota fetcher | `Services/*QuotaFetcher.swift` | Actor pattern, see existing fetchers |
| Add CLI agent | `Models/AgentModels.swift` → `CLIAgent` enum | + detection in `AgentDetectionService` |
| UI component | `Views/Components/` | Reuse `ProviderIcon`, `AccountRow`, `QuotaCard` |
| New screen | `Views/Screens/` | Add to `NavigationPage` enum in Models |
| OAuth flow | `ViewModels/QuotaViewModel.swift` | `startOAuth()`, poll pattern |
| Menu bar | `Services/StatusBarManager.swift` | Singleton, uses `StatusBarMenuBuilder` |

## Code Map (Key Symbols)

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `CLIProxyManager` | Class | Services/ | Proxy lifecycle, binary management, auth commands |
| `QuotaViewModel` | Class | ViewModels/ | Central state: quotas, auth, providers, logs |
| `ManagementAPIClient` | Actor | Services/ | HTTP client for CLIProxyAPI |
| `AIProvider` | Enum | Models/ | Provider definitions (13 providers) |
| `CLIAgent` | Enum | Models/ | CLI agent definitions (6 agents) |
| `StatusBarManager` | Class | Services/ | Menu bar icon and menu |
| `ProxyBridge` | Class | Services/ | TCP bridge layer for connection management |

## Build Commands

```bash
# Debug build
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build

# Release build
./scripts/build.sh

# Full release (build + package + notarize + appcast)
./scripts/release.sh

# Check compile errors
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build 2>&1 | head -50
```

## Conventions

### Swift 6 Concurrency (CRITICAL)
```swift
// UI classes: @MainActor @Observable
@MainActor @Observable
final class StatusBarManager {
    static let shared = StatusBarManager()
    private init() {}
}

// Thread-safe services: actor
actor ManagementAPIClient { ... }

// Data crossing boundaries: Sendable
struct AuthFile: Codable, Sendable { ... }
```

### Observable Pattern
```swift
// ViewModel
@MainActor @Observable
final class QuotaViewModel { var isLoading = false }

// View injection
@Environment(QuotaViewModel.self) private var viewModel

// Binding
@Bindable var vm = viewModel
```

### Codable with snake_case
```swift
struct AuthFile: Codable, Sendable {
    let statusMessage: String?
    enum CodingKeys: String, CodingKey {
        case statusMessage = "status_message"
    }
}
```

### View Structure
```swift
struct DashboardScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    // MARK: - Computed Properties
    private var isReady: Bool { ... }
    
    // MARK: - Body
    var body: some View { ... }
    
    // MARK: - Subviews
    private var headerSection: some View { ... }
}
```

## Anti-Patterns (NEVER)

| Pattern | Why Bad | Instead |
|---------|---------|---------|
| `Text("localhost:\(port)")` | Locale formats as "8.217" | `Text("localhost:" + String(port))` |
| Direct `UserDefaults` in View | Inconsistent | `@AppStorage("key")` |
| Blocking main thread | UI freeze | `Task { await ... }` |
| Force unwrap optionals | Crashes | Guard/if-let |
| Hardcoded strings | No i18n | `"key".localized()` |

## Critical Invariants

From code comments - **never violate**:
- ProxyStorageManager: **never delete current** version
- AgentConfigurationService: backups **never overwritten**
- ProxyBridge: target host **always localhost**
- CLIProxyManager: base URL **always points to CLIProxyAPI directly**

## Key Patterns

### Parallel Async Fetching
```swift
async let files = client.fetchAuthFiles()
async let stats = client.fetchUsageStats()
(self.authFiles, self.usageStats) = try await (files, stats)
```

### Mode-Aware Logic
```swift
if modeManager.isQuotaOnlyMode {
    // Direct fetch without proxy
} else {
    // Proxy mode
}
```

### Weak References (prevent retain cycles)
```swift
weak var viewModel: QuotaViewModel?
```

## Testing

No automated tests. Manual testing:
- Run with `Cmd + R`
- Verify light/dark mode
- Test menu bar integration
- Check all providers OAuth
- Validate localization

## Git Workflow

**Never commit to `master`**. Branch naming:
- `feature/<name>` - New features
- `bugfix/<desc>` - Bug fixes
- `refactor/<scope>` - Refactoring
- `docs/<content>` - Documentation

## Dependencies

- **Sparkle** - Auto-update (SPM)

## Config Files

| File | Purpose |
|------|---------|
| `Config/Debug.xcconfig` | Debug build settings |
| `Config/Release.xcconfig` | Release build settings |
| `Config/Local.xcconfig` | Developer overrides (gitignored) |
| `Quotio/Info.plist` | App metadata, URL schemes |
| `Quotio/Quotio.entitlements` | Sandbox disabled, network enabled |
