#Requires -Version 5.1
[CmdletBinding()]
param([string]$WorkDir)
$ErrorActionPreference = 'Stop'
if (-not $WorkDir) { $WorkDir = Join-Path $PSScriptRoot ('..\output\local-tests\replacement-tools-' + [guid]::NewGuid().ToString('N')) }
Import-Module (Join-Path $PSScriptRoot 'WeaselReplacement.psm1') -Force -DisableNameChecking
function Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function MustFail([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Check $failed $Message
}
function FakePE([string]$Path, [int]$Machine, [byte]$Marker) {
    $data = [byte[]]::new(256)
    $data[0] = 0x4d; $data[1] = 0x5a; $data[60] = 128
    $data[128] = 0x50; $data[129] = 0x45
    $data[132] = $Machine -band 255; $data[133] = $Machine -shr 8
    $data[255] = $Marker
    [IO.File]::WriteAllBytes($Path, $data)
}
[IO.Directory]::CreateDirectory($WorkDir) | Out-Null
$root = (Resolve-Path -LiteralPath $WorkDir).Path
$source = Join-Path $root 'source with spaces [test]'
$install = Join-Path $root 'installed'
$system = Join-Path $root 'fake-system32'
$wow = Join-Path $root 'fake-syswow64'
foreach ($dir in @($source, $install, $system, $wow)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
$names = @('weasel.dll', 'weaselx64.dll', 'WeaselServer.exe', 'WeaselDeployer.exe', 'WeaselSetup.exe', 'rime.dll', 'WinSparkle.dll')
foreach ($name in $names) {
    $machine = if ($name -in @('weasel.dll', 'WeaselSetup.exe')) { 0x14c } else { 0x8664 }
    FakePE (Join-Path $source $name) $machine 1
    FakePE (Join-Path $install $name) $machine 2
}
FakePE (Join-Path $system 'weasel.dll') 0x8664 2
FakePE (Join-Path $wow 'weasel.dll') 0x14c 2
& (Join-Path $PSScriptRoot 'New-WeaselReplacementPackage.ps1') -SourceDir $source -OutputDir $root -PackageName fixture -Profile Full
$package = Join-Path $root 'fixture'
$manifest = Read-WeaselPackage $package
Check (@($manifest.Files).Count -eq 7) 'Full package component count'
$plan = @(New-WeaselPlan $package $install $system $wow)
Check ($plan.Count -eq 9) 'System DLL copies are missing from replacement plan'
Check (@($plan | Where-Object Changed).Count -eq 9) 'Wrong changed-file count'

# Tampered payload, traversal, duplicate entries and missing components.
$dll = Join-Path $package 'bin\weaselx64.dll'
$bytes = [IO.File]::ReadAllBytes($dll)
[IO.File]::AppendAllText($dll, 'damage')
MustFail { Read-WeaselPackage $package } 'Tampered DLL accepted'
[IO.File]::WriteAllBytes($dll, $bytes)
$manifestPath = Join-Path $package 'manifest.json'
$original = [IO.File]::ReadAllText($manifestPath)
$bad = $original | ConvertFrom-Json
$bad.Files[0].Name = '..\outside.dll'
Write-WeaselJson $manifestPath $bad
MustFail { Read-WeaselPackage $package } 'Traversal filename accepted'
$bad = $original | ConvertFrom-Json
$bad.Files += $bad.Files[0]
Write-WeaselJson $manifestPath $bad
MustFail { Read-WeaselPackage $package } 'Duplicate file accepted'
$bad = $original | ConvertFrom-Json
$bad.Files = @($bad.Files | Where-Object Name -ne 'rime.dll')
Write-WeaselJson $manifestPath $bad
MustFail { Read-WeaselPackage $package } 'Incomplete Full package accepted'
[IO.File]::WriteAllText($manifestPath, $original)
MustFail { & (Join-Path $PSScriptRoot 'New-WeaselReplacementPackage.ps1') -SourceDir $source -OutputDir $root -PackageName fixture } 'Existing output overwritten'

# Exercise real file backup/replacement and rollback in fixture directories.
$saved = New-WeaselBackup $plan $install
Initialize-WeaselStages $saved.Manifest.Items
$lock = [IO.File]::Open($plan[1].Destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try { MustFail { Invoke-WeaselImmediate $saved.Manifest.Items } 'Locked target unexpectedly replaced' }
finally { $lock.Dispose() }
foreach ($record in $plan) { Assert-WeaselFile $record.Destination $record.OriginalSHA256 }
$saved = New-WeaselBackup $plan $install
Initialize-WeaselStages $saved.Manifest.Items
Invoke-WeaselImmediate $saved.Manifest.Items
foreach ($record in $plan) { Assert-WeaselFile $record.Destination $record.SHA256 }
Check (@(New-WeaselPlan $package $install $system $wow | Where-Object Changed).Count -eq 0) 'Installed version verification failed'
$backup = Read-WeaselBackup $saved.Path $install $system $wow
$restore = @($backup.Items | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Location = $_.Location; Destination = $_.Destination
        Source = Join-Path $saved.Path $_.BackupFile; SHA256 = $_.OriginalSHA256
        OriginalSHA256 = $_.SHA256; Changed = $true }
})
$restoreBackup = New-WeaselBackup $restore $install
Initialize-WeaselStages $restoreBackup.Manifest.Items
Invoke-WeaselImmediate $restoreBackup.Manifest.Items
foreach ($record in $plan) { Assert-WeaselFile $record.Destination $record.OriginalSHA256 }

# Pure queue filtering: no actual registry writes or reboot scheduling in tests.
$item = $saved.Manifest.Items[0]
$pending = [string[]]@('unrelated-source', '', ('*1\??\' + $item.Staged), ('*1!\??\' + $item.Destination), 'other-source', 'other-target')
$remaining = @(Select-WeaselPendingWithoutItems $pending @($item))
Check ($remaining.Count -eq 4 -and $remaining[0] -eq 'unrelated-source' -and $remaining[1] -eq '' -and $remaining[3] -eq 'other-target') 'Queue cancellation touched unrelated operations'
$sameTarget = [string[]]@('different-source', ('!\??\' + $item.Destination))
Check (@(Select-WeaselPendingWithoutItems $sameTarget @($item)).Count -eq 2) 'Cancellation removed a different installer operation'
MustFail { Select-WeaselPendingWithoutItems @('odd') @($item) } 'Malformed queue accepted'
$badBackup = $backup | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$badBackup.Items[0].Destination = Join-Path $system 'unrelated.dll'
Write-WeaselJson (Join-Path $saved.Path 'backup.json') $badBackup
MustFail { Read-WeaselBackup $saved.Path $install $system $wow } 'Backup target substitution accepted'
Write-WeaselJson (Join-Path $saved.Path 'backup.json') $backup

Write-Output 'PASS: package/ZIP, path spaces, full system mapping, tampering/traversal/duplicate/missing-file rejection, occupied-file rollback, immediate replacement, restore and pending-operation isolation.'
Write-Output "Fixtures: $root (no installed files or registry values were modified)."
