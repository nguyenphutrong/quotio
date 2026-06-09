namespace Quotio.Windows;

using System.Diagnostics;

public static class DiagnosticLog
{
    private const string LogDirectoryEnvironmentKey = "QUOTIO_WINDOWS_LOG_DIR";
    private static readonly object Sync = new();
    private static bool registeredUnhandledHandlers;

    public static string LogFilePath => Path.Combine(ResolveLogDirectory(), "windows-host.log");

    public static void Info(string message)
    {
        Trace.TraceInformation(message);
        Write("INFO", message);
    }

    public static void Error(string message, Exception error)
    {
        Trace.TraceError($"{message}: {error}");
        Write("ERROR", $"{message}: {error}");
    }

    public static void RegisterUnhandledExceptionHandlers()
    {
        lock (Sync)
        {
            if (registeredUnhandledHandlers)
            {
                return;
            }

            AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            {
                if (args.ExceptionObject is Exception error)
                {
                    Error("Unhandled application exception", error);
                    return;
                }

                Write("ERROR", $"Unhandled application exception: {args.ExceptionObject}");
            };
            TaskScheduler.UnobservedTaskException += (_, args) =>
            {
                Error("Unobserved task exception", args.Exception);
            };
            registeredUnhandledHandlers = true;
        }
    }

    private static void Write(string level, string message)
    {
        try
        {
            lock (Sync)
            {
                Directory.CreateDirectory(ResolveLogDirectory());
                File.AppendAllText(
                    LogFilePath,
                    $"{DateTimeOffset.UtcNow:O} [{level}] {message}{Environment.NewLine}"
                );
            }
        }
        catch (Exception error)
        {
            Trace.TraceError($"Failed to write Windows host diagnostic log: {error}");
        }
    }

    private static string ResolveLogDirectory()
    {
        var overridePath = Environment.GetEnvironmentVariable(LogDirectoryEnvironmentKey)?.Trim();
        if (!string.IsNullOrEmpty(overridePath))
        {
            return overridePath;
        }

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "Quotio", "logs");
    }
}
