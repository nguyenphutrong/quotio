# Quotio Windows Host

Native Windows shell for the shared desktop UI. Plan 05 owns the WinUI 3,
WebView2, tray, single-instance, and Rust bridge implementation.

The Windows host is currently a preview artifact. It is expected to build and
exercise the shared UI bridge, Credential Manager-backed bootstrap config, and
read-only agent adapter, but it is not production parity with macOS until
installer, signing, updater, agent write/rollback adapters, and cutover checks
in `docs/architecture/multiplatform/0006-cutover-gap-matrix.md` are done.

## Development

Build from Windows with the .NET 8 SDK and Windows App SDK workloads:

```powershell
dotnet build apps/windows-host/Quotio.Windows.csproj
dotnet run --project apps/windows-host-smoke/Quotio.WindowsSmoke.csproj --configuration Release
```

CI uploads `quotio-windows-preview.zip` from the Windows job. The artifact is a
preview build output for smoke testing only; it is not an installer, is not
signed, and does not include an updater.

Maintainers can publish the same unsigned ZIP as a GitHub prerelease through the
`Windows Preview Release` workflow. Preview release tags must start with
`windows-preview-`.

The host loads `apps/desktop-ui/dist` when bundled by MSBuild. For live UI
development, set `QUOTIO_DESKTOP_UI_DEV_SERVER` to the Vite server URL.

The preview runtime bridge can start and stop a process owned by the Windows
host when `QUOTIO_PROXY_BINARY` is set. Optional `QUOTIO_PROXY_ARGS` are split on
spaces, and `QUOTIO_PROXY_ENDPOINT` defaults to `http://127.0.0.1:8386`.

The management bridge keeps credentials out of the shared UI. In this
foundation phase it reads configuration from environment variables first, then
falls back to generic Windows Credential Manager entries:

- `QUOTIO_DESKTOP_UI_DEV_SERVER` or `Quotio/DesktopUiDevServer`
- `QUOTIO_MANAGEMENT_BASE_URL` or `Quotio/ManagementBaseUrl`
- `QUOTIO_MANAGEMENT_KEY` or `Quotio/ManagementKey`
- `QUOTIO_PROXY_BINARY` or `Quotio/ProxyBinary`
- `QUOTIO_PROXY_ARGS` or `Quotio/ProxyArgs`
- `QUOTIO_PROXY_ENDPOINT` or `Quotio/ProxyEndpoint`

The bootstrap still does not advertise remote connection, credential editing, or
native onboarding capabilities. Later plans should add verified write/update
flows before enabling those shared UI controls.

The shared Agents route is enabled with a read-only Windows adapter. It lists
agent descriptors, detects binaries/config files, and serves manual guides.
Automatic install and rollback actions remain disabled until backup and rollback
behavior is verified on Windows.
