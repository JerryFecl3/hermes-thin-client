[CmdletBinding()]
param([string]$Version, [string]$UpstreamCommit, [string]$NightlyDate)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Run([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}
Run 'node' @('-e', 'if(process.platform!=="win32"||process.arch!=="x64")throw Error("Windows x64 Node is required")')
if (-not $Version) {
    $Version = (Invoke-RestMethod 'https://api.github.com/repos/NousResearch/hermes-agent/releases/latest').tag_name
}
if ($Version -ne 'main' -and $Version -notmatch '^v[0-9]+(?:\.[0-9]+){1,3}$') { throw 'Version must be a stable numeric tag or main.' }
if ($UpstreamCommit -and $UpstreamCommit -notmatch '^[0-9a-f]{40}$') { throw 'UpstreamCommit must be a full commit SHA.' }
if ($Version -ne 'main' -and $NightlyDate) { throw 'NightlyDate is only valid for main.' }

# A fresh, complete checkout avoids stale build products and sparse-checkout dependencies.
$src = Join-Path $PSScriptRoot ".build/$([guid]::NewGuid().ToString('N'))"
Run 'git' @('init', $src)
Run 'git' @('-C', $src, 'remote', 'add', 'origin', 'https://github.com/NousResearch/hermes-agent.git')
$ref = if ($Version -eq 'main') { 'refs/heads/main' } else { "refs/tags/$Version" }
$fetchRef = if ($Version -eq 'main' -and $UpstreamCommit) { $UpstreamCommit } else { $ref }
Run 'git' @('-C', $src, 'fetch', '--depth=1', 'origin', $fetchRef)
Run 'git' @('-C', $src, 'checkout', '--detach', 'FETCH_HEAD')
$commit = (& git -C $src rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or ($UpstreamCommit -and $commit -ne $UpstreamCommit)) { throw 'Checkout does not match the selected commit.' }
if ($Version -eq 'main') {
    if (-not $NightlyDate) { $NightlyDate = [DateTime]::UtcNow.AddHours(8).ToString('yyyyMMdd') }
    if ($NightlyDate -notmatch '^[0-9]{8}$') { throw 'NightlyDate must use yyyyMMdd.' }
    $label = "nightly-$NightlyDate-$($commit.Substring(0,12))"
} else { $label = $Version }
$dist = Join-Path $PSScriptRoot 'dist'
$zip = Join-Path $dist "Hermes-Light-$label-win-x64.zip"
if (Test-Path $zip) { throw "Artifact already exists: $zip" }

$savedEnv = @{}
foreach ($key in @('HERMES_DESKTOP_VARIANT', 'HERMES_BUILD_COMMIT', 'HERMES_PAYLOAD_TAG', 'GITHUB_SHA', 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD', 'CSC_IDENTITY_AUTO_DISCOVERY')) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
Push-Location $src
try {
    $env:HERMES_DESKTOP_VARIANT = 'light'
    # Let upstream stamp this checkout, rather than this wrapper repository's CI SHA.
    $env:GITHUB_SHA = $null
    $env:HERMES_BUILD_COMMIT = $null
    $env:HERMES_PAYLOAD_TAG = $null
    $env:PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1'
    $env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
    Run 'npm.cmd' @('ci', '--workspace', 'apps/desktop', '--workspace', 'apps/shared', '--include-workspace-root', '--engine-strict', '--no-audit', '--no-fund')
    Run 'npm.cmd' @('run', 'pack', '--workspace', 'apps/desktop')

    $out = Join-Path $src 'apps/desktop/release/win-unpacked'
    $stamp = Get-Content (Join-Path $out 'resources/install-stamp.json') -Raw | ConvertFrom-Json
    if ($stamp.payload -ne 'light' -or $stamp.commit -ne $commit -or $stamp.dirty) { throw 'Expected a clean Light artifact from the selected commit.' }
    $exes = @(Get-ChildItem -LiteralPath $out -File -Filter '*.exe')
    if ($exes.Count -ne 1 -or -not (Test-Path (Join-Path $out 'resources/app.asar'))) { throw 'Expected an unpacked Windows Electron application.' }
    if (Test-Path (Join-Path $out 'resources/agent-payload')) { throw 'Light must not contain a bundled Agent runtime.' }

    New-Item -ItemType Directory -Force $dist | Out-Null
    $info = [ordered]@{
        upstream = 'NousResearch/hermes-agent'; ref = $Version; commit = $commit
        variant = 'light'; target = 'win-x64'; executable = $exes[0].Name
        builtAt = [DateTime]::UtcNow.ToString('o'); node = (& node --version).Trim()
        command = 'HERMES_DESKTOP_VARIANT=light npm run pack --workspace apps/desktop'
    } | ConvertTo-Json
    $info | Set-Content (Join-Path $out 'BUILD-INFO.json') -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $src 'LICENSE') -Destination (Join-Path $out 'LICENSE.hermes.txt')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($out, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$zip.sha256", "$hash  $([IO.Path]::GetFileName($zip))`n")
    $info | Set-Content (Join-Path $dist 'BUILD-INFO.json') -Encoding UTF8
    Write-Host "Package: $zip`nSHA256: $hash"
} finally {
    Pop-Location
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
}
