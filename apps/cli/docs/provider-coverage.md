# Provider contract coverage

This table is derived from `quotio providers --format json`. The contract test
checks every row against the runtime registry. `—` means the capability is absent;
platform declarations are implementation metadata, not runtime test results.

Every provider uses Rust's shared naming, account/source actions, metric states and
error projection. Verified cross-source grouping is currently supplied by Devin
Desktop, Copilot and Factory API-key responses; other sources retain distinct IDs
when identity evidence is unavailable. User labels always remain authoritative.
Missing metrics remain missing, and failures never imply zero or full quota.

Contract coverage is offline: registry/schema tests cover all entries, shared
snapshot fixtures cover plan-only and grouped-source results, and adapter tests
cover provider payload parsing. This is not a claim of live-account acceptance for
all providers. Windows/Linux runtime checks are deferred.

<!-- registry-table -->
| Provider | Authentication | Sources (ownership) | Account storage OS |
| --- | --- | --- | --- |
| mock | — | — | — |
| codex | oauth, native | codex_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| amp | api_key, native | amp_native (borrowed_native) | macos, linux, windows |
| antigravity | native, owned_token | antigravity_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| synthetic | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| openrouter | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| zai | api_key | quotio_custom_provider (borrowed_proxy), cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| minimax | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| factory | api_key, owned_token, native | factory_native (borrowed_native) | macos, linux, windows |
| aiand | api_key | — | macos, linux, windows |
| alibabacodingplan | api_key | — | macos, linux, windows |
| azureopenai | native | — | — |
| chutes | api_key | — | macos, linux, windows |
| claude | oauth, native | claude_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| clawrouter | api_key | — | macos, linux, windows |
| clinepass | api_key | quotio_custom_provider (borrowed_proxy) | macos, linux, windows |
| codebuff | api_key | — | macos, linux, windows |
| copilot | oauth, native | copilot_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| crof | api_key | — | macos, linux, windows |
| cursor | native | cursor_native (borrowed_native) | macos, linux, windows |
| deepgram | api_key | — | macos, linux, windows |
| deepinfra | api_key | — | macos, linux, windows |
| deepseek | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| devin | api_key | — | macos, linux, windows |
| devin-desktop | api_key | devin_desktop_native (borrowed_native) | macos, linux, windows |
| doubao | api_key | — | macos, linux, windows |
| elevenlabs | api_key | — | macos, linux, windows |
| fireworks | api_key | — | macos, linux, windows |
| gemini | native | cli_proxy_auth_file (borrowed_proxy) | — |
| grok | native, owned_token | grok_native (borrowed_native) | macos, linux, windows |
| groq | api_key | — | macos, linux, windows |
| ibmbob | api_key | — | macos, linux, windows |
| kilo | api_key | — | macos, linux, windows |
| kimi | api_key | — | macos, linux, windows |
| kiro | native, owned_token | kiro_native (borrowed_native), cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| litellm | api_key | — | macos, linux, windows |
| llmproxy | api_key | — | macos, linux, windows |
| moonshot | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| neuralwatt | api_key | — | macos, linux, windows |
| openai | api_key | — | macos, linux, windows |
| opencodego | api_key | — | macos, linux, windows |
| poe | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| sub2api | api_key | — | macos, linux, windows |
| venice | api_key | cli_proxy_auth_file (borrowed_proxy) | macos, linux, windows |
| vertexai | native | cli_proxy_auth_file (borrowed_proxy) | — |
| warp | api_key | — | macos, linux, windows |
| xai | api_key | — | macos, linux, windows |
| zenmux | api_key | — | macos, linux, windows |
