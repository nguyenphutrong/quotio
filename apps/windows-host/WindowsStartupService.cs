namespace Quotio.Windows;

using Microsoft.Win32;

public static class WindowsStartupService
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AppName = "Quotio";

    public static bool IsEnabled()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            return string.Equals(
                ReadRegisteredCommand(),
                BuildStartupCommand(),
                StringComparison.Ordinal
            );
        }
        catch (Exception error)
        {
            DiagnosticLog.Error("Failed to read Windows startup registration", error);
            return false;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
                ?? throw new InvalidOperationException("Unable to open Windows startup registry key");

            if (enabled)
            {
                key.SetValue(AppName, BuildStartupCommand(), RegistryValueKind.String);
            }
            else
            {
                key.DeleteValue(AppName, throwOnMissingValue: false);
            }
        }
        catch (Exception error)
        {
            DiagnosticLog.Error("Failed to update Windows startup registration", error);
            throw new InvalidOperationException("Unable to update Windows startup registration", error);
        }
    }

    internal static string? ReadRegisteredCommand()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(AppName) as string;
    }

    internal static void RestoreRegisteredCommand(string? command)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException("Unable to open Windows startup registry key");

        if (command is null)
        {
            key.DeleteValue(AppName, throwOnMissingValue: false);
        }
        else
        {
            key.SetValue(AppName, command, RegistryValueKind.String);
        }
    }

    public static string BuildStartupCommand(string? executablePath = null)
    {
        var path = string.IsNullOrWhiteSpace(executablePath)
            ? Environment.ProcessPath ?? Environment.GetCommandLineArgs().FirstOrDefault() ?? ""
            : executablePath;

        return QuoteCommandPath(path);
    }

    private static string QuoteCommandPath(string path)
    {
        return $"\"{path.Replace("\"", "\\\"", StringComparison.Ordinal)}\"";
    }
}
