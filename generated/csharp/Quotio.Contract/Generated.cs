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
    ManagementRequest,
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
