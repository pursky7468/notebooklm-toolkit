<#
.SYNOPSIS
    Add local files, folders, or URLs into a NotebookLM notebook. Supports a
    manual one-shot mode (-Path) and an unattended watch mode (-Watch, driven
    by config.json's watchTasks) with per-file dedup via a state file keyed
    on path + size + mtime (design D4).

.PARAMETER Path
    Manual mode: a file path, a folder path (recursed, extension-filtered),
    or a URL. Requires -Notebook.

.PARAMETER Notebook
    Manual mode: target notebook id (partial id accepted).

.PARAMETER Extensions
    Manual mode folder filter. Defaults to $script:DefaultExtensions.

.PARAMETER Watch
    Run all watch tasks defined in config.json (or just -TaskName if given).

.PARAMETER TaskName
    With -Watch, restrict to a single named task.

.PARAMETER ConfigPath
    Path to config.json. Defaults to '<toolkit>\config.json'.

.PARAMETER StateFile
    Path to the ingest state file. Defaults to config.json's
    "ingestStateFile" if present, else '<toolkit>\state\ingest-state.json'.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Path,
    [string]$Notebook,
    [string[]]$Extensions,
    [switch]$Watch,
    [string]$TaskName,
    [string]$ConfigPath,
    [string]$StateFile
)

. (Join-Path $PSScriptRoot '_common.ps1')

# $PSScriptRoot is not reliably populated during parameter binding, so the
# config path default is resolved here instead of in the param() block.
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }

$script:DefaultExtensions = @('.pdf', '.txt', '.md', '.docx', '.pptx', '.csv',
                               '.mp3', '.wav', '.m4a', '.mp4', '.mov')

function ConvertTo-NormalizedExtensions {
    # FileInfo.Extension always carries a leading dot, but a hand-written
    # config.json may list extensions either way. Normalise both forms so a
    # missing dot does not silently skip every file.
    param($Extensions)
    return @($Extensions | Where-Object { $_ } | ForEach-Object {
        $e = ([string]$_).Trim().ToLowerInvariant()
        if ($e.StartsWith('.')) { $e } else { ".$e" }
    })
}

function Resolve-StateFilePath {
    param([string]$Explicit, [string]$ConfigPath)
    if ($Explicit) { return $Explicit }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.ingestStateFile) { return $cfg.ingestStateFile }
        } catch {}
    }
    return (Join-Path $PSScriptRoot 'state\ingest-state.json')
}

function New-FileKey {
    param([string]$NotebookId, [string]$FullPath)
    return "$NotebookId::$FullPath"
}

# Returns $true if the file should be (re)uploaded: unseen, or size/mtime changed.
function Test-NeedsUpload {
    param($State, [string]$Key, [System.IO.FileInfo]$File)
    $existing = Get-StateValue -State $State -Key $Key
    if (-not $existing) { return $true }
    $sameSize = ($existing.size -eq $File.Length)
    $sameMtime = ($existing.mtime -eq $File.LastWriteTimeUtc.ToString('o'))
    return -not ($sameSize -and $sameMtime)
}

function Set-Uploaded {
    param($State, [string]$Key, [System.IO.FileInfo]$File)
    Set-StateValue -State $State -Key $Key -Value ([PSCustomObject]@{
        size        = $File.Length
        mtime       = $File.LastWriteTimeUtc.ToString('o')
        processedAt = (Get-Date).ToUniversalTime().ToString('o')
    })
}

# Adds one source to a notebook. Returns $true on success.
function Add-OneSource {
    param([string]$NotebookId, [string]$SourcePath, [string]$Type)
    $addArgs = @('source', 'add', $SourcePath, '-n', $NotebookId, '--type', $Type, '--json')
    $result = Invoke-NotebookLM -Arguments $addArgs
    return $result
}

function Invoke-ManualIngest {
    param([string]$Path, [string]$NotebookId, [string[]]$Extensions, $State, [string]$StateFile)

    $success = 0; $skip = 0; $fail = 0
    $failDetails = New-Object System.Collections.Generic.List[string]

    if ($Path -match '^(?i)https?://') {
        $result = Add-OneSource -NotebookId $NotebookId -SourcePath $Path -Type 'url'
        if ($result.ExitCode -eq 0) {
            Write-NbInfo "Added URL: $Path"
            $success++
        } else {
            Write-NbError "Failed to add URL $Path : $((Get-NbFailureText $result))"
            $fail++
            $failDetails.Add("$Path : $((Get-NbFailureText $result))")
        }
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        $file = Get-Item -LiteralPath $Path
        $key = New-FileKey -NotebookId $NotebookId -FullPath $file.FullName
        if (-not (Test-NeedsUpload -State $State -Key $key -File $file)) {
            Write-NbInfo "Skipped (already processed, unchanged): $($file.FullName)"
            $skip++
        } else {
            $result = Add-OneSource -NotebookId $NotebookId -SourcePath $file.FullName -Type 'file'
            if ($result.ExitCode -eq 0) {
                Write-NbInfo "Added: $($file.FullName)"
                Set-Uploaded -State $State -Key $key -File $file
                Save-JsonState -State $State -Path $StateFile
                $success++
            } else {
                Write-NbError "Failed to add $($file.FullName): $((Get-NbFailureText $result))"
                $fail++
                $failDetails.Add("$($file.FullName): $((Get-NbFailureText $result))")
            }
        }
    }
    elseif (Test-Path -LiteralPath $Path -PathType Container) {
        $wl = if ($Extensions) { $Extensions } else { $script:DefaultExtensions }
        $wl = ConvertTo-NormalizedExtensions -Extensions $wl
        $allFiles = Get-ChildItem -LiteralPath $Path -Recurse -File
        foreach ($file in $allFiles) {
            if ($wl -notcontains $file.Extension.ToLowerInvariant()) {
                Write-NbInfo "Skipped (extension not in whitelist): $($file.FullName)"
                $skip++
                continue
            }
            $key = New-FileKey -NotebookId $NotebookId -FullPath $file.FullName
            if (-not (Test-NeedsUpload -State $State -Key $key -File $file)) {
                Write-NbInfo "Skipped (already processed, unchanged): $($file.FullName)"
                $skip++
                continue
            }
            $result = Add-OneSource -NotebookId $NotebookId -SourcePath $file.FullName -Type 'file'
            if ($result.ExitCode -eq 0) {
                Write-NbInfo "Added: $($file.FullName)"
                Set-Uploaded -State $State -Key $key -File $file
                Save-JsonState -State $State -Path $StateFile
                $success++
            } else {
                Write-NbError "Failed to add $($file.FullName): $((Get-NbFailureText $result))"
                $fail++
                $failDetails.Add("$($file.FullName): $((Get-NbFailureText $result))")
            }
        }
    }
    else {
        Write-NbError "Path does not exist: $Path"
        exit 1
    }

    return [PSCustomObject]@{ Success = $success; Skip = $skip; Fail = $fail; FailDetails = $failDetails }
}

function Invoke-WatchTask {
    param($Task, $State, [string]$StateFile)

    $success = 0; $skip = 0; $fail = 0
    $failDetails = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $Task.folder)) {
        Write-NbError "Task '$($Task.name)': folder does not exist: $($Task.folder)"
        return [PSCustomObject]@{ Success = 0; Skip = 0; Fail = 1; FailDetails = @("folder not found: $($Task.folder)") }
    }

    if ($Task.mode -eq 'new') {
        $title = "$($Task.name)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $createResult = Invoke-NotebookLM -Arguments @('create', $title, '--json')
        if ($createResult.ExitCode -ne 0) {
            Write-NbError "Task '$($Task.name)': failed to create new notebook: $((Get-NbFailureText $createResult))"
            return [PSCustomObject]@{ Success = 0; Skip = 0; Fail = 1; FailDetails = @("create notebook failed: $((Get-NbFailureText $createResult))") }
        }
        try {
            $created = $createResult.StdOut | ConvertFrom-Json
            $notebookId = $created.id
        } catch {
            Write-NbError "Task '$($Task.name)': could not parse created-notebook JSON: $($_.Exception.Message)"
            return [PSCustomObject]@{ Success = 0; Skip = 0; Fail = 1; FailDetails = @("create notebook parse failed") }
        }
        Write-NbInfo "Task '$($Task.name)': created new notebook '$title' -> $notebookId"
        Write-Host $notebookId
    }
    elseif ($Task.mode -eq 'existing') {
        $notebookId = $Task.notebookId
        if (-not $notebookId) {
            Write-NbError "Task '$($Task.name)': mode is 'existing' but no notebookId set in config"
            return [PSCustomObject]@{ Success = 0; Skip = 0; Fail = 1; FailDetails = @("missing notebookId") }
        }
    }
    else {
        Write-NbError "Task '$($Task.name)': unknown mode '$($Task.mode)' (expected 'existing' or 'new')"
        return [PSCustomObject]@{ Success = 0; Skip = 0; Fail = 1; FailDetails = @("unknown mode") }
    }

    $wl = if ($Task.extensions) { $Task.extensions } else { $script:DefaultExtensions }
    $wl = ConvertTo-NormalizedExtensions -Extensions $wl
    $allFiles = Get-ChildItem -LiteralPath $Task.folder -Recurse -File

    if (-not $allFiles -or $allFiles.Count -eq 0) {
        Write-NbInfo "Task '$($Task.name)': no files in folder."
    }

    $matched = $allFiles | Where-Object { $wl -contains $_.Extension.ToLowerInvariant() }
    if (-not $matched -or $matched.Count -eq 0) {
        Write-NbInfo "No new files."
    }

    foreach ($file in $matched) {
        $key = New-FileKey -NotebookId $notebookId -FullPath $file.FullName
        if (-not (Test-NeedsUpload -State $State -Key $key -File $file)) {
            $skip++
            continue
        }
        $result = Add-OneSource -NotebookId $notebookId -SourcePath $file.FullName -Type 'file'
        if ($result.ExitCode -eq 0) {
            Write-NbInfo "Added: $($file.FullName)"
            Set-Uploaded -State $State -Key $key -File $file
            Save-JsonState -State $State -Path $StateFile
            $success++
        } else {
            Write-NbError "Failed to add $($file.FullName): $((Get-NbFailureText $result))"
            $fail++
            $failDetails.Add("$($file.FullName): $((Get-NbFailureText $result))")
        }
    }

    if ($success -eq 0 -and $skip -gt 0 -and $fail -eq 0) {
        Write-NbInfo "Task '$($Task.name)': no new files."
    }

    return [PSCustomObject]@{ Success = $success; Skip = $skip; Fail = $fail; FailDetails = $failDetails }
}

# --- main ---------------------------------------------------------------
$StateFile = Resolve-StateFilePath -Explicit $StateFile -ConfigPath $ConfigPath
$state = Get-JsonState -Path $StateFile

$totalSuccess = 0; $totalSkip = 0; $totalFail = 0
$allFailDetails = New-Object System.Collections.Generic.List[string]

if ($Watch) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-NbError "Config file not found: $ConfigPath"
        exit 1
    }
    # Parse explicitly: without this, a malformed config.json leaves $cfg
    # null and the script blames "no watchTasks", which sends the user
    # looking in entirely the wrong place. Backslashes in Windows paths must
    # be doubled in JSON, so this is an easy mistake to make by hand.
    $cfg = $null
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-NbError "Config file is not valid JSON: $ConfigPath"
        Write-NbError "  $($_.Exception.Message)"
        Write-NbError "  Hint: Windows paths need doubled backslashes, e.g. C:\GitSource\docs"
        exit 1
    }
    if (-not $cfg.watchTasks -or $cfg.watchTasks.Count -eq 0) {
        Write-NbError "No watchTasks defined in $ConfigPath"
        exit 1
    }
    # A -TaskName that matches nothing must fail loudly. Without this the
    # loop simply skips every task and the script exits 0 with all-zero
    # counters, which a scheduler would read as a successful run.
    if ($TaskName) {
        $matched = @($cfg.watchTasks | Where-Object { $_.name -eq $TaskName })
        if ($matched.Count -eq 0) {
            Write-NbError "Watch task '$TaskName' not found in $ConfigPath"
            exit 1
        }
    }
    foreach ($task in $cfg.watchTasks) {
        if ($TaskName -and $task.name -ne $TaskName) { continue }
        Write-NbInfo "Running watch task: $($task.name)"
        $r = Invoke-WatchTask -Task $task -State $state -StateFile $StateFile
        $totalSuccess += $r.Success; $totalSkip += $r.Skip; $totalFail += $r.Fail
        foreach ($d in $r.FailDetails) { $allFailDetails.Add($d) }
    }
}
elseif ($Path) {
    if (-not $Notebook) {
        Write-NbError "-Notebook is required with -Path"
        exit 1
    }
    $r = Invoke-ManualIngest -Path $Path -NotebookId $Notebook -Extensions $Extensions -State $state -StateFile $StateFile
    $totalSuccess += $r.Success; $totalSkip += $r.Skip; $totalFail += $r.Fail
    foreach ($d in $r.FailDetails) { $allFailDetails.Add($d) }
}
else {
    Write-NbError "Specify either -Path <file|folder|url> -Notebook <id>, or -Watch"
    exit 1
}

Save-JsonState -State $state -Path $StateFile

Write-Host ""
Write-Host "Result: success $totalSuccess / skip $totalSkip / fail $totalFail"
if ($allFailDetails.Count -gt 0) {
    Write-Host "Failures:"
    foreach ($d in $allFailDetails) { Write-Host "  - $d" }
}

if ($totalFail -gt 0) { exit 1 } else { exit 0 }
