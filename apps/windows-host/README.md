# Quotio Windows Host

Native Windows shell for the shared desktop UI. Plan 05 owns the WinUI 3,
WebView2, tray, single-instance, and Rust bridge implementation.

## Development

Build from Windows with the .NET 8 SDK and Windows App SDK workloads:

```powershell
dotnet build apps/windows-host/Quotio.Windows.csproj
```

The host loads `apps/desktop-ui/dist` when bundled by MSBuild. For live UI
development, set `QUOTIO_DESKTOP_UI_DEV_SERVER` to the Vite server URL.

The management bridge keeps credentials on the native side. In this foundation
phase it reads `QUOTIO_MANAGEMENT_BASE_URL` and `QUOTIO_MANAGEMENT_KEY` from the
Windows process environment; later plans should replace that with the shared
runtime/core configuration store.
