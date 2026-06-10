namespace Quotio.Windows;

using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Velopack;

internal static class Program
{
    private const string InstanceName = "dev.quotio.desktop.windows";

    [STAThread]
    private static void Main()
    {
        VelopackApp.Build().Run();
        DiagnosticLog.RegisterUnhandledExceptionHandlers();

        using var singleInstance = new SingleInstanceGuard(InstanceName);
        if (!singleInstance.IsPrimary)
        {
            singleInstance.SignalPrimary();
            return;
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread()
            );
            SynchronizationContext.SetSynchronizationContext(context);

            var app = new App(singleInstance);
            app.InitializeComponent();
        });
    }
}
