namespace Quotio.Windows;

using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

public static class WindowsCrashReporter
{
    private const string ReportDirectoryEnvironmentKey = "QUOTIO_WINDOWS_CRASH_REPORT_DIR";
    private const string UploadUrlEnvironmentKey = "QUOTIO_WINDOWS_CRASH_UPLOAD_URL";
    private static readonly TimeSpan UploadTimeout = TimeSpan.FromSeconds(5);
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static CrashReportResult Capture(Exception error, string source)
    {
        var report = new CrashReport(
            Id: Guid.NewGuid().ToString("N"),
            Timestamp: DateTimeOffset.UtcNow,
            Source: Redact(source),
            ExceptionType: error.GetType().FullName ?? error.GetType().Name,
            Message: Redact(error.Message),
            StackTrace: Redact(error.ToString())
        );
        var payload = JsonSerializer.Serialize(report, SerializerOptions);
        var reportPath = WriteReport(report.Id, payload);

        var uploadUrl = Environment.GetEnvironmentVariable(UploadUrlEnvironmentKey)?.Trim();
        if (!TryCreateUploadUri(uploadUrl, out var uri))
        {
            return new CrashReportResult(report.Id, reportPath, false, false, null);
        }

        try
        {
            using var client = new HttpClient { Timeout = UploadTimeout };
            using var content = new StringContent(payload, Encoding.UTF8);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            using var response = client.PostAsync(uri, content).GetAwaiter().GetResult();
            return new CrashReportResult(
                report.Id,
                reportPath,
                true,
                response.IsSuccessStatusCode,
                response.IsSuccessStatusCode
                    ? null
                    : $"Crash upload failed with {(int)response.StatusCode}"
            );
        }
        catch (Exception uploadError)
        {
            return new CrashReportResult(
                report.Id,
                reportPath,
                true,
                false,
                Redact(uploadError.Message)
            );
        }
    }

    private static string WriteReport(string id, string payload)
    {
        var directory = ResolveReportDirectory();
        Directory.CreateDirectory(directory);
        var reportPath = Path.Combine(directory, $"{id}.json");
        File.WriteAllText(reportPath, $"{payload}{Environment.NewLine}", new UTF8Encoding(false));
        return reportPath;
    }

    private static bool TryCreateUploadUri(string? rawUrl, out Uri uri)
    {
        if (Uri.TryCreate(rawUrl, UriKind.Absolute, out var parsed)
            && (parsed.Scheme == Uri.UriSchemeHttps
                || (parsed.Scheme == Uri.UriSchemeHttp && parsed.IsLoopback)))
        {
            uri = parsed;
            return true;
        }

        uri = new Uri("about:blank");
        return false;
    }

    private static string ResolveReportDirectory()
    {
        var overridePath = Environment.GetEnvironmentVariable(ReportDirectoryEnvironmentKey)?.Trim();
        if (!string.IsNullOrEmpty(overridePath))
        {
            return overridePath;
        }

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "Quotio", "crash-reports");
    }

    private static string Redact(string value)
    {
        var redacted = Regex.Replace(
            value,
            "(?i)(authorization\\s*:\\s*bearer\\s+)[^\\s,;]+",
            "$1[redacted]"
        );
        redacted = Regex.Replace(
            redacted,
            "(?i)((?:api|management)[-_ ]?key\\s*[:=]\\s*)[^\\s,;]+",
            "$1[redacted]"
        );
        return redacted;
    }

    private sealed record CrashReport(
        string Id,
        DateTimeOffset Timestamp,
        string Source,
        string ExceptionType,
        string Message,
        string StackTrace
    );
}

public sealed record CrashReportResult(
    string ReportId,
    string ReportPath,
    bool UploadAttempted,
    bool UploadSucceeded,
    string? UploadError
);
