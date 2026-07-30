# ---------------------------------------------------------------------------
# Runtime directory preflight
# Protects privileged logs, manifests, phase state, tripwires, and ACL backups.
# ---------------------------------------------------------------------------

if (-not ('DisableDefender.RuntimeFileNative' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DisableDefender {
    public sealed class RuntimeFileLease : IDisposable {
        private FileStream stream;
        private readonly RuntimeFileNative.BY_HANDLE_FILE_INFORMATION identity;
        private readonly byte[] securityDescriptor;

        internal RuntimeFileLease(
            FileStream stream,
            RuntimeFileNative.BY_HANDLE_FILE_INFORMATION identity,
            byte[] bytes,
            byte[] securityDescriptor) {
            this.stream = stream;
            this.identity = identity;
            this.Bytes = bytes;
            this.securityDescriptor = securityDescriptor;
            this.SecurityDescriptor = (byte[])securityDescriptor.Clone();
            this.Path = stream.Name;
            this.FileId = RuntimeFileNative.GetFileId(identity);
            this.Length = bytes.LongLength;
        }

        public string Path { get; private set; }
        public string FileId { get; private set; }
        public long Length { get; private set; }
        public byte[] Bytes { get; private set; }
        public byte[] SecurityDescriptor { get; private set; }

        public void AssertUnchanged() {
            if (this.stream == null) {
                throw new ObjectDisposedException("RuntimeFileLease");
            }

            RuntimeFileNative.BY_HANDLE_FILE_INFORMATION current =
                RuntimeFileNative.GetIdentity(this.stream.SafeFileHandle);
            if (!RuntimeFileNative.SameIdentity(this.identity, current) ||
                RuntimeFileNative.GetLength(current) != this.Length ||
                (current.FileAttributes & RuntimeFileNative.FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                throw new IOException("Privileged runtime file identity changed while leased: " + this.Path);
            }

            byte[] currentDescriptor =
                RuntimeFileNative.GetSecurityDescriptor(this.stream.SafeFileHandle);
            if (!RuntimeFileNative.SameBytes(this.securityDescriptor, currentDescriptor)) {
                throw new IOException("Privileged runtime file owner or DACL changed while leased: " + this.Path);
            }
        }

        public void Dispose() {
            if (this.stream != null) {
                this.stream.Dispose();
                this.stream = null;
            }
        }
    }

    public static class RuntimeFileNative {
        private const uint GENERIC_READ = 0x80000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;
        internal const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
        private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        private const uint OWNER_SECURITY_INFORMATION = 0x00000001;
        private const uint DACL_SECURITY_INFORMATION = 0x00000004;
        private const int SE_FILE_OBJECT = 1;

        [StructLayout(LayoutKind.Sequential)]
        internal struct FILETIME {
            internal uint LowDateTime;
            internal uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct BY_HANDLE_FILE_INFORMATION {
            internal uint FileAttributes;
            internal FILETIME CreationTime;
            internal FILETIME LastAccessTime;
            internal FILETIME LastWriteTime;
            internal uint VolumeSerialNumber;
            internal uint FileSizeHigh;
            internal uint FileSizeLow;
            internal uint NumberOfLinks;
            internal uint FileIndexHigh;
            internal uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern uint GetSecurityInfo(
            IntPtr handle,
            int objectType,
            uint securityInformation,
            out IntPtr owner,
            out IntPtr group,
            out IntPtr dacl,
            out IntPtr sacl,
            out IntPtr securityDescriptor);

        [DllImport("advapi32.dll")]
        private static extern uint GetSecurityDescriptorLength(IntPtr securityDescriptor);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        internal static BY_HANDLE_FILE_INFORMATION GetIdentity(SafeFileHandle handle) {
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information)) {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Unable to query privileged runtime file identity.");
            }
            return information;
        }

        internal static long GetLength(BY_HANDLE_FILE_INFORMATION information) {
            return ((long)information.FileSizeHigh << 32) | information.FileSizeLow;
        }

        internal static string GetFileId(BY_HANDLE_FILE_INFORMATION information) {
            return String.Format(
                "{0:x8}:{1:x8}{2:x8}",
                information.VolumeSerialNumber,
                information.FileIndexHigh,
                information.FileIndexLow);
        }

        internal static bool SameIdentity(
            BY_HANDLE_FILE_INFORMATION expected,
            BY_HANDLE_FILE_INFORMATION actual) {
            return expected.VolumeSerialNumber == actual.VolumeSerialNumber &&
                expected.FileIndexHigh == actual.FileIndexHigh &&
                expected.FileIndexLow == actual.FileIndexLow;
        }

        internal static bool SameBytes(byte[] expected, byte[] actual) {
            if (expected == null || actual == null || expected.Length != actual.Length) {
                return false;
            }
            for (int index = 0; index < expected.Length; index++) {
                if (expected[index] != actual[index]) {
                    return false;
                }
            }
            return true;
        }

        internal static byte[] GetSecurityDescriptor(SafeFileHandle handle) {
            IntPtr owner;
            IntPtr group;
            IntPtr dacl;
            IntPtr sacl;
            IntPtr descriptor;
            uint result = GetSecurityInfo(
                handle.DangerousGetHandle(),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                out owner,
                out group,
                out dacl,
                out sacl,
                out descriptor);
            if (result != 0) {
                throw new Win32Exception((int)result, "Unable to query privileged runtime file security.");
            }

            try {
                uint length = GetSecurityDescriptorLength(descriptor);
                if (length == 0 || length > 65536) {
                    throw new IOException("Privileged runtime file security descriptor has an invalid length.");
                }
                byte[] bytes = new byte[length];
                Marshal.Copy(descriptor, bytes, 0, (int)length);
                return bytes;
            } finally {
                if (descriptor != IntPtr.Zero) {
                    LocalFree(descriptor);
                }
            }
        }

        public static RuntimeFileLease OpenRead(string path, int maximumBytes) {
            if (maximumBytes < 1) {
                throw new ArgumentOutOfRangeException("maximumBytes");
            }

            SafeFileHandle handle = CreateFile(
                path,
                GENERIC_READ,
                FILE_SHARE_READ,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN,
                IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to open privileged runtime file.");
            }

            FileStream stream = null;
            try {
                BY_HANDLE_FILE_INFORMATION before = GetIdentity(handle);
                if ((before.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                    throw new IOException("Privileged runtime file path resolves to a directory.");
                }
                if ((before.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                    throw new IOException("Privileged runtime file is a reparse point.");
                }
                if (before.NumberOfLinks != 1) {
                    throw new IOException("Privileged runtime file has multiple hard links.");
                }

                long length = GetLength(before);
                if (length < 0 || length > maximumBytes) {
                    throw new IOException(
                        "Privileged runtime file exceeds the maximum byte length.");
                }

                byte[] descriptor = GetSecurityDescriptor(handle);
                stream = new FileStream(handle, FileAccess.Read, 4096, false);
                byte[] bytes = new byte[(int)length];
                int offset = 0;
                while (offset < bytes.Length) {
                    int read = stream.Read(bytes, offset, bytes.Length - offset);
                    if (read == 0) {
                        throw new EndOfStreamException(
                            "Privileged runtime file ended before its recorded length.");
                    }
                    offset += read;
                }
                if (stream.ReadByte() != -1) {
                    throw new IOException(
                        "Privileged runtime file grew beyond its validated length.");
                }

                BY_HANDLE_FILE_INFORMATION after = GetIdentity(stream.SafeFileHandle);
                if (!SameIdentity(before, after) ||
                    GetLength(after) != length ||
                    (after.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                    throw new IOException(
                        "Privileged runtime file identity changed while being read.");
                }
                byte[] afterDescriptor = GetSecurityDescriptor(stream.SafeFileHandle);
                if (!SameBytes(descriptor, afterDescriptor)) {
                    throw new IOException(
                        "Privileged runtime file owner or DACL changed while being read.");
                }

                return new RuntimeFileLease(stream, before, bytes, descriptor);
            } catch {
                if (stream != null) {
                    stream.Dispose();
                } else {
                    handle.Dispose();
                }
                throw;
            }
        }
    }
}
"@
}

function Test-DefenderRuntimeWriteRights {
    param([Parameter(Mandatory)][System.Security.AccessControl.FileSystemRights]$Rights)

    $writeMask = [int64][System.Security.AccessControl.FileSystemRights]::Write `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::WriteData `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::CreateFiles `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::AppendData `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::CreateDirectories `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::WriteAttributes `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::Delete `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::ChangePermissions `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::TakeOwnership `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::Modify `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::FullControl

    return (([int64]$Rights -band $writeMask) -ne 0)
}

function Get-DefenderRuntimeDirectoryWeakWriteRules {
    param([Parameter(Mandatory)][System.Security.AccessControl.DirectorySecurity]$Acl)

    $allowedSids = @{
        'S-1-5-18'     = $true # SYSTEM
        'S-1-5-32-544' = $true # BUILTIN\Administrators
    }
    $weak = New-Object System.Collections.ArrayList
    $rules = $Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = [string]$rule.IdentityReference
        if ($allowedSids.ContainsKey($sid)) { continue }
        if (-not (Test-DefenderRuntimeWriteRights -Rights $rule.FileSystemRights)) { continue }
        [void]$weak.Add([pscustomobject]@{
            Identity = $sid
            Rights   = $rule.FileSystemRights.ToString()
        })
    }
    return @($weak)
}

function Get-DefenderRuntimeDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $directory = New-Object System.IO.DirectoryInfo($Path)
    return $directory.GetAccessControl()
}

function Set-DefenderRuntimeDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $acl = Get-DefenderRuntimeDirectoryAcl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }

    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $accessType = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sidValue in @('S-1-5-32-544','S-1-5-18')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $accessType)
        $acl.AddAccessRule($rule)
    }

    $directory = New-Object System.IO.DirectoryInfo($Path)
    $directory.SetAccessControl($acl)
}

function Test-DefenderStrictPathDescendant {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )

    $parentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $childPath = [System.IO.Path]::GetFullPath($Child).TrimEnd('\')
    return $childPath.StartsWith(
        $parentPath + '\',
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-DefenderRuntimePathComponents {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$Path
    )

    $rootPath = [System.IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-DefenderStrictPathDescendant -Parent $rootPath -Child $fullPath)) {
        throw "Privileged runtime file must be a strict descendant of the runtime directory: $fullPath"
    }

    $relativePath = $fullPath.Substring($rootPath.Length).TrimStart('\')
    $currentPath = $rootPath
    foreach ($component in ($relativePath -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($component) -or $component -in @('.','..')) {
            throw "Privileged runtime file path contains an invalid component: $fullPath"
        }
        $currentPath = Join-Path $currentPath $component
        if (-not (Test-Path -LiteralPath $currentPath)) { continue }
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Privileged runtime file path contains a reparse point: $currentPath"
        }
    }
}

function Assert-DefenderPrivilegedFileSecurity {
    param(
        [Parameter(Mandatory)]$Lease,
        [bool]$EnforcePrivilegedAcl = $true
    )

    try {
        $descriptor = [System.Security.AccessControl.RawSecurityDescriptor]::new(
            [byte[]]$Lease.SecurityDescriptor,
            0)
    } catch {
        throw "Privileged runtime file security descriptor is invalid: $($_.Exception.Message)"
    }
    if ($null -eq $descriptor.Owner) {
        throw 'Privileged runtime file has no owner.'
    }
    if (($descriptor.ControlFlags -band
            [System.Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -eq 0 -or
        $null -eq $descriptor.DiscretionaryAcl) {
        throw 'Privileged runtime file has no DACL.'
    }
    if (-not $EnforcePrivilegedAcl) { return }

    $allowedSids = @{
        'S-1-5-18'     = $true
        'S-1-5-32-544' = $true
    }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $allowedSids[$identity.User.Value] = $true
    }

    $ownerSid = $descriptor.Owner.Value
    if (-not $allowedSids.ContainsKey($ownerSid)) {
        throw "Privileged runtime file owner is not SYSTEM or an administrator: $ownerSid"
    }

    $writeMask = [uint64][System.Security.AccessControl.FileSystemRights]::Write `
        -bor [uint64][System.Security.AccessControl.FileSystemRights]::WriteData `
        -bor [uint64][System.Security.AccessControl.FileSystemRights]::AppendData `
        -bor [uint64][System.Security.AccessControl.FileSystemRights]::CreateFiles `
        -bor [uint64][System.Security.AccessControl.FileSystemRights]::CreateDirectories `
        -bor [uint64][System.Security.AccessControl.FileSystemRights]::Delete `
        -bor [uint64][System.Security.AccessControl.FileSystemRights]::ChangePermissions `
        -bor [uint64][System.Security.AccessControl.FileSystemRights]::TakeOwnership `
        -bor [uint64]0x10000000 `
        -bor [uint64]0x40000000
    foreach ($ace in $descriptor.DiscretionaryAcl) {
        if ($ace -isnot [System.Security.AccessControl.QualifiedAce] -or
            $ace.AceQualifier -ne [System.Security.AccessControl.AceQualifier]::AccessAllowed) {
            continue
        }
        $mask = [uint64][uint32]$ace.AccessMask
        if (($mask -band $writeMask) -eq 0) { continue }
        $sid = [string]$ace.SecurityIdentifier.Value
        if (-not $allowedSids.ContainsKey($sid)) {
            throw "Privileged runtime file grants write access to a non-admin principal: $sid"
        }
    }
}

function Open-DefenderPrivilegedRuntimeFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateRange(1, 16777216)][int]$MaximumBytes
    )

    $runtimeRoot = [System.IO.Path]::GetFullPath($script:AppDir)
    Assert-DefenderRuntimeDirectory -Path $runtimeRoot
    Assert-DefenderRuntimePathComponents -RuntimeRoot $runtimeRoot -Path $Path

    $lease = $null
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $lease = [DisableDefender.RuntimeFileNative]::OpenRead($fullPath, $MaximumBytes)
        Assert-DefenderPrivilegedFileSecurity -Lease $lease `
            -EnforcePrivilegedAcl:(Test-DefenderDefaultRuntimeDirectory -Path $runtimeRoot)
        $lease.AssertUnchanged()
        return $lease
    } catch {
        if ($null -ne $lease) { $lease.Dispose() }
        throw
    }
}

function ConvertFrom-DefenderRuntimeFileBytes {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes
    )

    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString(
            $Bytes,
            2,
            $Bytes.Length - 2)
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        return $strictUtf8.GetString($Bytes)
    } catch {
        throw "Privileged runtime file is not valid UTF-8 or BOM-marked UTF-16: $($_.Exception.Message)"
    }
}

function Get-DefenderRuntimeFileSha256 {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha256.ComputeHash($Bytes)).
            Replace('-', '').
            ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Test-DefenderDefaultRuntimeDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $defaultPath = [System.IO.Path]::GetFullPath((Join-Path $env:ProgramData 'DisableDefender')).TrimEnd('\')
    $candidatePath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    return $candidatePath.Equals($defaultPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Initialize-DefenderRuntimeDirectory {
    param(
        [string]$Path = $script:AppDir,
        [bool]$RepairAcl = $true
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Runtime directory path is not configured.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $created = $false
    $repaired = $false

    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            throw "Runtime directory path exists but is not a directory: $fullPath"
        }
        if (([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Runtime directory refused because it is a reparse point: $fullPath"
        }
    } else {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        $created = $true
    }

    $acl = Get-DefenderRuntimeDirectoryAcl -Path $fullPath
    $weakRules = @(Get-DefenderRuntimeDirectoryWeakWriteRules -Acl $acl)
    if ($RepairAcl -and ($created -or $weakRules.Count -gt 0 -or -not $acl.AreAccessRulesProtected)) {
        try {
            Set-DefenderRuntimeDirectoryAcl -Path $fullPath
            $repaired = $true
        } catch {
            throw "Runtime directory ACL hardening failed for ${fullPath}: $($_.Exception.Message)"
        }
    }

    if (-not $RepairAcl) {
        return [pscustomobject]@{
            Path     = $fullPath
            Created  = $created
            Repaired = $repaired
        }
    }

    $verifiedAcl = Get-DefenderRuntimeDirectoryAcl -Path $fullPath
    $remainingWeakRules = @(Get-DefenderRuntimeDirectoryWeakWriteRules -Acl $verifiedAcl)
    if ($remainingWeakRules.Count -gt 0) {
        $identities = ($remainingWeakRules | ForEach-Object { $_.Identity }) -join ', '
        throw "Runtime directory grants write access to non-admin principals: $identities"
    }
    if (-not $verifiedAcl.AreAccessRulesProtected) {
        throw "Runtime directory ACL inheritance remains enabled after hardening: $fullPath"
    }

    return [pscustomobject]@{
        Path     = $fullPath
        Created  = $created
        Repaired = $repaired
    }
}

function Assert-DefenderRuntimeDirectory {
    param([string]$Path = $script:AppDir)
    Initialize-DefenderRuntimeDirectory -Path $Path -RepairAcl:(Test-DefenderDefaultRuntimeDirectory -Path $Path) | Out-Null
}
