# Read only the Node/npm pins needed by the Light wrapper. Never infer a version
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
    foreach ($name in @('node', 'npm')) {
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
        lockSha256 = (Get-FileHash -LiteralPath $LockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-UpstreamToolchain($Toolchain, [string]$NodeVersion, [string]$NpmVersion) {
    if ($NodeVersion -cne "v$($Toolchain.node)" -or $NpmVersion -cne $Toolchain.npm) {
        throw "Toolchain mismatch: upstream requires Node $($Toolchain.node), npm $($Toolchain.npm); found $NodeVersion, $NpmVersion. Install the exact pm/lock.json pins before building."
    }
}
