# ADR 0001: Layer Ownership

## Status

Accepted for migration.

## Context

Quotio is currently a native macOS menu bar app. The port must preserve native
feel on macOS and Windows while avoiding a full rewrite of product screens.

## Decision

- Native hosts own OS integration: windows, menu bar/system tray, credentials,
  launch at login/startup, updater, native dialogs, notifications, focus,
  shortcuts, file pickers, OAuth browser handoff, and lifecycle.
- React owns shared main-window screens, navigation, layout, presentation state,
  and non-system controls.
- Rust owns platform-neutral runtime behavior, CLIProxyAPI supervision,
  management API access, normalized domain models, compatibility checks, and
  shared configuration logic.
- Platform-specific behavior enters Rust through narrow host adapters rather
  than through React.

## Consequences

React never receives management keys, OAuth secrets, local credential paths, or
raw process handles. Native hosts may expose typed capabilities to React, but
they remain authoritative for privileged operations.
