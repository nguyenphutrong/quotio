namespace Quotio.Windows;

using System.Diagnostics;
using System.Net.Sockets;
using Quotio.Contract;

public sealed class RuntimeProcessController : IDisposable
{
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan ProbeInterval = TimeSpan.FromMilliseconds(100);
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

        if (child is not null)
        {
            DisposeExitedChild();
            return new RuntimeStatus
            {
                State = "crashed",
                Endpoint = null
            };
        }

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

        if (!WaitForEndpoint())
        {
            Stop();
            throw new InvalidOperationException("Windows runtime process started but did not become reachable");
        }

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

    public RuntimeStatus Restart()
    {
        Stop();
        return Start();
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

    private void DisposeExitedChild()
    {
        var process = child;
        child = null;

        if (process is null)
        {
            return;
        }

        try
        {
            if (process.HasExited)
            {
                process.WaitForExit();
            }
        }
        finally
        {
            process.Dispose();
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

    private bool WaitForEndpoint()
    {
        if (!Uri.TryCreate(config.ProxyEndpoint, UriKind.Absolute, out var endpoint) || endpoint.Port <= 0)
        {
            return false;
        }

        var deadline = DateTimeOffset.UtcNow + StartupTimeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (!ChildIsRunning())
            {
                return false;
            }

            if (CanConnect(endpoint.Host, endpoint.Port))
            {
                return true;
            }

            Thread.Sleep(ProbeInterval);
        }

        return false;
    }

    private static bool CanConnect(string host, int port)
    {
        try
        {
            using var client = new TcpClient();
            var connect = client.ConnectAsync(host, port);
            return connect.Wait(ProbeInterval) && client.Connected;
        }
        catch (SocketException)
        {
            return false;
        }
        catch (AggregateException)
        {
            return false;
        }
        catch (ObjectDisposedException)
        {
            return false;
        }
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
