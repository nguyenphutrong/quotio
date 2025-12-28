# Quotio Electron

> Command Center for AI Coding Assistants - Electron Edition

Quotio is a cross-platform desktop application for managing quotas and accounts across multiple AI providers. This Electron version provides the same functionality as the native macOS app with cross-platform support.

![Quotio Dashboard](screenshots/dashboard.png)

## Features

- **Multi-Provider Support** - Manage quotas for Gemini, Claude, OpenAI, Copilot, Cursor, and more
- **Local Proxy Server** - Route requests through multiple accounts with automatic failover
- **Real-time Dashboard** - Monitor usage, requests, and quota status
- **CLI Agent Detection** - Automatically detect and configure Claude Code, Codex CLI, etc.
- **Menu Bar Integration** - Quick access without leaving your workflow
- **Secure by Design** - Context isolation, sandboxing, and CSP enabled

## Security

This application follows Electron security best practices:

- ✅ Context isolation enabled
- ✅ Node integration disabled
- ✅ Sandbox mode enabled
- ✅ Content Security Policy configured
- ✅ IPC channel validation
- ✅ External URL allowlisting
- ✅ Input sanitization
- ✅ Hardened runtime for macOS

See [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for the complete security audit.

## Installation

### From DMG (macOS)

1. Download the latest `.dmg` from [Releases](https://github.com/nguyenphutrong/quotio/releases)
2. Open the DMG and drag Quotio to Applications
3. Launch Quotio from Applications

### From Source

```bash
# Clone the repository
git clone https://github.com/nguyenphutrong/quotio.git
cd quotio/electron-app

# Install dependencies
npm install

# Run in development mode
npm run dev

# Build for production
npm run build

# Create DMG
npm run dist:dmg
```

## Development

### Prerequisites

- Node.js 18+
- npm 9+

### Project Structure

```
electron-app/
├── src/
│   ├── main/           # Electron main process
│   │   ├── main.ts     # App entry point
│   │   ├── preload.ts  # Secure context bridge
│   │   └── services/   # Backend services
│   ├── renderer/       # React frontend
│   │   ├── components/ # Reusable UI components
│   │   ├── pages/      # Page components
│   │   ├── store/      # State management
│   │   └── styles/     # CSS styles
│   └── shared/         # Shared types and utilities
│       ├── types/      # TypeScript interfaces
│       ├── constants/  # App constants
│       └── utils/      # Security utilities
├── resources/          # App resources (icons, entitlements)
├── scripts/           # Build scripts
└── package.json       # Dependencies and scripts
```

### Scripts

| Script | Description |
|--------|-------------|
| `npm run dev` | Start development server |
| `npm run build` | Build for production |
| `npm run dist` | Create distribution packages |
| `npm run dist:dmg` | Create macOS DMG |
| `npm run lint` | Run ESLint |
| `npm run typecheck` | Run TypeScript type checking |
| `npm run security:audit` | Run security audit |

## Configuration

### Proxy Settings

The proxy runs on `http://127.0.0.1:8080` by default. Configure in Settings:

- **Auto Start Proxy** - Start proxy when app launches
- **Quota Alert Threshold** - Notification threshold for low quotas

### Supported Providers

| Provider | Auth Method | Status |
|----------|-------------|--------|
| Google Gemini | OAuth | ✅ Supported |
| Anthropic Claude | OAuth | ✅ Supported |
| OpenAI | OAuth | ✅ Supported |
| GitHub Copilot | Device Code | ✅ Supported |
| Cursor | Browser Auth | ✅ Supported |
| Vertex AI | Service Account | ✅ Supported |

### CLI Agents

Automatically detected and configured:

- Claude Code
- Codex CLI
- Gemini CLI
- Amp CLI
- OpenCode
- Factory Droid

## Building for Distribution

### macOS

```bash
# Build and create DMG
npm run dist:dmg
```

The DMG will be created in `build/`.

### Code Signing (macOS)

For notarized distribution:

```bash
# Set environment variables
export CSC_LINK="path/to/certificate.p12"
export CSC_KEY_PASSWORD="certificate_password"
export APPLE_ID="your@apple.id"
export APPLE_APP_SPECIFIC_PASSWORD="app-specific-password"

# Build with signing
npm run dist:mac -- --sign
```

## Architecture

### Main Process

- **ProxyManager** - Manages CLIProxyAPI binary lifecycle
- **QuotaService** - Fetches and caches quota information
- **SettingsService** - Encrypted settings storage
- **AgentDetectionService** - Detects installed CLI tools
- **LoggerService** - Secure logging with data masking

### Renderer Process

- **React 18** - UI framework
- **React Router** - Client-side routing
- **Tailwind CSS** - Styling
- **Context API** - State management

### IPC Communication

All IPC channels are prefixed with `quotio:` and validated:

```typescript
// Valid channels
quotio:proxy:start
quotio:quota:refresh
quotio:settings:update

// Invalid (blocked)
anything:else
```

## Security Considerations

### CSP Policy

```
default-src 'self';
script-src 'self';
style-src 'self' 'unsafe-inline';
img-src 'self' data: https:;
connect-src 'self' https://api.github.com
```

### Permissions

| Permission | Usage |
|------------|-------|
| Network Client | API requests |
| Network Server | Local proxy |
| Files (User Selected) | Auth file access |

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `npm run lint` and `npm run typecheck`
5. Submit a pull request

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

- Original Quotio by [@nguyenphutrong](https://github.com/nguyenphutrong)
- Built with [Electron](https://www.electronjs.org/)
- UI powered by [React](https://reactjs.org/) and [Tailwind CSS](https://tailwindcss.com/)
