$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../scripts/toolchain.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
$path = Join-Path $temp 'lock.json'
$count = 0
function Expect-Failure([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected the toolchain contract to reject this input.' }
}
try {
    Expect-Failure { Get-UpstreamToolchain $path }; $count++
    foreach ($invalid in @(
        '{',
        '{"schema":2,"packages":{"node":{"version":"26.12.1"},"npm":{"version":"12.0.2"}}}',
        '{"schema":1,"packages":{}}',
        '{"schema":1,"packages":{"node":{"version":26},"npm":{"version":"12.0.2"}}}',
        '{"schema":1,"packages":{"node":{"version":"latest"},"npm":{"version":"12.0.2"}}}',
        '{"schema":1,"packages":{"node":{"version":"26.12.1"},"npm":{"version":"^12.0.2"}}}',
        '{"schema":1,"packages":{"node":{"version":"26.12.1"},"npm":{"version":"12.0.2\nx=bad"}}}'
    )) {
        Set-Content -LiteralPath $path -Value $invalid
        Expect-Failure { Get-UpstreamToolchain $path }; $count++
    }
    # Different revisions must keep their own exact pins, including older tools.
    foreach ($pair in @(@('26.12.1', '12.0.2'), @('22.20.0', '10.9.3'))) {
        @{schema=1;packages=@{node=@{version=$pair[0]};npm=@{version=$pair[1]}}} |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path
        $pins = Get-UpstreamToolchain $path
        if ($pins.node -cne $pair[0] -or $pins.npm -cne $pair[1] -or
            $pins.lockSha256 -cne (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw 'Pins or lock digest changed unexpectedly.'
        }
        Assert-UpstreamToolchain $pins "v$($pair[0])" $pair[1]; $count++
        Expect-Failure { Assert-UpstreamToolchain $pins 'v0.0.0' $pair[1] }; $count++
        Expect-Failure { Assert-UpstreamToolchain $pins "v$($pair[0])" '0.0.0' }; $count++
    }
    Write-Host "Passed $count toolchain contract checks."
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
