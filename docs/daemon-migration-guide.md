# Daemon Architecture Migration Guide

**Last Updated:** January 14, 2026
**Migration Status:** ✅ Complete

## Overview

Quotio has migrated from direct HTTP communication with CLIProxyAPI to a **daemon-based IPC architecture**. This guide explains the changes, their rationale, and how to work with the new system.

## Architecture Change

### Before (Deprecated)
```
Swift App → ManagementAPIClient (HTTP) → CLIProxyAPI (localhost:18317)
```

### After (Current)
```
Local Mode:
Swift App → DaemonIPCClient (Unix Socket) → quotio-cli daemon → CLIProxyAPI

Remote Mode:
Swift App → ManagementAPIClient (HTTP) → Remote CLIProxyAPI Server
```

## Why This Change?

### Benefits

1. **Unified Interface** - One daemon serves multiple clients (Swift macOS, Tauri Windows/Linux)
2. **Better Performance** - Unix socket IPC is faster than HTTP for local communication
3. **Simpler State Management** - Daemon maintains single source of truth
4. **Cross-platform Foundation** - Enables Tauri app without duplicating HTTP logic
5. **Reduced Memory** - Swift app delegates heavy operations to daemon process

### Trade-offs

- **Local Only** - IPC cannot work over network (requires ManagementAPIClient for remote mode)
- **Daemon Dependency** - Swift app requires quotio-cli daemon to be running
- **Two Code Paths** - Maintain both IPC (local) and HTTP (remote) implementations

## New Service Architecture

### Daemon Services (Local Mode)

| Service | Purpose | IPC Methods Used |
|---------|---------|------------------|
| `DaemonManager` | Daemon lifecycle, health checks | `daemon.health`, `daemon.ping` |
| `DaemonIPCClient` | Low-level IPC communication | All 58 IPC methods |
| `DaemonProxyConfigService` | Proxy configuration | `proxyConfig.get`, `proxyConfig.set`, `proxyConfig.getAll` |
| `DaemonAuthService` | Auth file operations | `auth.list`, `auth.models`, `auth.delete`, `auth.deleteAll` |
| `DaemonQuotaService` | Quota and stats | `stats.get`, `quota.fetch` |
| `DaemonAPIKeysService` | API key management | `apiKeys.list`, `apiKeys.add`, `apiKeys.delete` |
| `DaemonLogsService` | Log operations | `logs.fetch`, `logs.clear` |
| `DaemonProxyService` | Proxy health/version | `proxy.healthCheck`, `proxy.latestVersion` |
| `DaemonAgentService` | Agent detection | `agents.detect`, `agents.configure` |
| `DaemonConfigService` | App config storage | `config.get`, `config.set` |
| `DaemonTunnelService` | Tunnel management | `tunnel.start`, `tunnel.stop`, `tunnel.status` |

### ManagementAPIClient (Remote Mode Only)

**Status:** `@available(*, deprecated, message: "Use DaemonIPCClient instead")`

Still used for **remote mode only** where IPC cannot reach remote servers over network.

## Migration Patterns

### Before: Direct HTTP API Call

```swift
// DEPRECATED - Don't use for local mode
guard let apiClient = viewModel.apiClient else { return }
let config = try await apiClient.fetchConfig()
```

### After: IPC via Daemon Service

```swift
// For local mode
let proxyConfigService = DaemonProxyConfigService.shared
let config = try await proxyConfigService.fetchAllConfig()
```

### Handling Both Modes

```swift
private func loadConfig() async {
    if usesDaemonIPC {
        // Local mode: Use daemon service
        if let config = await proxyConfigService.fetchAllConfig() {
            self.debugMode = config.debug ?? false
            self.routingStrategy = config.routingStrategy ?? "round-robin"
        }
    } else {
        // Remote mode: Use ManagementAPIClient
        guard let apiClient = viewModel.apiClient else { return }
        let config = try await apiClient.fetchConfig()
        self.debugMode = config.debug ?? false
        self.routingStrategy = try await apiClient.getRoutingStrategy()
    }
}
```

## Common Operations

### 1. Fetch Proxy Configuration

```swift
let service = DaemonProxyConfigService.shared

// Get all config
let config = try await service.fetchAllConfig()

// Get specific values
let debugMode = try await service.getDebug()
let strategy = try await service.getRoutingStrategy()
let proxyURL = try await service.getProxyURL()
```

### 2. Manage Auth Files

```swift
let service = DaemonAuthService.shared

// List auth files
let files = try await service.listAuthFiles()

// Get models for specific auth
let models = try await service.getAuthFileModels(name: "my-auth.json")

// Delete auth file
try await service.deleteAuthFile(name: "my-auth.json")
```

### 3. Manage API Keys

```swift
let service = DaemonAPIKeysService.shared

// List keys
let keys = try await service.listAPIKeys()

// Add key
let newKey = try await service.addAPIKey("sk-...")

// Delete key
try await service.deleteAPIKey("sk-...")
```

### 4. Fetch Logs

```swift
let service = DaemonLogsService.shared

// Fetch recent logs
let entries = await service.fetchLogs(after: lastId)

// Clear logs
try await service.clearLogs()
```

### 5. Check Daemon Health

```swift
let manager = DaemonManager.shared

// Check if daemon is healthy
let isHealthy = await manager.checkHealth()

// Start daemon if not running
if !isHealthy {
    await manager.startDaemon()
}
```

## IPC Protocol

### Request Format

```typescript
interface IPCRequest {
    id: string           // Unique request ID
    method: string       // IPC method (e.g., "auth.list", "proxyConfig.get")
    params?: unknown     // Optional parameters
}
```

### Response Format

```typescript
interface IPCResponse {
    id: string           // Matches request ID
    success: boolean     // Operation success status
    result?: unknown     // Result data if successful
    error?: string       // Error message if failed
}
```

### Available IPC Methods (58 total)

**Daemon:**
- `daemon.health`, `daemon.ping`

**Auth:**
- `auth.list`, `auth.models`, `auth.delete`, `auth.deleteAll`

**Proxy Config:**
- `proxyConfig.get`, `proxyConfig.set`, `proxyConfig.getAll`

**API Keys:**
- `apiKeys.list`, `apiKeys.add`, `apiKeys.delete`

**Logs:**
- `logs.fetch`, `logs.clear`

**Stats:**
- `stats.get`

**Proxy:**
- `proxy.healthCheck`, `proxy.latestVersion`, `proxy.apiCall`

**Agents:**
- `agents.detect`, `agents.configure`

**Config:**
- `config.get`, `config.set`

**Tunnel:**
- `tunnel.start`, `tunnel.stop`, `tunnel.status`

**Remote:**
- `remote.connect`, `remote.disconnect`, `remote.config.get`, `remote.config.set`

**OAuth:**
- `oauth.start`, `oauth.poll`

## Adding New IPC Methods

### Step 1: Define in quotio-cli daemon

**File:** `quotio-cli/src/services/daemon/service.ts`

```typescript
"myNewMethod": async (params) => {
    const { key } = params as { key: string };
    const client = getManagementClient();
    const result = await client.someOperation(key);
    return { result };
}
```

### Step 2: Add to Swift IPC Protocol

**File:** `Quotio/Services/Daemon/IPCProtocol.swift`

```swift
// Add enum case
case myNewMethod = "myNewMethod"

// Add param type
struct IPCMyNewMethodParams: Codable {
    let key: String
}

// Add result type
struct IPCMyNewMethodResult: Codable {
    let result: String
}
```

### Step 3: Add to DaemonIPCClient

**File:** `Quotio/Services/Daemon/DaemonIPCClient.swift`

```swift
func myNewMethod(key: String) async throws -> IPCMyNewMethodResult {
    let params = IPCMyNewMethodParams(key: key)
    return try await call(.myNewMethod, params: params)
}
```

### Step 4: Create Service Wrapper (Optional)

**File:** `Quotio/Services/Daemon/DaemonMyService.swift`

```swift
@MainActor @Observable
final class DaemonMyService {
    static let shared = DaemonMyService()
    private let ipcClient = DaemonIPCClient.shared

    func doSomething(key: String) async throws -> String {
        let result = try await ipcClient.myNewMethod(key: key)
        return result.result
    }
}
```

## Testing

### Unit Tests

Test daemon services in isolation:

```swift
func testProxyConfigService() async throws {
    let service = DaemonProxyConfigService.shared

    // Test get
    let debug = try await service.getDebug()
    XCTAssertNotNil(debug)

    // Test set
    try await service.setDebug(true)
    let updated = try await service.getDebug()
    XCTAssertEqual(updated, true)
}
```

### Integration Tests

Test full IPC flow with daemon:

```swift
func testIPCHealthCheck() async throws {
    let manager = DaemonManager.shared
    let isHealthy = await manager.checkHealth()
    XCTAssertTrue(isHealthy, "Daemon should be healthy")
}
```

## Troubleshooting

### Daemon Not Running

**Symptom:** IPC operations fail with connection errors

**Solution:**
```swift
let manager = DaemonManager.shared
await manager.startDaemon()

// Wait for daemon to be ready
var attempts = 0
while attempts < 10 {
    if await manager.checkHealth() {
        break
    }
    try await Task.sleep(for: .milliseconds(500))
    attempts += 1
}
```

### IPC Timeout

**Symptom:** Operations hang or timeout

**Solution:** Check daemon logs, increase timeout if needed:

```swift
// In DaemonIPCClient
private let timeout: TimeInterval = 30.0  // Increase if needed
```

### Remote Mode Not Working

**Symptom:** Remote connections fail

**Solution:** Ensure ManagementAPIClient is used, not IPC:

```swift
// Correct: Check mode first
if !modeManager.isRemoteProxyMode {
    // Use daemon IPC
} else {
    // Use ManagementAPIClient
}
```

## Performance Considerations

### IPC vs HTTP

| Metric | IPC (Local) | HTTP (Local) | HTTP (Remote) |
|--------|-------------|--------------|---------------|
| Latency | ~1-2ms | ~5-10ms | ~50-200ms |
| Throughput | Very High | High | Medium |
| Connection | Persistent | Per-request | Per-request |
| Overhead | Minimal | JSON + HTTP | JSON + HTTP + Network |

### Best Practices

1. **Batch Operations** - Combine multiple IPC calls where possible
2. **Cache Results** - Don't repeatedly fetch static data
3. **Health Checks** - Check daemon health before critical operations
4. **Error Handling** - Gracefully degrade if daemon unavailable
5. **Timeouts** - Set appropriate timeouts for long operations

## Migration Checklist

- [x] Phase 1: Extend Daemon IPC Handlers (quotio-cli)
- [x] Phase 2: Extend Swift IPC Protocol & Client
- [x] Phase 3: Create Unified Daemon Services (Swift)
- [x] Phase 4: Update Swift ViewModels & Views
- [x] Phase 5: Handle Remote Mode (Option A - Keep ManagementAPIClient)
- [x] Phase 6: Cleanup & Deprecation
  - [x] Mark ManagementAPIClient as deprecated
  - [x] Update AGENTS.md documentation
  - [x] Create migration guide

## Future Improvements

1. **Tauri App** - Use same daemon IPC for Windows/Linux clients
2. **CLI Integration** - quotio-cli can be used standalone
3. **Multi-client Support** - Multiple apps can share single daemon
4. **Hot Reload** - Daemon updates without app restart
5. **WebSocket IPC** - Alternative to Unix Socket for remote scenarios

## References

- [Daemon Architecture Plan](../plans/260114-1815-full-daemon-migration/plan.md)
- [DaemonIPCClient.swift](../Quotio/Services/Daemon/DaemonIPCClient.swift)
- [quotio-cli daemon](../quotio-cli/src/services/daemon/service.ts)
- [AGENTS.md](../Quotio/Services/AGENTS.md)
