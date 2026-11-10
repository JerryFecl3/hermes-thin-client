# Run the real wrapper against disposable checkouts and command fakes. No Node,
# package manager, Git, network, or Windows build is required for these checks.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) "hermes build tests $([guid]::NewGuid().ToString('N'))"
$commit = '0123456789abcdef0123456789abcdef01234567'
$count = 0
$envKeys = @('HERMES_DESKTOP_VARIANT', 'HERMES_BUILD_COMMIT', 'HERMES_PAYLOAD_TAG', 'GITHUB_SHA', 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD', 'CSC_IDENTITY_AUTO_DISCOVERY')
$savedEnv = @{}
foreach ($key in $envKeys + 'GITHUB_STEP_SUMMARY') {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
$savedExitCode = Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
Assert (-not (Get-Variable HermesBuildTestCase -Scope Global -ErrorAction SilentlyContinue)) 'A build test is already running in this session.'
function Assert-Arguments([string[]]$Actual, [string[]]$Expected) {
    Assert (($Actual | ConvertTo-Json -Compress) -ceq ($Expected | ConvertTo-Json -Compress)) "Unexpected arguments: $($Actual -join ' ')"
}
function Assert-BuildEnvironment {
    Assert ((Get-Location).Path -ceq $global:HermesBuildTestCase.source) 'Build command ran outside the checkout.'
    Assert ($env:HERMES_DESKTOP_VARIANT -ceq 'light') 'Build did not request Light.'
    Assert (-not $env:GITHUB_SHA -and -not $env:HERMES_BUILD_COMMIT -and -not $env:HERMES_PAYLOAD_TAG) 'Wrapper provenance leaked into the upstream build.'
    Assert ($env:PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD -ceq '1' -and $env:CSC_IDENTITY_AUTO_DISCOVERY -ceq 'false') 'Build environment guards changed.'
}
function New-FakeArtifact {
    Assert-BuildEnvironment
    $global:HermesBuildTestCase.packCount++
    if ($global:HermesBuildTestCase.fault -eq 'pack-failure') { $global:LASTEXITCODE = 24; return }
    $out = Join-Path $global:HermesBuildTestCase.source 'apps/desktop/release/win-unpacked'
    New-Item -ItemType Directory -Force (Join-Path $out 'resources') | Out-Null
    if ($global:HermesBuildTestCase.fault -ne 'missing-exe') { Set-Content (Join-Path $out 'Hermes.exe') 'fake executable' }
    if ($global:HermesBuildTestCase.fault -eq 'extra-exe') { Set-Content (Join-Path $out 'Unexpected.exe') 'fake executable' }
    if ($global:HermesBuildTestCase.fault -ne 'missing-asar') { Set-Content (Join-Path $out 'resources/app.asar') 'fake application' }
    if ($global:HermesBuildTestCase.fault -eq 'bundled-agent') { New-Item -ItemType Directory (Join-Path $out 'resources/agent-payload') | Out-Null }
    @{
        payload = $(if ($global:HermesBuildTestCase.fault -eq 'wrong-payload') { 'full' } else { 'light' })
        commit = $(if ($global:HermesBuildTestCase.fault -eq 'wrong-stamp-commit') { 'f' * 40 } else { $global:HermesBuildTestCase.commit })
        dirty = $global:HermesBuildTestCase.fault -eq 'dirty-stamp'
    } | ConvertTo-Json | Set-Content (Join-Path $out 'resources/install-stamp.json')
}
# The wrapper runs in its own script scope, so its command fakes share one
# uniquely named global fixture. It is removed in the test suite's finally block.
function Invoke-FakeCommand([string]$Exe, [string[]]$Arguments) {
    $global:LASTEXITCODE = 0
    if ($Exe -eq 'git') {
        if ($Arguments[0] -eq 'init') {
            Assert ($Arguments.Count -eq 2) 'Unexpected git init arguments.'
            $global:HermesBuildTestCase.source = $Arguments[1]
            New-Item -ItemType Directory -Force (Join-Path $global:HermesBuildTestCase.source 'pm') | Out-Null
            $packages = @{ node = @{ version = '26.12.1' }; npm = @{ version = '12.0.2' } }
            if ($global:HermesBuildTestCase.modern) { $packages.pnpm = @{ version = '12.15.0' } }
            @{ schema = 1; packages = $packages } | ConvertTo-Json -Depth 4 |
                Set-Content (Join-Path $global:HermesBuildTestCase.source 'pm/lock.json')
            Set-Content (Join-Path $global:HermesBuildTestCase.source 'LICENSE') 'Upstream test license'
            if ($global:HermesBuildTestCase.modern -and $global:HermesBuildTestCase.fault -ne 'missing-cli') {
                New-Item -ItemType Directory -Force (Join-Path $global:HermesBuildTestCase.source 'scripts/build') | Out-Null
                Set-Content (Join-Path $global:HermesBuildTestCase.source 'scripts/build/node-deps.mjs') '// fake upstream CLI'
            }
            return
        }
        Assert ($Arguments[0] -ceq '-C' -and $Arguments[1] -ceq $global:HermesBuildTestCase.source) 'Git used the wrong checkout.'
        switch ($Arguments[2]) {
            'remote' { Assert-Arguments $Arguments @('-C', $global:HermesBuildTestCase.source, 'remote', 'add', 'origin', 'https://github.com/NousResearch/hermes-agent.git'); return }
            'fetch' { Assert-Arguments $Arguments @('-C', $global:HermesBuildTestCase.source, 'fetch', '--depth=1', 'origin', $global:HermesBuildTestCase.commit); return }
            'checkout' { Assert-Arguments $Arguments @('-C', $global:HermesBuildTestCase.source, 'checkout', '--detach', 'FETCH_HEAD'); return }
            'rev-parse' {
                Assert-Arguments $Arguments @('-C', $global:HermesBuildTestCase.source, 'rev-parse', 'HEAD')
                if ($global:HermesBuildTestCase.fault -eq 'wrong-checkout') { return ('f' * 40) }
                return $global:HermesBuildTestCase.commit
            }
        }
    }
    if ($Exe -eq 'node' -and $Arguments[0] -eq '-e') {
        Assert-Arguments $Arguments @('-e', 'if(process.platform!=="win32"||process.arch!=="x64")throw Error("Windows x64 Node is required")')
        return
    }
    if ($Arguments.Count -eq 1 -and $Arguments[0] -eq '--version') {
        switch ($Exe) {
            'node' { return 'v26.12.1' }
            'npm.cmd' { return '12.0.2' }
            'pnpm.cmd' {
                Assert $global:HermesBuildTestCase.modern 'Legacy builds must not require pnpm.'
                if ($global:HermesBuildTestCase.fault -eq 'wrong-pnpm') { return '0.0.0' }
                return '12.15.0'
            }
        }
    }
    if ($Exe -eq 'node' -and $Arguments[0] -eq 'scripts/build/node-deps.mjs') {
        Assert $global:HermesBuildTestCase.modern 'Legacy build unexpectedly delegated to node-deps.'
        Assert-Arguments $Arguments @('scripts/build/node-deps.mjs', '--source', $global:HermesBuildTestCase.source, '--workspace', 'apps/desktop')
        Assert-BuildEnvironment
        $global:HermesBuildTestCase.preparationCount++
        if (-not (Test-Path -LiteralPath $Arguments[0])) { $global:LASTEXITCODE = 1; return }
        if ($global:HermesBuildTestCase.fault -eq 'preparation-failure') { $global:LASTEXITCODE = 23 }
        return
    }
    if ($Exe -eq 'npm.cmd' -and $Arguments[0] -eq 'ci') {
        Assert (-not $global:HermesBuildTestCase.modern) 'Modern builds must not run npm ci.'
        Assert-Arguments $Arguments @('ci', '--workspace', 'apps/desktop', '--workspace', 'apps/shared', '--include-workspace-root', '--engine-strict', '--no-audit', '--no-fund')
        Assert-BuildEnvironment
        $global:HermesBuildTestCase.preparationCount++
        if ($global:HermesBuildTestCase.fault -eq 'preparation-failure') { $global:LASTEXITCODE = 23 }
        return
    }
    if ($Exe -eq 'pnpm.cmd' -and $Arguments[0] -eq '--dir') {
        Assert $global:HermesBuildTestCase.modern 'Legacy builds must not package with pnpm.'
        Assert-Arguments $Arguments @('--dir', 'apps/desktop', 'run', 'pack')
        Assert ($global:HermesBuildTestCase.preparationCount -eq 1) 'Packaging must follow exactly one dependency preparation.'
        New-FakeArtifact
        return
    }
    if ($Exe -eq 'npm.cmd' -and $Arguments[0] -eq 'run') {
        Assert (-not $global:HermesBuildTestCase.modern) 'Modern builds must not package with npm.'
        Assert-Arguments $Arguments @('run', 'pack', '--workspace', 'apps/desktop')
        Assert ($global:HermesBuildTestCase.preparationCount -eq 1) 'Packaging must follow exactly one npm ci.'
        New-FakeArtifact
        return
    }
    throw "Unexpected mock command: $Exe $($Arguments -join ' ')"
}
function node { Invoke-FakeCommand 'node' $args }
function npm.cmd { Invoke-FakeCommand 'npm.cmd' $args }
function pnpm.cmd { Invoke-FakeCommand 'pnpm.cmd' $args }
function git { Invoke-FakeCommand 'git' $args }
function Invoke-RestMethod { throw 'Tests must not access the network.' }

function Run-Case([string]$Name, [bool]$Modern = $true, [string]$Fault = '', [string]$ExpectedError = '') {
    $root = Join-Path $temp $Name
    New-Item -ItemType Directory -Force (Join-Path $root 'scripts') | Out-Null
    Copy-Item (Join-Path $repo 'build.ps1') $root
    Copy-Item (Join-Path $repo 'scripts/toolchain.ps1') (Join-Path $root 'scripts')
    $global:HermesBuildTestCase = [pscustomobject]@{
        root = $root; source = ''; modern = $Modern; fault = $Fault; commit = $commit
        preparationCount = 0; packCount = 0
    }
    $version = if ($Modern) { 'main' } else { 'v0.22.5' }
    $label = if ($Modern) { "nightly-20261110-$($commit.Substring(0,12))" } else { $version }
    $zip = Join-Path $root "dist/Hermes-Light-$label-win-x64.zip"
    if ($Fault -eq 'existing-zip') {
        New-Item -ItemType Directory (Split-Path $zip) | Out-Null
        Set-Content $zip 'Existing artifact must survive'
    }
    $env:GITHUB_STEP_SUMMARY = Join-Path $root 'summary.txt'
    foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, "original-$key", 'Process') }
    $beforeLocation = (Get-Location).Path
    $failure = $null
    try {
        $parameters = @{ Version = $version; UpstreamCommit = $commit }
        if ($Modern) { $parameters.NightlyDate = '20261110' }
        & (Join-Path $root 'build.ps1') @parameters
    } catch { $failure = $_.Exception.Message }
    Assert ((Get-Location).Path -ceq $beforeLocation) "$Name did not restore the working directory."
    foreach ($key in $envKeys) {
        Assert ([Environment]::GetEnvironmentVariable($key, 'Process') -ceq "original-$key") "$Name did not restore $key."
    }
    if ($ExpectedError) {
        Assert ($null -ne $failure -and $failure -match $ExpectedError) "$Name expected '$ExpectedError', got '$failure'."
        if ($Fault -eq 'existing-zip') {
            Assert ((Get-Content $zip -Raw).Trim() -ceq 'Existing artifact must survive') 'Existing artifact was overwritten.'
        } else { Assert (-not (Test-Path $zip)) "$Name produced a ZIP despite failure." }
        Assert (-not (Test-Path "$zip.sha256") -and -not (Test-Path (Join-Path $root 'dist/BUILD-INFO.json'))) "$Name published metadata despite failure."
        Assert (-not (Test-Path $env:GITHUB_STEP_SUMMARY)) "$Name reported success despite failure."
    } else {
        Assert ($null -eq $failure) "$Name failed: $failure"
        Assert ($global:HermesBuildTestCase.preparationCount -eq 1 -and $global:HermesBuildTestCase.packCount -eq 1) "$Name did not prepare then package exactly once."
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert ((Get-Content "$zip.sha256" -Raw) -ceq "$hash  $([IO.Path]::GetFileName($zip))`n") 'Checksum manifest does not match the ZIP.'
        $infoText = Get-Content (Join-Path $root 'dist/BUILD-INFO.json') -Raw
        $info = $infoText | ConvertFrom-Json
        Assert ($info.upstream -ceq 'NousResearch/hermes-agent' -and $info.ref -ceq $version -and $info.commit -ceq $commit) 'Wrong upstream provenance.'
        Assert ($info.variant -ceq 'light' -and $info.target -ceq 'win-x64' -and $info.executable -ceq 'Hermes.exe') 'Wrong artifact provenance.'
        Assert ($info.node -ceq 'v26.12.1' -and $info.npm -ceq '12.0.2') 'Wrong Node/npm provenance.'
        $expectedPnpm = if ($Modern) { '12.15.0' } else { $null }
        Assert ($info.pnpm -ceq $expectedPnpm) 'Wrong pnpm provenance.'
        $lockHash = (Get-FileHash (Join-Path $global:HermesBuildTestCase.source 'pm/lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert ($info.toolchainLock -ceq 'pm/lock.json' -and $info.toolchainLockSha256 -ceq $lockHash) 'Wrong lock provenance.'
        $expectedCommand = if ($Modern) { 'HERMES_DESKTOP_VARIANT=light pnpm --dir apps/desktop run pack' } else { 'HERMES_DESKTOP_VARIANT=light npm run pack --workspace apps/desktop' }
        Assert ($info.command -ceq $expectedCommand) 'Wrong packaging command provenance.'
        Assert ([DateTime]::Parse($info.builtAt).ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(-5)) 'Missing build timestamp.'
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            Assert-Arguments @($archive.Entries.FullName | Sort-Object) @('BUILD-INFO.json', 'Hermes.exe', 'LICENSE.hermes.txt', 'resources/app.asar', 'resources/install-stamp.json')
            foreach ($entry in @('BUILD-INFO.json', 'LICENSE.hermes.txt')) {
                $reader = [IO.StreamReader]::new($archive.GetEntry($entry).Open())
                try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $expected = if ($entry -eq 'BUILD-INFO.json') { $infoText } else { Get-Content (Join-Path $global:HermesBuildTestCase.source 'LICENSE') -Raw }
                Assert ($content -ceq $expected) "ZIP has incorrect $entry."
            }
        } finally { $archive.Dispose() }
        Assert ((Get-Content $env:GITHUB_STEP_SUMMARY -Raw) -match [regex]::Escape($hash)) 'CI summary is missing the ZIP digest.'
    }
    if ($Fault -in @('preparation-failure', 'missing-cli', 'existing-zip', 'wrong-checkout', 'wrong-pnpm')) {
        Assert ($global:HermesBuildTestCase.packCount -eq 0) "$Name reached packaging after a failed prerequisite."
    }
    $script:count++
    Write-Host "PASS $Name"
}

try {
    Run-Case 'modern-delegation'
    Run-Case 'legacy-npm' $false
    Run-Case 'modern-preparation-failure' $true 'preparation-failure' 'node failed with exit code 23'
    Run-Case 'missing-upstream-cli' $true 'missing-cli' 'node failed with exit code 1'
    Run-Case 'legacy-preparation-failure' $false 'preparation-failure' 'npm.cmd failed with exit code 23'
    Run-Case 'packaging-failure' $true 'pack-failure' 'pnpm.cmd failed with exit code 24'
    foreach ($fault in @('wrong-payload', 'wrong-stamp-commit', 'dirty-stamp')) {
        Run-Case $fault $true $fault 'Expected a clean Light artifact from the selected commit'
    }
    foreach ($fault in @('missing-exe', 'extra-exe', 'missing-asar')) {
        Run-Case $fault $true $fault 'Expected an unpacked Windows Electron application'
    }
    Run-Case 'bundled-agent' $true 'bundled-agent' 'Light must not contain a bundled Agent runtime'
    Run-Case 'existing-zip' $true 'existing-zip' 'Artifact already exists'
    Run-Case 'wrong-checkout' $true 'wrong-checkout' 'Checkout does not match the selected commit'
    Run-Case 'wrong-pnpm' $true 'wrong-pnpm' 'Toolchain mismatch: upstream requires pnpm'
    Write-Host "Passed $count offline build regression cases."
} finally {
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    if ($null -ne $savedExitCode) { $global:LASTEXITCODE = $savedExitCode }
    else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    Remove-Variable HermesBuildTestCase -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
