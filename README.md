# Quotio

<p align="center">
  <img
    src="apps/macos/screenshots/menu_bar.png"
    alt="Quotio menu bar showing AI provider quota usage"
    width="720"
  />
</p>

<p align="center">
  <a href="https://github.com/nguyenphutrong/quotio/releases">
    <img src="https://img.shields.io/github/v/release/nguyenphutrong/quotio?filter=v*&amp;label=macOS" alt="Latest Quotio release for macOS" />
  </a>
  <a href="https://www.npmjs.com/package/quotio">
    <img src="https://img.shields.io/npm/v/quotio?label=CLI" alt="Latest Quotio CLI release on npm" />
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="Requires macOS 14 or later" />
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license" />
  </a>
</p>

<p align="center">
  <strong>Your command center for AI coding quotas, accounts, and local agents.</strong>
</p>

<p align="center">
  Quotio helps you see what quota remains, manage provider accounts, operate
  CLIProxyAPI, and connect your coding agents—from a native macOS app or the terminal.
</p>

<p align="center">
  <a href="#install-quotio">Install Quotio</a> ·
  <a href="apps/macos/README.md">macOS app documentation</a> ·
  <a href="apps/cli/README.md">CLI documentation</a> ·
  <a href="https://github.com/nguyenphutrong/quotio/releases">GitHub releases</a>
</p>

## Stay ahead of your AI limits

Quotio puts provider usage and local tooling in one place, so you can spend less
time checking dashboards and editing configuration files.

- **See quota at a glance.** Track account limits and reset windows from the menu
  bar, desktop app, terminal, JSON output, or local REST API.
- **Bring your accounts together.** Use supported OAuth, API key, CLI, and native
  credential sources without copying secrets into project files.
- **Run your local proxy with confidence.** Start and monitor CLIProxyAPI, manage
  routing, and keep provider accounts close to the tools that use them.
- **Connect coding agents faster.** Detect and configure Claude Code, Codex CLI,
  Amp, OpenCode, and Factory Droid while preserving existing user settings.
- **Choose the interface that fits.** Use the native macOS experience for daily
  work or the Rust CLI for scripts, headless systems, and automation.

## Choose your Quotio

| Product | Best for | Platforms |
| --- | --- | --- |
| [Quotio for macOS](apps/macos/README.md) | Visual quota monitoring, account management, CLIProxyAPI lifecycle, agent setup, menu bar access, and automatic updates | macOS 14 or later |
| [Quotio CLI](apps/cli/README.md) | Fast text or JSON reports, scripting, saved accounts, and a loopback REST API | macOS Apple Silicon/Intel and Linux x64 |

Both products live in this repository and share one goal: make AI coding usage
visible and manageable without sending your credentials through a hosted Quotio
service.

## Sponsors

### Featured Sponsor

<p align="center">
  <a href="https://pateway.ai/?ch=wmw7uy">
    <img
      src=".github/assets/sponsors/patewayai.png"
      alt="PatewayAI official model API relay service for Claude and GPT"
      width="100%"
    />
  </a>
</p>

Thanks to [PatewayAI](https://pateway.ai/?ch=wmw7uy) for sponsoring this project!
PatewayAI specializes in high-quality official model API relay services. It fully
supports Claude and GPT series, with transparent billing and enterprise-grade services.
Our Economy Mode offers discounts as low as 5% off!
[Sign up via this link](https://pateway.ai/?ch=wmw7uy) to receive trial credits. You
can also join occasional promotions to claim free credits. The two-way referral reward
is up to $150.

### Standard Sponsors

<table>
  <tr>
    <td width="180" align="center">
      <a href="https://www.swiftproxy.net/?ref=quotio">
        <img src=".github/assets/sponsors/swiftproxy.png" alt="Swiftproxy logo" width="160" />
      </a>
    </td>
    <td>
      Power your AI-powered workflows with
      <a href="https://www.swiftproxy.net/?ref=quotio">Swiftproxy</a>, a residential
      proxy provider offering rotating and static residential proxies for reliable web
      access and data collection. Access 90M+ residential IPs across 220+ locations,
      with HTTP(S), SOCKS5, and flexible rotating and sticky sessions. Try it for free
      and get started with residential proxies from just $0.7/GB. Use code
      <strong>PROXY90</strong> for an additional 10% off.
      <br />
      <a href="https://www.swiftproxy.net/?ref=quotio">Explore Swiftproxy →</a>
    </td>
  </tr>
  <tr>
    <td width="180" align="center">
      <a href="https://88api.ai/sign-up?aff=OMpN">
        <img src=".github/assets/sponsors/88api.jpg" alt="88API logo" width="160" />
      </a>
    </td>
    <td>
      <a href="https://88api.ai/sign-up?aff=OMpN">88API</a> is a Hong Kong-operated
      multi-model AI API platform for developers, creators, and AI applications. It
      provides a unified API for text, image, audio, and video models, supporting common
      workflows such as AI coding, translation, content creation, voice generation, image
      generation, and video generation. 88API can be added and switched directly in CC
      Switch. It supports major international payment methods, can provide invoices, and
      offers stable service for teams and individual developers. Users who register
      through <a href="https://88api.ai/sign-up?aff=OMpN">this dedicated link</a> may
      receive complimentary credits.
      <br />
      <a href="https://88api.ai/sign-up?aff=OMpN">Explore 88API →</a>
    </td>
  </tr>
  <tr>
    <td width="180" align="center">
      <a href="https://proxy-seller.com/?partner=442060D973F44C90">
        <img src=".github/assets/sponsors/proxy-seller.png" alt="Proxy-Seller logo" width="160" />
      </a>
    </td>
    <td>
      <a href="https://proxy-seller.com/?partner=442060D973F44C90">Proxy-Seller</a> gives you reliable proxy infrastructure for any
      workflow: private residential, mobile (4G/5G/LTE), ISP, and datacenter IPv4/IPv6
      proxies, all with HTTP(S) and SOCKS5 support. Tap into 47M+ residential IPs across
      220+ locations, target exactly the country, city, or ISP you need, and count on
      99.7% uptime backed by 24/7 support. Quotio users get 15% off with promo code
      <strong>QUOTIO</strong>.
      <br />
      <a href="https://proxy-seller.com/?partner=442060D973F44C90">Explore Proxy-Seller →</a>
    </td>
  </tr>
  <tr>
    <td width="180" align="center">
      <a href="https://x6.ai">
        <img src=".github/assets/sponsors/x6ai.png" alt="x6.ai logo" width="160" />
      </a>
    </td>
    <td>
      <a href="https://x6.ai">x6.ai</a>: One API key for every major model. Official-key and proxy
      channels, up to 90% off, free credits on sign-up. Pay with Alipay, Google Pay,
      Apple Pay, Visa or Mastercard.
      <br />
      <a href="https://x6.ai">Explore x6.ai →</a>
    </td>
  </tr>
</table>

Interested in sponsoring Quotio? Contact
[quotio@bytrong.app](mailto:quotio@bytrong.app).

## Quotio for macOS

The native SwiftUI app is the full command center. It combines provider quota,
account setup, local proxy controls, agent configuration, notifications, and updates
in a desktop app that stays close in the menu bar.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="apps/macos/screenshots/dashboard_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="apps/macos/screenshots/dashboard.png" />
  <img
    src="apps/macos/screenshots/dashboard.png"
    alt="Quotio for macOS dashboard with local proxy status and quota summaries"
  />
</picture>

Read the [complete macOS feature guide and screenshot gallery](apps/macos/README.md).
The macOS guide is also available in
[Vietnamese](README.vi.md),
[Simplified Chinese](README.zh.md), and
[French](README.fr.md).

## Quotio CLI

The standalone Rust CLI brings quota checks to your terminal and automation. It
supports a broad provider catalog, private saved-account storage, deterministic JSON
reports, and an optional loopback REST API. Distributed packages contain native
binaries, so npm and Homebrew installs do not require a Rust toolchain.

```console
$ quotio providers
$ quotio usage
$ quotio usage --provider mock --format json
```

Read the [CLI usage, provider, account, and API documentation](apps/cli/README.md).

## Supported ecosystem

Quotio works with providers and services including Anthropic Claude, OpenAI Codex,
Gemini and Vertex AI, GitHub Copilot, Qwen, Kiro, Antigravity, and many more.
Provider availability and authentication methods vary between the macOS app and CLI;
their product documentation contains the current support matrix.

The macOS app can configure these coding agents to use your local proxy:

- Claude Code
- Codex CLI
- Amp
- OpenCode
- Factory Droid

## Install Quotio

### macOS app

```bash
brew install --cask nguyenphutrong/tap/quotio
```

You can also download the signed and notarized DMG from the
[latest macOS release](https://github.com/nguyenphutrong/quotio/releases/latest).

### CLI

Install the CLI with Homebrew:

```bash
brew install nguyenphutrong/tap/quotio
```

Or install the same native binaries through npm:

```bash
npm install --global quotio
```

See the [CLI release-channel documentation](apps/cli/docs/release-channels.md) for
prerelease channels and supported release targets.

## Repository layout

- [`apps/macos/`](apps/macos) — Swift and SwiftUI macOS application.
- [`apps/ios/`](apps/ios) — native iPhone companion and WidgetKit extension.
- [`apps/cli/`](apps/cli) — cross-platform Rust command-line client.
- [`Packages/QuotioCore/`](Packages/QuotioCore) — shared Swift package for the Apple app.
- [`scripts/dev`](scripts/dev) — common local build, run, and test entrypoint.
- [`.github/workflows/`](.github/workflows) — independent CI and release pipelines for each product.

## Development

Run local development commands from the repository root:

```bash
# Build and run
./scripts/dev cli -- usage
./scripts/dev macos --verify
./scripts/dev ios-sim [SIMULATOR_UDID]
./scripts/dev ios-device [DEVICE_ID]

# Test one product or the whole repository
./scripts/dev test cli
./scripts/dev test macos
./scripts/dev test ios [SIMULATOR_UDID]
./scripts/dev test all [SIMULATOR_UDID]
```

`ios-sim` and `ios-device` use the first compatible iPhone when you omit its ID.
Before using `ios-device`, copy `apps/ios/Config/Local.xcconfig.example` to
`apps/ios/Config/Local.xcconfig` and set your Apple development team. Run
`./scripts/dev --help` for the complete command list.

Use `v*` tags for macOS releases and `cli-v*` tags for CLI releases. See each
product README for build, architecture, security, and release details.

## Contributing

Bug reports, feature ideas, documentation improvements, and code contributions are
welcome. Use the repository's
[GitHub issue templates](https://github.com/nguyenphutrong/quotio/issues/new/choose)
to provide the context needed to investigate your request.

Read the [contribution guide](CONTRIBUTING.md) before opening a pull request:
current development targets `master`; legacy macOS 0.x fixes, including CLI agent
configuration, must start from and target `v0.x`.

## License

Quotio is available under the [MIT License](LICENSE).

### iPhone companion

The native iOS companion and widgets live in [apps/ios](apps/ios/README.md). It connects to Quotio hosts over HTTPS on a LAN or private VPN with a read-only device credential. Physical-device, Windows runtime and TestFlight acceptance are still pending; see the iOS README for setup and verification.
