namespace Quotio.Windows;

using System.Threading;

public sealed class SingleInstanceGuard : IDisposable
{
    private readonly string eventName;
    private readonly EventWaitHandle activationEvent;
    private readonly Mutex mutex;
    private bool disposed;

    public SingleInstanceGuard(string name)
    {
        eventName = $"{name}.activate";
        mutex = new Mutex(initiallyOwned: true, name, out var createdNew);
        IsPrimary = createdNew;
        activationEvent = new EventWaitHandle(false, EventResetMode.AutoReset, eventName);
    }

    public bool IsPrimary { get; }

    public event EventHandler? ActivationRequested;

    public void StartListening()
    {
        if (!IsPrimary)
        {
            return;
        }

        var thread = new Thread(() =>
        {
            while (!disposed)
            {
                activationEvent.WaitOne();
                if (!disposed)
                {
                    ActivationRequested?.Invoke(this, EventArgs.Empty);
                }
            }
        })
        {
            IsBackground = true,
            Name = "Quotio single-instance activation"
        };
        thread.Start();
    }

    public void SignalPrimary()
    {
        activationEvent.Set();
    }

    public void Dispose()
    {
        disposed = true;
        activationEvent.Set();
        activationEvent.Dispose();
        mutex.Dispose();
    }
}
