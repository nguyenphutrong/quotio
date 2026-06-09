# Native Multiplatform Architecture

This directory records the migration decisions for the macOS + Windows
architecture. The implementation source of truth remains the current Swift app
on `dev`; these ADRs define the boundaries for the staged migration.

## Demo Frontend Pin

Frontend source reference:
`/Volumes/Avocado/code/nguyenphutrong/quotio-go-demo`

Pinned tracked commit:
`351a839646114f39479d4c534796019aea757236`

The demo worktree was dirty when the pin was recorded, so migration work must
copy files from the pinned commit, not from the live working tree.

## ADRs

- [ADR 0001: Layer ownership](0001-layer-ownership.md)
- [ADR 0002: Process model](0002-process-model.md)
- [ADR 0003: IPC and host bridge](0003-ipc-and-host-bridge.md)
- [ADR 0004: Schema versioning](0004-schema-versioning.md)
- [ADR 0005: Demo frontend adoption](0005-demo-frontend-adoption.md)
- [ADR 0006: Cutover gap matrix](0006-cutover-gap-matrix.md)
