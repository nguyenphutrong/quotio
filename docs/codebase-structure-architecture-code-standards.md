# Quotio - Codebase Structure, Architecture, and Code Standards

> **Last Updated**: January 2, 2025  
> **Swift Version**: 6.0  
> **Minimum macOS**: 15.0 (Sequoia)

---

## Table of Contents

1. [Directory Structure](#directory-structure)
2. [Architecture Patterns](#architecture-patterns)
3. [Code Style Guidelines](#code-style-guidelines)
4. [Key Implementation Patterns](#key-implementation-patterns)

---

## Directory Structure

```
Quotio/
├── Config/
│   ├── Debug.xcconfig           # Debug build configuration
│   ├── Release.xcconfig         # Release build configuration
│   └── Local.xcconfig.example   # Template for local overrides
│
├── Quotio/
│   ├── Assets.xcassets/
│   │   ├── AccentColor.colorset/    # Accent color definition
│   │   ├── AppIcon.appiconset/      # Production app icons
│   │   ├── AppIconDev.appiconset/   # Development app icons
│   │   ├── MenuBarIcons/            # Provider icons for menu bar
│   │   │   ├── claude-menubar.imageset/
│   │   │   ├── gemini-menubar.imageset/
│   │   │   └── ... (other providers)
│   │   └── ProviderIcons/           # Provider logos for UI
│   │       ├── claude.imageset/
│   │       ├── gemini.imageset/
│   │       └── ... (other providers)
│   │
│   ├── Models/
│   │   ├── Models.swift             # Core data types
│   │   ├── AgentModels.swift        # CLI agent types
│   │   ├── AntigravityActiveAccount.swift # Antigravity account model
│   │   ├── AppMode.swift            # App mode management
│   │   └── MenuBarSettings.swift    # Menu bar settings
│   │
│   ├── Services/
│   │   ├── CLIProxyManager.swift        # Proxy lifecycle management
│   │   ├── ManagementAPIClient.swift    # HTTP client (actor)
│   │   ├── StatusBarManager.swift       # Menu bar management
│   │   ├── StatusBarMenuBuilder.swift   # Native NSMenu builder
│   │   ├── NotificationManager.swift    # User notifications
│   │   ├── UpdaterService.swift         # Sparkle integration
│   │   ├── AgentDetectionService.swift  # Agent detection
│   │   ├── AgentConfigurationService.swift # Config generation
│   │   ├── ShellProfileManager.swift    # Shell profile updates
│   │   ├── DirectAuthFileService.swift  # Direct file scanning
│   │   ├── CLIExecutor.swift            # CLI execution
│   │   ├── LanguageManager.swift        # Localization
│   │   ├── AntigravityAccountSwitcher.swift # Account switching orchestrator
│   │   ├── AntigravityDatabaseService.swift # SQLite database operations
│   │   ├── AntigravityProcessManager.swift  # IDE process lifecycle
│   │   ├── AntigravityProtobufHandler.swift # Protobuf encoding/decoding
│   │   ├── AntigravityQuotaFetcher.swift
│   │   ├── OpenAIQuotaFetcher.swift
│   │   ├── CopilotQuotaFetcher.swift
│   │   ├── ClaudeCodeQuotaFetcher.swift
│   │   ├── CursorQuotaFetcher.swift
│   │   ├── CodexCLIQuotaFetcher.swift
│   │   └── GeminiCLIQuotaFetcher.swift
│   │
│   ├── ViewModels/
│   │   ├── QuotaViewModel.swift         # Main app state
│   │   └── AgentSetupViewModel.swift    # Agent setup state
│   │
│   ├── Views/
│   │   ├── Components/
│   │   │   ├── AccountRow.swift         # Account row with switch button
│   │   │   ├── AgentCard.swift          # Agent display card
│   │   │   ├── AgentConfigSheet.swift   # Configuration sheet
│   │   │   ├── ProviderIcon.swift       # Provider icon component
│   │   │   ├── QuotaCard.swift          # Quota display card
│   │   │   ├── QuotaProgressBar.swift   # Progress bar component
│   │   │   ├── SidebarView.swift        # Navigation sidebar
│   │   │   └── SwitchAccountSheet.swift # Account switch confirmation
│   │   ├── Onboarding/
│   │   │   └── ModePickerView.swift     # Mode selection
│   │   └── Screens/
│   │       ├── DashboardScreen.swift
│   │       ├── QuotaScreen.swift
│   │       ├── ProvidersScreen.swift
│   │       ├── AgentSetupScreen.swift
│   │       ├── APIKeysScreen.swift
│   │       ├── LogsScreen.swift
│   │       └── SettingsScreen.swift
│   │
│   ├── Info.plist                   # App metadata
│   ├── Quotio.entitlements          # App entitlements
│   └── QuotioApp.swift              # App entry point
│
├── Quotio.xcodeproj/
│   ├── project.pbxproj              # Project configuration
│   └── xcshareddata/
│       └── xcschemes/
│           └── Quotio.xcscheme      # Build scheme
│
├── scripts/
│   ├── build.sh                     # Build script
│   ├── release.sh                   # Release workflow
│   ├── bump-version.sh              # Version management
│   ├── notarize.sh                  # Apple notarization
│   ├── package.sh                   # DMG packaging
│   ├── generate-appcast.sh          # Sparkle appcast
│   ├── config.sh                    # Shared configuration
│   └── ExportOptions.plist          # Archive export options
│
├── screenshots/                     # Documentation screenshots
│
├── AGENTS.md                        # Development guidelines
├── CHANGELOG.md                     # Version history
├── README.md                        # Project readme (English)
├── README.vi.md                     # Project readme (Vietnamese)
└── RELEASE.md                       # Release documentation
```

---

## Architecture Patterns

### MVVM (Model-View-ViewModel)

Quotio follows the MVVM architectural pattern with SwiftUI:

```
┌─────────────────────────────────────────────────────────────┐
│                          View Layer                          │
│  (SwiftUI Views in Views/Screens/ and Views/Components/)    │
└─────────────────────────────┬───────────────────────────────┘
                              │ @Environment(ViewModel.self)
                              │ @Bindable var vm = viewModel
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                       ViewModel Layer                        │
│  (QuotaViewModel, AgentSetupViewModel in ViewModels/)       │
│  - @Observable macro                                         │
│  - @MainActor for UI thread safety                          │
└─────────────────────────────┬───────────────────────────────┘
                              │ async/await calls
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                       Service Layer                          │
│  (CLIProxyManager, ManagementAPIClient, *Fetcher in Services/)│
│  - Singleton pattern for managers                            │
│  - Actor isolation for API clients                           │
└─────────────────────────────┬───────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        Model Layer                           │
│  (Data types in Models/)                                     │
│  - Codable for JSON serialization                            │
│  - Sendable for cross-actor transfer                         │
└─────────────────────────────────────────────────────────────┘
```

### Observable Pattern (Swift 6)

The app uses the new `@Observable` macro instead of `ObservableObject`:

```swift
// ViewModel Declaration
@MainActor
@Observable
final class QuotaViewModel {
    var isLoading = false
    var authFiles: [AuthFile] = []
    // Properties are automatically observed
}

// View Usage
struct DashboardScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    var body: some View {
        @Bindable var vm = viewModel  // For two-way bindings
        
        List(selection: $vm.currentPage) {
            // ...
        }
    }
}
```

### Actor-Based Concurrency

Thread-safe services use the `actor` keyword:

```swift
actor ManagementAPIClient {
    private let baseURL: String
    private let authKey: String
    private let session: URLSession
    
    func fetchAuthFiles() async throws -> [AuthFile] {
        // Actor isolation ensures thread safety
        let data = try await makeRequest("/auth-files")
        return try JSONDecoder().decode(AuthFilesResponse.self, from: data).files
    }
}
```

### Singleton Pattern for Managers

Long-lived services use the singleton pattern:

```swift
@MainActor
@Observable
final class StatusBarManager {
    static let shared = StatusBarManager()
    
    private var statusItem: NSStatusItem?
    
    private init() {}  // Private initializer
    
    func updateStatusBar(...) {
        // ...
    }
}
```

---

## Code Style Guidelines

### Swift Version and Concurrency

**Swift 6** with strict concurrency checking is required:

```swift
// All UI-related classes must be MainActor
@MainActor
@Observable
final class QuotaViewModel {
    // UI state
}

// Thread-safe services use actor
actor ManagementAPIClient {
    // Network operations
}

// Data types crossing actor boundaries must be Sendable
struct AuthFile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    // ...
}

// Async operations use async/await
func refreshData() async {
    let files = try await client.fetchAuthFiles()
    self.authFiles = files
}
```

### Observable Pattern

Use `@Observable` macro (not `ObservableObject`):

```swift
// Declaration
@MainActor
@Observable
final class QuotaViewModel {
    var isLoading = false
    var authFiles: [AuthFile] = []
}

// View access via @Environment
@Environment(QuotaViewModel.self) private var viewModel

// Two-way bindings via @Bindable
var body: some View {
    @Bindable var vm = viewModel
    Toggle("Auto Start", isOn: $vm.autoStart)
}
```

### Naming Conventions

| Element | Convention | Examples |
|---------|------------|----------|
| **Types** | PascalCase | `AIProvider`, `QuotaViewModel`, `StatusBarManager` |
| **Properties** | camelCase | `authFiles`, `isLoading`, `proxyStatus` |
| **Methods** | camelCase | `refreshData()`, `startProxy()`, `toggleItem(_:)` |
| **Constants** | camelCase | `managementKey`, `warningThreshold` |
| **Enum Types** | PascalCase | `AIProvider`, `AppMode`, `NavigationPage` |
| **Enum Cases** | camelCase | `case gemini`, `case claude`, `case quotaOnly` |
| **File Names** | Match primary type | `QuotaViewModel.swift`, `CLIProxyManager.swift` |

### Import Order

Organize imports in this order with blank lines between groups:

```swift
// 1. System frameworks
import Foundation
import SwiftUI
import AppKit
import ServiceManagement

// 2. Conditional imports for optional frameworks
#if canImport(Sparkle)
import Sparkle
#endif

// 3. Local modules (if any)
// (Currently none in this project)
```

### Type Definitions

**Enums with Raw Values for API Compatibility**:

```swift
enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case gemini = "gemini-cli"
    case claude = "claude"
    case codex = "codex"
    case copilot = "github-copilot"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .gemini: return "Gemini CLI"
        case .claude: return "Claude Code"
        case .codex: return "Codex (OpenAI)"
        case .copilot: return "GitHub Copilot"
        }
    }
}
```

**Codable Structs with CodingKeys for snake_case APIs**:

```swift
struct AuthFile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String
    let statusMessage: String?
    let runtimeOnly: Bool?
    let accountType: String?
    let createdAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, provider
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
        case accountType = "account_type"
        case createdAt = "created_at"
    }
}
```

### View Structure

Organize views with `MARK: -` comments:

```swift
struct DashboardScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    // MARK: - Computed Properties
    
    private var isSetupComplete: Bool {
        viewModel.proxyManager.isBinaryInstalled &&
        viewModel.proxyManager.proxyStatus.running
    }
    
    private var totalAccounts: Int {
        viewModel.authFiles.count
    }
    
    // MARK: - Body
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSection
                statsSection
                quickActionsSection
            }
            .padding()
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack {
            Text("Dashboard")
                .font(.title)
            Spacer()
        }
    }
    
    private var statsSection: some View {
        // ...
    }
    
    private var quickActionsSection: some View {
        // ...
    }
}
```

### Error Handling

Use custom error enums conforming to `LocalizedError`:

```swift
enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .httpError(let code): return "HTTP error: \(code)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        }
    }
}

// Usage in ViewModel
func refreshData() async {
    do {
        self.authFiles = try await client.fetchAuthFiles()
    } catch {
        // Store for UI display
        self.errorMessage = error.localizedDescription
    }
}
```

### Localization

All user-facing strings must use localization:

```swift
// Extension method usage
Text("nav.dashboard".localized())
Label("action.refresh".localized(), systemImage: "arrow.clockwise")

// Key format: category.subcategory.item
// Examples:
// - nav.dashboard
// - action.startProxy
// - status.running
// - settings.port
// - error.networkError
```

### UserDefaults Usage

Use `@AppStorage` in views, `UserDefaults.standard` in services:

```swift
// In Views - for reactive properties
struct SettingsScreen: View {
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @AppStorage("loggingToFile") private var loggingToFile = true
    
    var body: some View {
        Toggle("Auto Start", isOn: $autoStartProxy)
    }
}

// In Services - for direct access
final class CLIProxyManager {
    init() {
        let savedPort = UserDefaults.standard.integer(forKey: "proxyPort")
        if savedPort > 0 && savedPort < 65536 {
            self.proxyStatus.port = UInt16(savedPort)
        }
    }
    
    var port: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(newValue), forKey: "proxyPort")
        }
    }
}
```

### Color Handling

Use hex color initializer from `Models.swift`:

```swift
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}

// Usage in AIProvider
var color: Color {
    switch self {
    case .gemini: return Color(hex: "4285F4") ?? .blue
    case .claude: return Color(hex: "D97706") ?? .orange
    case .codex: return Color(hex: "10A37F") ?? .green
    }
}
```

### Comments

Use appropriate comment styles:

```swift
// Single-line implementation notes
let port: UInt16 = 8317  // Default proxy port

/// Documentation comments for public APIs
/// - Parameter provider: The AI provider to authenticate
/// - Returns: OAuth URL response or error
func getOAuthURL(for provider: AIProvider) async throws -> OAuthURLResponse

// MARK: - Section Headers
// Use to organize code sections

// MARK: - Computed Properties
// MARK: - Body
// MARK: - Subviews
// MARK: - Private Methods

// Avoid obvious comments
// BAD: Increment counter by 1
// GOOD: (no comment needed for self-explanatory code)
```

---

## Key Implementation Patterns

### Async Data Refresh with Parallel Requests

```swift
func refreshData() async {
    guard let client = apiClient else { return }
    
    do {
        // Parallel async requests
        async let files = client.fetchAuthFiles()
        async let stats = client.fetchUsageStats()
        async let keys = client.fetchAPIKeys()
        
        // Await all results
        self.authFiles = try await files
        self.usageStats = try await stats
        self.apiKeys = try await keys
    } catch {
        if !Task.isCancelled {
            errorMessage = error.localizedDescription
        }
    }
}
```

### Mode-Aware Logic

```swift
func initialize() async {
    if modeManager.isQuotaOnlyMode {
        // Quota-only mode: Direct quota fetching
        await loadDirectAuthFiles()
        await refreshQuotasDirectly()
        startQuotaOnlyAutoRefresh()
    } else {
        // Full mode: Proxy management
        if autoStartProxy && proxyManager.isBinaryInstalled {
            await startProxy()
        }
    }
}
```

### Process Management

```swift
func start() async throws {
    guard isBinaryInstalled else {
        throw ProxyError.binaryNotFound
    }
    
    isStarting = true
    defer { isStarting = false }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = ["-config", configPath]
    
    // Set up environment
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    process.environment = environment
    
    // Termination handler
    process.terminationHandler = { terminatedProcess in
        let status = terminatedProcess.terminationStatus
        Task { @MainActor [weak self] in
            self?.proxyStatus.running = false
            if status != 0 {
                self?.lastError = "Process exited with code: \(status)"
            }
        }
    }
    
    try process.run()
    self.process = process
    
    // Wait for startup
    try await Task.sleep(nanoseconds: 1_500_000_000)
    
    if process.isRunning {
        proxyStatus.running = true
    } else {
        throw ProxyError.startupFailed
    }
}
```

### Menu Bar Integration with NSHostingView

```swift
func updateStatusBar(
    items: [MenuBarQuotaDisplayItem],
    colorMode: MenuBarColorMode,
    isRunning: Bool,
    showMenuBarIcon: Bool,
    showQuota: Bool,
    menuContentProvider: @escaping () -> AnyView
) {
    guard showMenuBarIcon else {
        removeStatusItem()
        return
    }
    
    if statusItem == nil {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
    
    // Configure popover
    popover?.contentViewController = NSHostingController(rootView: menuContentProvider())
    
    // Create SwiftUI content view
    let contentView: AnyView
    if !showQuota || !isRunning || items.isEmpty {
        contentView = AnyView(StatusBarDefaultView(isRunning: isRunning))
    } else {
        contentView = AnyView(StatusBarQuotaView(items: items, colorMode: colorMode))
    }
    
    // Wrap in NSHostingView
    let hostingView = NSHostingView(rootView: contentView)
    hostingView.setFrameSize(hostingView.intrinsicContentSize)
    
    // Add to status bar button
    let containerView = StatusBarContainerView(...)
    containerView.addSubview(hostingView)
    button.addSubview(containerView)
}
```

### OAuth Polling Pattern

```swift
private func pollOAuthStatus(state: String, provider: AIProvider) async {
    guard let client = apiClient else { return }
    
    // Poll for up to 2 minutes (60 iterations × 2 seconds)
    for _ in 0..<60 {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        
        do {
            let response = try await client.pollOAuthStatus(state: state)
            
            switch response.status {
            case "ok":
                oauthState = OAuthState(provider: provider, status: .success)
                await refreshData()
                return
            case "error":
                oauthState = OAuthState(provider: provider, status: .error, error: response.error)
                return
            default:
                continue  // Keep polling
            }
        } catch {
            continue  // Retry on network errors
        }
    }
    
    oauthState = OAuthState(provider: provider, status: .error, error: "OAuth timeout")
}
```

### Auto-Refresh Task Pattern

```swift
private var refreshTask: Task<Void, Never>?

private func startAutoRefresh() {
    refreshTask?.cancel()
    refreshTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)  // 15 seconds
            await refreshData()
        }
    }
}

func stopProxy() {
    refreshTask?.cancel()
    refreshTask = nil
    proxyManager.stop()
}
```

### Notification Throttling Pattern

```swift
func notifyQuotaLow(provider: String, account: String, remainingPercent: Double) {
    let key = "\(provider)_\(account)"
    let lastNotified = lastQuotaNotifications[key] ?? .distantPast
    
    // Only notify once per hour
    guard Date().timeIntervalSince(lastNotified) > 3600 else { return }
    
    let content = UNMutableNotificationContent()
    content.title = "Low Quota Alert"
    content.body = "\(provider) account \(account) has \(Int(remainingPercent))% remaining"
    content.sound = .default
    
    let request = UNNotificationRequest(
        identifier: "quota-\(key)",
        content: content,
        trigger: nil
    )
    
    UNUserNotificationCenter.current().add(request)
    lastQuotaNotifications[key] = Date()
}
```

### Configuration Generation Pattern

```swift
func generateConfiguration(
    agent: CLIAgent,
    config: AgentConfiguration,
    mode: ConfigurationMode,
    storageOption: ConfigStorageOption = .jsonOnly,
    detectionService: AgentDetectionService
) async throws -> AgentConfigResult {
    
    switch agent {
    case .claudeCode:
        return try await generateClaudeCodeConfig(config, mode: mode, storageOption: storageOption)
    case .codexCLI:
        return try await generateCodexConfig(config, mode: mode)
    case .geminiCLI:
        return generateGeminiCLIConfig(config, mode: mode)
    case .ampCLI:
        return try await generateAmpConfig(config, mode: mode)
    case .openCode:
        return try await generateOpenCodeConfig(config, mode: mode)
    case .factoryDroid:
        return try await generateFactoryDroidConfig(config, mode: mode)
    }
}
```

---

## Testing Guidelines

> **Note**: This project currently has no automated tests.

When implementing features, test manually:

1. **Build Verification**:
   ```bash
   xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build
   ```

2. **UI Testing**:
   - Run app in Xcode (`Cmd + R`)
   - Test in both light and dark mode
   - Verify all screens render correctly

3. **Menu Bar Testing**:
   - Check icon displays correctly
   - Verify popover opens/closes
   - Test quota display updates

4. **Localization Testing**:
   - Switch system language to Vietnamese
   - Verify all strings are translated

5. **Mode Testing**:
   - Test Full Mode with proxy
   - Test Quota-Only Mode without proxy
   - Test mode switching

---

## Build Commands Reference

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

# Check for compile errors
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build 2>&1 | head -50
```
