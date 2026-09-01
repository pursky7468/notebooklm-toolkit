<#
.SYNOPSIS
    B-type pipeline: pull this week's top AI-news URLs and ingest them into a
    NotebookLM notebook, then print the notebook description an agent needs to
    decide what to ask.

    Deterministic and zero-token up to that point. The digest step is left to
    the caller on purpose: questions are chosen per batch by an agent reading
    the nb-inspect output, not from a fixed list in config.

.PARAMETER Notebook
    Existing notebook id to accumulate into. Accumulating across weeks is what
    this adds over the project's own weekly briefing: the briefing answers
    "what happened this week", a growing corpus answers "when did this theme
    start showing up".

.PARAMETER NewNotebook
    Create a fresh notebook named after the date range instead of accumulating.

.PARAMETER PerDay
    Top N articles per day (default 2).

.PARAMETER Days
    Days to look back from the newest post in the database (default 7).
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Notebook,
    [switch]$NewNotebook,
    [int]$PerDay = 2,
    [int]$Days = 7,
    [int]$WaitTimeoutSeconds = 900
)

$toolkit = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolkit '_common.ps1')

if (-not $Notebook -and -not $NewNotebook) {
    Write-NbError "Pass -Notebook <id> to accumulate, or -NewNotebook to create one."
    exit 1
}

# Preflight: the short-lived rotation cookie expires in about 12 minutes and
# the stored session goes stale if a refresh is missed, so an unattended run
# can arrive with dead credentials. 'notebooklm login' is fully
# non-interactive while the persistent browser profile still holds a valid
# Google session -- it just re-exports the cookies -- so the schedule can
# self-heal without a human. It only needs a person when that profile itself
# has expired, which nb-doctor reports on the second check.
& (Join-Path $toolkit 'nb-doctor.ps1') | Out-Null
if ($LASTEXITCODE -eq 1) {
    Write-NbWarn "Stored session is stale; re-exporting credentials from the browser profile..."
    $reauth = Invoke-NotebookLM -Arguments @('login')
    if ($reauth.ExitCode -ne 0) {
        Write-NbError "Automatic re-auth failed. Run 'notebooklm login' yourself: $((Get-NbFailureText $reauth))"
        exit 1
    }
    & (Join-Path $toolkit 'nb-doctor.ps1') | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-NbError "Still not authenticated after re-auth (nb-doctor exit $LASTEXITCODE). Run 'notebooklm login' interactively."
        exit 1
    }
    Write-NbInfo "Credentials refreshed."
}

$connector = Join-Path $PSScriptRoot 'Get-AiNewsUrls.py'
if (-not (Test-Path -LiteralPath $connector)) {
    Write-NbError "Connector not found: $connector"
    exit 1
}

Write-NbInfo "Collecting URLs (last $Days days, top $PerDay per day)..."
$urls = @(& python $connector --days $Days --per-day $PerDay | Where-Object { $_ -match '^\s*https?://' } | ForEach-Object { $_.Trim() })
if ($urls.Count -eq 0) {
    Write-NbError "Connector returned no URLs."
    exit 1
}
Write-NbInfo "Got $($urls.Count) URL(s)."

if ($NewNotebook) {
    $title = "AI News - $(Get-Date -Format 'yyyy-MM-dd')"
    $created = Invoke-NotebookLM -Arguments @('create', $title, '--json')
    if ($created.ExitCode -ne 0) {
        Write-NbError "Could not create notebook: $((Get-NbFailureText $created))"
        exit 1
    }
    try {
        $Notebook = ($created.StdOut | ConvertFrom-Json).notebook.id
    } catch {
        Write-NbError "Could not parse the created notebook id: $($_.Exception.Message)"
        exit 1
    }
    Write-NbInfo "Created notebook $Notebook ($title)"
}

& (Join-Path $toolkit 'nb-ingest.ps1') -Path $urls -Notebook $Notebook -Wait -WaitTimeoutSeconds $WaitTimeoutSeconds
$ingestExit = $LASTEXITCODE
if ($ingestExit -ne 0) {
    Write-NbWarn "Ingest reported problems (exit $ingestExit); the notebook description below may be incomplete."
}

Write-Host ""
& (Join-Path $toolkit 'nb-inspect.ps1') -Notebook $Notebook

exit $ingestExit
