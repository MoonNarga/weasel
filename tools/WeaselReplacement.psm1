Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Required = @('weasel.dll', 'weaselx64.dll', 'WeaselServer.exe', 'WeaselDeployer.exe', 'WeaselSetup.exe', 'rime.dll', 'WinSparkle.dll')
$script:Optional = @('weasel.ime', 'weaselx64.ime', '7z.exe', '7z.dll', 'curl.exe')

function Get-WeaselComponentNames {
    param([ValidateSet('Full', 'TsfX64')][string]$Profile, [string]$SourceDir)
    if ($Profile -eq 'TsfX64') { return @('weaselx64.dll') }
    $script:Required
    foreach ($name in $script:Optional) {
        if (Test-Path -LiteralPath (Join-Path $SourceDir $name) -PathType Leaf) { $name }
    }
}

function Get-WeaselPEMachine {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid PE file: $Path" }
        $stream.Position = 60
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw "Invalid PE header: $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $Path" }
        '{0:X4}' -f $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Write-WeaselJson {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($true))
}

function Assert-WeaselFile {
    param([string]$Path, [string]$Hash)
    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Not a regular file: $Path" }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) { throw "Hash mismatch: $Path" }
}

function Read-WeaselPackage {
    param([string]$PackageDir)
    $root = (Resolve-Path -LiteralPath $PackageDir).Path
    $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Schema -ne 1 -or $manifest.Profile -notin @('Full', 'TsfX64')) { throw 'Unsupported package manifest.' }
    $required = if ($manifest.Profile -eq 'Full') { $script:Required } else { @('weaselx64.dll') }
    $allowed = if ($manifest.Profile -eq 'Full') { $script:Required + $script:Optional } else { $required }
    $seen = @{}
    foreach ($entry in $manifest.Files) {
        if ($entry.Name -notin $allowed -or $seen.ContainsKey($entry.Name)) { throw "Unexpected or duplicate package file: $($entry.Name)" }
        $seen[$entry.Name] = $true
        if ($entry.SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid SHA256 in manifest.' }
        $path = Join-Path (Join-Path $root 'bin') $entry.Name
        Assert-WeaselFile $path $entry.SHA256
        $machine = Get-WeaselPEMachine $path
        if ($machine -ne $entry.Machine -or $machine -notin @('014C', '8664')) { throw "Unsupported or mismatched architecture: $($entry.Name)" }
        if ($entry.Name -in @('weasel.dll', 'weasel.ime') -and $machine -ne '014C') { throw 'The x86 IME must be an x86 binary.' }
        if ($entry.Name -in @('weaselx64.dll', 'weaselx64.ime') -and $machine -ne '8664') { throw 'The x64 IME must be an x64 binary.' }
        if ((Get-Item -LiteralPath $path).Length -ne $entry.Size) { throw "Size mismatch: $($entry.Name)" }
    }
    foreach ($name in $required) { if (-not $seen.ContainsKey($name)) { throw "Missing required file: $name" } }
    if ($manifest.Profile -eq 'Full') {
        $architectures = @($manifest.Files | Where-Object Name -in @('WeaselServer.exe', 'WeaselDeployer.exe', 'rime.dll', 'WinSparkle.dll') | ForEach-Object Machine | Select-Object -Unique)
        if ($architectures.Count -ne 1) { throw 'Server, deployer, rime and WinSparkle must use the same architecture.' }
    }
    $manifest
}

function Resolve-WeaselTarget {
    param([string]$Name, [string]$Location, [string]$InstallDir, [string]$SystemDir, [string]$WowDir)
    if ($Name -notin ($script:Required + $script:Optional)) { throw "Unsupported target: $Name" }
    switch ($Location) {
        'Install' { return Join-Path $InstallDir $Name }
        'System64' { if ($Name -eq 'weaselx64.dll') { return Join-Path $SystemDir 'weasel.dll' } }
        'System32' { if ($Name -eq 'weasel.dll') { return Join-Path $WowDir 'weasel.dll' } }
    }
    throw "Invalid target mapping: $Location/$Name"
}

function New-WeaselPlan {
    param([string]$PackageDir, [string]$InstallDir, [string]$SystemDir, [string]$WowDir)
    $manifest = Read-WeaselPackage $PackageDir
    $root = (Resolve-Path -LiteralPath $InstallDir).Path
    if (-not (Test-Path -LiteralPath (Join-Path $root 'WeaselServer.exe') -PathType Leaf)) { throw 'Select an existing Weasel installation.' }
    foreach ($entry in $manifest.Files) {
        $locations = @('Install')
        if ($entry.Name -eq 'weaselx64.dll') { $locations += 'System64' }
        if ($entry.Name -eq 'weasel.dll') { $locations += 'System32' }
        foreach ($location in $locations) {
            $target = Resolve-WeaselTarget $entry.Name $location $root $SystemDir $WowDir
            $current = (Get-FileHash -LiteralPath $target).Hash
            Assert-WeaselFile $target $current
            [pscustomobject]@{
                Name = $entry.Name; Location = $location; Destination = $target
                Source = Join-Path (Join-Path $PackageDir 'bin') $entry.Name
                SHA256 = $entry.SHA256; OriginalSHA256 = $current
                Changed = $current -ne $entry.SHA256
            }
        }
    }
}

function New-WeaselBackup {
    param([object[]]$Plan, [string]$InstallDir)
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $root = Join-Path $InstallDir ('backup-replacement-' + $id)
    New-Item -ItemType Directory -Path $root | Out-Null
    $items = @()
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $record = $Plan[$i]
        Assert-WeaselFile $record.Source $record.SHA256
        Assert-WeaselFile $record.Destination $record.OriginalSHA256
        $backupName = "$i-$($record.Name)"
        $backupPath = Join-Path $root $backupName
        Copy-Item -LiteralPath $record.Destination -Destination $backupPath
        Assert-WeaselFile $backupPath $record.OriginalSHA256
        $items += [pscustomobject]@{
            Name = $record.Name; Location = $record.Location; BackupFile = $backupName
            OriginalSHA256 = $record.OriginalSHA256; SHA256 = $record.SHA256
            Destination = $record.Destination; Changed = $record.Changed
            Staged = $record.Destination + '.weasel-stage-' + $id
            Previous = $record.Destination + '.weasel-previous-' + $id
            Source = $record.Source
        }
    }
    $backup = [pscustomobject]@{ Schema = 1; InstallDir = $InstallDir; State = 'Prepared'; Items = $items }
    Write-WeaselJson (Join-Path $root 'backup.json') $backup
    [pscustomobject]@{ Path = $root; Manifest = $backup }
}

function Initialize-WeaselStages {
    param([object[]]$Items)
    foreach ($item in $Items | Where-Object Changed) {
        Assert-WeaselFile $item.Source $item.SHA256
        Assert-WeaselFile $item.Destination $item.OriginalSHA256
        Copy-Item -LiteralPath $item.Source -Destination $item.Staged
        Assert-WeaselFile $item.Staged $item.SHA256
    }
}

function Invoke-WeaselImmediate {
    param([object[]]$Items)
    $moved = [Collections.Generic.List[object]]::new()
    try {
        foreach ($item in $Items | Where-Object Changed) {
            Assert-WeaselFile $item.Staged $item.SHA256
            Assert-WeaselFile $item.Destination $item.OriginalSHA256
            Move-Item -LiteralPath $item.Destination -Destination $item.Previous
            $moved.Add($item)
            Move-Item -LiteralPath $item.Staged -Destination $item.Destination
            Assert-WeaselFile $item.Destination $item.SHA256
        }
    } catch {
        $failure = $_.Exception.Message
        $rollbackErrors = @()
        for ($i = $moved.Count - 1; $i -ge 0; $i--) {
            $item = $moved[$i]
            try {
                if (Test-Path -LiteralPath $item.Destination) {
                    Move-Item -LiteralPath $item.Destination -Destination ($item.Staged + '.failed')
                }
                Move-Item -LiteralPath $item.Previous -Destination $item.Destination
                Assert-WeaselFile $item.Destination $item.OriginalSHA256
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count) { throw "Replacement failed: $failure; ROLLBACK INCOMPLETE: $($rollbackErrors -join '; ')" }
        throw "Replacement failed; originals restored. $failure Use OnRestart if files are in use."
    }
}

function ConvertFrom-WeaselPendingPath {
    param([string]$Path)
    # Windows versions can prefix entries with *1 as well as ! and \??\.
    ($Path -replace '^\*\d+', '' -replace '^!', '' -replace '^\\\?\?\\', '')
}

function Get-WeaselPending {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager')
    try { @($key.GetValue('PendingFileRenameOperations', [string[]]@())) } finally { $key.Dispose() }
}

function Select-WeaselPendingWithoutItems {
    param([string[]]$Pending, [object[]]$Items)
    if ($Pending.Count % 2) { throw 'Malformed pending rename operations; refusing to edit.' }
    for ($i = 0; $i -lt $Pending.Count; $i += 2) {
        $source = ConvertFrom-WeaselPendingPath $Pending[$i]
        $destination = ConvertFrom-WeaselPendingPath $Pending[$i + 1]
        $matches = @($Items | Where-Object { $_.Changed -and $_.Staged -eq $source -and $_.Destination -eq $destination })
        if (-not $matches.Count) { $Pending[$i]; $Pending[$i + 1] }
    }
}

function Remove-WeaselPending {
    param([object[]]$Items)
    $pending = @(Get-WeaselPending)
    $remaining = [string[]]@(Select-WeaselPendingWithoutItems $pending $Items)
    if ($remaining.Count -eq $pending.Count) { return }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager', $true)
    try {
        if ($remaining.Count) { $key.SetValue('PendingFileRenameOperations', $remaining, [Microsoft.Win32.RegistryValueKind]::MultiString) }
        else { $key.DeleteValue('PendingFileRenameOperations', $false) }
    } finally { $key.Dispose() }
}

function Assert-NoWeaselPendingConflict {
    param([object[]]$Plan)
    $pending = @(Get-WeaselPending)
    if ($pending.Count % 2) { throw 'Malformed pending rename operations.' }
    for ($i = 1; $i -lt $pending.Count; $i += 2) {
        $target = ConvertFrom-WeaselPendingPath $pending[$i]
        if (@($Plan | Where-Object Destination -eq $target).Count) { throw "An existing restart replacement targets $target. Restart first, or cancel it using its original backup." }
    }
}

function Invoke-WeaselOnRestart {
    param([object[]]$Items)
    if (-not ('WeaselReplacementNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class WeaselReplacementNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool MoveFileEx(string source, string destination, int flags);
}
'@
    }
    try {
        foreach ($item in $Items | Where-Object Changed) {
            Assert-WeaselFile $item.Staged $item.SHA256
            if (-not [WeaselReplacementNative]::MoveFileEx($item.Staged, $item.Destination, 5)) {
                throw "Cannot schedule $($item.Destination): $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
        }
    } catch {
        $failure = $_
        Remove-WeaselPending $Items
        throw $failure
    }
}

function Read-WeaselBackup {
    param([string]$BackupDir, [string]$InstallDir, [string]$SystemDir, [string]$WowDir)
    $root = (Resolve-Path -LiteralPath $BackupDir).Path
    $backup = Get-Content -LiteralPath (Join-Path $root 'backup.json') -Raw | ConvertFrom-Json
    if ($backup.Schema -ne 1 -or $backup.InstallDir -ne $InstallDir) { throw 'Backup belongs to another installation or has an unsupported format.' }
    $seen = @{}
    foreach ($item in $backup.Items) {
        $target = Resolve-WeaselTarget $item.Name $item.Location $InstallDir $SystemDir $WowDir
        if ($item.Destination -ne $target -or $seen.ContainsKey($target)) { throw 'Invalid or duplicate backup destination.' }
        $seen[$target] = $true
        if ($item.BackupFile -notmatch '^\d+-[^\\/:]+$' -or [IO.Path]::GetFileName($item.BackupFile) -ne $item.BackupFile) { throw 'Invalid backup filename.' }
        if (-not $item.Staged.StartsWith($target + '.weasel-stage-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid staged filename.' }
        if ($item.Staged.Substring($target.Length + '.weasel-stage-'.Length) -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid staged filename suffix.' }
        Assert-WeaselFile (Join-Path $root $item.BackupFile) $item.OriginalSHA256
    }
    $backup
}

Export-ModuleMember -Function *-Weasel*, Assert-NoWeaselPendingConflict, ConvertFrom-WeaselPendingPath, Select-WeaselPendingWithoutItems, Resolve-WeaselTarget, Initialize-WeaselStages
