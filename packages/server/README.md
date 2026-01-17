# @quotio/server

TypeScript-native proxy server for AI coding agents. Drop-in replacement for CLIProxyAPI (Go).

## Features

- **Multi-Provider Support**: Claude, Gemini, OpenAI, Copilot, Qwen, iFlow, Vertex AI, Kiro
- **OpenAI-Compatible API**: `/v1/chat/completions`, `/v1/messages`, `/v1/models`
- **OAuth Management**: Full OAuth 2.0 + PKCE, Device Code flow, Service Account import
- **Credential Pooling**: Round-robin or fill-first selection with cooldown tracking
- **Resilience**: Circuit breaker, retry with exponential backoff, timeouts
- **Observability**: Request logging, metrics collection, structured JSON output
- **Management API**: Auth CRUD, usage stats, logs, health checks

## Quick Start

```bash
# Build
bun run build

# Run
./dist/quotio-server

# Or run directly
bun run src/index.ts
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `QUOTIO_PORT` | `8317` | Server port |
| `QUOTIO_HOST` | `0.0.0.0` | Bind address |
| `QUOTIO_AUTH_DIR` | `~/.cli-proxy-api` | Auth files directory |
| `QUOTIO_CONFIG_DIR` | `~/.config/quotio` | Config directory |
| `QUOTIO_DEBUG` | `false` | Enable debug logging |
| `QUOTIO_PASSTHROUGH_ENABLED` | `true` | Forward to CLIProxyAPI |
| `QUOTIO_CLI_PROXY_PORT` | `18317` | CLIProxyAPI port |

## API Reference

### OpenAI-Compatible (v1)

#### Chat Completions
```http
POST /v1/chat/completions
Content-Type: application/json

{
  "model": "claude-sonnet-4-20250514",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": false
}
```

#### Messages (Anthropic-style)
```http
POST /v1/messages
Content-Type: application/json

{
  "model": "claude-sonnet-4-20250514",
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 1024
}
```

#### List Models
```http
GET /v1/models
```

### Management API (v0)

#### Health & Status
```http
GET /health                    # Basic health
GET /v0/management/health      # Detailed health
GET /v0/management/ready       # Readiness probe
GET /v0/management/live        # Liveness probe
```

#### Authentication
```http
GET /v0/management/auth                      # List all auth files
GET /v0/management/auth/:provider            # Get auth by provider
DELETE /v0/management/auth/:id               # Delete auth by ID
DELETE /v0/management/auth/provider/:provider # Delete all for provider
```

#### OAuth Flow
```http
POST /v0/management/oauth/start              # Start OAuth
GET /v0/management/oauth/status?state=xxx    # Check OAuth status
POST /v0/management/oauth/device-start       # Start Device Code flow
POST /v0/management/oauth/device-poll        # Poll Device Code
POST /v0/management/oauth/import-service-account # Import Vertex SA
POST /v0/management/oauth/refresh/:provider  # Refresh token
GET /v0/management/oauth/providers           # List supported providers
```

#### Usage & Logs
```http
GET /v0/management/usage                     # Usage overview
GET /v0/management/usage/:provider           # Per-provider usage
GET /v0/management/usage/quotas/all          # All quota statuses
POST /v0/management/usage/reset              # Reset metrics
GET /v0/management/logs                      # Recent logs
GET /v0/management/logs?limit=50             # With limit
GET /v0/management/logs/provider/:provider   # Filter by provider
GET /v0/management/logs/status/4xx           # Filter by status
DELETE /v0/management/logs                   # Clear logs
```

## Architecture

```
src/
├── index.ts                 # Entry point
├── config/                  # Zod configuration schemas
├── store/                   # Token persistence (FileTokenStore)
├── auth/                    # OAuth handlers
│   └── oauth/               # Provider implementations
├── executor/                # Provider executors
│   ├── claude.ts            # Claude API executor
│   ├── gemini.ts            # Gemini API executor
│   ├── openai.ts            # OpenAI API executor
│   ├── copilot.ts           # GitHub Copilot executor
│   ├── qwen.ts              # Qwen API executor
│   ├── iflow.ts             # iFlow API executor
│   ├── pool.ts              # Credential pool
│   └── selector.ts          # Selection strategies
├── proxy/                   # Request dispatching
├── translator/              # Request format conversion
│   ├── openai.ts            # OpenAI format
│   └── anthropic.ts         # Anthropic format
├── resilience/              # Fault tolerance
│   ├── circuit-breaker.ts   # Circuit breaker pattern
│   ├── retry.ts             # Retry with backoff
│   └── timeout.ts           # Timeout utilities
├── middleware/              # Hono middleware
│   └── api-key.ts           # API key authentication
├── logging/                 # Observability
│   ├── request-logger.ts    # Request logging
│   └── metrics.ts           # Metrics collection
└── api/                     # HTTP routes
    ├── routes/v1/           # OpenAI-compatible API
    └── routes/management/   # Admin API
```

## Providers

| Provider | Auth Method | Executor |
|----------|-------------|----------|
| Claude | OAuth + PKCE | ✅ |
| Gemini | OAuth + PKCE | ✅ |
| OpenAI/Codex | OAuth + PKCE | ✅ |
| GitHub Copilot | Device Code | ✅ |
| Vertex AI | Service Account | Pending |
| Kiro | OAuth + PKCE | Pending |
| Qwen | OAuth + PKCE | ✅ |
| iFlow | OAuth + PKCE | ✅ |

## Development

```bash
# Type check
bun run typecheck

# Build
bun run build

# Run in development
bun run --watch src/index.ts
```

## License

MIT
