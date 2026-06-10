namespace Quotio.Windows;

public sealed record WindowPlacement(
    int X,
    int Y,
    int Width,
    int Height,
    string? MonitorDeviceName,
    bool IsMaximized = false
);

public readonly record struct WindowBounds(int X, int Y, int Width, int Height);

public readonly record struct DisplayWorkArea(
    string? DeviceName,
    int Left,
    int Top,
    int Right,
    int Bottom
);

public static class WindowPlacementService
{
    public static WindowBounds RestoreBounds(
        WindowPlacement placement,
        IReadOnlyList<DisplayWorkArea> displays
    )
    {
        var width = Math.Max(placement.Width, 900);
        var height = Math.Max(placement.Height, 600);
        var display = ResolveDisplay(placement, displays);
        if (display is null)
        {
            return new WindowBounds(placement.X, placement.Y, width, height);
        }

        var area = display.Value;
        var x = Clamp(placement.X, area.Left, Math.Max(area.Left, area.Right - width));
        var y = Clamp(placement.Y, area.Top, Math.Max(area.Top, area.Bottom - height));
        return new WindowBounds(x, y, width, height);
    }

    private static DisplayWorkArea? ResolveDisplay(
        WindowPlacement placement,
        IReadOnlyList<DisplayWorkArea> displays
    )
    {
        if (displays.Count == 0)
        {
            return null;
        }

        if (!string.IsNullOrEmpty(placement.MonitorDeviceName))
        {
            var saved = displays.FirstOrDefault(
                display => display.DeviceName == placement.MonitorDeviceName
            );
            if (saved.DeviceName is not null)
            {
                return saved;
            }
        }

        var centerX = placement.X + Math.Max(placement.Width, 1) / 2;
        var centerY = placement.Y + Math.Max(placement.Height, 1) / 2;
        foreach (var display in displays)
        {
            if (centerX >= display.Left
                && centerX <= display.Right
                && centerY >= display.Top
                && centerY <= display.Bottom)
            {
                return display;
            }
        }

        return displays[0];
    }

    private static int Clamp(int value, int min, int max)
    {
        return Math.Min(Math.Max(value, min), max);
    }
}
