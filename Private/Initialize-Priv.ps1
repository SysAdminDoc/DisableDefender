# ---------------------------------------------------------------------------
# SeTakeOwnership + registry ACL override (primary method for service keys).
# No TrustedInstaller needed; privacy.sexy avoids TI because it triggers
# Defender alarms. This path works on stock Windows 10/11 with Admin rights.
# ---------------------------------------------------------------------------
$script:PrivType = @'
using System;
using System.Runtime.InteropServices;

public static class Priv {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool AdjustTokenPrivileges(IntPtr h, bool dis, ref TOKEN_PRIVILEGES np, int len, IntPtr prev, IntPtr rl);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    public const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    public const uint TOKEN_QUERY             = 0x0008;
    public const uint SE_PRIVILEGE_ENABLED    = 0x2;

    public static bool Enable(string priv) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out tok)) return false;
        LUID luid;
        if (!LookupPrivilegeValue(null, priv, out luid)) { CloseHandle(tok); return false; }
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Privileges.Luid = luid;
        tp.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
        bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(tok);
        return ok;
    }
}
'@

function Initialize-Priv {
    if (-not ('Priv' -as [type])) { Add-Type -TypeDefinition $script:PrivType -ErrorAction Stop }
    [Priv]::Enable('SeTakeOwnershipPrivilege') | Out-Null
    [Priv]::Enable('SeRestorePrivilege')       | Out-Null
    [Priv]::Enable('SeBackupPrivilege')        | Out-Null
    [Priv]::Enable('SeSecurityPrivilege')      | Out-Null
}
