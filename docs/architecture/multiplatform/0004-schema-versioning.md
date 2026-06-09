# ADR 0004: Schema Versioning

## Status

Accepted for migration foundation.

## Context

Swift, C#, Rust, and TypeScript must agree on request, response, event, and
model shapes. Silent decoding drift would make cross-platform behavior fragile.

## Decision

Keep schema files under `schema/` and generate language artifacts from them.
Every envelope carries `contractVersion`. Hosts reject messages with an
unsupported major version before decoding payload-specific fields.

Generated artifacts are committed. CI checks that regeneration is deterministic
and fails when schema changes are not reflected in generated files.

## Consequences

Handwritten duplicate DTOs are not allowed for contract types. Platform models
may wrap generated DTOs only at ownership boundaries.
