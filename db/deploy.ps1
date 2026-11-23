<#
.SYNOPSIS
    Creates (or updates) the AcmeKB database and runs the tests.
.EXAMPLE
    .\deploy.ps1                               # default instance on this machine, Windows auth
    .\deploy.ps1 -Server 'localhost\SQL2025'   # named instance
    .\deploy.ps1 -SkipSeed -SkipEngineTest
#>
param(
    [string]$Server = 'localhost',
    [switch]$SkipSeed,
    [switch]$SkipTests,
    [switch]$SkipEngineTest
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Invoke-SqlFile([string]$file) {
    Write-Host "==> $file" -ForegroundColor Cyan
    # -E Windows auth, -C trust the local certificate, -b exit code on error, -y 0 no truncation
    & sqlcmd -S $Server -E -C -b -y 0 -i (Join-Path $here $file)
    if ($LASTEXITCODE -ne 0) { throw "$file failed (exit code $LASTEXITCODE)" }
}

Invoke-SqlFile '01_schema.sql'
Invoke-SqlFile '02_procs.sql'
if (-not $SkipSeed) { Invoke-SqlFile '03_seed.sql' }
if (-not $SkipTests) { Invoke-SqlFile '..\tests\04_tests.sql' }
if (-not $SkipEngineTest) { Invoke-SqlFile '..\tests\05_engine_test.sql' }
