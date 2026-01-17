# Cross-Platform Architecture for Quotio v2 (Tauri)

**Status:** Proposed  
**Date:** 2026-01-17  
**Author:** AI Assistant  
**Linear Issues:** QUO-1 through QUO-10

## Summary

This document describes the architecture for enabling Quotio to run on Windows and Linux platforms using Tauri v2 while maintaining the existing macOS Swift app.

## Current Architecture (macOS Only)

```
┌─────────────────────────────────────────────────────────────────┐
│                      Swift macOS App                             │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐ │
│  │ DaemonIPCClient  │  │ DaemonProxyConfig│  │ DaemonAPIKeys  │ │
│  │                  │  │ Service          │  │ Service        │ │
│  └────────┬─────────┘  └────────┬─────────┘  └───────┬────────┘ │
│           │                     │                     │          │
│           └─────────────────────┼─────────────────────┘          │
│                                 │                                │
│                    Unix Socket IPC (quotio.sock)                 │
└─────────────────────────────────┼────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                     quotio-cli daemon (Bun/TS)                   │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐ │
│  │ IPC Server       │  │ Daemon Handlers  │  │ Quota Fetchers │ │
│  │ (Unix Socket)    │  │ (50+ methods)    │  │ (12 providers) │ │
│  └────────┬─────────┘  └────────┬─────────┘  └───────┬────────┘ │
│           │                     │                     │          │
│           └─────────────────────┼─────────────────────┘          │
│                                 │                                │
│                        HTTP (localhost:18317)                    │
└─────────────────────────────────┼────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                  @quotio/server (TypeScript/Hono)                │
└─────────────────────────────────────────────────────────────────┘
```

### Current IPC Protocol

- **Transport:** Unix Socket at `~/.cache/quotio-cli/quotio.sock`
- **Protocol:** JSON-RPC 2.0 (newline-delimited)
- **Methods:** 50+ defined in `packages/cli/src/ipc/protocol.ts`
- **Swift Client:** `Quotio/Services/Daemon/DaemonIPCClient.swift`

## Decision: Dual Transport (HTTP + Unix Socket)

### Why HTTP for Cross-Platform?

| Option | macOS | Linux | Windows | Complexity |
|--------|-------|-------|---------|------------|
| Unix Socket | ✅ | ✅ | ❌ (Named Pipes differ) | Low |
| Named Pipes | ❌ | ❌ | ✅ | High (3 implementations) |
| TCP Socket | ✅ | ✅ | ✅ | Medium |
| **HTTP Server** | ✅ | ✅ | ✅ | **Low (single impl)** |

**Decision:** Add HTTP server to daemon, keep Unix Socket for Swift backward compatibility.

### Why Keep the Daemon?

The daemon provides critical orchestration that `@quotio/server` doesn't have:

1. **Process Management:** Spawns/monitors proxy server subprocess
2. **Quota Fetchers:** 12 provider-specific scrapers requiring browser automation
3. **Agent Detection:** Scans filesystem for CLI tools
4. **Tunnel Management:** Cloudflare tunnel lifecycle
5. **State Persistence:** Stats, credentials, config sync

**Removing daemon would require migrating all logic to Rust (Tauri) or embedding in @quotio/server.**

## Proposed Architecture (Cross-Platform)

```
┌───────────────────────────────────────────────────────────────────────────┐
│                     Frontend (TypeScript/React)                            │
│                                                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                    DaemonClient (TypeScript)                         │  │
│  │          HTTP fetch() calls to localhost:18318/rpc                   │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ HTTP POST /rpc (JSON-RPC 2.0)
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                      Tauri v2 (Rust)                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ Sidecar Manager: spawn/monitor quotio-cli binary                    │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                       │
│                           Spawns as sidecar                                │
└───────────────────────────────────┼───────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                     quotio-cli daemon (Bun/TS)                             │
│                                                                            │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐   │
│  │ HTTP Server     │  │ Unix Socket     │  │ Daemon Service          │   │
│  │ (port 18318)    │  │ (macOS/Linux)   │  │ (50+ handlers)          │   │
│  │ POST /rpc       │  │ ~/.cache/...    │  │                         │   │
│  │ GET /health     │  │ JSON-RPC 2.0    │  │ - Quota fetchers        │   │
│  └────────┬────────┘  └────────┬────────┘  │ - Agent detection       │   │
│           │                    │           │ - Tunnel management     │   │
│           └────────────────────┴───────────┤ - Stats tracking        │   │
│                                            └─────────────────────────┘   │
│                                    │                                       │
│                           HTTP (localhost:18317)                           │
└───────────────────────────────────┼───────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                  @quotio/server (TypeScript/Hono)                          │
│                  OpenAI-compatible API, provider routing                   │
└───────────────────────────────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: HTTP Server Addition (QUO-3)

**File:** `packages/cli/src/ipc/http-server.ts`

```typescript
// HTTP server exposing JSON-RPC 2.0 over POST /rpc
export interface HTTPServerConfig {
  port: number;
  host: string;
}

export async function startHTTPServer(config: HTTPServerConfig): Promise<void>;
export async function stopHTTPServer(): Promise<void>;
```

**Endpoints:**
- `POST /rpc` - JSON-RPC 2.0 handler (reuses existing handlers)
- `GET /health` - Simple health check
- `GET /version` - Daemon version info

**Integration point:** `packages/cli/src/services/daemon/service.ts`
- Call `startHTTPServer()` alongside `startServer()` in daemon startup

### Phase 2: Tauri Sidecar Configuration (QUO-4)

**tauri.conf.json additions:**
```json
{
  "bundle": {
    "externalBin": ["quotio-cli"]
  }
}
```

**Build matrix:**
- `quotio-cli-x86_64-pc-windows-msvc.exe`
- `quotio-cli-x86_64-unknown-linux-gnu`
- `quotio-cli-aarch64-apple-darwin`
- `quotio-cli-x86_64-apple-darwin`

### Phase 3: TypeScript Client Library (QUO-6)

**Package:** `packages/client/`

```typescript
// Type-safe client matching IPCMethods interface
import type { IPCMethods, MethodParams, MethodResult } from '@quotio/cli';

class DaemonClient {
  constructor(baseURL: string);
  
  async call<M extends keyof IPCMethods>(
    method: M, 
    params: MethodParams<M>
  ): Promise<MethodResult<M>>;
  
  // Convenience methods
  async ping(): Promise<{ pong: true }>;
  async getStatus(): Promise<DaemonStatus>;
  async startProxy(port?: number): Promise<ProxyStartResult>;
}
```

### Phase 4: Tauri Commands (QUO-7)

**Rust commands wrapping sidecar:**
```rust
#[tauri::command]
async fn start_daemon(app: AppHandle) -> Result<(), String> {
    app.shell()
        .sidecar("quotio-cli")?
        .args(["daemon", "start"])
        .spawn()?;
    Ok(())
}

#[tauri::command]
async fn daemon_rpc(method: String, params: Value) -> Result<Value, String> {
    // HTTP call to localhost:18318/rpc
}
```

## Migration Path

### Swift App (Preserved)
- Continues using Unix Socket IPC
- No changes required
- `DaemonIPCClient.swift` works as-is

### Tauri App (New)
- Uses HTTP transport exclusively
- TypeScript client in frontend
- Rust manages sidecar lifecycle

## Port Allocation

| Service | Port | Purpose |
|---------|------|---------|
| @quotio/server (proxy) | 8317 | CLI agent connections |
| @quotio/server (management) | 18317 | Internal API |
| quotio-cli HTTP | 18318 | Daemon IPC (cross-platform) |
| quotio-cli TCP | 18217 | Windows fallback (if needed) |

## Security Considerations

1. **HTTP Server binds to localhost only** - No external access
2. **No authentication on localhost** - Same trust model as Unix Socket
3. **CORS disabled** - Only Tauri webview accesses
4. **Rate limiting optional** - Local-only, not exposed

## File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `packages/cli/src/ipc/http-server.ts` | New | HTTP server implementation |
| `packages/cli/src/services/daemon/service.ts` | Modify | Start HTTP alongside IPC |
| `packages/cli/src/utils/paths.ts` | Done | Already has Windows support |
| `packages/cli/package.json` | Modify | Add build targets for all platforms |
| `packages/client/` | New | TypeScript client library |
| `apps/tauri/` | New | Tauri v2 application |

## Open Questions

1. **Electron vs Tauri?** - Tauri chosen for binary size and Rust ecosystem
2. **Single binary vs daemon?** - Daemon allows decoupled updates
3. **Authentication for remote mode?** - Use existing management key pattern

## References

- [Tauri Sidecar Documentation](https://tauri.app/v2/guides/building/sidecar/)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
- [Bun HTTP Server](https://bun.sh/docs/api/http)
