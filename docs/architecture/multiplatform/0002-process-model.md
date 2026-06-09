# ADR 0002: Process Model

## Status

Accepted for migration.

## Context

The existing macOS app manages CLIProxyAPI/cpa-plusplus locally and also
supports remote and quota-only modes. Windows needs equivalent lifecycle
semantics without assuming macOS process APIs.

## Decision

The Rust core models three runtime ownership states:

- `managed`: Quotio owns the proxy process and may stop or restart it.
- `external`: a compatible proxy is reachable but was not started by Quotio.
- `stopped`: no compatible proxy is reachable.

The host owns process cleanup on application exit. Rust provides bounded start,
stop, restart, status, health probe, and event streams, but it must not terminate
an unrelated external process.

## Consequences

The current managed binary must never be deleted during cleanup or upgrade.
Crash recovery must be bounded and visible through lifecycle events.
