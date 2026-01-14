# Services Layer

30+ services implementing business logic, API clients, daemon IPC, and system integrations.

## Architecture

**Current Architecture (January 2026):**
- **Local Mode**: Swift app communicates with quotio-cli daemon via IPC (Unix Socket)
- **Remote Mode**: Swift app uses ManagementAPIClient for HTTP communication with remote proxy servers

Three concurrency patterns used:

| Pattern | Count | Use Case |
|---------|-------|----------|
| `@MainActor @Observable` | 11+ | UI-bound state (DaemonProxyConfigService, StatusBarManager) |
| `actor` | 13+ | Thread-safe async (API clients, quota fetchers, ManagementAPIClient) |
| Singleton (`static let shared`) | 12+ | App-wide coordination (DaemonManager, services) |

## Where to Look

| Task | File | Pattern |
|------|------|---------|
| Add IPC method | `DaemonIPCClient.swift` + `quotio-cli/src/services/daemon/service.ts` | IPC protocol |
| Add daemon service | Create `Daemon*Service.swift` | Singleton wrapping DaemonIPCClient |
| Add quota fetcher | Create `*QuotaFetcher.swift` | Actor, see `ClaudeCodeQuotaFetcher` |
| ~~Add API endpoint~~ | **DEPRECATED** - Use daemon IPC instead | ~~Actor methods~~ |
| Menu bar changes | `StatusBarManager.swift` + `StatusBarMenuBuilder.swift` | Singleton + builder |
| Proxy lifecycle | `CLIProxyManager.swift` | `start()`, `stop()`, `toggle()` |
| Auth commands | `DaemonAuthService.swift` | Daemon IPC methods |
| Binary management | `ProxyStorageManager.swift` | Versioned storage with symlinks |

## Service Categories

### Daemon IPC Services (Local Mode)
- `DaemonIPCClient` - Unix Socket IPC client for quotio-cli daemon
- `DaemonManager` - Daemon lifecycle management and health checks
- `DaemonProxyConfigService` - Proxy configuration via daemon
- `DaemonAuthService` - Auth file operations via daemon
- `DaemonQuotaService` - Quota and stats via daemon
- `DaemonAPIKeysService` - API key management via daemon
- `DaemonLogsService` - Log fetching and clearing via daemon
- `DaemonProxyService` - Proxy health and version checks via daemon
- `DaemonAgentService` - Agent detection and configuration via daemon
- `DaemonConfigService` - App config storage via daemon
- `DaemonTunnelService` - Tunnel management via daemon

### Core Infrastructure
- `CLIProxyManager` - Proxy process lifecycle, binary download, auth commands
- `ProxyBridge` - TCP bridge layer, forces `Connection: close`
- `ProxyStorageManager` - Versioned binary storage, SHA256 verification
- `CompatibilityChecker` - Version compatibility validation

### API Clients (Remote Mode Only)
- `ManagementAPIClient` - **DEPRECATED for local use** - HTTP client for remote CLIProxyAPI servers only (actor)

### Quota Fetchers (all actors)
| Fetcher | Provider | Method |
|---------|----------|--------|
| `AntigravityQuotaFetcher` | Antigravity | Protobuf DB injection |
| `ClaudeCodeQuotaFetcher` | Claude Code | Filesystem auth scan |
| `CopilotQuotaFetcher` | GitHub Copilot | OAuth API |
| `CursorQuotaFetcher` | Cursor IDE | SQLite direct read |
| `TraeQuotaFetcher` | Trae IDE | SQLite direct read |
| `OpenAIQuotaFetcher` | OpenAI/Codex | OAuth API |
| `GeminiCLIQuotaFetcher` | Gemini CLI | Filesystem scan |
| `CodexCLIQuotaFetcher` | Codex CLI | Filesystem scan |

### Agent Configuration
- `AgentDetectionService` - Detects installed CLI agents
- `AgentConfigurationService` - Generates and applies agent configs
- `ShellProfileManager` - Modifies shell profiles (.zshrc, .bashrc)

### UI Services
- `StatusBarManager` - Menu bar icon and state (singleton)
- `StatusBarMenuBuilder` - NSMenu construction
- `NotificationManager` - macOS notifications
- `LanguageManager` - Localization with String Catalogs

### Antigravity Suite
- `AntigravityAccountSwitcher` - Account switching orchestration
- `AntigravityDatabaseService` - SQLite operations
- `AntigravityProcessManager` - IDE process management
- `AntigravityProtobufHandler` - Protobuf encoding/decoding

## Conventions

### Creating a New Service

**Singleton (UI-bound):**
```swift
@MainActor @Observable
final class MyService {
    static let shared = MyService()
    private init() {}
    
    var state: String = ""
    
    func doSomething() async { ... }
}
```

**Actor (thread-safe):**
```swift
actor MyFetcher {
    func fetch() async throws -> Data {
        // Safe concurrent access
    }
}
```

### API Client Pattern
```swift
actor MyAPIClient {
    private let session: URLSession
    
    func fetchData() async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            throw APIError.httpError(statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
```

### Quota Fetcher Template
```swift
actor NewProviderQuotaFetcher {
    func fetchQuota() async throws -> ProviderQuota {
        // 1. Locate auth file/database
        // 2. Extract credentials
        // 3. Call API or parse local data
        // 4. Return normalized ProviderQuota
    }
}
```

## Critical Rules

- **DaemonIPCClient**: Local mode ONLY - cannot work over network (Unix Socket limitation)
- **ManagementAPIClient**: Remote mode ONLY - deprecated for local use
- **CLIProxyManager**: Base URL always points to CLIProxyAPI directly
- **ProxyStorageManager**: Never delete current version symlink
- **ProxyBridge**: Target host always localhost
- **DaemonManager**: Health check before all IPC operations

## Dependencies Between Services

**Local Mode:**
```
QuotaViewModel
├── DaemonQuotaService → DaemonIPCClient → quotio-cli daemon → CLIProxyAPI
├── DaemonAuthService
├── All QuotaFetchers
├── DirectAuthFileService
├── NotificationManager
└── RequestTracker

SettingsScreen
└── DaemonProxyConfigService → DaemonIPCClient → quotio-cli daemon

LogsViewModel
└── DaemonLogsService → DaemonIPCClient → quotio-cli daemon
```

**Remote Mode:**
```
QuotaViewModel
├── ManagementAPIClient (HTTP) → Remote CLIProxyAPI server
├── All QuotaFetchers
├── DirectAuthFileService
├── NotificationManager
└── RequestTracker
```

**Core Services:**
```
CLIProxyManager
├── ProxyBridge
├── ProxyStorageManager
└── CompatibilityChecker

StatusBarManager
└── StatusBarMenuBuilder

DaemonManager
├── DaemonIPCClient
└── Health check logic
```
