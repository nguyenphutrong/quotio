namespace Quotio.Windows;

using System.Diagnostics;
using Quotio.Contract;

public sealed class RuntimeProcessController : IDisposable
{
    private const string DefaultEndpoint = "http://127.0.0.1:8386";
    private Process? child;

    public RuntimeStatus Status()
    {
        if (ChildIsRunning())
        {
            return ManagedStatus();
        }

        child = null;
        return new RuntimeStatus
        {
            State = "stopped",
            Endpoint = null
        };
    }

    public RuntimeStatus Start()
    {
        if (ChildIsRunning())
        {
            return ManagedStatus();
        }

        var binaryPath = Environment.GetEnvironmentVariable("QUOTIO_PROXY_BINARY")?.Trim();
        if (string.IsNullOrEmpty(binaryPath))
        {
            throw new InvalidOperationException("Windows runtime binary is not configured");
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = binaryPath,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        foreach (var argument in ReadArguments())
        {
            startInfo.ArgumentList.Add(argument);
        }

        child = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Failed to start Windows runtime process");

        return ManagedStatus();
    }

    public RuntimeStatus Stop()
    {
        var process = child;
        child = null;

        if (process is null)
        {
            return new RuntimeStatus
            {
                State = "stopped",
                Endpoint = null
            };
        }

        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }

            process.WaitForExit();
        }
        finally
        {
            process.Dispose();
        }

        return new RuntimeStatus
        {
            State = "stopped",
            Endpoint = null
        };
    }

    public void Dispose()
    {
        Stop();
    }

    private bool ChildIsRunning()
    {
        try
        {
            return child is { HasExited: false };
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    private static RuntimeStatus ManagedStatus()
    {
        return new RuntimeStatus
        {
            State = "managed",
            Endpoint = RuntimeEndpoint()
        };
    }

    private static string RuntimeEndpoint()
    {
        var endpoint = Environment.GetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT")?.Trim();
        return string.IsNullOrEmpty(endpoint) ? DefaultEndpoint : endpoint;
    }

    private static IReadOnlyList<string> ReadArguments()
    {
        var rawArgs = Environment.GetEnvironmentVariable("QUOTIO_PROXY_ARGS");
        if (string.IsNullOrWhiteSpace(rawArgs))
        {
            return [];
        }

        return rawArgs.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }
}
