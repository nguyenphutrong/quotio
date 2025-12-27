# Changelog

All notable changes to Quotio will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] - 2025-12-27

### Fixed

- **Proxy Connection Leak**: Fix URLSession connection leak in ManagementAPIClient with proper lifecycle management (#11)
- **Menu Bar Sync**: Fix menu bar not updating when accounts are removed or logged out (#11)
- **Quota Calculation**: Filter out unknown percentages when calculating lowest quota for menu bar display (#8)
- **ForEach Duplicate ID**: Add uniqueId field combining provider+email to prevent duplicate ID warnings (#11)
- **Race Condition**: Avoid race condition in stopProxy by capturing client reference before invalidation (#11)

### Added

- **Refresh Button**: Manual refresh button for auto-detected providers section to detect logout changes (#11)

### Changed

- Increase auto-refresh interval from 5s to 15s to reduce connection pressure (#11)

## [0.2.1] - 2025-12-27

### Added

- **Appearance Settings**: New theme settings with System, Light, and Dark mode options

### Fixed

- **Claude Code Reconfigure**: Preserve existing settings.json configuration when reconfiguring Claude Code (#3)
- **Dashboard UI**: Hide +Cursor button for non-manual-auth providers (#5)

### Changed

- Updated and optimized app screenshots

## [0.2.0] - 2025-12-27

### Added

- **Quota-Only Mode**: New app mode for tracking quotas without running proxy server
- **Cursor Quota Tracking**: Monitor Cursor IDE usage and quota directly
- **Quota Display Mode**: Choose between showing used or remaining percentage
- **Direct Provider Authentication**: Read quota from provider auth files (Claude Code, Gemini CLI, Codex CLI)
- Mode picker onboarding for first-time setup

### Changed

- **Redesigned Quota UI**: New segmented provider control with improved layout
- **Improved Menu Bar Settings**: Direct toggle with better UX
- **Better Status Section**: Improved sidebar layout and port display formatting
- **Improved Mode Picker**: Fixed UI freeze when switching app modes

### Fixed

- UI freeze when switching between Proxy and Quota-Only modes
- Cursor excluded from manual add options (quota tracking only)
- Appcast generation with DMG files

## [0.1.3] - 2025-12-27

### Fixed

- Proxy process not terminating after running for a while
- Orphan proxy processes remaining after app quit
- Proxy still running when quitting app from menu bar

### Added

- Loading indicator in sidebar during proxy startup
- Force termination with timeout and SIGKILL fallback for reliable proxy shutdown
- Kill-by-port cleanup to handle orphan processes
- Claude Code configuration storage option (global vs project-local)
- Dev build distinction with separate app icon

### Changed

- Menu bar now persists when main window is closed (app runs in background)
- Improved build configuration with xcconfig support for dev/prod separation

## [0.1.0] - 2025-12-26

### Added

- **Multi-Provider Support**: Connect accounts from Gemini, Claude, OpenAI Codex, Qwen, Vertex AI, iFlow, Antigravity, Kiro, and GitHub Copilot
- **Real-time Dashboard**: Monitor request traffic, token usage, and success rates live
- **Smart Quota Management**: Visual quota tracking per account with automatic failover strategies
- **Menu Bar Integration**: Quick access to server status, quota overview, and controls from menu bar
  - Custom provider icons display in menu bar
  - Combined provider status indicators
- **Quota Display Improvements**:
  - GitHub Copilot quota display (Chat, Completions, Premium)
  - Antigravity models grouped into Claude, Gemini Pro, and Gemini Flash categories
  - Collapsible model groups with detailed breakdown
  - High precision percentage display
- **Agent Configuration**: Auto-detect and configure AI coding tools (Claude Code, OpenCode, Gemini CLI, Amp CLI, Codex CLI, Factory Droid)
- **API Key Management**: Generate and manage API keys for local proxy
- **System Notifications**: Alerts for low quotas, account cooling periods, and proxy status
- **Settings**:
  - Logging to file toggle with dynamic sidebar visibility
  - Routing strategy configuration (Round Robin / Fill First)
  - Auto-start proxy option
- **About Screen**: App info with donation options (Momo, Bank QR codes)
- **Sparkle Auto-Update**: Automatic update checking and installation
- **Bilingual Support**: English and Vietnamese localization

### Fixed

- Sheet state not resetting when reopening
- Agent configurations persisting correctly on navigation
- CLI agent configurations matching CLIProxyAPI documentation

## [0.0.1] - 2025-12-20

### Added

- Initial release
- Basic proxy management
- Provider authentication via OAuth
- Simple quota display
