# Server Package (@quotio/server)

Hono-based OpenAI-compatible proxy server handling multi-provider routing, credential pooling, and request translation.

## Structure

```
server/
├── src/
│   ├── api/              # Hono app and routes
│   │   ├── routes/v1/    # OpenAI-compatible endpoints
│   │   ├── routes/management/ # Admin API (health, logs, usage)
│   │   ├── routes/oauth/ # OAuth callbacks
│   │   └── middleware/   # Logging, CORS
│   ├── executor/         # Provider-specific request execution (10 files)
│   ├── translator/       # Request/response format conversion
│   ├── auth/             # OAuth, Device Code, Service Account handlers
│   ├── store/            # Credential file storage
│   ├── resilience/       # Circuit breakers, retries, timeouts
│   ├── proxy/            # Request dispatching logic
│   └── config/           # Default settings
└── package.json
```

## Where to Look

| Task | Location | Notes |
|------|----------|-------|
| Add API endpoint | `api/routes/` | Use Hono patterns |
| Add AI provider | `executor/` + `translator/` | Create both files |
| Modify routing | `proxy/dispatcher.ts` | Central request logic |
| Add auth flow | `auth/oauth/` | Follow existing providers |
| Change pooling | `executor/pool.ts` | Round Robin / Fill First |

## Code Map

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `createApp` | Function | api/index.ts | Hono app factory with DI |
| `ProxyDispatcher` | Class | proxy/dispatcher.ts | Routes requests to providers |
| `CredentialPool` | Class | executor/pool.ts | Manages account rotation |
| `ProviderSelector` | Class | executor/selector.ts | Round Robin / Fill First logic |
| `Translator` | Interface | translator/index.ts | OpenAI ↔ Provider format |

## API Routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/v1/chat/completions` | POST | OpenAI-compatible chat |
| `/v1/messages` | POST | Anthropic-compatible messages |
| `/v0/management/health` | GET | Server health check |
| `/v0/management/usage` | GET | Token usage stats |
| `/v0/management/logs` | GET | Request logs |

## Provider Executors

| Provider | Executor File | Notes |
|----------|---------------|-------|
| Claude | `executor/claude.ts` | Anthropic Messages API |
| Gemini | `executor/gemini.ts` | Google AI format |
| OpenAI | `executor/openai.ts` | Native format |
| Copilot | `executor/copilot.ts` | GitHub OAuth |
| Qwen | `executor/qwen.ts` | Alibaba API |
| iFlow | `executor/iflow.ts` | TODO: token refresh |

## Conventions

### Executor Pattern
```typescript
export class ClaudeExecutor implements ProviderExecutor {
  async execute(request: ProxyRequest, credential: Credential): Promise<Response> {
    // 1. Translate request to Anthropic format
    // 2. Call upstream API
    // 3. Handle streaming if needed
    // 4. Translate response back
  }
}
```

### Middleware Stack Order
1. `loggingMiddleware` - Request/response logging
2. `corsMiddleware` - CORS headers

## Anti-Patterns

| Pattern | Why Bad | Instead |
|---------|---------|---------|
| Blocking in request handler | Kills throughput | Use async/await properly |
| Ignoring 429 response | Wastes quota | Return `ModelCooldownError` |
| Hardcoded provider URLs | Inflexible | Use config/defaults.ts |

## Critical Rules

- **Streaming**: MUST use Hono's `stream` helper for SSE responses
- **Cooldowns**: 429 errors trigger cooldown in `CredentialPool`, auto-retry with next account

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `PORT` | Override default port (18317) |

## Commands

```bash
bun run build      # Compile
bun run dev        # Development with watch
bun test           # Run tests
```
