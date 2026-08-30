<#
.SYNOPSIS
    Output a NotebookLM notebook's minimal structured description (id, title,
    source list) without ever including source content. This is the only
    input an agent should read when deciding what question to ask.

.PARAMETER Notebook
    Notebook id (partial id accepted, per notebooklm CLI convention). If
    omitted, lists all notebooks in the account instead.

.PARAMETER Json
    Emit machine-readable JSON instead of a human-readable listing.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Notebook,
    [switch]$Json
)

. (Join-Path $PSScriptRoot '_common.ps1')

if (-not $Notebook) {
    $result = Invoke-NotebookLM -Arguments @('list', '--json')
    if ($result.ExitCode -ne 0) {
        Write-NbError "notebooklm list failed (exit $($result.ExitCode)): $((Get-NbFailureText $result))"
        exit 1
    }

    try {
        $parsed = $result.StdOut | ConvertFrom-Json
    } catch {
        Write-NbError "Could not parse notebook list as JSON: $($_.Exception.Message)"
        exit 1
    }

    # 'notebooklm list --json' wraps the array: {"notebooks":[...],"count":N}.
    # Unwrap it, but stay tolerant of a bare array in case upstream changes.
    if ($null -ne $parsed -and $parsed.PSObject.Properties.Name -contains 'notebooks') {
        $notebooks = @($parsed.notebooks)
    } else {
        $notebooks = @($parsed)
    }

    if ($Json) {
        $notebooks | ConvertTo-Json -Depth 6
    } else {
        if (-not $notebooks -or $notebooks.Count -eq 0) {
            Write-Output "(no notebooks found)"
        } else {
            foreach ($nb in $notebooks) {
                Write-Output "$($nb.id)  $($nb.title)"
            }
        }
    }
    exit 0
}

# Single-notebook mode: metadata only, never source content.
$result = Invoke-NotebookLM -Arguments @('metadata', '-n', $Notebook, '--json')
if ($result.ExitCode -ne 0) {
    Write-NbError "notebooklm metadata failed (exit $($result.ExitCode)): $((Get-NbFailureText $result))"
    exit 1
}

try {
    $meta = $result.StdOut | ConvertFrom-Json
} catch {
    Write-NbError "Could not parse notebook metadata as JSON: $($_.Exception.Message)"
    exit 1
}

# Explicit field whitelist, not a pass-through of $meta: this is defense in
# depth for the "SHALL NOT include source content" requirement. It holds
# today because 'notebooklm metadata --json' only ever returns id/title/
# created_at/is_owner + sources[type,title,url] (per its own --help text),
# but projecting explicitly means a hypothetical future upstream change that
# adds a content/transcript field can't leak through nb-inspect silently.
$safeSources = @()
if ($meta.sources) {
    $safeSources = @($meta.sources | ForEach-Object {
        [PSCustomObject]@{ type = $_.type; title = $_.title; url = $_.url }
    })
}
$safeMeta = [PSCustomObject]@{
    id         = $meta.id
    title      = $meta.title
    created_at = $meta.created_at
    is_owner   = $meta.is_owner
    sources    = $safeSources
}

if ($Json) {
    $safeMeta | ConvertTo-Json -Depth 6
    exit 0
}

Write-Output "Notebook: $($safeMeta.title)"
Write-Output "Id:       $($safeMeta.id)"
if ($safeMeta.created_at) { Write-Output "Created:  $($safeMeta.created_at)" }
Write-Output ""
Write-Output "Sources:"
if (-not $safeMeta.sources -or $safeMeta.sources.Count -eq 0) {
    Write-Output "  (none)"
} else {
    foreach ($src in $safeMeta.sources) {
        $label = if ($src.title) { $src.title } else { $src.url }
        Write-Output "  [$($src.type)] $label"
    }
}
exit 0
