# Provider Authentication Architecture

> **Last Updated**: January 10, 2026  
> **Branch**: feat/universal-provider-architecture  
> **Status**: Feature in development

---

## Table of Contents

1. [Overview](#overview)
2. [Authentication Mechanisms](#authentication-mechanisms)
3. [Architecture Diagram](#architecture-diagram)
4. [CLIProxyAPI OAuth Flow](#cliproxyapi-oauth-flow)
5. [UniversalProvider + KeychainService](#universalprovider--keychainservice)
6. [Data Flow](#data-flow)
7. [Storage Locations](#storage-locations)
8. [Key Components](#key-components)

---

## Overview

Quotio supports two complementary authentication mechanisms for AI providers:

| Mechanism | Purpose | Providers | Storage |
|-----------|---------|-----------|---------|
| **CLIProxyAPI OAuth** | Browser-based OAuth for official providers | Gemini, Claude, Codex, Qwen, iFlow, Antigravity, Copilot, Kiro | `~/.cli-proxy-api/*.json` |
| **UniversalProvider + Keychain** | API key storage for custom/direct providers | OpenRouter, direct Anthropic/OpenAI API, custom endpoints | macOS Keychain |

These mechanisms do **NOT conflict**. They serve different use cases and can coexist.

---

## Authentication Mechanisms

### 1. CLIProxyAPI OAuth (Existing)

For official AI provider accounts that use OAuth:

```
User clicks "Add Account"
         ↓
CLIProxyManager.runAuthCommand(provider)
         ↓
CLIProxyAPI binary opens browser → Provider OAuth page
         ↓
User authenticates in browser
         ↓
CLIProxyAPI receives callback, stores token
         ↓
Auth file created: ~/.cli-proxy-api/{provider}_{email}.json
         ↓
QuotaViewModel polls ManagementAPIClient.fetchAuthFiles()
         ↓
Account appears in Quotio UI
```

**Supported Providers:**
- Google Gemini (`/gemini-cli-auth-url`)
- Anthropic Claude (`/anthropic-auth-url`)
- OpenAI Codex (`/codex-auth-url`)
- Qwen (`/qwen-auth-url`)
- iFlow (`/iflow-auth-url`)
- Antigravity (`/antigravity-auth-url`)
- GitHub Copilot (CLI-based auth)
- Kiro (CLI-based auth)

### 2. UniversalProvider + KeychainService (New Feature)

For providers that use API keys (no OAuth):

```
User adds UniversalProvider (name, baseURL, modelId)
         ↓
User enters API key
         ↓
KeychainService.storeByAccount("universal.{uuid}", key)
         ↓
UniversalProviderService stores provider metadata in UserDefaults
         ↓
Provider available for CLI agent configuration
```

**Use Cases:**
- OpenRouter API access
- Direct Anthropic API (with personal API key)
- Direct OpenAI API (with personal API key)
- Custom LLM endpoints (self-hosted, enterprise)

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Quotio App                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      QuotaViewModel                              │    │
│  │  - Orchestrates all auth operations                              │    │
│  │  - Holds authFiles from CLIProxyAPI                              │    │
│  │  - References UniversalProviderService                           │    │
│  └────────────────────────┬────────────────────────────────────────┘    │
│                           │                                              │
│           ┌───────────────┴───────────────┐                             │
│           ▼                               ▼                              │
│  ┌─────────────────────┐       ┌─────────────────────────┐              │
│  │  CLIProxyManager    │       │ UniversalProviderService │              │
│  │  (OAuth Flow)       │       │ (API Key Flow)           │              │
│  └─────────┬───────────┘       └───────────┬─────────────┘              │
│            │                               │                             │
│            ▼                               ▼                             │
│  ┌─────────────────────┐       ┌─────────────────────────┐              │
│  │ ManagementAPIClient │       │    KeychainService      │              │
│  │ (HTTP to CLIProxyAPI)│       │ (macOS Keychain API)    │              │
│  └─────────┬───────────┘       └───────────┬─────────────┘              │
│            │                               │                             │
└────────────┼───────────────────────────────┼─────────────────────────────┘
             │                               │
             ▼                               ▼
    ┌─────────────────┐           ┌─────────────────────┐
    │  CLIProxyAPI    │           │   macOS Keychain    │
    │  Binary         │           │   (Secure Enclave)  │
    └────────┬────────┘           └─────────────────────┘
             │
             ▼
    ┌─────────────────────────────────────┐
    │  ~/.cli-proxy-api/                  │
    │  ├── gemini_user@gmail.com.json     │
    │  ├── claude_user@email.com.json     │
    │  └── config.json                    │
    └─────────────────────────────────────┘
```

---

## CLIProxyAPI OAuth Flow

### Components Involved

| Component | Role |
|-----------|------|
| `CLIProxyManager` | Manages proxy lifecycle, runs auth commands |
| `ManagementAPIClient` | HTTP client to communicate with CLIProxyAPI |
| `QuotaViewModel` | Polls for auth status, updates UI |

### Detailed Flow

```swift
// 1. User initiates OAuth
CLIProxyManager.shared.runAuthCommand(for: .gemini)

// 2. CLIProxyAPI returns device code and URL
// Response: { "url": "https://...", "device_code": "ABC123" }

// 3. User opens URL, authenticates in browser

// 4. Quotio polls for completion
while !authenticated {
    let status = try await apiClient.checkOAuthStatus(deviceCode)
    if status.isComplete {
        authenticated = true
    }
    try await Task.sleep(for: .seconds(2))
}

// 5. Auth file created by CLIProxyAPI
// ~/.cli-proxy-api/gemini_user@gmail.com.json

// 6. Quotio fetches updated auth files
let authFiles = try await apiClient.fetchAuthFiles()
```

### Auth File Structure

```json
{
  "provider": "gemini",
  "email": "user@gmail.com",
  "auth_index": "gemini_user@gmail.com",
  "quota_used": 150000,
  "quota_limit": 1000000,
  "status_message": "Active",
  "is_cooling": false
}
```

---

## UniversalProvider + KeychainService

### Components Involved

| Component | Role |
|-----------|------|
| `UniversalProviderService` | CRUD for providers, active state tracking |
| `KeychainService` | Secure API key storage via macOS Keychain |
| `CommonConfigService` | Extracts/applies config snippets for CLI agents |

### UniversalProvider Model

```swift
struct UniversalProvider: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String           // "OpenRouter", "My Custom API"
    var baseURL: String        // "https://openrouter.ai/api/v1"
    var modelId: String        // "anthropic/claude-3.5-sonnet"
    var isBuiltIn: Bool        // true for predefined providers
    var iconAssetName: String? // Asset catalog icon name
    var color: String          // Hex color "#6366F1"
    var supportedAgents: Set<String>  // Which CLI agents can use this
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
}
```

### Built-in Providers

```swift
static let builtInProviders: [UniversalProvider] = [
    UniversalProvider(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Anthropic",
        baseURL: "https://api.anthropic.com",
        modelId: "claude-sonnet-4-20250514",
        isBuiltIn: true,
        iconAssetName: "claude",
        color: "#D97706"
    ),
    // OpenAI, Google Gemini, OpenRouter...
]
```

### KeychainService Operations

```swift
actor KeychainService {
    // Store API key for a provider
    func storeByAccount(_ account: String, key: String) throws
    
    // Retrieve API key
    func retrieveByAccount(_ account: String) throws -> String?
    
    // Delete API key
    func deleteByAccount(_ account: String) throws
    
    // Check if key exists
    func existsByAccount(_ account: String) -> Bool
    
    // List all universal provider accounts
    func listUniversalProviderAccounts() throws -> [String]
}

// Account naming convention: "universal.{provider-uuid}"
// Example: "universal.550e8400-e29b-41d4-a716-446655440000"
```

### API Key Validation

```swift
func validateAPIKey(_ key: String, for provider: UniversalProvider) -> ValidationResult {
    // Empty check
    guard !key.isEmpty else { return .invalid("API key cannot be empty") }
    
    // Length check
    guard key.count >= 8 else { return .invalid("API key appears too short") }
    
    // Provider-specific prefix warnings
    let baseURL = provider.baseURL.lowercased()
    if baseURL.contains("anthropic") && !key.hasPrefix("sk-ant-") {
        return .warning("Anthropic keys typically start with 'sk-ant-'")
    }
    if baseURL.contains("openai") && !key.hasPrefix("sk-") {
        return .warning("OpenAI keys typically start with 'sk-'")
    }
    if baseURL.contains("openrouter") && !key.hasPrefix("sk-or-") {
        return .warning("OpenRouter keys typically start with 'sk-or-'")
    }
    
    return .valid
}
```

---

## Data Flow

### Adding an OAuth Provider Account

```
1. User: Settings → Providers → Gemini → "Add Account"
2. CLIProxyManager.runAuthCommand(for: .gemini)
3. CLIProxyAPI opens browser with OAuth URL
4. User authenticates with Google
5. CLIProxyAPI receives token, creates auth file
6. QuotaViewModel.fetchAuthFiles() picks up new account
7. UI updates to show new account
```

### Adding a UniversalProvider with API Key

```
1. User: Settings → Custom Providers → "Add Provider"
2. User fills: name, baseURL, modelId
3. UniversalProviderService.addProvider(provider)
4. User enters API key
5. KeychainService.storeByAccount("universal.{id}", key)
6. Provider available for agent configuration
```

### CLI Agent Using Provider

```
1. User: Agents → Claude Code → Configure
2. AgentConfigurationService generates config with:
   - If OAuth provider: points to CLIProxyAPI endpoint
   - If UniversalProvider: retrieves API key from Keychain, injects into config
3. Config written to agent's config file
4. CLI agent uses provider for AI requests
```

---

## Storage Locations

### CLIProxyAPI OAuth Data

| Path | Purpose |
|------|---------|
| `~/.cli-proxy-api/` | Auth files directory |
| `~/.cli-proxy-api/config.json` | CLIProxyAPI configuration |
| `~/.cli-proxy-api/{provider}_{email}.json` | Individual auth files |

### UniversalProvider Data

| Location | Data |
|----------|------|
| `UserDefaults["universalProviders"]` | Provider metadata (JSON encoded) |
| `UserDefaults["universalProviderActiveState"]` | Which provider active per agent |
| macOS Keychain (`com.quotio.api-keys`) | API keys (secure) |

### CLI Agent Configs

| Agent | Config Path |
|-------|-------------|
| Claude Code | `~/.config/claude-code/config.json` |
| Codex CLI | `~/.codex/config.toml` |
| Gemini CLI | `~/.config/gemini/config.json` |
| Amp CLI | `~/.config/amp/config.json` |
| OpenCode | `~/.config/opencode/config.json` |

---

## Key Components

### CLIProxyManager

```swift
@MainActor @Observable
final class CLIProxyManager {
    static let shared = CLIProxyManager()
    
    // Proxy lifecycle
    func start() async throws
    func stop()
    func toggle() async
    
    // OAuth commands
    func runAuthCommand(for provider: AIProvider) async -> AuthCommandResult
    func checkAuthStatus(deviceCode: String) async throws -> OAuthStatusResponse
    
    // Binary management
    func downloadAndInstall() async throws
    var isInstalled: Bool { get }
    var isRunning: Bool { get }
}
```

### ManagementAPIClient

```swift
actor ManagementAPIClient {
    // Auth file operations
    func fetchAuthFiles() async throws -> [AuthFile]
    func deleteAuthFile(authIndex: String) async throws
    
    // OAuth flow
    func getOAuthURL(for provider: AIProvider) async throws -> OAuthURLResponse
    func checkOAuthStatus(deviceCode: String) async throws -> OAuthStatusResponse
    
    // Settings
    func fetchSettings() async throws -> ProxySettings
    func updateSettings(_ settings: ProxySettings) async throws
    
    // Statistics
    func fetchUsageStats() async throws -> UsageStatsResponse
}
```

### UniversalProviderService

```swift
@MainActor @Observable
final class UniversalProviderService {
    static let shared = UniversalProviderService()
    
    // Provider access
    var providers: [UniversalProvider]
    var enabledProviders: [UniversalProvider]
    var customProviders: [UniversalProvider]
    var builtInProviders: [UniversalProvider]
    
    // CRUD
    func addProvider(_ provider: UniversalProvider)
    func updateProvider(_ provider: UniversalProvider)
    func removeProvider(id: UUID)
    func toggleProvider(id: UUID)
    
    // Active state (which provider for which agent)
    func setActive(_ provider: UniversalProvider, for agent: CLIAgent)
    func clearActive(for agent: CLIAgent)
    func activeProvider(for agent: CLIAgent) -> UniversalProvider?
    
    // API Key management (delegates to KeychainService)
    func storeAPIKey(_ key: String, for provider: UniversalProvider) async throws -> ValidationResult
    func retrieveAPIKey(for provider: UniversalProvider) async throws -> String?
    func deleteAPIKey(for provider: UniversalProvider) async throws
    func hasAPIKey(for provider: UniversalProvider) async -> Bool
}
```

### KeychainService

```swift
actor KeychainService {
    static let shared = KeychainService()
    
    private let serviceName = "com.quotio.api-keys"
    
    // Provider-based operations (legacy, for AIProvider enum)
    func store(key: String, for provider: AIProvider, account: String?) throws
    func retrieve(for provider: AIProvider, account: String?) throws -> String?
    func delete(for provider: AIProvider, account: String?) throws
    
    // Account-based operations (for UniversalProvider)
    func storeByAccount(_ account: String, key: String) throws
    func retrieveByAccount(_ account: String) throws -> String?
    func deleteByAccount(_ account: String) throws
    func existsByAccount(_ account: String) -> Bool
    
    // Validation
    func validate(key: String, for provider: AIProvider) -> ValidationResult
}
```

### CommonConfigService

```swift
actor CommonConfigService {
    static let shared = CommonConfigService()
    
    // Extract common config fields from an agent's config
    func extractCommonConfig(from agent: CLIAgent) throws -> [String: Any]
    
    // Apply common config to an agent
    func applyCommonConfig(_ config: [String: Any], to agent: CLIAgent) throws
    
    // Stored snippets for reuse
    func getStoredSnippet(for agent: CLIAgent) -> String?
    func storeSnippet(_ snippet: String, for agent: CLIAgent)
}
```

---

## Security Considerations

### Keychain Security

- API keys stored in macOS Keychain with `kSecAttrAccessibleAfterFirstUnlock`
- Keys accessible only after device unlock (boot)
- Keys tied to app's code signature
- No plaintext storage on disk

### OAuth Token Security

- Tokens managed by CLIProxyAPI binary
- Stored in auth files with restricted permissions
- Refresh tokens handled automatically
- Quotio never sees raw OAuth tokens

### Best Practices

1. **Never log API keys** - Only log validation status
2. **Validate before store** - Catch obviously invalid keys early
3. **Secure deletion** - Remove from Keychain when provider deleted
4. **No clipboard persistence** - Clear clipboard after paste (future enhancement)

---

## Future Enhancements

1. **API Key Rotation** - Track key age, prompt for refresh
2. **Key Health Checks** - Validate keys periodically with test requests
3. **Import/Export** - Encrypted backup of provider configurations
4. **Team Sharing** - Share provider configs (without keys) across team

---

*Document generated for feat/universal-provider-architecture branch*
