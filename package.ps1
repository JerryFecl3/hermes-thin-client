[CmdletBinding()]
param([string]$NodeDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
. (Join-Path $root 'toolchain.ps1') -NodeDirectory $NodeDirectory
$state = Get-Content (Join-Path $root 'build-state.json') -Raw | ConvertFrom-Json
$out = [IO.Path]::GetFullPath((Join-Path $root 'src/apps/desktop/release/win-unpacked'))
if (-not (Test-Path "$out/Hermes.exe")) { throw 'Run build.ps1 first.' }
$commit = (& git.exe -C (Join-Path $root 'src') rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -ne $state.commit) { throw 'Source commit differs from recorded build.' }
$stamp = Get-Content "$out/resources/install-stamp.json" -Raw | ConvertFrom-Json
if ($stamp.commit -ne $state.commit -or $stamp.dirty) { throw 'Packaged install stamp differs or is dirty.' }
& node.exe (Join-Path $root 'audit-payload.cjs') $out
if ($LASTEXITCODE -ne 0) { throw 'ASAR / x64 payload audit failed.' }
$files = @(Get-ChildItem -LiteralPath $out -Recurse -File)
$bad = @($files | Where-Object {
    $_.FullName.Substring($out.Length) -match '(?i)[\\/](\.git|\.venv|venv|hermes-agent|PortableGit|python(?:w|\d+(?:\.\d+)*)?(?:\.exe|\.dll)?|uv(?:\.exe)?|git\.exe|node\.exe|npm(?:\.cmd)?|ffmpeg\.exe|rg\.exe|playwright)([\\/]|$)'
})
if ($bad.Count) { throw "Forbidden runtime payload: $($bad.FullName -join ', ')" }
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$packageVersion = $state.tag
if ($state.sourceRef -ne 'main') {
    # Read from the exact built commit without expanding the sparse checkout or running Python.
    $versionSource = & git.exe -C (Join-Path $root 'src') show "$($state.commit):hermes_cli/__init__.py"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read upstream Agent version from the built commit.' }
    $versionMatch = [regex]::Match(($versionSource -join "`n"), '(?m)^__version__\s*=\s*["'']([0-9]+\.[0-9]+\.[0-9]+)["'']\s*$')
    if (-not $versionMatch.Success) { throw 'Expected a stable semantic Agent version in hermes_cli/__init__.py.' }
    $packageVersion = "v$($versionMatch.Groups[1].Value)"
}
$name = "Hermes-ThinClient-$packageVersion-win-x64.zip"
$zip = Join-Path $dist $name
if (Test-Path $zip) { throw "Artifact exists: $zip. Rename/archive it before repackaging." }
$info = @"
Upstream:
NousResearch/hermes-agent
Build version:
$($state.tag)
Package version:
$packageVersion
Upstream ref:
$($state.sourceRef)
Commit:
$($state.commit)
Build date:
$($state.builtAt)
Target:
Windows x64
Mode:
Remote-only Desktop / Thin Client
Local Hermes Runtime:
Not included
Node version (build machine):
$($state.node)
npm version (build machine):
$($state.npm)
Electron version:
$($state.electron)
electron-builder version:
$($state.electronBuilder)
Desktop package version:
$($state.desktopVersion)
Upstream source modifications:
None
Build command:
npm run pack --workspace apps/desktop
Sparse checkout:
apps/desktop, apps/shared, root-level files (Git cone mode)
Notes:
Electron embeds Chromium, V8 and Node internally; no standalone Node/npm distribution.
Stock Local mode remains available. Select Connect to existing Hermes / Remote Gateway.
Use external rebuild/deploy for upgrades; do not use the in-app source updater.
"@
$info | Set-Content "$out/BUILD-INFO.txt" -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $root 'src/LICENSE') -Destination "$out/LICENSE.hermes.txt"
$info | Set-Content (Join-Path $root 'BUILD-INFO.txt') -Encoding UTF8
@'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Start-Hermes.ps1"
'@ | Set-Content "$out/Start-Hermes.cmd" -Encoding ASCII
Copy-Item -LiteralPath (Join-Path $root 'launch.ps1') -Destination "$out/Start-Hermes.ps1"
# ZipFile streams large archives and includes dotfiles; no top-level wrapper folder.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($out, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name" | Set-Content "$zip.sha256" -Encoding ASCII
$bytes = (Get-ChildItem -LiteralPath $out -Recurse -File | Measure-Object Length -Sum).Sum
[ordered]@{zip=$zip;zipBytes=(Get-Item $zip).Length;unpackedBytes=$bytes;sha256=$hash} | ConvertTo-Json | Set-Content (Join-Path $dist 'package-size.json') -Encoding UTF8
Write-Host "Package: $zip`nSHA256: $hash`nUnpacked bytes: $bytes"
