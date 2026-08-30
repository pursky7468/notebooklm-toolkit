<#
.SYNOPSIS
    Ask one or more questions (passed as parameters, never from a config file
    -- design decision D2/D3) against a NotebookLM notebook and write a
    structured Markdown digest with citations.

.PARAMETER Notebook
    Notebook id (partial id accepted).

.PARAMETER Question
    One or more question strings. Each is sent to notebooklm via
    '--prompt-file -' (stdin), never as a positional argv value, so quotes
    and embedded newlines survive intact (design D3).

.PARAMETER OutDir
    Directory to write the output .md file into. Defaults to config.json's
    "digestOutputDir" if present, else '<toolkit>\out'.

.PARAMETER NewConversation
    DESTRUCTIVE. Starts a fresh server-side conversation before asking the
    first question (notebooklm ask --new -y), permanently deleting the
    notebook's existing conversation. Off by default (design D6). Applies
    only once per digest run -- later questions in the same run continue
    the freshly-started conversation rather than wiping it again.

.PARAMETER ConfigPath
    Path to config.json. Defaults to '<toolkit>\config.json'.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory)][string]$Notebook,
    [Parameter(Mandatory)][string[]]$Question,
    [string]$OutDir,
    [switch]$NewConversation,
    [switch]$Brief,
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot '_common.ps1')

# $PSScriptRoot is not reliably populated during parameter binding, so the
# config path default is resolved here instead of in the param() block.
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }

if (-not $OutDir) {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.digestOutputDir) { $OutDir = $cfg.digestOutputDir }
        } catch {
            Write-NbWarn "Could not read $ConfigPath, falling back to default output dir: $($_.Exception.Message)"
        }
    }
}
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

if ($NewConversation) {
    Write-NbWarn "--NewConversation: this permanently deletes the notebook's existing server-side conversation before asking. This cannot be undone."
}

if ($Brief) {
    Write-NbWarn "-Brief: NotebookLM returns no reference objects for short bulleted answers, so this digest will have no References section. Inline [n] markers may still appear but cannot be resolved. Omit -Brief when citation traceability matters."
}

# Resolve the notebook's title for the report header and filename.
$metaResult = Invoke-NotebookLM -Arguments @('metadata', '-n', $Notebook, '--json')
if ($metaResult.ExitCode -ne 0) {
    Write-NbError "notebooklm metadata failed (exit $($metaResult.ExitCode)): $((Get-NbFailureText $metaResult))"
    exit 1
}
try {
    $meta = $metaResult.StdOut | ConvertFrom-Json
} catch {
    Write-NbError "Could not parse notebook metadata as JSON: $($_.Exception.Message)"
    exit 1
}
$notebookTitle = $meta.title
$notebookId = $meta.id

# Map source ids to titles so references can be rendered compactly. The whole
# point of this toolkit is to keep the digest small, so the raw reference
# objects (which embed the full cited source text) must never be dumped.
$sourceTitles = @{}
$srcResult = Invoke-NotebookLM -Arguments @('source', 'list', '-n', $Notebook, '--json')
if ($srcResult.ExitCode -eq 0) {
    try {
        $srcParsed = $srcResult.StdOut | ConvertFrom-Json
        $srcItems = if ($null -ne $srcParsed -and $srcParsed.PSObject.Properties.Name -contains 'sources') {
                        @($srcParsed.sources)
                    } else { @($srcParsed) }
        foreach ($s in $srcItems) {
            if ($s.id) { $sourceTitles[[string]$s.id] = [string]$s.title }
        }
    } catch {
        Write-NbWarn "Could not parse source list; references will show ids instead of titles."
    }
} else {
    Write-NbWarn "Could not list sources; references will show ids instead of titles."
}

$results = New-Object System.Collections.Generic.List[object]
$pendingNewFlag = $NewConversation.IsPresent

foreach ($q in $Question) {
    $askArgs = @('ask')
    if ($pendingNewFlag) {
        $askArgs += @('--new', '-y')
        $pendingNewFlag = $false  # only the first question in this run starts fresh
    }
    $askArgs += @('-n', $Notebook, '--prompt-file', '-', '--json')

    # NotebookLM answers at length by default, which works against the whole
    # point of this toolkit. -Brief prepends a concision directive so the
    # digest stays small enough to hand straight to an agent.
    $prompt = $q
    if ($Brief) {
        $prompt = "$q`n`n[FORMAT] Answer in bullet points, 300 characters maximum. State only conclusions and key facts. Do not elaborate, do not restate the question, and do not end with follow-up suggestions or offers. Answer in the same language as the question."
    }

    $askResult = Invoke-NotebookLM -Arguments $askArgs -StdinInput $prompt

    if ($askResult.ExitCode -ne 0) {
        $results.Add([PSCustomObject]@{
            Question   = $q
            Answer     = $null
            References = $null
            Error      = (Get-NbFailureText $askResult)
        })
        Write-NbError "Question failed: $q"
        continue
    }

    $answerText = $null
    $references = $null
    try {
        $parsed = $askResult.StdOut | ConvertFrom-Json
        # Field name is defensive: verified against --help docs only, not a
        # live response (see VERIFY.md / final report for why).
        $answerText = if ($parsed.PSObject.Properties.Name -contains 'answer') { $parsed.answer }
                      elseif ($parsed.PSObject.Properties.Name -contains 'response') { $parsed.response }
                      elseif ($parsed.PSObject.Properties.Name -contains 'text') { $parsed.text }
                      else { $askResult.StdOut }
        if ($parsed.PSObject.Properties.Name -contains 'references') { $references = $parsed.references }
    } catch {
        $answerText = $askResult.StdOut
    }

    $results.Add([PSCustomObject]@{
        Question   = $q
        Answer     = $answerText
        References = $references
        Error      = $null
    })
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeTitle = ($notebookTitle -replace '[\\/:*?"<>|]', '_')
if ([string]::IsNullOrWhiteSpace($safeTitle)) { $safeTitle = $notebookId }
$outFile = Join-Path $OutDir "$safeTitle-$timestamp.md"

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# NotebookLM Digest: $notebookTitle")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("- Notebook ID: $notebookId")
[void]$sb.AppendLine("- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$sb.AppendLine("- New conversation started: $($NewConversation.IsPresent)")
[void]$sb.AppendLine("- Brief mode: $($Brief.IsPresent)")
[void]$sb.AppendLine("")

foreach ($r in $results) {
    [void]$sb.AppendLine("## Q: $($r.Question)")
    [void]$sb.AppendLine("")
    if ($r.Error) {
        [void]$sb.AppendLine("**ERROR:** $($r.Error)")
    } else {
        [void]$sb.AppendLine($r.Answer)
        if ($r.References) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("### References")
            foreach ($ref in $r.References) {
                $sid = [string]$ref.source_id
                $label = if ($sourceTitles.ContainsKey($sid)) { $sourceTitles[$sid] }
                         elseif ($sid) { $sid.Substring(0, [Math]::Min(8, $sid.Length)) }
                         else { '(unknown source)' }
                $snippet = ''
                if ($ref.cited_text) {
                    $snippet = ([string]$ref.cited_text) -replace '\s+', ' '
                    $snippet = $snippet.Trim()
                    if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) + '...' }
                }
                $line = "- [$($ref.citation_number)] $label"
                if ($snippet) { $line += " -- $snippet" }
                [void]$sb.AppendLine($line)
            }
        }
    }
    [void]$sb.AppendLine("")
}

# PS 5.1's -Encoding UTF8 always emits a BOM; write without one.
$utf8NoBomOut = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outFile, $sb.ToString(), $utf8NoBomOut)

# Write-Output, not Write-Host: this path is the script's return value and
# callers (schedulers, agents) must be able to capture it. Log lines stay on
# Write-Host so they never pollute stdout.
Write-Output $outFile

$failCount = ($results | Where-Object { $_.Error }).Count
if ($failCount -gt 0) { exit 1 } else { exit 0 }
