<#
.SYNOPSIS
    Health check for the notebooklm-toolkit environment. Classifies failures
    by exit code so a scheduler can decide whether it needs agent help
    (design D5):
      0 = healthy
      1 = auth invalid, user can self-heal by re-running 'notebooklm login'
      2 = RPC/decode failure -- upstream reverse-engineered API likely broke,
          needs agent maintenance
      3 = installed version is behind the latest on PyPI

.PARAMETER Json
    Emit a single machine-readable JSON result instead of console text.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [switch]$Json
)

. (Join-Path $PSScriptRoot '_common.ps1')

$reportStatus = 'ok'
$reportMessage = ''
$reportDetail = $null
$exitCode = 0

function Write-DoctorResult {
    param([string]$Status, [string]$Message, $Detail, [int]$Code)
    if ($Json) {
        [PSCustomObject]@{
            status  = $Status
            message = $Message
            detail  = $Detail
        } | ConvertTo-Json -Depth 6
    } else {
        switch ($Status) {
            'ok'    { Write-NbInfo $Message }
            'warn'  { Write-NbWarn $Message }
            default { Write-NbError $Message }
        }
        if ($Detail) {
            Write-Host ($Detail | ConvertTo-Json -Depth 6)
        }
    }
    exit $Code
}

# --- Step 1: auth + connectivity check (read-only, unattended-safe) --------
$authResult = Invoke-NotebookLM -Arguments @('auth', 'check', '--test', '--passive', '--json')

$authJson = $null
try { $authJson = $authResult.StdOut | ConvertFrom-Json } catch {}

if (-not $authJson) {
    # Could not even parse the auth check's own output -- treat this as an
    # RPC/CLI-behavior-changed situation, not a self-fixable auth problem.
    Write-DoctorResult -Status 'error' `
        -Message "nb-doctor: could not parse 'notebooklm auth check' output. Upstream CLI behavior may have changed." `
        -Detail ([PSCustomObject]@{ exitCode = $authResult.ExitCode; stderr = $authResult.StdErr; stdoutRaw = $authResult.StdOut }) `
        -Code 2
}

# Only ever surface validity + path info, never cookie/token values
# (requirement: nb-doctor output SHALL NOT contain cookie/token contents).
$safeChecks = $authJson.checks
$storagePath = $authJson.storage_path
$authError = $authJson.details.error

$localChecksOk = $authJson.checks.storage_exists -and $authJson.checks.json_valid -and `
                 $authJson.checks.cookies_present -and $authJson.checks.sid_cookie

if (-not $localChecksOk) {
    Write-DoctorResult -Status 'error' `
        -Message "Auth invalid. Self-fix: run 'notebooklm login' to re-authenticate." `
        -Detail ([PSCustomObject]@{
            storage_path = $storagePath
            checks       = $safeChecks
            error        = $authError
        }) `
        -Code 1
}

if ($authJson.checks.token_fetch -eq $false) {
    Write-DoctorResult -Status 'error' `
        -Message "Local credentials look valid, but a live token fetch from NotebookLM failed. This looks like an upstream RPC/decoding failure (or a network outage) -- needs agent maintenance." `
        -Detail ([PSCustomObject]@{
            storage_path = $storagePath
            checks       = $safeChecks
            error        = $authError
        }) `
        -Code 2
}

# Catch-all: the auth check reported failure through a path none of the
# branches above recognise (a new check field, a changed schema). Falling
# through to 'Healthy' here would hide a real outage, so classify it as
# needing agent maintenance rather than guessing.
if ($authResult.ExitCode -ne 0) {
    Write-DoctorResult -Status 'error' `
        -Message "'notebooklm auth check' reported failure (exit $($authResult.ExitCode)) for a reason nb-doctor does not recognise -- needs agent maintenance." `
        -Detail ([PSCustomObject]@{
            storage_path = $storagePath
            checks       = $safeChecks
            error        = $authError
            exitCode     = $authResult.ExitCode
        }) `
        -Code 2
}

# --- Step 2: version freshness check ---------------------------------------
$versionResult = Invoke-NotebookLM -Arguments @('--version')
$localVersion = $null
if ($versionResult.StdOut -match '(\d+\.\d+\.\d+)') {
    $localVersion = $Matches[1]
}

$latestVersion = $null
try {
    $pypi = Invoke-RestMethod -Uri 'https://pypi.org/pypi/notebooklm-py/json' -TimeoutSec 10
    $latestVersion = $pypi.info.version
} catch {
    Write-NbWarn "Could not reach PyPI to check for a newer version: $($_.Exception.Message)"
}

if ($localVersion -and $latestVersion) {
    try {
        $localV = [version]$localVersion
        $latestV = [version]$latestVersion
        if ($latestV -gt $localV) {
            Write-DoctorResult -Status 'warn' `
                -Message "Installed notebooklm-py $localVersion is behind the latest release $latestVersion on PyPI." `
                -Detail ([PSCustomObject]@{
                    installedVersion = $localVersion
                    latestVersion    = $latestVersion
                    upgradeCommand   = 'uv tool upgrade notebooklm-py'
                }) `
                -Code 3
        }
    } catch {
        Write-NbWarn "Could not compare versions '$localVersion' vs '$latestVersion': $($_.Exception.Message)"
    }
}

# --- All checks passed -------------------------------------------------------
Write-DoctorResult -Status 'ok' `
    -Message "Healthy: auth valid, NotebookLM reachable, version up to date." `
    -Detail ([PSCustomObject]@{
        storage_path     = $storagePath
        installedVersion = $localVersion
        latestVersion    = $latestVersion
    }) `
    -Code 0
