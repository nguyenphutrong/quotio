// Generated from schema/contract.json. Do not edit manually.

namespace Quotio.Contract;

public static class QuotioContract
{
    public const int Version = 1;
}

public enum QuotioRequestKind
{
    RuntimeStatus,
    RuntimeStart,
    RuntimeStop,
    RuntimeRestart,
    ManagementRequest,
    NativeConfirm,
    NativeNotify,
    NativeOpenExternal,
    NativeOpenTextFile,
    NativeCredentialRead,
    NativeCredentialWrite,
    NativeCredentialDelete,
}

public enum QuotioEventKind
{
    RuntimeStatusChanged,
}

public sealed record RuntimeStatus
{
    public required string State { get; init; }
    public required string? Endpoint { get; init; }
}

public sealed record ManagementResponse
{
    public required int Status { get; init; }
    public required string? Body { get; init; }
}

public sealed record AgentDescriptor
{
    public required string Id { get; init; }
    public required string DisplayName { get; init; }
    public required string ConfigType { get; init; }
    public required IReadOnlyList<string> BinaryNames { get; init; }
    public required IReadOnlyList<string> MacosConfigPaths { get; init; }
    public required IReadOnlyList<string> WindowsConfigPaths { get; init; }
    public required string MacosSupport { get; init; }
    public required string WindowsSupport { get; init; }
    public required string BackupPolicy { get; init; }
    public required string? DocsUrl { get; init; }
}

public sealed record AgentDetectionStatus
{
    public required string AgentId { get; init; }
    public required string PlatformSupport { get; init; }
    public required bool Installed { get; init; }
    public required bool Configured { get; init; }
    public required bool RollbackAvailable { get; init; }
    public required string? BinaryPath { get; init; }
    public required string? Version { get; init; }
    public required string? Message { get; init; }
}

public sealed record NativeCredential
{
    public required string TargetName { get; init; }
    public required bool Exists { get; init; }
    public required string? Value { get; init; }
}
