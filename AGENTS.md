# AGENTS.md - Quotio Development Guidelines

## Project Overview

Quotio is a native macOS application (SwiftUI) for managing CLIProxyAPI - a local proxy server for AI coding agents. It supports multiple AI providers (Gemini, Claude, OpenAI, Copilot, etc.) with OAuth authentication, quota tracking, and CLI tool configuration.

**Requirements**: macOS 15.0+ (Sequoia), Swift 6, Xcode 16+

## Build Commands

```bash
# Open project in Xcode
open Quotio.xcodeproj

# Build for development (Debug)
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build

# Build for release (unsigned)
./scripts/build.sh

# Archive for distribution
xcodebuild archive \
    -project Quotio.xcodeproj \
    -scheme Quotio \
    -configuration Release \
    -archivePath build/Quotio.xcarchive \
    -destination "generic/platform=macOS"
```

## Testing

This project currently has no automated tests. When implementing features:

- Test manually in Xcode using `Cmd + R`
- Verify UI changes across light/dark mode
- Test menu bar functionality by running the app
- Check localization for both English and Vietnamese

## Git Workflow

**Important**: Never commit changes directly to the `master` branch. Always create a new branch appropriate for the type of work:

- `feature/<feature-name>` - New features
- `bugfix/<bug-description>` - Bug fixes
- `refactor/<scope>` - Code refactoring
- `docs/<content>` - Documentation updates
- `chore/<content>` - Maintenance tasks, dependency updates

```bash
# Example branch creation
git checkout -b feature/add-new-provider
git checkout -b bugfix/fix-quota-display
git checkout -b refactor/simplify-auth-flow
```

After completing the work, create a Pull Request to merge into `master`.

## Linting / Type Checking

Swift compiler handles type checking during build. No separate linting tool is configured.

```bash
# Build to check for compile errors
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build 2>&1 | head -50
```

## Project Structure

```
Quotio/
├── QuotioApp.swift          # App entry point, AppDelegate, ContentView
├── Models/                  # Data models and enums
│   ├── Models.swift         # Core types: AIProvider, ProxyStatus, AuthFile, etc.
│   ├── AgentModels.swift    # CLI agent configuration types
│   ├── AppMode.swift        # App mode management (Full/Quota-Only)
│   └── MenuBarSettings.swift # Menu bar configuration
├── Services/                # Business logic and API clients
│   ├── CLIProxyManager.swift        # Proxy process management
│   ├── ManagementAPIClient.swift    # HTTP client for proxy API
│   ├── StatusBarManager.swift       # NSStatusBar management
│   ├── *QuotaFetcher.swift          # Provider-specific quota fetchers
│   └── ...
├── ViewModels/              # Observable state containers
│   ├── QuotaViewModel.swift         # Main app state
│   └── AgentSetupViewModel.swift    # Agent configuration state
├── Views/
│   ├── Components/          # Reusable UI components
│   └── Screens/             # Full-page views
└── Assets.xcassets/         # Images, icons, colors
```

## Code Style Guidelines

### Swift Version & Concurrency
- **Swift 6** with strict concurrency checking
- Use `@MainActor` for all UI-related classes
- Use `actor` for thread-safe service classes (e.g., `ManagementAPIClient`)
- Use `async/await` for asynchronous operations
- Mark types as `Sendable` when crossing actor boundaries

### Observable Pattern
- Use `@Observable` macro (not `ObservableObject`)
- Access via `@Environment(TypeName.self)` in views
- Use `@Bindable var vm = viewModel` for two-way bindings

```swift
@MainActor
@Observable
final class QuotaViewModel {
    var isLoading = false
    // ...
}

// In View:
@Environment(QuotaViewModel.self) private var viewModel
```

### Naming Conventions
- **Types**: PascalCase (`AIProvider`, `QuotaViewModel`, `StatusBarManager`)
- **Properties/Methods**: camelCase (`authFiles`, `refreshData()`)
- **Constants**: camelCase (`managementKey`)
- **Enums**: PascalCase type, camelCase cases (`case gemini`, `case claude`)
- **File names**: Match primary type name (`QuotaViewModel.swift`)

### Import Order
1. Foundation/AppKit/SwiftUI (system frameworks)
2. Third-party packages (Sparkle)
3. Local modules (if any)

```swift
import Foundation
import SwiftUI
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif
```

### Type Definitions

**Enums with raw values for API compatibility:**
```swift
enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case gemini = "gemini-cli"
    case claude = "claude"
    // ...
    var id: String { rawValue }
}
```

**Codable structs with custom CodingKeys for snake_case APIs:**
```swift
struct AuthFile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let statusMessage: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case statusMessage = "status_message"
    }
}
```

### View Structure
- Keep views focused and small
- Extract reusable components to `Views/Components/`
- Use `MARK: -` comments to organize sections
- Use computed properties for derived state

```swift
struct DashboardScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    // MARK: - Computed Properties
    
    private var isSetupComplete: Bool {
        viewModel.proxyManager.isBinaryInstalled &&
        viewModel.proxyManager.proxyStatus.running
    }
    
    // MARK: - Body
    
    var body: some View {
        ScrollView {
            // ...
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        // ...
    }
}
```

### Error Handling
- Use custom error enums conforming to `LocalizedError`
- Store error messages in ViewModel for UI display
- Log errors silently for non-critical operations

```swift
enum APIError: LocalizedError {
    case invalidURL
    case httpError(Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP error: \(code)"
        }
    }
}

// In ViewModel:
do {
    try await client.fetchData()
} catch {
    errorMessage = error.localizedDescription
}
```

### Localization
- All user-facing strings must use localization
- Use `.localized()` extension method
- Keys follow dot notation: `"nav.dashboard"`, `"action.startProxy"`

```swift
Text("nav.dashboard".localized())
Label("action.refresh".localized(), systemImage: "arrow.clockwise")
```

### Singleton Pattern
Services use shared instance pattern:

```swift
@MainActor
@Observable
final class StatusBarManager {
    static let shared = StatusBarManager()
    private init() {}
}
```

### UserDefaults
- Use `@AppStorage` for view-bound preferences
- Use `UserDefaults.standard` directly in services

```swift
// In View:
@AppStorage("autoStartProxy") private var autoStartProxy = false

// In Service:
UserDefaults.standard.set(port, forKey: "proxyPort")
```

### Color Handling
Use hex color initializer from `Models.swift`:

```swift
var color: Color {
    Color(hex: "4285F4") ?? .blue
}
```

### Comments
- Use `//` for implementation notes
- Use `///` for documentation comments on public APIs
- Use `// MARK: -` to organize code sections
- Avoid obvious comments; code should be self-documenting

## Dependencies

- **Sparkle** - Auto-update framework (Swift Package Manager)

## Configuration Files

- `Config/Debug.xcconfig` - Debug build settings
- `Config/Release.xcconfig` - Release build settings  
- `Config/Local.xcconfig.example` - Template for local overrides

## Scripts

- `scripts/build.sh` - Build release archive
- `scripts/release.sh` - Full release workflow
- `scripts/bump-version.sh` - Version management
- `scripts/notarize.sh` - Apple notarization

## Menu Bar Implementation

Uses `NSStatusItem` with `NSHostingView` for SwiftUI content:

```swift
let hostingView = NSHostingView(rootView: contentView)
button.addSubview(containerView)
```

## Key Patterns

### Async Data Refresh
```swift
func refreshData() async {
    guard let client = apiClient else { return }
    async let files = client.fetchAuthFiles()
    async let stats = client.fetchUsageStats()
    self.authFiles = try await files
    self.usageStats = try await stats
}
```

### Mode-Aware Logic
```swift
if modeManager.isQuotaOnlyMode {
    // Direct quota fetching without proxy
} else {
    // Full mode with proxy management
}
```

### Process Management
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: binaryPath)
process.arguments = ["--config", configPath]
try process.run()
```
