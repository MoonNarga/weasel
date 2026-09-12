#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$OutputDir,
    [ValidateSet('Full', 'TsfX64')][string]$Profile = 'Full',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$PackageName,
    [string]$Description = 'Replacement files copied from the selected source directory; this tool does not compile binaries.'
)
$ErrorActionPreference = 'Stop'
if (-not $SourceDir) { $SourceDir = Join-Path $PSScriptRoot '..\output' }
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot '..\output\replacement-packages' }
Import-Module (Join-Path $PSScriptRoot 'WeaselReplacement.psm1') -Force -DisableNameChecking
$source = (Resolve-Path -LiteralPath $SourceDir).Path
$names = @(Get-WeaselComponentNames $Profile $source)
$files = @()
foreach ($name in $names) {
    $path = Join-Path $source $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $name in $source. Supply a complete, compatible build with -SourceDir; no installed-file fallback is used." }
    $info = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path).Hash
    Assert-WeaselFile $path $hash
    $files += [pscustomobject]@{
        Name = $name; SHA256 = $hash; Size = $info.Length
        Machine = Get-WeaselPEMachine $path
        FileVersion = $info.VersionInfo.FileVersion
        SourceModifiedUtc = $info.LastWriteTimeUtc.ToString('o')
    }
}
if (-not $PackageName) { $PackageName = 'weasel-replacement-' + $Profile.ToLowerInvariant() + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDir).Path
$package = Join-Path $outputRoot $PackageName
$zip = $package + '.zip'
if ((Test-Path -LiteralPath $package) -or (Test-Path -LiteralPath $zip)) { throw 'Output already exists; choose a new package name.' }
New-Item -ItemType Directory -Path (Join-Path $package 'bin') | Out-Null
foreach ($entry in $files) { Copy-Item -LiteralPath (Join-Path $source $entry.Name) -Destination (Join-Path (Join-Path $package 'bin') $entry.Name) }
foreach ($name in @('Replace-Weasel.ps1', 'WeaselReplacement.psm1', 'Install.cmd', 'Verify.cmd')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $package $name)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'replacement-package.md') -Destination (Join-Path $package 'README.md')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\LICENSE.txt') -Destination (Join-Path $package 'LICENSE.txt')
$manifest = [pscustomobject]@{
    Schema = 1; Profile = $Profile; CreatedUtc = [DateTime]::UtcNow.ToString('o')
    Description = $Description; Files = $files
}
Write-WeaselJson (Join-Path $package 'manifest.json') $manifest
Read-WeaselPackage $package | Out-Null
$sums = @()
foreach ($file in Get-ChildItem -LiteralPath $package -Recurse -File) {
    $relative = $file.FullName.Substring($package.Length + 1).Replace('\', '/')
    $sums += (Get-FileHash -LiteralPath $file.FullName).Hash + '  ' + $relative
}
[IO.File]::WriteAllLines((Join-Path $package 'SHA256SUMS.txt'), $sums, [Text.UTF8Encoding]::new($false))
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem -LiteralPath $package -Recurse -File) {
        $relative = $file.FullName.Substring($package.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relative, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $archive.Dispose() }
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    foreach ($entry in $files) {
        $member = $archive.GetEntry('bin/' + $entry.Name)
        if (-not $member) { throw "Missing ZIP member: $($entry.Name)" }
        $stream = $member.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $sha.Dispose(); $stream.Dispose() }
        if ($hash -ne $entry.SHA256) { throw "ZIP verification failed: $($entry.Name)" }
    }
} finally { $archive.Dispose() }
[IO.File]::WriteAllText(($zip + '.sha256'), (Get-FileHash -LiteralPath $zip).Hash + '  ' + [IO.Path]::GetFileName($zip) + "`r`n")
Write-Output "Package: $package"
Write-Output "ZIP: $zip"
Write-Output "Verified $($files.Count) program files."
