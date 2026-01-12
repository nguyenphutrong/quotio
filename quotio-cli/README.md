# quotio-cli

Cross-platform CLI tool for managing CLIProxyAPI - the local proxy server for AI coding agents.

quotio-cli is the command-line companion to the Quotio macOS app, allowing you to manage quota tracking, authentication, and agent configuration on any platform that supports the Bun runtime.

## Features

- **Quota Management**: Track usage across multiple AI providers including Claude Code, Gemini CLI, and GitHub Copilot.
- **Authentication**: Manage OAuth tokens and API keys for your AI accounts.
- **Proxy Control**: Control the local CLIProxyAPI server instance.
- **Agent Configuration**: Automatically detect and configure CLI tools to use the proxy.
- **Cross-Platform**: Runs on macOS, Linux, and Windows (via WSL).

## Installation

### Prerequisites

- [Bun](https://bun.sh) runtime (version 1.1.0 or higher)

### Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/nguyenphutrong/quotio.git
   cd quotio/quotio-cli
   ```

2. Install dependencies:
   ```bash
   bun install
   ```

3. Build the binary:
   ```bash
   bun run build
   ```

The binary will be available at `./dist/quotio`.

## Usage

Run the CLI using the built binary:

```bash
./dist/quotio <command> [options]
```

Or directly via Bun during development:

```bash
bun run dev <command> [options]
```

### Global Options

- `--format <type>`: Output format (table, json, plain). Default: table.
- `--verbose, -v`: Enable verbose output.
- `--base-url <url>`: CLIProxyAPI base URL. Default: http://localhost:8217.
- `--help, -h`: Show help for a command.

## Commands

### Manage Quota

View and manage your AI provider quotas.

```bash
# View all quotas
quotio quota list

# Check specific provider
quotio quota status --provider claude
```

### Authentication

Manage your accounts and tokens.

```bash
# List authenticated accounts
quotio auth list

# Login to a new provider
quotio auth login --provider gemini
```

### Proxy Control

Manage the local proxy server.

```bash
# Check proxy status
quotio proxy status

# Restart the proxy
quotio proxy restart
```

### Agent Configuration

Configure your CLI tools to use the proxy.

```bash
# Detect installed agents
quotio agent detect

# Configure a specific agent
quotio agent configure --name claude-code
```

## Supported Providers

- Claude Code
- Gemini CLI
- GitHub Copilot
- Cursor (IDE)
- Trae (IDE)
- Kiro (CodeWhisperer)
- Antigravity
- Codex (OpenAI)

## Development

### Scripts

- `bun run dev`: Run the CLI in development mode.
- `bun run build`: Compile the CLI into a single binary.
- `bun run lint`: Run the linter to check for code style issues.
- `bun run format`: Format the code using the project's style guide.

### Project Structure

- `src/cli`: Command definitions and handlers.
- `src/models`: TypeScript interfaces and data models.
- `src/services`: Core business logic including quota fetchers and agent detection.
- `src/utils`: Helper functions.

## License

This project is licensed under the MIT License.
