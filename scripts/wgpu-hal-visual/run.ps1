[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$TargetDirectory,
    [string]$Toolchain = 'stable',
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run this test on an interactive Windows desktop.' }
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $TargetDirectory) {
    $TargetDirectory = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $repository 'target/wgpu-hal-visual' }
}
$TargetDirectory = [IO.Path]::GetFullPath($TargetDirectory)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $TargetDirectory ('results/' + [guid]::NewGuid().ToString('N')) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ((Test-Path -LiteralPath $OutputDirectory) -and (Get-ChildItem -LiteralPath $OutputDirectory -Force | Select-Object -First 1)) {
    throw 'Output directory must be new or empty; old captures must not pass a new run.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$backend = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'backend.json') -Raw | ConvertFrom-Json
$savedTarget = $env:CARGO_TARGET_DIR
$savedBackend = $env:WGPU_BACKEND
$cargoOptions = @()
if ($Toolchain) { $cargoOptions += "+$Toolchain" }
$executables = @{}
$metadata = @{}

try {
    $env:CARGO_TARGET_DIR = $TargetDirectory
    $env:WGPU_BACKEND = 'dx12'
    foreach ($side in @('before', 'after')) {
        $build = Join-Path $OutputDirectory "build/$side"
        New-Item -ItemType Directory -Path $build -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Cargo.toml'), (Join-Path $PSScriptRoot 'Cargo.lock') -Destination $build
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'src') -Destination $build -Recurse
        $manifest = Join-Path $build 'Cargo.toml'
        if ($side -eq 'after') {
            $patch = "`n[patch.crates-io]`n"
            foreach ($package in $backend.packages) {
                $patch += "$package = { git = `"$($backend.url)`", rev = `"$($backend.revision)`" }`n"
            }
            [IO.File]::AppendAllText($manifest, $patch, [Text.UTF8Encoding]::new($false))
            & cargo @cargoOptions fetch --manifest-path $manifest
            if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the pinned fork.' }
            & cargo @cargoOptions build --manifest-path $manifest --offline
        } else {
            & cargo @cargoOptions build --manifest-path $manifest --locked
        }
        if ($LASTEXITCODE -ne 0) { throw "Could not build $side variant." }
        $text = & cargo @cargoOptions metadata --manifest-path $manifest --format-version 1 --locked
        if ($LASTEXITCODE -ne 0) { throw "Could not read $side dependency graph." }
        $metadata[$side] = $text | ConvertFrom-Json
        $binary = Join-Path $build "$side.exe"
        Copy-Item -LiteralPath (Join-Path $TargetDirectory 'debug/dx12-egui-smoke.exe') -Destination $binary
        $executables[$side] = $binary
    }

    $beforeGraph = @($metadata.before.packages | Where-Object name -NotIn $backend.packages | ForEach-Object { "$($_.name)@$($_.version)|$($_.source)" } | Sort-Object)
    $afterGraph = @($metadata.after.packages | Where-Object name -NotIn $backend.packages | ForEach-Object { "$($_.name)@$($_.version)|$($_.source)" } | Sort-Object)
    if (Compare-Object $beforeGraph $afterGraph) { throw 'A/B dependency versions or sources differ outside the pinned wgpu family.' }
    $expectedSource = "git+$($backend.url)?rev=$($backend.revision)#$($backend.revision)"
    foreach ($package in $backend.packages) {
        $beforePackage = @($metadata.before.packages | Where-Object name -eq $package)
        $afterPackage = @($metadata.after.packages | Where-Object name -eq $package)
        if ($beforePackage.Count -ne 1 -or $afterPackage.Count -ne 1) { throw "Expected exactly one $package in each graph." }
        if ($beforePackage[0].version -ne $backend.version -or -not $beforePackage[0].source.StartsWith('registry+') -or $afterPackage[0].version -ne $backend.version -or $afterPackage[0].source -ne $expectedSource) {
            throw "Unexpected source or version for $package."
        }
    }
    $originalHal = @($metadata.before.packages | Where-Object name -eq 'wgpu-hal')
    $patchedHal = @($metadata.after.packages | Where-Object name -eq 'wgpu-hal')
    if ($originalHal.Count -ne 1 -or $patchedHal.Count -ne 1) { throw 'Expected exactly one wgpu-hal in each graph.' }
    if ($originalHal[0].version -ne '30.0.1' -or $patchedHal[0].version -ne '30.0.1' -or -not $originalHal[0].source.StartsWith('registry+')) {
        throw 'The baseline must be the published wgpu-hal 30.0.1.'
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -File) {
        $a = (Get-FileHash -LiteralPath (Join-Path $OutputDirectory "build/before/src/$($file.Name)") -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath (Join-Path $OutputDirectory "build/after/src/$($file.Name)") -Algorithm SHA256).Hash
        if ($a -ne $b) { throw "A/B harness source differs: $($file.Name)" }
    }
    @{
        baseline = 'crates.io wgpu-hal 30.0.1'
        patched = $expectedSource
        fork_packages = $backend.packages
        fork_dx12_sha256 = (Get-FileHash -LiteralPath (Join-Path (Split-Path $patchedHal[0].manifest_path) 'src/dx12/mod.rs') -Algorithm SHA256).Hash
        other_dependency_versions_and_sources_match = $true
        harness_sources_match = $true
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'provenance.json') -Encoding UTF8

    if ($BuildOnly) {
        Write-Host "Built and verified the crates.io baseline and pinned fork: $OutputDirectory"
        return
    }
    foreach ($side in @('before', 'after')) {
        & $executables[$side] capture (Join-Path $OutputDirectory $side) *> (Join-Path $OutputDirectory "$side.log")
        if ($LASTEXITCODE -ne 0) { throw "Capture failed for $side. Inspect $OutputDirectory/$side.log." }
    }
    & $executables.after compare $OutputDirectory
    $comparisonExit = $LASTEXITCODE
    $report = Join-Path $OutputDirectory 'RESULTS.md'
    if ((Test-Path -LiteralPath $report) -and $env:GITHUB_STEP_SUMMARY) {
        Get-Content -LiteralPath $report | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8
    }
    Write-Host "Images and numerical report: $OutputDirectory"
    if ($comparisonExit -eq 2) { throw 'INCONCLUSIVE: unpatched blur did not reproduce; this is not a regression pass.' }
    if ($comparisonExit -ne 0) { throw 'FAIL: inspect RESULTS.md and the captures.' }
} finally {
    $env:CARGO_TARGET_DIR = $savedTarget
    $env:WGPU_BACKEND = $savedBackend
}
