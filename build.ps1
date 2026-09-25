[CmdletBinding()]
param([string]$Version, [string]$NodeDirectory, [string]$UpstreamCommit, [string]$NightlyDate)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$src = Join-Path $root 'src'
New-Item -ItemType Directory -Force (Join-Path $root 'logs') | Out-Null
. (Join-Path $root 'toolchain.ps1') -NodeDirectory $NodeDirectory
foreach ($command in @('git.exe','node.exe','npm.cmd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required on the BUILD machine only." }
}
function Run([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}
if (-not $Version) {
    $release = Invoke-RestMethod 'https://api.github.com/repos/NousResearch/hermes-agent/releases/latest'
    if ($release.prerelease -or $release.draft) { throw 'Latest release is not a stable published release.' }
    $Version = $release.tag_name
}
if ($Version -eq 'main') {
    if (-not $UpstreamCommit) {
        $head = & git.exe ls-remote https://github.com/NousResearch/hermes-agent.git refs/heads/main
        if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Cannot resolve upstream main.' }
        $UpstreamCommit = ($head -split '\s+')[0]
    }
    if ($UpstreamCommit -notmatch '^[0-9a-f]{40}$') { throw 'A full upstream commit SHA is required.' }
    if (-not $NightlyDate) { $NightlyDate = [DateTime]::UtcNow.AddHours(8).ToString('yyyyMMdd') }
    if ($NightlyDate -notmatch '^[0-9]{8}$') { throw 'NightlyDate must use yyyyMMdd.' }
    $artifactVersion = "nightly-$NightlyDate-$($UpstreamCommit.Substring(0,12))"
    $fetchRef = $UpstreamCommit
    $checkoutRef = $UpstreamCommit
} else {
    if ($UpstreamCommit -or $NightlyDate) { throw 'UpstreamCommit and NightlyDate are only supported with -Version main.' }
    if ($Version -notmatch '^v[0-9]+(?:\.[0-9]+){1,3}$') { throw 'Specify a stable numeric release tag or main.' }
    $artifactVersion = $Version
    $fetchRef = "refs/tags/${Version}:refs/tags/${Version}"
    $checkoutRef = "refs/tags/$Version"
}
Write-Host "Selected upstream: $Version ($checkoutRef); artifact: $artifactVersion"
Start-Transcript -Path (Join-Path $root "logs/build-$(Get-Date -Format yyyyMMdd-HHmmss).log") | Out-Null
try {
    if (-not (Test-Path $src)) {
        Run 'git.exe' @('clone','--filter=blob:none','--no-checkout','--single-branch','--branch',$Version,'https://github.com/NousResearch/hermes-agent.git',$src)
    } else {
        if (-not (Test-Path (Join-Path $src '.git'))) { throw 'src exists but is not the managed git checkout.' }
        $origin = & git.exe -C $src remote get-url origin
        if ($LASTEXITCODE -ne 0 -or $origin -notmatch '^https://github.com/NousResearch/hermes-agent(?:\.git)?$') { throw 'Unexpected upstream origin.' }
        # Ignore never-checked-out files on a new --no-checkout clone; otherwise refuse tracked edits.
        $dirty = & git.exe -C $src status --porcelain --untracked-files=no
        if ($dirty) { throw 'Tracked source files have changes. Preserve/review them before switching releases.' }
    }
    Run 'git.exe' @('-C',$src,'fetch','--filter=blob:none','origin',$fetchRef)
    Run 'git.exe' @('-C',$src,'sparse-checkout','init','--cone')
    Run 'git.exe' @('-C',$src,'sparse-checkout','set','apps/desktop','apps/shared')
    Run 'git.exe' @('-C',$src,'checkout','--detach',$checkoutRef)
    $resolvedCommit = (& git.exe -C $src rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or ($Version -eq 'main' -and $resolvedCommit -ne $UpstreamCommit)) { throw 'Checked-out commit does not match the selected source.' }
    $desktop = Get-Content (Join-Path $src 'apps/desktop/package.json') -Raw | ConvertFrom-Json
    if (-not $desktop.scripts.pack -or -not $desktop.scripts.build) { throw 'Upstream Desktop build contract changed. Review the new release before building.' }
    Push-Location $src
    try {
        Run 'node.exe' @('-e','if(process.platform!=="win32"||process.arch!=="x64")throw Error("This build script requires a Windows x64 Node runtime")')
        # npm bundles semver. Check BOTH upstream manifests before allowing install scripts.
        $npmRoot = Split-Path (Get-Command npm.cmd).Source
        $semver = Join-Path $npmRoot 'node_modules/npm/node_modules/semver'
        if (-not (Test-Path $semver)) { throw 'Cannot find npm semver; supply -NodeDirectory pointing to an official Node Windows distribution.' }
        $env:HERMES_THIN_SEMVER = $semver
        $env:HERMES_THIN_NPM_VERSION = (& npm.cmd --version).Trim()
        Run 'node.exe' @('-e', 'const fs=require("fs"),s=require(process.env.HERMES_THIN_SEMVER);for(const p of ["package.json","apps/desktop/package.json"]){const e=JSON.parse(fs.readFileSync(p)).engines||{};if(e.node&&!s.satisfies(process.version,e.node))throw Error(p+" requires Node "+e.node);if(e.npm&&!s.satisfies(process.env.HERMES_THIN_NPM_VERSION,e.npm))throw Error(p+" requires npm "+e.npm)}console.log("Build Node:",process.version,"npm:",process.env.HERMES_THIN_NPM_VERSION)')
        $env:npm_config_cache = Join-Path $root 'tools/npm-cache'
        $env:PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1'
        $env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
        Run 'npm.cmd' @('ci','--workspace','apps/desktop','--workspace','apps/shared','--include-workspace-root','--no-audit','--no-fund')
        $compatVersion = & node.exe (Join-Path $root 'dependency-compat.cjs') $src
        if ($LASTEXITCODE -ne 0) { throw 'Dependency compatibility check failed.' }
        if ($compatVersion) {
            Write-Host "Compatibility: installing undeclared lucide-react@$compatVersion from upstream lockfile version."
            Run 'npm.cmd' @('install',"lucide-react@$compatVersion",'--no-save','--package-lock=false','--ignore-scripts','--workspace','apps/desktop','--workspace','apps/shared','--include-workspace-root','--no-audit','--no-fund')
        }
        # The workflow repository is not the upstream checkout. Let upstream
        # inspect its own Git tree instead of stamping the workflow's GITHUB_SHA.
        $workflowSha = $env:GITHUB_SHA
        try {
            $env:GITHUB_SHA = $null
            Run 'npm.cmd' @('run','pack','--workspace','apps/desktop')
        } finally { $env:GITHUB_SHA = $workflowSha }
        $out = Join-Path $src 'apps/desktop/release/win-unpacked'
        foreach ($file in @('Hermes.exe','resources/app.asar','resources/app.asar.unpacked/dist/electron-main.mjs')) {
            if (-not (Test-Path (Join-Path $out $file))) { throw "Missing output: $file" }
        }
        $metadata = [ordered]@{
            upstream = 'NousResearch/hermes-agent'; tag = $artifactVersion; sourceRef = $Version
            commit = (& git.exe rev-parse HEAD).Trim(); builtAt = [DateTime]::UtcNow.ToString('o')
            node = (& node.exe --version).Trim(); npm = (& npm.cmd --version).Trim()
            electron = $desktop.build.electronVersion; electronBuilder = $desktop.devDependencies.'electron-builder'
            desktopVersion = $desktop.version; unpackedPath = $out
            dependencyCompatibility = $(if ($compatVersion) { "lucide-react@$compatVersion (undeclared Desktop import)" } else { 'None' })
        }
        $metadata | ConvertTo-Json | Set-Content (Join-Path $root 'build-state.json') -Encoding UTF8
        Write-Host "Build complete: $out"
    } finally { Pop-Location }
} finally { Stop-Transcript | Out-Null }
