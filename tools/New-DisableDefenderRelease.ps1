#Requires -Version 5.1
<#
    Builds an unsigned local DisableDefender release zip.

    Recursive cleanup is limited to a newly created, identity-tracked staging
    directory. Existing output directories are never recursively deleted.
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDirectory,
    [switch]$SkipSigning
)

$ErrorActionPreference = 'Stop'
if ($SkipSigning) {
    Write-Verbose '-SkipSigning is retained for compatibility; release artifacts are always unsigned.'
}

if (-not ('DisableDefender.ReleaseDirectoryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DisableDefender
{
    public static class ReleaseDirectoryNative
    {
        private const uint OpenExisting = 3;
        private const uint ShareReadWriteDelete = 7;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileFlagBackupSemantics = 0x02000000;

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
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
            out ByHandleFileInformation information);

        public static string GetIdentity(string path)
        {
            using (SafeFileHandle handle = CreateFile(
                path,
                0,
                ShareReadWriteDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagOpenReparsePoint | FileFlagBackupSemantics,
                IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not open release directory for identity validation.");
                }

                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not read release directory identity.");
                }

                return string.Format(
                    "{0:X8}:{1:X8}{2:X8}",
                    information.VolumeSerialNumber,
                    information.FileIndexHigh,
                    information.FileIndexLow);
            }
        }
    }
}
'@
}

function ConvertTo-ReleaseFullPath {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($pathRoot)) {
        throw "Release path has no filesystem root: $Path"
    }

    $relativePath = $fullPath.Substring($pathRoot.Length)
    foreach ($segment in @($relativePath -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw "Release path contains a trailing dot or space: $Path"
        }
        if ($segment.Contains(':')) {
            throw "Release path contains an alternate data stream token: $Path"
        }
    }

    if ($fullPath.Equals($pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $pathRoot
    }
    return $fullPath.TrimEnd([char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ))
}

function Test-ReleaseStrictDescendant {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )

    $fullParent = ConvertTo-ReleaseFullPath -Path $Parent
    $fullChild = ConvertTo-ReleaseFullPath -Path $Child
    if ($fullParent.Equals($fullChild, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $prefix = $fullParent.TrimEnd('\') + '\'
    return $fullChild.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-ReleasePathHasNoReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = ConvertTo-ReleaseFullPath -Path $Path
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    $current = $pathRoot
    $relativePath = $fullPath.Substring($pathRoot.Length)
    foreach ($segment in @($relativePath -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            break
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Release path contains an existing reparse point: $current"
        }
    }
}

function Get-ReleaseDirectoryIdentity {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = ConvertTo-ReleaseFullPath -Path $Path
    Assert-ReleasePathHasNoReparsePoint -Path $fullPath
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Release directory path is not a directory: $fullPath"
    }

    return [PSCustomObject][ordered]@{
        Path     = $fullPath
        Identity = [DisableDefender.ReleaseDirectoryNative]::GetIdentity($fullPath)
    }
}

function Assert-ReleaseDirectoryIdentity {
    param(
        [Parameter(Mandatory)]$Expected
    )

    $current = Get-ReleaseDirectoryIdentity -Path $Expected.Path
    if (-not $current.Path.Equals($Expected.Path, [StringComparison]::OrdinalIgnoreCase) -or
        $current.Identity -ne $Expected.Identity) {
        throw "Release directory identity changed after validation: $($Expected.Path)"
    }
}

function Remove-ReleaseDirectorySafely {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]$DirectoryIdentity,
        [Parameter(Mandatory)]$ParentIdentity
    )

    if (-not (Test-ReleaseStrictDescendant -Parent $ParentIdentity.Path -Child $DirectoryIdentity.Path)) {
        throw "Refusing recursive cleanup outside the verified output directory: $($DirectoryIdentity.Path)"
    }

    Assert-ReleaseDirectoryIdentity -Expected $ParentIdentity
    Assert-ReleaseDirectoryIdentity -Expected $DirectoryIdentity
    if ($PSCmdlet.ShouldProcess($DirectoryIdentity.Path, 'Remove verified release staging directory')) {
        Remove-Item -LiteralPath $DirectoryIdentity.Path -Recurse -Force
    }
}

function Remove-ExistingReleaseArtifact {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$OutputIdentity
    )

    if (-not (Test-ReleaseStrictDescendant -Parent $OutputIdentity.Path -Child $Path)) {
        throw "Refusing artifact cleanup outside the verified output directory: $Path"
    }
    Assert-ReleaseDirectoryIdentity -Expected $OutputIdentity

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if ($item.PSIsContainer) {
        throw "Release artifact path unexpectedly resolves to a directory: $Path"
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release artifact path is a reparse point: $Path"
    }

    Assert-ReleaseDirectoryIdentity -Expected $OutputIdentity
    if ($PSCmdlet.ShouldProcess($Path, 'Remove existing release artifact')) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Publish-ReleaseArtifact {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)]$StageIdentity,
        [Parameter(Mandatory)]$OutputIdentity
    )

    if (-not (Test-ReleaseStrictDescendant -Parent $StageIdentity.Path -Child $Source)) {
        throw "Refusing to publish an artifact outside the verified stage: $Source"
    }
    if (-not (Test-ReleaseStrictDescendant -Parent $OutputIdentity.Path -Child $Destination)) {
        throw "Refusing to publish an artifact outside the verified output directory: $Destination"
    }

    Assert-ReleaseDirectoryIdentity -Expected $StageIdentity
    Assert-ReleaseDirectoryIdentity -Expected $OutputIdentity
    $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($sourceItem.PSIsContainer -or
        ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Staged release artifact is not a regular file: $Source"
    }

    Remove-ExistingReleaseArtifact -Path $Destination -OutputIdentity $OutputIdentity
    Assert-ReleaseDirectoryIdentity -Expected $StageIdentity
    Assert-ReleaseDirectoryIdentity -Expected $OutputIdentity
    [IO.File]::Move($Source, $Destination)
}

$repoRoot = ConvertTo-ReleaseFullPath -Path (Split-Path -Parent $PSScriptRoot)
$manifestPath = Join-Path $repoRoot 'DisableDefender.psd1'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Module manifest not found: $manifestPath"
}

$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = [string]$manifest.Version
}
if ([string]$manifest.Version -ne $Version) {
    throw "Requested version $Version does not match manifest version $($manifest.Version)."
}

$distRoot = ConvertTo-ReleaseFullPath -Path (Join-Path $repoRoot 'dist')
$tempRoot = ConvertTo-ReleaseFullPath -Path ([IO.Path]::GetTempPath())
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = $distRoot
}
$fullOutput = ConvertTo-ReleaseFullPath -Path $OutputDirectory

if ($fullOutput.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release output must be a strict descendant of the repository root: $fullOutput"
}
if ($fullOutput.Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release output cannot be the system temp root: $fullOutput"
}

$insideRepository = Test-ReleaseStrictDescendant -Parent $repoRoot -Child $fullOutput
$insideDist = $fullOutput.Equals($distRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-ReleaseStrictDescendant -Parent $distRoot -Child $fullOutput)
$insideTemp = Test-ReleaseStrictDescendant -Parent $tempRoot -Child $fullOutput
if ($insideRepository -and -not $insideDist) {
    throw "Repository release output is permitted only under dist: $fullOutput"
}
if (-not $insideDist -and -not $insideTemp) {
    throw "Release output must be under the repository dist directory or a new temp directory: $fullOutput"
}

$outputExists = Test-Path -LiteralPath $fullOutput
Assert-ReleasePathHasNoReparsePoint -Path $fullOutput
if ($insideTemp -and $outputExists) {
    throw "Temp release output must be a newly created unique directory: $fullOutput"
}
if ($outputExists) {
    $outputItem = Get-Item -LiteralPath $fullOutput -Force -ErrorAction Stop
    if (-not $outputItem.PSIsContainer) {
        throw "Release output is not a directory: $fullOutput"
    }
}

if (-not $outputExists) {
    [IO.Directory]::CreateDirectory($fullOutput) | Out-Null
}
Assert-ReleasePathHasNoReparsePoint -Path $fullOutput
$outputIdentity = Get-ReleaseDirectoryIdentity -Path $fullOutput

$stageRoot = Join-Path $fullOutput ('.DisableDefender-stage-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $stageRoot) {
    throw "Unique release stage already exists: $stageRoot"
}
[IO.Directory]::CreateDirectory($stageRoot) | Out-Null
$stageIdentity = Get-ReleaseDirectoryIdentity -Path $stageRoot

$metadata = $null
try {
    $packageRoot = Join-Path $stageRoot "DisableDefender-v$Version"
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null

    $releasePaths = @(
        'Private',
        'Public',
        'Tests',
        'tools',
        'DisableDefender.GUI.bat',
        'DisableDefender.GUI.ps1',
        'DisableDefender.ps1',
        'DisableDefender.psd1',
        'DisableDefender.psm1',
        'PSScriptAnalyzerSettings.psd1',
        'README.md',
        'CHANGELOG.md',
        'LICENSE'
    )

    foreach ($item in $releasePaths) {
        $source = Join-Path $repoRoot $item
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Release input missing: $source"
        }
        Copy-Item -LiteralPath $source -Destination $packageRoot -Recurse -Force
    }

    $zipName = "DisableDefender-v$Version.zip"
    $hashName = "$zipName.sha256"
    $metadataName = "DisableDefender-v$Version.release.json"
    $stagedZip = Join-Path $stageRoot $zipName
    $stagedHash = Join-Path $stageRoot $hashName
    $stagedMetadata = Join-Path $stageRoot $metadataName
    Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $stagedZip

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($stagedZip)
        try {
            $hash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }

    Set-Content -LiteralPath $stagedHash -Value "$hash  $zipName" -Encoding ASCII

    $finalZip = Join-Path $fullOutput $zipName
    $metadata = [PSCustomObject][ordered]@{
        Version         = $Version
        BuiltAt         = (Get-Date).ToString('o')
        ZipPath         = $finalZip
        Sha256          = $hash
        SignatureStatus = 'Unsigned'
        SignedFiles     = @()
    }
    $metadata | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $stagedMetadata -Encoding UTF8

    foreach ($artifact in @(
        [PSCustomObject]@{ Source = $stagedZip; Destination = $finalZip },
        [PSCustomObject]@{ Source = $stagedHash; Destination = (Join-Path $fullOutput $hashName) },
        [PSCustomObject]@{ Source = $stagedMetadata; Destination = (Join-Path $fullOutput $metadataName) }
    )) {
        Publish-ReleaseArtifact -Source $artifact.Source -Destination $artifact.Destination `
            -StageIdentity $stageIdentity -OutputIdentity $outputIdentity
    }
} finally {
    Remove-ReleaseDirectorySafely -DirectoryIdentity $stageIdentity -ParentIdentity $outputIdentity
}

return $metadata
