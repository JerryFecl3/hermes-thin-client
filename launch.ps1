[CmdletBinding()]
param(
    [string]$ExePath = (Join-Path $PSScriptRoot 'Hermes.exe'),
    [string]$UserDataPath = (Join-Path $env:APPDATA 'HermesThin')
)
$ErrorActionPreference = 'Stop'
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
$UserDataPath = [IO.Path]::GetFullPath($UserDataPath)
$protocolKey = 'HKCU:\Software\Classes\hermes\shell\open\command'
$previousCommand = if (Test-Path $protocolKey) { (Get-Item $protocolKey).GetValue('') } else { $null }
$savedEnv = @{}
foreach ($key in @('HERMES_DESKTOP_USER_DATA_DIR','HERMES_HOME')) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key,'Process')
}
try {
    $env:HERMES_DESKTOP_USER_DATA_DIR = $UserDataPath
    $env:HERMES_HOME = Join-Path $UserDataPath 'hermes-home'
    $running = @(Get-Process Hermes -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $ExePath })
    if ($running.Count) {
        # Stock single-instance forwarding raises the already-running window.
        Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath) | Out-Null
        return
    }
    $client = Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath) -PassThru
    $restored = $false
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        $client.Refresh()
        if ($client.HasExited) { throw "Hermes exited at launch: $($client.ExitCode)" }
        # Upstream unconditionally claims hermes:// on ready. Preserve another
        # installed client's existing command; no upstream changes are needed.
        if (-not $restored -and $previousCommand -and (Test-Path $protocolKey)) {
            $now = (Get-Item $protocolKey).GetValue('')
            if ($now -ne $previousCommand -and $now.Contains($ExePath)) {
                Set-Item -LiteralPath $protocolKey -Value $previousCommand
                $restored = $true
            }
        }
    }
    [pscustomobject]@{Id=$client.Id;Exe=$ExePath;UserData=$UserDataPath;PreviousProtocolPreserved=([bool]$previousCommand)}
} finally {
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process') }
}
