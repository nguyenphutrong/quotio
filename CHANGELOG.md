# Changelog

All notable changes to Quotio will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-01-01

### Added

- **Custom AI Providers**: Add and configure your own AI providers with custom API endpoints, headers, and model mappings (#62)
- **Upstream Proxy Support**: Configure upstream proxy URL in Settings for corporate networks or VPN environments (#63)

### Fixed

- **Proxy Idle Hang**: Prevent proxy process from hanging after extended idle periods (Issue #37, #53)

## [0.3.3] - 2025-12-31

### Added

- **Beta Channel Support**: Opt-in to beta updates via Settings with separate Sparkle appcast feed (#56)
- **Dynamic App Icon**: App icon automatically switches between production and beta based on update channel (#56)
- **Privacy Mode**: Option to hide sensitive information (emails, account names) with asterisks across the app (#46)

### Fixed

- **ProgressView Crash**: Fixed Auto Layout constraint conflicts by replacing ProgressView with custom SmallProgressView component (#56)
- **Version Parsing**: Fixed version check parsing in CLIProxyManager (#56)
- **About Screen Icon**: Use observable for real-time icon updates when switching update channels (#56)
- **Menu Bar Spacing**: Adjusted horizontal padding to match native macOS spacing (#50)

## [0.3.2] - 2025-12-30

### Added

- **Chinese Localization**: Full Simplified Chinese translation for all UI strings (#39)

### Fixed

- **Sparkle Update Loop**: Sync build number to match released version, preventing false update notifications

## [0.3.1] - 2025-12-30

### Added

- **Claude Code 2.0+ Support**: Read OAuth credentials from macOS Keychain instead of credentials.json (#27)
- **Managed Proxy Upgrade**: Version manager for proxy binary updates (#30)
  - Versioned binary storage with symlink-based switching
  - SHA256 checksum verification for secure downloads
  - Compatibility check (dry-run) before activation
  - Rollback capability for failed upgrades
  - Auto-check for proxy updates on app launch
  - Upgrade available notifications
- **IDE Scan Dialog**: New consent-based IDE scanning with privacy notice (#33)
- **IDE Quota Persistence**: Cursor and Trae quota data now persists across app restarts
- **Localization**: Vietnamese translations for IDE scan UI
- **Chinese README**: Documentation in Simplified Chinese (#35)
- **MIT License**: Project now licensed under MIT (#24)

### Changed

- **About Screen Redesign**: Move update settings into About screen with modern card-based UI

### Fixed

- **Privacy**: Reduce file system access to address macOS privacy warnings (#33)
  - Remove Cursor and Trae from auto-refresh - require explicit user scan
  - Add "Scan for IDEs" button with consent dialog on Providers screen
  - No persistent storage of scan consent - cleared on app restart
- **Agent Detection**: Restore CLI binary paths for proper detection
  - GUI apps don't inherit user's shell PATH, causing `which` to fail
  - Re-add common paths: ~/.local/bin, ~/.bun/bin, ~/.cargo/bin, ~/.deno/bin
  - Add tool-specific: ~/.opencode/bin
  - Add version manager support: nvm, fnm, Volta, asdf, mise
- **ForEach ID Collision**: Fix duplicate ID issue when Cursor and Trae share same email (#33)

## [0.3.0] - 2025-12-29

### Added

- **Standalone Quota Mode**: View quota and accounts without running the proxy server - perfect for quick checks
- **Mode Switcher**: Responsive toggle in sidebar to switch between Full and Quota-Only modes
- **Trae Provider**: Support for Trae AI coding agent with quota tracking

### Changed

- **Menu Bar Redesign**: Provider-first layout with improved Liquid Glass compatibility
- **Menu Bar Animation**: Use Timer-based rotation for reliable refresh animation

### Fixed

- **Cursor SQLite**: Use immutable mode to avoid WAL file lock errors

## [0.2.3] - 2025-12-28

### Fixed

- **Menu Bar Full-Screen Support**: Replace NSPopover with custom NSPanel to enable visibility in full-screen applications (#13)
- **Menu Bar Auto-Focus**: Prevent auto-focus on buttons when panel opens (#13)

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
