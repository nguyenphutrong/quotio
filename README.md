# CKota

<p align="center">
  <img src="screenshots/home.png" width="600" alt="CKota Home" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey.svg?style=flat" alt="Platform macOS" />
  <img src="https://img.shields.io/badge/Swift_6-F05138.svg?style=flat" alt="Swift 6" />
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat" alt="License MIT" />
  <a href="README.vi.md"><img src="https://img.shields.io/badge/lang-Tiếng%20Việt-red.svg?style=flat" alt="Vietnamese" /></a>
</p>

A macOS menu bar app for managing AI coding assistant accounts. It wraps [CLIProxyAPI](https://github.com/synh/CLIProxyAPI) - a local proxy that routes requests across multiple provider accounts.

Track quotas across Claude Code, Antigravity, Gemini, Codex, Copilot, and more. See which accounts are ready, cooling, or exhausted at a glance.

**v0.2.2** | macOS 15.0+ | [Docs](./docs/)

## Install

Download the [latest release](https://github.com/synh/CKota/releases) or build from source:

```bash
git clone https://github.com/synh/CKota.git
cd CKota && open CKota.xcodeproj
# Cmd + R to build and run
```

The proxy binary downloads automatically on first launch.

## Screenshots

| Home | Analytics |
|------|-----------|
| ![Home](screenshots/home.png) | ![Analytics](screenshots/analytics.png) |

| Accounts | Settings |
|----------|----------|
| ![Accounts](screenshots/accounts.png) | ![Settings](screenshots/settings.png) |

<p align="center">
  <img src="screenshots/MenuBar.png" width="300" alt="Menu Bar" />
</p>

## What it does

**Two modes:**
- **Full Mode** - Runs the proxy server, manages accounts, configures CLI agents
- **Quota Monitor** - Just tracks quota usage without running the proxy (lightweight)

**Account management:**
- OAuth login for supported providers (Claude, Antigravity, etc.)
- Status indicators: Ready (green), Cooling (orange), Exhausted (red)
- Per-account quota breakdown with time until reset

**Menu bar:**
- Quick view of your lowest quota accounts
- Colored or monochrome icons based on preference

## Providers

Claude Code, Antigravity

## Usage

1. Launch CKota, pick Full Mode or Quota Monitor
2. Go to **Accounts** and add your provider accounts via OAuth
3. Check **Analytics** for detailed quota breakdowns per account
4. The menu bar shows your top accounts at a glance

Settings let you configure language (EN/VI), appearance, launch at login, and notification preferences.

## Architecture

SwiftUI + MVVM with async/await. The app talks to CLIProxyAPI via REST for account management and quota fetching.

```
Views → ViewModels (@Observable) → Services → CLIProxyAPI
```

Key files:
- `CKotaApp.swift` - Entry point, menu bar setup
- `ViewModels/QuotaViewModel.swift` - Central state
- `Services/CLIProxyManager.swift` - Proxy lifecycle
- `Services/*QuotaFetcher.swift` - Provider-specific quota APIs

## Docs

- [Project Overview](docs/project-overview-pdr.md)
- [Code Standards](docs/code-standards.md)
- [System Architecture](docs/system-architecture.md)
- [Codebase Summary](docs/codebase-summary.md)

## Contributing

Fork, branch, PR. Follow the [code standards](docs/code-standards.md). See [CLAUDE.md](CLAUDE.md) for dev workflow.

## License

MIT
