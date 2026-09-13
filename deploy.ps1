[CmdletBinding()]
param(
    [string]$ZipPath,
    [string]$InstallRoot = 'C:\Apps\HermesThin',
    [string]$UserDataPath = (Join-Path $env:APPDATA 'HermesThin'),
    [switch]$Rollback,
    [switch]$ForceClose,
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$UserDataPath = [IO.Path]::GetFullPath($UserDataPath).TrimEnd('\')
if ($InstallRoot -eq [IO.Path]::GetPathRoot($InstallRoot).TrimEnd('\')) { throw 'InstallRoot cannot be a drive root.' }
if ($UserDataPath.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'userData must remain outside the program directory.' }
$current = Join-Path $InstallRoot 'current'
$backups = Join-Path $InstallRoot 'backups'
$marker = Join-Path $InstallRoot '.hermes-thin-managed.json'
if ((Test-Path $InstallRoot) -and -not (Test-Path $marker)) {
    if (@(Get-ChildItem -LiteralPath $InstallRoot -Force).Count) { throw 'Existing non-managed directory: refusing to overwrite. Choose an empty InstallRoot.' }
}
function Assert-Child([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes installation: $Path" }
    # Never follow symlinks/junctions in the managed tree.
    $probe = $resolved
    while ($probe.Length -ge $InstallRoot.Length) {
        if (Test-Path -LiteralPath $probe) {
            if ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point refused: $probe" }
        }
        $probe = Split-Path $probe
        if (-not $probe) { break }
    }
    return $resolved
}
function Stop-Client {
    $targetExe = Join-Path $current 'Hermes.exe'
    $running = @(Get-Process Hermes -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $targetExe })
    foreach ($process in $running) { if ($process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() } }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $remaining = @(Get-Process Hermes -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $targetExe })
        if (-not $remaining.Count) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $ForceClose) { throw 'Hermes is still running (possibly minimized to tray). Quit from its tray menu, or rerun with -ForceClose after saving work. No program files have been moved.' }
    $remaining | Stop-Process -Force
    foreach ($process in $remaining) { $process.WaitForExit(10000) | Out-Null }
    if (@(Get-Process Hermes -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $targetExe }).Count) { throw 'Hermes did not exit.' }
}
function Start-Client {
    $exe = Join-Path $current 'Hermes.exe'
    $process = & (Join-Path $PSScriptRoot 'launch.ps1') -ExePath $exe -UserDataPath $UserDataPath
    Write-Host "Hermes started (PID $($process.Id)); userData: $UserDataPath"
}
New-Item -ItemType Directory -Force $InstallRoot,$backups | Out-Null
[void](Assert-Child $current)
[void](Assert-Child $backups)
if (-not (Test-Path $marker)) { @{managedBy='Hermes Thin Client deploy.ps1';userData=$UserDataPath} | ConvertTo-Json | Set-Content $marker -Encoding UTF8 }
$lockPath = Join-Path $InstallRoot '.deploy.lock'
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $journalPath = Join-Path $InstallRoot 'deployment.json'
    if ($Rollback) {
        $journal = Get-Content $journalPath -Raw | ConvertFrom-Json
        $restore = Assert-Child $journal.backup
        if (-not (Test-Path "$restore/Hermes.exe")) { throw 'No valid backup to restore.' }
        Stop-Client
        $displaced = Assert-Child (Join-Path $backups "rollback-displaced-$(Get-Date -Format yyyyMMdd-HHmmss)-$([guid]::NewGuid().ToString('N').Substring(0,8))")
        if (Test-Path $current) { Move-Item -LiteralPath $current -Destination $displaced }
        Move-Item -LiteralPath $restore -Destination $current
        @{backup=$displaced;deployedAt=[DateTime]::UtcNow.ToString('o');rollback=$true} | ConvertTo-Json | Set-Content $journalPath -Encoding UTF8
        if (-not $NoStart) { Start-Client }
        return
    }
    if (-not $ZipPath) {
        $latest = Get-ChildItem (Join-Path $PSScriptRoot 'dist') -Filter 'Hermes-ThinClient-*-win-x64.zip' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw 'No package found. Run package.ps1 first.' }
        $ZipPath = $latest.FullName
    }
    $ZipPath = (Resolve-Path -LiteralPath $ZipPath).Path
    $expected = ((Get-Content "$ZipPath.sha256" -Raw).Trim() -split '\s+')[0]
    if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash $ZipPath -Algorithm SHA256).Hash -ne $expected) { throw 'ZIP SHA256 verification failed.' }
    $stage = Assert-Child (Join-Path $InstallRoot "staging-$([guid]::NewGuid().ToString('N'))")
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $dest = [IO.Path]::GetFullPath((Join-Path $stage $entry.FullName))
            if (-not $dest.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':')) { throw "Unsafe ZIP entry: $($entry.FullName)" }
        }
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $stage)
    foreach ($file in @('Hermes.exe','resources/app.asar','BUILD-INFO.txt')) { if (-not (Test-Path (Join-Path $stage $file))) { throw "Package is missing $file" } }
    Stop-Client
    $backup = $null
    if (Test-Path $current) {
        $backup = Assert-Child (Join-Path $backups "before-$(Get-Date -Format yyyyMMdd-HHmmss)-$([guid]::NewGuid().ToString('N').Substring(0,8))")
        Move-Item -LiteralPath $current -Destination $backup
    }
    try {
        Move-Item -LiteralPath $stage -Destination $current
        # The stable launcher avoids collision with another stock Hermes installation.
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'launch.ps1') -Destination (Join-Path $InstallRoot 'Start-Hermes.ps1') -Force
        @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Start-Hermes.ps1" -ExePath "%~dp0current\Hermes.exe" -UserDataPath "$UserDataPath"
"@ | Set-Content (Join-Path $InstallRoot 'Start-Hermes.cmd') -Encoding Default
        @{zip=$ZipPath;sha256=$expected;backup=$backup;userData=$UserDataPath;deployedAt=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content $journalPath -Encoding UTF8
        if (-not $NoStart) { Start-Client }
    } catch {
        $launchError = $_
        if (Test-Path $current) {
            Stop-Client
            $failed = Assert-Child (Join-Path $InstallRoot "failed-$([guid]::NewGuid().ToString('N'))")
            Move-Item -LiteralPath $current -Destination $failed
        }
        if ($backup -and (Test-Path $backup)) {
            Move-Item -LiteralPath $backup -Destination $current
            if (-not $NoStart) { Start-Client }
        }
        throw $launchError
    }
    Write-Host "Deployed: $current. Backup: $backup. Persistent data was not removed."
} finally { $lock.Dispose() }
