# Settings Ownership

This map keeps shared settings UI from storing platform-only state or secrets.

## Shared UI Read Model

- `operatingMode`: host-provided mode (`local`, `remote`, or future `quota-only`).
- `capabilities`: host-provided booleans used to hide unsupported controls.
- `features`: host-provided route flags used to expose only ported screens.
- `locale` and `appearance`: host-owned values mirrored into shared UI.

## Server-Managed Settings

- Gateway logging, debug, switch-preview, quota-exceeded, model filters, virtual model routing, and usage statistics settings belong to CLIProxyAPI management endpoints.
- Shared UI may render these settings only through the management bridge.
- Mutations must refresh authoritative server state after success.

## macOS-Only Settings

- Sparkle update settings, menu bar display, launch behavior, app appearance source of truth, language source of truth, bundled proxy storage, local proxy process controls, CLI agent file patching, and Keychain-backed remote credentials.
- Shared UI can request host actions for these, but must not persist them itself.

## Windows-Only Settings

- Window placement, tray behavior, Windows Credential Manager remote credentials, Windows installer/update settings, and Windows service/startup integration.
- Shared UI can display controls only when `capabilities` says the host supports them.

## Secret Handling

- Management keys, OAuth codes, provider tokens, cookies, and client-key secrets must not be logged or stored in shared preferences.
- Remote management credentials stay in Keychain on macOS and Credential Manager on Windows.
- Shared UI may temporarily hold credential input state only inside an active form before passing it to the native host.

## Mode Rules

- Local mode may show proxy control, port, CLI OAuth, and agent configuration.
- Remote mode must hide local proxy controls, port configuration, CLI OAuth, and agent configuration.
- Quota-only mode is reserved for a future restricted surface and must default to the smallest route set.
