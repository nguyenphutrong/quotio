# Changelog

All notable changes to Quotio will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.7] - 2026-01-27

### Added

- **logs**: Display fallback trace details in request log (#200)

### Fixed

- **proxy**: Handle thinking block signature errors on provider switch (#218)
  - Detect provider-bound cryptographic signatures that cause 400 errors
  - Add response-driven sanitization with automatic retry
  - Strip thinking/redacted_thinking blocks when forwarding between Claude providers
- **quota**: Handle ISO8601 dates with and without fractional seconds (#233)
  - Fix reset time not displaying for some providers (e.g., Codex)
- **settings**: Initialize app services on launch for auto-start at login (#225)
  - Fix proxy not auto-starting when app launches at login with dock hidden
  - Move initialization to AppDelegate for immediate service startup
- **agent**: Update Factory Droid URL to new documentation site (#224)
- **auth**: Preserve prefix, project_id, and proxy_url fields when refreshing auth tokens (#210)
- **menubar**: Add configurable max items with improved UX (#209)
  - Add truncation confirmation dialog when reducing max items
  - Fix warning threshold relative to maxItems

## [0.7.6] - 2026-01-17

### Added

- **warp**: Add support for Warp AI quota tracking (#197)
  - Dedicated Warp provider with OAuth-based authentication
  - Display bonus credits with expiration and tooltip
  - Fetch bonus grants from workspaces and user level

### Fixed

- **quota**: Scope subscriptions by provider and show plan badges in menubar (#199)
  - Store subscriptionInfos per provider to avoid cross-provider overrides
  - Fall back to planDisplayName for menubar tier badge
  - Improve Codex accountId extraction for ChatGPT-Account-Id header

## [0.7.5] - 2026-01-15

### Added

- **agent-config**: Agent configuration persistence, proxy switching & backups (#178)
  - Load existing agent settings from disk and environment variables
  - Toggle between routing through Quotio proxy or direct to providers
  - Automatic configuration backups before applying new settings
  - UI to view and restore from previous backups

### Changed

- **fallback**: Simplify fallback logic by removing format conversion (#186)

## [0.7.4] - 2026-01-13

### Added

- **settings**: Customizable usage calculation and aggregation modes (#160)
  - Total usage calculation: session-only vs combined
  - Model aggregation: lowest vs average
  - New Usage Display section in Settings

### Fixed

- **routing**: Fetch routing strategy from dedicated API endpoint (#174)
  - Fix setting reset to 'round-robin' when navigating away from Settings
  - Handle both legacy and new response formats
- **routing**: Prevent routing strategy reset when leaving settings view (#173)
- **i18n**: Add missing translations for zh-Hans, vi, and fr (#171)

## [0.7.3] - 2026-01-13

### Added

- **fallback**: Cross-provider format conversion with FallbackFormatConverter (#169)
  - APIFormat detection (openai, anthropic, google) for automatic conversion
  - Message and tool_use/tool_calls conversion between Anthropic and OpenAI formats
  - System message and parameter conversion across providers
  - Thinking block cleanup for non-Claude models
- **kiro**: Proactive token refresh with 5-min buffer before expiry (#169)
  - Reactive refresh on 401/403 responses with automatic retry
  - Display token expiry time in quota UI
- **fallback**: Dynamic provider parameter adaptation for virtual models (#169)
  - Fix maxOutputTokens error by adapting API parameters based on actual provider
  - ModelCache with stale-while-revalidate pattern
  - Cache by entry ID (not index) for correct reordering handling
- **logs**: Display fallback route info (virtual → resolved model/provider) in request logs (#169)
- **agent-setup**: Decoupled cache invalidation when provider accounts change (#169)

### Fixed

- **copilot**: Treat educational quota as Pro for GitHub Copilot (#164)
  - Educational accounts (free_educational_quota) now display as 'Pro' with unlimited chat/completions
- **fallback**: Model picker now falls back to default when saved model unavailable (#169)

## [0.7.2] - 2026-01-12

### Fixed

- **copilot**: Add missing plan types to planDisplayName (#162)
  - Add 8 additional plan types: guest, go, free_workspace, business, education, quorum, k12, edu
- **crash**: Prevent crash in String.index(after:) at boundary (#161)
  - Add bounds checking to prevent EXC_BREAKPOINT at string boundaries (Fixes #103)

## [0.7.1] - 2026-01-12

### Added

- **tunnel**: Share Proxy via Cloudflare Tunnel (#137)
  - Expose local proxy to internet with temporary public URL
  - TunnelManager for lifecycle management with orphan cleanup
  - Dashboard integration with status badge and public URL display
  - Menu bar tunnel section with start/stop controls
  - Auto-start tunnel option in Settings
- **menu-bar**: Quota display styles with ring progress indicator (#146)
  - QuotaDisplayStyle enum (card, lowestBar, ring)
  - RingProgressView circular progress component
  - Display style picker in Settings
- **network**: Allow network access - bind to 0.0.0.0 (#147) - thanks @Benson 🎉
- **proxy**: Upstream proxy support for all quota fetchers and managers (#145) - thanks @Tsingv 🎉
  - ProxyConfigurationService for centralized proxy configuration
  - All quota fetchers now route through user-configurable proxy

### Fixed

- **settings**: Launch at login setting not working (#130, #139)
  - Add LaunchAtLoginManager with robust error handling
  - App location validation (/Applications requirement)
  - Handle .requiresApproval status from System Settings
- **tunnel**: Clean build warnings and tunnel handling (ccbf9ff)

## [0.7.0] - 2026-01-09

### Added

- **fallback**: Model Fallback Strategy System (Experimental) (#136)
  - Create virtual models with automatic provider fallback based on quota availability
  - Dynamic fallback resolution at request time in ProxyBridge
  - Auto-retry with next fallback entry on quota exhaustion (429)
  - Bridge Mode routing when Fallback is enabled
  - New Fallback screen for managing virtual models and entries
- **ui**: Add ExperimentalBadge component for marking experimental features (a345698)
- **onboarding**: Complete redesign with step-based flow (#136)
  - Welcome, Mode Selection, Provider, Remote Setup, and Completion steps
- **remote**: Remote connection support for connecting to remote proxy servers (#136)
- **ui**: CurrentModeBadge component for displaying current operating mode (#136)
- **docs**: Add Contributor Covenant Code of Conduct (6c2915b)

### Changed

- **mode**: Refactor operating mode system with enhanced OperatingMode struct (#136)
- **agent**: Route through ProxyBridge when Fallback is enabled for virtual model detection (#136)

### Fixed

- **dock**: Fix dock icon management and ghost icon issues (#133)
- **fallback**: Fix fallback route caching for better performance (#133)
- **proxy**: CLIProxyAPIPlus v6.6.92+ compatibility (#133)
- **quality**: Code quality improvements and cleanup (#135)

## [0.6.0] - 2026-01-06

### Added

- **kiro**: Complete Kiro provider integration with quota monitoring and OAuth improvements (#118)
  - Rewrite KiroQuotaFetcher to parse actual AWS CodeWhisperer API response
  - Support trial accounts (500 bonus credits) and paid accounts (50 base credits)
  - Display correct percentage remaining with expiry/reset dates
  - Show plan type from subscription info (e.g., "KIRO FREE")
- **models**: Dynamic model fetching from proxy `/models` endpoint (#118)
  - Cache models in UserDefaults for faster subsequent loads
  - Add refresh button with loading indicator in Agent Config sheet
  - Group models by provider (Anthropic, OpenAI, Google) in picker dropdown
- **antigravity**: Auto-warmup scheduling for token counter reset (#104)
  - Flexible scheduling: "Every X minutes", "Every X hours", or "Daily at [Time]"
  - Immediate trigger for interval-based schedules
  - Cost-efficient single model selection to minimize resource consumption
- **quota**: Improve Claude Code quota handling and multi-account UX (#109)
  - Authentication error detection for expired OAuth tokens (~1 hour TTL)
  - Show re-authenticate button when token expires
  - Account count badge in AddProviderPopover
  - Hint text for adding multiple accounts
  - Show "quota not available" message for providers without quota API

### Changed

- Replace curl with URLSession for Claude Code network requests (#109)

### Fixed

- **settings**: Fix menu bar icon toggle and dock visibility (#107)
  - Fix bug where toggling "Show Menu Bar Icon" OFF caused window and dock to disappear
  - Fix bug where toggling menu bar icon back ON didn't restore the icon
  - Apply "Show in Dock" toggle immediately on app launch
- **kiro**: Fix menu bar ghost icon issue for Kiro accounts (#118)
- **kiro**: Show auth provider name (e.g., "Google") when email is empty (#118)
- **agent-config**: Adjust footer height in AgentConfigSheet for better layout (#119)
- **quota**: Fix RequestTracker ISO8601 date decoding mismatch (#109)

## [0.5.1] - 2026-01-04

### Added

- **glm**: add GLM provider support with API key-based quota tracking (#77) - thanks @prnake 🎉

### Fixed

- **detection**: check XDG_DATA_HOME for fnm path detection (#102)
- **glm**: resolve Swift 6 concurrency warnings in GLMQuotaFetcher (#106)

## [0.5.0] - 2026-01-04

### Added

- unified operating mode system with remote management support (#86)
- **settings**: add management API key display and regenerate (#97)

### Changed

- **changelog**: clean up duplicates and add auto-squash for prereleases (fa1a273)
- Memory optimization - reduce RAM from 150-250MB to <100MB (#100)

### Fixed

- **proxy**: add buffer to reduce stop/start race condition window (#93)
- **settings**: add restart notice for routing strategy changes (#94)
- **proxy**: prevent hang after extended runtime (#96)

## [0.4.4] - 2026-01-03

### Fixed

- **antigravity**: Fix account switch DB lock handling with SQLite3 busy timeout and immediate transactions (#88)

## [0.4.3] - 2026-01-03

### Added

- migrate to Swift 6 with strict concurrency (#83)

### Fixed

- **ci**: resolve bash regex parsing issue and add manual workflow trigger (651fd46)
- **ci**: merge appcast entries to make beta releases visible to updater (33e28a8)
- **antigravity**: fix Use in IDE hanging on macOS 15.5+ (#81)

## [0.4.2] - 2026-01-02

### Added

- **Configurable Refresh Cadence**: Add setting to configure auto-refresh interval with 10-minute default (#76)
- **GitHub Actions CI/CD**: Automated release workflow with tag-based and manual triggers (#74)
  - Add `update-changelog.sh` script for automated changelog updates
  - Add `generate-appcast-ci.sh` for CI-compatible Sparkle appcast generation
  - Add `quick-release.sh` helper for local tag creation

### Changed

- **String Catalogs Localization**: Migrate from in-code dictionary to `Localizable.xcstrings` with 600+ keys across 4 languages (#74)
  - Dynamic language switching without app restart
  - Modernize `LanguageManager` with `@Observable` pattern
  - Migrate legacy "zh" language code to "zh-Hans"

### Fixed

- **Swift 6 Concurrency**: Resolve build errors and concurrency warnings for Xcode 16.2
  - Add `localizedStatic()` nonisolated variant for enum computed properties
  - Fix sendability issues in `AntigravityDatabaseService`, `AntigravityProcessManager`, `CLIExecutor`, `CLIProxyManager`
- **CI Compatibility**: Update Xcode version to 16.2 for macos-14 runner compatibility
- **Build Scripts**: Improve reliability and error handling
- **Localization Crash**: Fix duplicate dictionary key causing compiler error and app launch crash

## [0.4.1] - 2026-01-02

### Added

- **French Localization**: Full French translation for all UI strings and README documentation
- **Antigravity 4-Group Display**: Replace 3-group display with 4 model groups: Gemini 3 Pro, Gemini 3 Flash, Gemini 3 Image, Claude 4.5 (#66)
  - Add expandable group rows in QuotaScreen with individual model details
  - Show model count badge and individual progress bars when expanded
- **Native Menu Bar Submenus**: Implement `NSMenuItem.submenu` for Antigravity accounts with automatic hover cascade (#66)
  - Reactive provider picker - accounts update immediately when switching providers (no menu close needed)
  - Add `rebuildMenuInPlace()` for proper menu refresh across macOS Desktops

### Fixed

- **Menu Bar Submenu Hover**: Fix submenu not working after switching macOS Desktops (#66)
- **Menu Bar Dynamic Height**: Fix incorrect height when switching between providers (#66)
- **Menu Bar Loading Animation**: Use Timer with `.common` RunLoop mode for animation while menu is open (#66)
- **Model Display Names**: Consistent naming across QuotaScreen and menu bar (#66)

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

### Added

- **Refresh Button**: Manual refresh button for auto-detected providers section to detect logout changes (#11)

### Changed

- Increase auto-refresh interval from 5s to 15s to reduce connection pressure (#11)

### Fixed

- **Proxy Connection Leak**: Fix URLSession connection leak in ManagementAPIClient with proper lifecycle management (#11)
- **Menu Bar Sync**: Fix menu bar not updating when accounts are removed or logged out (#11)
- **Quota Calculation**: Filter out unknown percentages when calculating lowest quota for menu bar display (#8)
- **ForEach Duplicate ID**: Add uniqueId field combining provider+email to prevent duplicate ID warnings (#11)
- **Race Condition**: Avoid race condition in stopProxy by capturing client reference before invalidation (#11)

## [0.2.1] - 2025-12-27

### Added

- **Appearance Settings**: New theme settings with System, Light, and Dark mode options

### Changed

- Updated and optimized app screenshots

### Fixed

- **Claude Code Reconfigure**: Preserve existing settings.json configuration when reconfiguring Claude Code (#3)
- **Dashboard UI**: Hide +Cursor button for non-manual-auth providers (#5)

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

### Added

- Loading indicator in sidebar during proxy startup
- Force termination with timeout and SIGKILL fallback for reliable proxy shutdown
- Kill-by-port cleanup to handle orphan processes
- Claude Code configuration storage option (global vs project-local)
- Dev build distinction with separate app icon

### Changed

- Menu bar now persists when main window is closed (app runs in background)
- Improved build configuration with xcconfig support for dev/prod separation

### Fixed

- Proxy process not terminating after running for a while
- Orphan proxy processes remaining after app quit
- Proxy still running when quitting app from menu bar

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
