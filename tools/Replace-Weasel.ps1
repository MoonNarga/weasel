#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Verify', 'Restore', 'CancelPending')][string]$Mode = 'Install',
    [ValidateSet('OnRestart', 'Immediate')][string]$Timing = 'OnRestart',
    [string]$PackageDir,
    [string]$InstallDir,
    [string]$BackupDir,
    [switch]$Elevate,
    [string]$ResultFile
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell's Get-FileHash can inherit WhatIf during its path
# resolution. Preflight below is read-only; restore the preference before the
# single ShouldProcess gate guarding all changes and elevation.
$requestedWhatIf = $WhatIfPreference
$WhatIfPreference = $false
if (-not $PackageDir) { $PackageDir = $PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'WeaselReplacement.psm1') -Force -DisableNameChecking
$messages = [Collections.Generic.List[string]]::new()
$mutex = $null
$locked = $false
$exitCode = 0
function Report([string]$Message) { $messages.Add($Message); Write-Host $Message }
function Registered-Tsf([Microsoft.Win32.RegistryView]$View) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    $key = $base.OpenSubKey('SOFTWARE\Classes\CLSID\{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}\InprocServer32')
    try { if ($key) { $key.GetValue('') } } finally { if ($key) { $key.Dispose() }; $base.Dispose() }
}
try {
    if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use 64-bit PowerShell on x64 Windows. ARM64 is not supported by this package.' }
    if (-not $InstallDir) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $key = $base.OpenSubKey('SOFTWARE\Rime\Weasel')
            try { if ($key) { $InstallDir = $key.GetValue('WeaselRoot') } } finally { if ($key) { $key.Dispose() }; $base.Dispose() }
            if ($InstallDir) { break }
        }
    }
    if (-not $InstallDir) { throw 'Cannot find Weasel. Specify -InstallDir.' }
    $InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path
    $systemDir = [Environment]::SystemDirectory
    $wowDir = Join-Path $env:SystemRoot 'SysWOW64'
    if ($Mode -in @('Restore', 'CancelPending')) {
        if (-not $BackupDir) { throw '-BackupDir is required; choose the backup you intend to restore or cancel.' }
        $BackupDir = (Resolve-Path -LiteralPath $BackupDir).Path
        $backup = Read-WeaselBackup $BackupDir $InstallDir $systemDir $wowDir
        $plan = @($backup.Items | ForEach-Object {
            $current = (Get-FileHash -LiteralPath $_.Destination).Hash
            [pscustomobject]@{
                Name = $_.Name; Location = $_.Location; Destination = $_.Destination
                Source = Join-Path $BackupDir $_.BackupFile; SHA256 = $_.OriginalSHA256
                OriginalSHA256 = $current; Changed = $current -ne $_.OriginalSHA256
            }
        })
    } else {
        $PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
        $plan = @(New-WeaselPlan $PackageDir $InstallDir $systemDir $wowDir)
    }
    foreach ($record in $plan) {
        $status = if ($record.Changed) { 'DIFFERENT' } else { 'MATCH' }
        Report "$status $($record.Destination)"
    }
    if (@($plan | Where-Object Location -eq 'System64').Count -and (Registered-Tsf Registry64) -ne (Join-Path $systemDir 'weasel.dll')) { throw 'Unexpected x64 TSF registration; refusing to replace an unrelated DLL.' }
    if (@($plan | Where-Object Location -eq 'System32').Count -and (Registered-Tsf Registry32) -ne (Join-Path $wowDir 'weasel.dll')) { throw 'Unexpected x86 TSF registration; refusing to replace an unrelated DLL.' }
    $WhatIfPreference = $requestedWhatIf
    if ($Mode -eq 'Verify') {
        $changes = @($plan | Where-Object Changed).Count
        Report "Verified $($plan.Count) target paths; $changes differ from the package."
        if ($changes) { $exitCode = 2 }
    } elseif ($PSCmdlet.ShouldProcess($InstallDir, "$Mode ($Timing)")) {
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            if (-not $Elevate) { throw 'Replacement requires administrator rights. Use Install.cmd or add -Elevate; Verify and -WhatIf do not require elevation.' }
            $result = Join-Path $env:TEMP ('weasel-replacement-' + [guid]::NewGuid().ToString('N') + '.json')
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Mode', $Mode, '-Timing', $Timing, '-PackageDir', ('"' + $PackageDir.TrimEnd('\') + '"'), '-InstallDir', ('"' + $InstallDir.TrimEnd('\') + '"'), '-ResultFile', ('"' + $result + '"'))
            if ($BackupDir) { $arguments += @('-BackupDir', ('"' + $BackupDir.TrimEnd('\') + '"')) }
            $process = Start-Process -FilePath (Join-Path $systemDir 'WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
            if (Test-Path -LiteralPath $result) {
                $response = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
                foreach ($line in $response.Messages) { Report $line }
            }
            $exitCode = $process.ExitCode
        } else {
            $mutex = [Threading.Mutex]::new($false, 'Global\WeaselReplacementTools')
            $locked = $mutex.WaitOne(0)
            if (-not $locked) { throw 'Another Weasel replacement tool is running.' }
            if ($Mode -eq 'CancelPending') {
                Remove-WeaselPending $backup.Items
                $backup.State = 'PendingCancelled'
                Write-WeaselJson (Join-Path $BackupDir 'backup.json') $backup
                Report 'Cancelled only the restart operations recorded in this backup. Already installed files were not restored.'
            } else {
                Assert-NoWeaselPendingConflict $plan
                if (-not @($plan | Where-Object Changed).Count) { Report 'All target files already match; no replacement needed.' }
                else {
                    $saved = New-WeaselBackup $plan $InstallDir
                    Report "Backup: $($saved.Path)"
                    try {
                        Initialize-WeaselStages $saved.Manifest.Items
                        if ($Timing -eq 'OnRestart') {
                            Invoke-WeaselOnRestart $saved.Manifest.Items
                            $saved.Manifest.State = 'PendingRestart'
                            Report 'SCHEDULED: save your work and restart Windows when ready. No automatic restart is performed.'
                        } else {
                            Invoke-WeaselImmediate $saved.Manifest.Items
                            $saved.Manifest.State = 'Installed'
                            Report 'INSTALLED: restart applications using Weasel to load the new DLLs.'
                        }
                    } catch {
                        $saved.Manifest.State = 'Failed'
                        throw
                    } finally { Write-WeaselJson (Join-Path $saved.Path 'backup.json') $saved.Manifest }
                    Report 'Use Verify.cmd after restarting to compare every installed file with the package.'
                }
            }
        }
    }
} catch {
    $exitCode = 1
    Report ('ERROR: ' + $_.Exception.Message)
} finally {
    $WhatIfPreference = $requestedWhatIf
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    if ($ResultFile -and -not $requestedWhatIf) { Write-WeaselJson $ResultFile ([pscustomobject]@{ ExitCode = $exitCode; Messages = @($messages) }) }
}
exit $exitCode
