namespace Quotio.Windows;

using System.Text.Json;

public sealed class WindowSettingsStore
{
    private readonly string settingsPath;

    public WindowSettingsStore()
        : this(DefaultSettingsPath())
    {
    }

    public WindowSettingsStore(string settingsPath)
    {
        this.settingsPath = settingsPath;
        var directory = Path.GetDirectoryName(settingsPath);
        if (string.IsNullOrWhiteSpace(directory))
        {
            return;
        }
        Directory.CreateDirectory(directory);
    }

    public bool TryLoad(out WindowPlacement placement)
    {
        placement = default!;
        try
        {
            if (!File.Exists(settingsPath))
            {
                return false;
            }

            var loaded = JsonSerializer.Deserialize<WindowPlacement>(
                File.ReadAllText(settingsPath)
            );
            if (loaded is null || loaded.Width <= 0 || loaded.Height <= 0)
            {
                return false;
            }

            placement = loaded;
            return true;
        }
        catch (Exception error)
        {
            DiagnosticLog.Error("Failed to load window placement", error);
            return false;
        }
    }

    public void Save(
        int x,
        int y,
        int width,
        int height,
        string? monitorDeviceName,
        bool isMaximized
    )
    {
        try
        {
            if (isMaximized && TryLoad(out var previous))
            {
                x = previous.X;
                y = previous.Y;
                width = previous.Width;
                height = previous.Height;
            }

            var placement = new WindowPlacement(
                x,
                y,
                width,
                height,
                monitorDeviceName,
                isMaximized
            );
            File.WriteAllText(
                settingsPath,
                JsonSerializer.Serialize(placement, new JsonSerializerOptions { WriteIndented = true })
            );
        }
        catch (Exception error)
        {
            DiagnosticLog.Error("Failed to save window placement", error);
        }
    }

    private static string DefaultSettingsPath()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Quotio"
        );
        return Path.Combine(directory, "window.json");
    }
}
