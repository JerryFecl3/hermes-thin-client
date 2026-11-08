# Read only the build-tool pins needed by the Light wrapper. Never infer a version
# from engines ranges or silently fall back when upstream changes this contract.
function Get-UpstreamToolchain([string]$LockPath) {
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        throw "Missing upstream toolchain lock: $LockPath. This upstream revision is not supported."
    }
    $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json -AsHashtable
    if ($lock.schema -cne 1 -or $lock.packages -isnot [System.Collections.IDictionary]) {
        throw 'Unsupported upstream pm/lock.json schema; review the upstream toolchain contract.'
    }
    $pins = @{}
    $names = @('node', 'npm')
    if ($lock.packages.Contains('pnpm')) { $names += 'pnpm' }
    foreach ($name in $names) {
        $package = $lock.packages[$name]
        if ($package -isnot [System.Collections.IDictionary] -or
            $package.version -isnot [string] -or
            $package.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
            throw "Expected an exact $name version in upstream pm/lock.json."
        }
        $pins[$name] = $package.version
    }
    [pscustomobject]@{
        node = $pins.node
        npm = $pins.npm
        pnpm = $pins['pnpm']
        lockSha256 = (Get-FileHash -LiteralPath $LockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-UpstreamToolchain($Toolchain, [string]$NodeVersion, [string]$NpmVersion, [string]$PnpmVersion) {
    if ($NodeVersion -cne "v$($Toolchain.node)" -or $NpmVersion -cne $Toolchain.npm) {
        throw "Toolchain mismatch: upstream requires Node $($Toolchain.node), npm $($Toolchain.npm); found $NodeVersion, $NpmVersion. Install the exact pm/lock.json pins before building."
    }
    if ($Toolchain.pnpm -and $PnpmVersion -cne $Toolchain.pnpm) {
        throw "Toolchain mismatch: upstream requires pnpm $($Toolchain.pnpm); found '$PnpmVersion'. Install the exact pm/lock.json pin before building."
    }
}
