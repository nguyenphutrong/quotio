# Quotio Windows Host

Native Windows shell for the shared desktop UI. Plan 05 owns the WinUI 3,
WebView2, tray, single-instance, and Rust bridge implementation.

The Windows host has a preview ZIP path and a Velopack installer package path.
It is expected to build and exercise the shared UI bridge, Credential
Manager-backed bootstrap config, shared remote credential editing, local
crash-report capture, optional crash upload, native agent write/rollback
adapters, and installer/update metadata, but it is not production parity with
macOS until signing and cutover checks in
`docs/architecture/multiplatform/0006-cutover-gap-matrix.md` are done.

## Development

Build from Windows with the .NET 8 SDK and Windows App SDK workloads:

```powershell
dotnet build apps/windows-host/Quotio.Windows.csproj --configuration Release
dotnet run --project apps/windows-host-smoke/Quotio.WindowsSmoke.csproj --configuration Release
```

CI uploads `quotio-windows-preview.zip`, a `.sha256` checksum, and a
`.manifest.json` file from the Windows job. The manifest records the source
commit, build configuration, required bundled files, and per-file size/hash
metadata. The artifact is a preview build output for smoke testing only; it is
not an installer, is not signed, and does not include an updater.

CI also builds a Velopack installer artifact from the same bundled host output:

```powershell
./scripts/package-windows-installer.ps1 -Version "0.1.0" -Channel stable
```

The installer artifact contains the setup executable, `releases.<channel>.json`
update metadata, a checksum, and `quotio-windows-installer.manifest.json`.
Signing is enabled only when the script receives `-SignTemplate`; unsigned
installer artifacts are suitable for CI smoke testing but not final production
distribution.

Maintainers can publish the same unsigned ZIP as a GitHub prerelease through the
`Windows Preview Release` workflow. Preview release tags must start with
`windows-preview-`.

Maintainers can publish a Velopack installer release through the
`Windows Installer Release` workflow. Installer release tags must start with
`windows-v`. The native Settings route checks for updates through Velopack when
the app was installed by the Velopack setup executable. Raw ZIP, local build,
and dev-server launches report update support but cannot check/apply updates.

The host loads `apps/desktop-ui/dist` when bundled by MSBuild. For live UI
development, set `QUOTIO_DESKTOP_UI_DEV_SERVER` to the Vite server URL.

The preview runtime bridge can start, stop, and restart a process owned by the
Windows host when `QUOTIO_PROXY_BINARY` is set. Optional `QUOTIO_PROXY_ARGS` are
split on spaces, and `QUOTIO_PROXY_ENDPOINT` defaults to
`http://127.0.0.1:8386`. Startup is gated on the endpoint becoming reachable;
unexpected child exits are reported once as a crashed runtime status before the
bridge returns to stopped.

The host writes local diagnostics to
`%LOCALAPPDATA%\Quotio\logs\windows-host.log` and records unhandled application
exceptions plus bridge/runtime errors. Set `QUOTIO_WINDOWS_LOG_DIR` to redirect
the log during smoke testing.

Unhandled exceptions also write redacted JSON crash reports to
`%LOCALAPPDATA%\Quotio\crash-reports`. Set
`QUOTIO_WINDOWS_CRASH_REPORT_DIR` to redirect crash reports during smoke
testing. Set `QUOTIO_WINDOWS_CRASH_UPLOAD_URL` to an HTTPS endpoint to upload
the same redacted JSON payload after it is written locally. Plain HTTP is only
accepted for loopback smoke tests. The preview build does not configure a
production upload endpoint by default.

The management bridge keeps credentials in the native host. It reads
configuration from environment variables first, then falls back to generic
Windows Credential Manager entries:

- `QUOTIO_DESKTOP_UI_DEV_SERVER` or `Quotio/DesktopUiDevServer`
- `QUOTIO_MANAGEMENT_BASE_URL` or `Quotio/ManagementBaseUrl`
- `QUOTIO_MANAGEMENT_KEY` or `Quotio/ManagementKey`
- `QUOTIO_PROXY_BINARY` or `Quotio/ProxyBinary`
- `QUOTIO_PROXY_ARGS` or `Quotio/ProxyArgs`
- `QUOTIO_PROXY_ENDPOINT` or `Quotio/ProxyEndpoint`
- `QUOTIO_WINDOWS_UPDATE_REPOSITORY_URL` or `Quotio/WindowsUpdateRepositoryUrl`
- `QUOTIO_WINDOWS_UPDATE_CHANNEL` or `Quotio/WindowsUpdateChannel`

The native bridge can read, write, and delete `Quotio/*` Credential Manager
entries. The shared Settings route exposes remote management connection editing
for `Quotio/ManagementBaseUrl` and `Quotio/ManagementKey`. Native onboarding
controls stay hidden until their host adapter is implemented.

The shared Agents route is enabled with a Windows adapter. It lists agent
descriptors, detects binaries/config files, serves manual guides, and supports
Codex, Claude Code settings.json, Amp, Gemini PowerShell profile, OpenCode, and
Factory Droid install/rollback with timestamped backups. Future agents remain
read-only until their backup and rollback behavior is verified on Windows.
