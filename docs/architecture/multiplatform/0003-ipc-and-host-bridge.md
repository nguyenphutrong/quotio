# ADR 0003: IPC and Host Bridge

## Status

Accepted for migration foundation.

## Context

The same React bundle must run in `WKWebView` and WebView2. The same shared core
must be callable from Swift and C#.

## Decision

Use an asynchronous, versioned JSON-RPC style bridge as the production baseline:

- React sends typed request envelopes to the native host.
- Native hosts route requests to Rust core or host adapters.
- Responses include request id, result or normalized error, and contract version.
- Events flow from host to React with typed event envelopes.
- No React render path requires synchronous IPC.

UniFFI remains a spike candidate for direct Swift/C# Rust bindings. It is not a
requirement for the first production foundation because the JSON-RPC contract is
easier to validate consistently across Swift, C#, Rust, and TypeScript.

## Failure And Cancellation Semantics

Unsupported contract versions fail before handler dispatch. Unknown methods
return a typed `unsupportedMethod` error. Timed-out requests return
`timeout`. Host-initiated cancellation emits a terminal response when possible
and a best-effort cancellation event when the underlying operation cannot be
interrupted immediately.
