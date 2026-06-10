namespace Quotio.Windows;

using Velopack;
using Velopack.Sources;

public sealed class WindowsUpdateService
{
    private readonly WindowsHostConfig config;
    private readonly WindowsNativePreferencesStore preferencesStore;
    private bool isChecking;
    private DateTimeOffset? lastUpdateCheckAt;
    private WindowsUpdateResult? lastResult;

    public WindowsUpdateService(
        WindowsHostConfig config,
        WindowsNativePreferencesStore preferencesStore
    )
    {
        this.config = config;
        this.preferencesStore = preferencesStore;
    }

    public WindowsUpdateSnapshot Snapshot()
    {
        var preferences = preferencesStore.Load();
        var configured = !string.IsNullOrWhiteSpace(config.WindowsUpdateRepositoryUrl);
        var updateChannel = EffectiveUpdateChannel(preferences);
        var manager = TryCreateUpdateManager(updateChannel);
        var installed = manager?.IsInstalled ?? false;
        var supported = configured && installed;

        return new WindowsUpdateSnapshot(
            UpdatesSupported: supported,
            AutoCheckUpdates: preferences.AutoCheckUpdates,
            UpdateChannel: updateChannel,
            UpdateChannelLocked: config.WindowsUpdateChannelLocked,
            CanCheckForUpdates: supported && installed && !isChecking,
            IsCheckingForUpdates: isChecking,
            LastUpdateCheckAt: lastUpdateCheckAt?.UtcDateTime.ToString("O"),
            LastResult: lastResult
        );
    }

    public async Task<WindowsUpdateSnapshot> CheckForUpdatesAsync()
    {
        var preferences = preferencesStore.Load();
        var manager = TryCreateUpdateManager(EffectiveUpdateChannel(preferences));
        if (manager is null)
        {
            lastResult = new WindowsUpdateResult(false, null, "Windows updates require a Velopack-installed build.");
            return Snapshot();
        }

        if (!manager.IsInstalled)
        {
            lastResult = new WindowsUpdateResult(false, null, "Windows updates require a Velopack-installed build.");
            return Snapshot();
        }

        isChecking = true;
        try
        {
            lastUpdateCheckAt = DateTimeOffset.UtcNow;
            var update = await manager.CheckForUpdatesAsync();
            if (update is null)
            {
                lastResult = new WindowsUpdateResult(false, null, null);
            }
            else
            {
                await manager.DownloadUpdatesAsync(update);
                lastResult = new WindowsUpdateResult(
                    true,
                    update.TargetFullRelease.Version.ToString(),
                    "Update downloaded. Restart Quotio to apply it."
                );
            }
        }
        finally
        {
            isChecking = false;
        }

        return Snapshot();
    }

    private string EffectiveUpdateChannel(WindowsNativePreferencesState preferences)
    {
        return config.WindowsUpdateChannelLocked
            ? config.WindowsUpdateChannel
            : preferences.UpdateChannel;
    }

    private UpdateManager? TryCreateUpdateManager(string updateChannel)
    {
        var repositoryUrl = config.WindowsUpdateRepositoryUrl;
        if (string.IsNullOrWhiteSpace(repositoryUrl))
        {
            return null;
        }

        try
        {
            var source = new GithubSource(
                repositoryUrl,
                null,
                updateChannel == "beta",
                null
            );
            return new UpdateManager(source, new UpdateOptions
            {
                ExplicitChannel = updateChannel
            });
        }
        catch (Exception error) when (error is InvalidOperationException)
        {
            return null;
        }
    }
}

public sealed record WindowsUpdateSnapshot(
    bool UpdatesSupported,
    bool AutoCheckUpdates,
    string UpdateChannel,
    bool UpdateChannelLocked,
    bool CanCheckForUpdates,
    bool IsCheckingForUpdates,
    string? LastUpdateCheckAt,
    WindowsUpdateResult? LastResult
);

public sealed record WindowsUpdateResult(
    bool UpdateAvailable,
    string? Version,
    string? Message
);
