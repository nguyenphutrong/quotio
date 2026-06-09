namespace Quotio.Windows;

using Microsoft.UI.Xaml;

public sealed partial class App : Application
{
    private readonly SingleInstanceGuard singleInstance;
    private MainWindow? window;

    public App(SingleInstanceGuard singleInstance)
    {
        this.singleInstance = singleInstance;
        this.singleInstance.ActivationRequested += OnActivationRequested;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
        singleInstance.StartListening();
    }

    private void OnActivationRequested(object? sender, EventArgs args)
    {
        window?.DispatcherQueue.TryEnqueue(() =>
        {
            window.ShowFromActivation();
        });
    }
}
