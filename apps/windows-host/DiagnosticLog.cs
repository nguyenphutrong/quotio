namespace Quotio.Windows;

using System.Diagnostics;

public static class DiagnosticLog
{
    public static void Info(string message)
    {
        Trace.TraceInformation(message);
    }

    public static void Error(string message, Exception error)
    {
        Trace.TraceError($"{message}: {error}");
    }
}
