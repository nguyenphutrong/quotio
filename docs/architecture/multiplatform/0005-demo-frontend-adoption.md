# ADR 0005: Demo Frontend Adoption

## Status

Accepted for migration foundation.

## Context

`quotio-go-demo` already contains a Turbo/Bun React workspace, `@quotio/ui`,
shadcn/Base UI primitives, Tailwind CSS v4 tokens, TanStack libraries, i18next,
provider assets, and feature screens that overlap with Quotio.

## Decision

Adopt the tracked frontend baseline from commit
`351a839646114f39479d4c534796019aea757236`. Do not copy uncommitted demo
worktree changes.

Copy with minimal changes:

- root Bun/Turbo/TypeScript/Biome/Lefthook setup
- `packages/ui`
- design tokens and shadcn/Base UI primitives
- TanStack Router, Query, Form, and i18next patterns
- provider assets and reusable feature folder layout

Adapt before use:

- replace web admin token/login/runtime with a typed host bridge
- make native hosts authoritative for theme, accent, credentials, dialogs, file
  pickers, OAuth, and notifications
- replace browser/server bootstrap assumptions with host-provided bootstrap
- use system font stacks and platform token overrides for desktop chrome

## Consequences

The demo is the preferred implementation starting point, but native OS behavior
and the current Swift app remain higher-precedence references.
