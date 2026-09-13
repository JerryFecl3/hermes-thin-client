# Dot-source from build/package entry points. Changes only this PowerShell process.
param([string]$NodeDirectory)
$toolRoot = Join-Path $PSScriptRoot 'tools'
$localGit = Join-Path $toolRoot 'git/cmd'
$localNode = Join-Path $toolRoot 'node'
if (Test-Path (Join-Path $localGit 'git.exe')) { $env:PATH = "$localGit;$env:PATH" }
if ($NodeDirectory) {
    if (-not (Test-Path (Join-Path $NodeDirectory 'node.exe'))) { throw "Node executable missing in $NodeDirectory" }
    $env:PATH = "$NodeDirectory;$env:PATH"
} elseif (Test-Path (Join-Path $localNode 'node.exe')) {
    $env:PATH = "$localNode;$env:PATH"
}
$env:npm_config_cache = Join-Path $toolRoot 'npm-cache'
$env:ELECTRON_CACHE = Join-Path $toolRoot 'electron-cache'
$env:ELECTRON_BUILDER_CACHE = Join-Path $toolRoot 'electron-builder-cache'
