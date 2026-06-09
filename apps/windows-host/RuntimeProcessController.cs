namespace Quotio.Windows;

using System.Diagnostics;
using Quotio.Contract;

public sealed class RuntimeProcessController : IDisposable
{
    private readonly WindowsHostConfig config;
    private Process? child;

    public RuntimeProcessController(WindowsHostConfig config)
    {
        this.config = config;
    }

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

        var binaryPath = config.ProxyBinary;
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

    private RuntimeStatus ManagedStatus()
    {
        return new RuntimeStatus
        {
            State = "managed",
            Endpoint = config.ProxyEndpoint
        };
    }

    private IReadOnlyList<string> ReadArguments()
    {
        var rawArgs = config.ProxyArgs;
        if (string.IsNullOrWhiteSpace(rawArgs))
        {
            return [];
        }

        return rawArgs.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }
}
