namespace Quotio.Windows;

using System.Text.Json;
using global::Windows.Graphics;

public sealed class WindowSettingsStore
{
    private readonly string settingsPath;

    public WindowSettingsStore()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Quotio"
        );
        Directory.CreateDirectory(directory);
        settingsPath = Path.Combine(directory, "window.json");
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

    public void Save(PointInt32 position, SizeInt32 size, string? monitorDeviceName)
    {
        try
        {
            var placement = new WindowPlacement(
                position.X,
                position.Y,
                size.Width,
                size.Height,
                monitorDeviceName
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
}
