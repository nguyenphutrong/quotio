namespace Quotio.Windows;

using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Cryptography;
using System.Text;

public static class WindowsCredentialStore
{
    private const uint CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    public static string? TryReadGenericCredential(string targetName)
    {
        if (!CredRead(targetName, CredTypeGeneric, 0, out var credentialPointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error != ErrorNotFound)
            {
                DiagnosticLog.Info($"Credential Manager entry {targetName} is unavailable: {error}");
            }

            return null;
        }

        try
        {
            var credential = Marshal.PtrToStructure<Credential>(credentialPointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return null;
            }

            var bytes = new byte[checked((int)credential.CredentialBlobSize)];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);

            try
            {
                return Encoding.UTF8.GetString(bytes).TrimEnd('\0');
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        finally
        {
            CredFree(credentialPointer);
        }
    }

    public static void WriteGenericCredential(string targetName, string value)
    {
        var targetNamePointer = IntPtr.Zero;
        var userNamePointer = IntPtr.Zero;
        var credentialBlobPointer = IntPtr.Zero;
        byte[]? credentialBytes = null;

        try
        {
            credentialBytes = Encoding.UTF8.GetBytes(value);
            targetNamePointer = Marshal.StringToCoTaskMemUni(targetName);
            userNamePointer = Marshal.StringToCoTaskMemUni(Environment.UserName);
            credentialBlobPointer = Marshal.AllocHGlobal(credentialBytes.Length);
            Marshal.Copy(credentialBytes, 0, credentialBlobPointer, credentialBytes.Length);

            var credential = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = targetNamePointer,
                CredentialBlobSize = checked((uint)credentialBytes.Length),
                CredentialBlob = credentialBlobPointer,
                Persist = CredPersistLocalMachine,
                UserName = userNamePointer
            };

            if (!CredWrite(ref credential, 0))
            {
                throw new InvalidOperationException(
                    $"Failed to write Credential Manager entry {targetName}: {Marshal.GetLastWin32Error()}"
                );
            }
        }
        finally
        {
            if (credentialBytes is not null)
            {
                CryptographicOperations.ZeroMemory(credentialBytes);
            }
            if (credentialBlobPointer != IntPtr.Zero)
            {
                var zeroes = new byte[credentialBytes?.Length ?? 0];
                Marshal.Copy(zeroes, 0, credentialBlobPointer, zeroes.Length);
                Marshal.FreeHGlobal(credentialBlobPointer);
            }
            if (targetNamePointer != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(targetNamePointer);
            }
            if (userNamePointer != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(userNamePointer);
            }
        }
    }

    public static void DeleteGenericCredential(string targetName)
    {
        if (CredDelete(targetName, CredTypeGeneric, 0))
        {
            return;
        }

        var error = Marshal.GetLastWin32Error();
        if (error != ErrorNotFound)
        {
            throw new InvalidOperationException(
                $"Failed to delete Credential Manager entry {targetName}: {error}"
            );
        }
    }

    [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(
        string targetName,
        uint type,
        uint flags,
        out IntPtr credential
    );

    [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(
        ref Credential credential,
        uint flags
    );

    [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(
        string targetName,
        uint type,
        uint flags
    );

    [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = false)]
    private static extern void CredFree(IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }
}
