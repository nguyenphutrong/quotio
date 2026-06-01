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

# Agentmap Integration

This project uses **agentlens** for AI-optimized documentation.

## Reading Protocol

Follow this order to understand the codebase efficiently:

1. **Start here**: `.agentlens/INDEX.md` - Project overview and module routing
2. **AI instructions**: `.agentlens/AGENT.md` - How to use the documentation
3. **Module details**: `.agentlens/modules/{module}/MODULE.md` - File lists and entry points
4. **Before editing**: Check `.agentlens/modules/{module}/memory.md` for warnings/TODOs

## Documentation Structure

```
.agentlens/
├── INDEX.md              # Start here - global routing table
├── AGENT.md              # AI agent instructions
├── modules/
│   └── {module-slug}/
│       ├── MODULE.md     # Module summary
│       ├── outline.md    # Symbol maps for large files
│       ├── memory.md     # Warnings, TODOs, business rules
│       └── imports.md    # Dependencies
└── files/                # Deep docs for complex files
```

## During Development

- Use `.agentlens/modules/{module}/outline.md` to find symbols in large files
- Check `.agentlens/modules/{module}/imports.md` for dependencies
- For complex files, see `.agentlens/files/{file-slug}.md`

## Commands

| Task | Command |
|------|---------|
| Regenerate docs | `agentlens` |
| Fast update (changed only) | `agentlens --diff main` |
| Check if stale | `agentlens --check` |
| Force full regen | `agentlens --force` |

## Key Patterns

- **Module boundaries**: `mod.rs` (Rust), `index.ts` (TS), `__init__.py` (Python)
- **Large files**: >500 lines, have symbol outlines
- **Complex files**: >30 symbols, have L2 deep docs
- **Hub files**: Imported by 3+ files, marked with 🔗
- **Memory markers**: TODO, FIXME, WARNING, SAFETY, RULE

---
*Generated by [agentlens](https://github.com/nguyenphutrong/agentlens)*
