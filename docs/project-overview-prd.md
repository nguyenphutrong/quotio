# Quotio - Project Overview and Product Requirements Document (PRD)

> **Last Updated**: December 27, 2024
> **Version**: 1.0.0
> **Platform**: macOS 15.0+ (Sequoia)

---

## Table of Contents

1. [Project Purpose](#project-purpose)
2. [Target Users](#target-users)
3. [Key Features](#key-features)
4. [Supported AI Providers](#supported-ai-providers)
5. [Compatible CLI Agents](#compatible-cli-agents)
6. [App Modes](#app-modes)
7. [System Requirements](#system-requirements)

---

## Project Purpose

Quotio is a native macOS application that serves as the **command center for AI coding assistants**. It provides a graphical user interface for managing **CLIProxyAPI** - a local proxy server that powers AI coding agents.

### Core Goals

1. **Centralized Account Management**: Manage multiple AI provider accounts from different services in one unified interface.
2. **Quota Tracking**: Monitor API usage and quotas across all connected accounts with real-time visual feedback.
3. **CLI Tool Configuration**: Auto-detect and configure popular AI coding CLI tools to route through the centralized proxy.
4. **Seamless Integration**: Provide menu bar integration for quick status checks without interrupting workflow.

### Problem Statement

Developers using AI coding assistants often need to:

- Manage multiple accounts across different AI providers
- Track quota usage to avoid service interruptions
- Configure multiple CLI tools with consistent settings
- Monitor real-time usage statistics

Quotio solves these challenges by providing a unified management layer with automatic configuration and quota tracking.

---

## Target Users

### Primary Users

1. **Professional Developers**: Engineers who use AI coding assistants daily and need to manage multiple accounts or team allocations.

2. **Power Users**: Developers who work with multiple AI providers and need centralized quota monitoring.

3. **Team Leads/DevOps**: Personnel responsible for managing AI tool access and monitoring usage across accounts.

### User Personas

| Persona | Use Case | Key Needs |
|---------|----------|-----------|
| Solo Developer | Uses 2-3 AI tools daily | Quota tracking, easy setup |
| Freelancer | Multiple client accounts | Account switching, usage monitoring |
| Team Lead | Manages team quotas | Dashboard overview, notifications |
| DevOps Engineer | Infrastructure management | Proxy configuration, API key management |

---

## Key Features

### Multi-Provider Support

Connect and manage accounts from multiple AI providers through a unified interface:

- OAuth-based authentication for most providers
- Service account JSON import for Vertex AI
- CLI-based authentication for GitHub Copilot and Kiro
- Browser session integration for Cursor

### Quota Tracking

Visual quota monitoring with intelligent notifications:

- Per-account quota breakdown
- Model-level usage tracking
- Automatic low-quota alerts
- Configurable notification thresholds
- Historical usage statistics

### Agent Configuration

One-click configuration for popular CLI coding tools:

- Automatic agent detection
- Configuration generation (JSON/TOML/Environment)
- Shell profile integration (zsh/bash/fish)
- Manual configuration mode with copy-to-clipboard
- Model slot customization (Opus/Sonnet/Haiku)

### Menu Bar Integration

Always-accessible status from the macOS menu bar:

- Proxy status indicator
- Quota percentage display per provider
- Custom provider icons
- Color-coded status (green/yellow/red)
- Quick access popover

### Notifications

Intelligent alert system for critical events:

- Low quota warnings (configurable threshold)
- Account cooling period notifications
- Proxy crash alerts
- Sound and banner options

### Auto-Update

Seamless update experience via Sparkle framework:

- Background update checks
- One-click update installation
- Changelog display

### Bilingual Support

Full localization for:

- English (en)
- Vietnamese (vi)

---

## Supported AI Providers

| Provider | Authentication Method | Quota Tracking | Manual Auth |
|----------|----------------------|----------------|-------------|
| **Google Gemini** | OAuth | Yes | Yes |
| **Anthropic Claude** | OAuth | Yes (via CLI) | Yes |
| **OpenAI Codex** | OAuth | Yes | Yes |
| **Qwen Code** | OAuth | No | Yes |
| **Vertex AI** | Service Account JSON | No | Yes |
| **iFlow** | OAuth | No | Yes |
| **Antigravity** | OAuth | Yes | Yes |
| **Kiro (CodeWhisperer)** | CLI Auth (Google/AWS) | No | Yes |
| **GitHub Copilot** | Device Code Flow | Yes | Yes |
| **Cursor** | Browser Session | Yes | No (Auto-detect) |

### Provider Capabilities

- **OAuth Providers**: Gemini, Claude, Codex, Qwen, iFlow, Antigravity
- **CLI Auth**: GitHub Copilot (Device Code), Kiro (Google OAuth / AWS Builder ID)
- **File Import**: Vertex AI (Service Account JSON)
- **Auto-Detect Only**: Cursor (reads from local Cursor app database)

---

## Compatible CLI Agents

Quotio can automatically detect and configure the following CLI coding tools:

| Agent | Binary | Config Type | Config Files |
|-------|--------|-------------|--------------|
| **Claude Code** | `claude` | JSON + Environment | `~/.claude/settings.json` |
| **Codex CLI** | `codex` | TOML + JSON | `~/.codex/config.toml`, `~/.codex/auth.json` |
| **Gemini CLI** | `gemini` | Environment Only | - |
| **Amp CLI** | `amp` | JSON + Environment | `~/.config/amp/settings.json`, `~/.local/share/amp/secrets.json` |
| **OpenCode** | `opencode`, `oc` | JSON | `~/.config/opencode/opencode.json` |
| **Factory Droid** | `droid`, `factory-droid`, `fd` | JSON | `~/.factory/config.json` |

### Configuration Modes

1. **Automatic Mode**: Directly updates config files and shell profiles
2. **Manual Mode**: Generates configuration for user to copy and apply

### Model Slot Configuration

Agents can be configured with custom model routing:

- **Opus Slot**: High intelligence tasks (e.g., `gemini-claude-opus-4-6-thinking`)
- **Sonnet Slot**: Balanced tasks (e.g., `gemini-claude-sonnet-4-5`)
- **Haiku Slot**: Fast/simple tasks (e.g., `gemini-3-flash-preview`)

---

## App Modes

Quotio supports two operating modes to accommodate different user needs:

### Full Mode (Default)

Complete functionality including proxy server management:

**Features:**

- Run local proxy server (CLIProxyAPI)
- Manage multiple AI accounts
- Configure CLI agents
- Track quota in menu bar
- API key management for clients
- Request/response logging

**Visible Pages:**

- Dashboard
- Quota
- Providers
- Agents
- API Keys
- Logs
- Settings
- About

### Quota-Only Mode

Lightweight mode for quota monitoring without proxy overhead:

**Features:**

- Track quota in menu bar
- No proxy server required
- Minimal UI and resource usage
- Direct quota fetching via CLI commands
- Similar to CodexBar / ccusage

**Visible Pages:**

- Dashboard
- Quota
- Accounts (renamed from Providers)
- Settings
- About

### Mode Selection

- Users select their preferred mode during onboarding
- Mode can be changed anytime via Settings
- Switching from Full to Quota-Only automatically stops the proxy

---

## System Requirements

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| **Architecture** | Apple Silicon or Intel x64 | Apple Silicon |
| **Memory** | 4 GB RAM | 8 GB RAM |
| **Storage** | 100 MB available | 200 MB available |

### Software Requirements

| Requirement | Version |
|-------------|---------|
| **macOS** | 15.0 (Sequoia) or later |
| **Xcode** (for development) | 16.0+ |
| **Swift** (for development) | 6.0+ |

### Network Requirements

- Internet connection for OAuth authentication
- Localhost access for proxy server (port 8317 default)
- Access to GitHub API for binary downloads

### Optional Dependencies

- **Sparkle Framework**: Auto-updates (bundled via Swift Package Manager)
- **CLI Tools**: Required if using agent configuration features

---

## Technical Architecture Overview

```text
┌─────────────────────────────────────────────────────────────┐
│                      Quotio (SwiftUI)                       │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  Dashboard  │  │   Quota     │  │     Providers       │  │
│  │   Screen    │  │   Screen    │  │      Screen         │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Agents    │  │  API Keys   │  │      Settings       │  │
│  │   Screen    │  │   Screen    │  │       Screen        │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                    QuotaViewModel                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ CLIProxy    │  │ Management  │  │    StatusBar        │  │
│  │  Manager    │  │ APIClient   │  │     Manager         │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Quota     │  │   Agent     │  │   Notification      │  │
│  │  Fetchers   │  │  Services   │  │     Manager         │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    CLIProxyAPI Binary                        │
│            (Local HTTP Proxy on port 8317)                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
          ┌────────────────────────────────────┐
          │         AI Provider APIs           │
          │  (Gemini, Claude, OpenAI, etc.)    │
          └────────────────────────────────────┘
```

---

## Roadmap (Future Considerations)

1. **Automated Testing**: Implement unit and UI tests
2. **Enhanced Analytics**: Usage trends and predictions
3. **Team Features**: Shared account management
4. **Plugin System**: Custom provider integrations
5. **Cloud Sync**: Settings synchronization across devices

---

## References

- [CLIProxyAPI GitHub Repository](https://github.com/router-for-me/CLIProxyAPIPlus)
- [Sparkle Framework Documentation](https://sparkle-project.org/)
- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
