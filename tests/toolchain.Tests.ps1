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
    # pnpm is optional for older npm revisions, but a present pin must be valid
    # and installed exactly. Never fall back to npm for a broken pnpm contract.
    foreach ($invalidPnpm in @($null, '12.15.0', @{}, @{version='^12.15.0'}, @{version="12.15.0`nx=bad"})) {
        @{schema=1;packages=@{node=@{version='26.12.1'};npm=@{version='12.0.2'};pnpm=$invalidPnpm}} |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path
        Expect-Failure { Get-UpstreamToolchain $path }; $count++
    }
    @{schema=1;packages=@{node=@{version='26.12.1'};npm=@{version='12.0.2'};pnpm=@{version='12.15.0'}}} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path
    $pins = Get-UpstreamToolchain $path
    if ($pins.pnpm -cne '12.15.0') { throw 'pnpm pin changed unexpectedly.' }
    Assert-UpstreamToolchain $pins 'v26.12.1' '12.0.2' '12.15.0'; $count++
    Expect-Failure { Assert-UpstreamToolchain $pins 'v26.12.1' '12.0.2' }; $count++
    Expect-Failure { Assert-UpstreamToolchain $pins 'v26.12.1' '12.0.2' '12.14.0' }; $count++
    Write-Host "Passed $count toolchain contract checks."
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
