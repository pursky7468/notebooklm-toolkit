# _common.ps1
# Shared setup and helpers for the notebooklm-toolkit scripts.
# NOTE: comments in this file must stay ASCII-only (a PreToolUse hook
# rejects non-ASCII characters in .ps1 comment lines). String literals
# shown to the user (e.g. Write-Host text) are not restricted.

# --- UTF-8 encoding setup ---------------------------------------------------
# A cp950 decode error was observed during login. Force UTF-8 everywhere so
# console I/O and the child Python process agree on encoding.
# Use a no-BOM UTF8Encoding instance, not the [System.Text.Encoding]::UTF8
# singleton. The singleton's GetPreamble() returns a 3-byte BOM, and .NET
# Framework's Process.StandardInput StreamWriter is built from Console.InputEncoding.
# Accessing that StreamWriter's .BaseStream (which Invoke-NotebookLM does below,
# to write raw stdin bytes for '--prompt-file -') forces a Flush() that emits the
# pending preamble first, silently gluing a BOM character onto the front of every
# stdin payload. Confirmed by direct test in this environment: with the
# BOM-emitting singleton, the child process reads the payload with a stray
# leading marker character it should not have.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8NoBom
try { [Console]::OutputEncoding = $utf8NoBom } catch {}
try { [Console]::InputEncoding = $utf8NoBom } catch {}
$env:PYTHONIOENCODING = 'utf-8'

# --- notebooklm.exe path resolution -----------------------------------------
function Get-NotebookLMExe {
    if ($env:NOTEBOOKLM_EXE -and (Test-Path -LiteralPath $env:NOTEBOOKLM_EXE)) {
        return (Resolve-Path -LiteralPath $env:NOTEBOOKLM_EXE).Path
    }
    $default = Join-Path $env:USERPROFILE '.local\bin\notebooklm.exe'
    if (Test-Path -LiteralPath $default) {
        return (Resolve-Path -LiteralPath $default).Path
    }
    $cmd = Get-Command notebooklm.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw "notebooklm.exe not found. Set NOTEBOOKLM_EXE or check 'uv tool list'."
}

$script:NotebookLMExe = Get-NotebookLMExe

# --- console helpers ---------------------------------------------------------
function Write-NbInfo {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-NbWarn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-NbError {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# notebooklm's --json mode puts structured error detail on STDOUT (e.g.
# {"error": true, "code": "...", "message": "..."}), not STDERR, so error
# reporting must not rely on StdErr alone -- it is often empty even on
# failure. This picks whichever stream actually has content.
function Get-NbFailureText {
    param($Result)
    if (-not [string]::IsNullOrWhiteSpace($Result.StdErr)) { return $Result.StdErr }
    if (-not [string]::IsNullOrWhiteSpace($Result.StdOut)) { return $Result.StdOut }
    return "(no error output from notebooklm)"
}

# --- Win32 command-line argument quoting --------------------------------------
# .NET Framework 4.x (the CLR backing Windows PowerShell 5.1) has no
# ProcessStartInfo.ArgumentList -- that API only exists on .NET Core/5+.
# ProcessStartInfo.Arguments is a single pre-quoted string, so we must quote
# each argument ourselves. This reproduces the exact algorithm CommandLineToArgvW
# expects (same one .NET's own ArgumentList uses internally), so quotes,
# backslashes, and spaces round-trip correctly. Embedded newlines need no
# special handling: inside a quoted argument they are just literal characters.
function ConvertTo-Win32Argument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $len = $Value.Length
    for ($i = 0; $i -lt $len; $i++) {
        $backslashes = 0
        while ($i -lt $len -and $Value[$i] -eq '\') { $backslashes++; $i++ }

        if ($i -eq $len) {
            [void]$sb.Append([string]'\' * ($backslashes * 2))
            break
        }
        elseif ($Value[$i] -eq '"') {
            [void]$sb.Append([string]'\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
        }
        else {
            [void]$sb.Append([string]'\' * $backslashes)
            [void]$sb.Append($Value[$i])
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# --- safe native-exe invocation ----------------------------------------------
# Two PowerShell 5.1 pitfalls this guards against:
#   (a) empty-string arguments are silently dropped when calling a native exe
#       via the normal '&' call operator, which desyncs positional args after it.
#   (b) splatting a plain string[] array with '&' can lose or misjoin elements
#       that contain quotes/spaces because PowerShell re-parses the joined
#       command line. Building the ProcessStartInfo.Arguments string ourselves
#       via ConvertTo-Win32Argument avoids that re-parsing step entirely.
# It also writes stdin as raw UTF-8 bytes directly to the underlying stream,
# bypassing .NET Framework's default StreamWriter encoding for redirected
# stdin (which is not UTF-8 and is the other half of the cp950 problem).
function Invoke-NotebookLM {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [string]$StdinInput = $null
    )

    foreach ($a in $Arguments) {
        if ([string]::IsNullOrEmpty($a)) {
            throw ("Invoke-NotebookLM: refusing an empty-string argument. " +
                   "Omit the argument instead of passing ''. " +
                   "Arguments so far: [$($Arguments -join ' | ')]")
        }
    }

    $quoted = $Arguments | ForEach-Object { ConvertTo-Win32Argument $_ }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:NotebookLMExe
    $psi.Arguments = [string]::Join(' ', $quoted)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    if ($null -ne $StdinInput) { $psi.RedirectStandardInput = $true }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    [void]$proc.Start()

    # Start both async reads immediately, before touching stdin, so the
    # child's stdout/stderr pipe buffers never fill up and deadlock us while
    # we write. ReadToEndAsync reads each stream sequentially on its own
    # background task, so (unlike the OutputDataReceived event pattern this
    # replaced) line order within each stream is preserved exactly -- that
    # event-based version was observed to scramble line order under load in
    # this environment, corrupting JSON output.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if ($null -ne $StdinInput) {
        # If the child exits immediately (bad args, missing runtime) the pipe
        # is already closed and Write/Flush throws. Swallowing that lets the
        # real stdout/stderr below surface instead of a bare IOException.
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $bytes = $utf8NoBom.GetBytes($StdinInput)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
            $proc.StandardInput.Close()
        } catch [System.IO.IOException] {
        } catch [System.ObjectDisposedException] {
        }
    }

    $proc.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    [PSCustomObject]@{
        StdOut   = $stdout.TrimEnd("`r", "`n")
        StdErr   = $stderr.TrimEnd("`r", "`n")
        ExitCode = $proc.ExitCode
    }
}

# --- JSON state-file helpers (used by nb-ingest) ------------------------------
function Get-JsonState {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return [PSCustomObject]@{} }
        return $raw | ConvertFrom-Json
    }
    return [PSCustomObject]@{}
}

function Save-JsonState {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # PS 5.1's -Encoding UTF8 always emits a BOM; write without one so other
    # tools reading this JSON do not have to strip it.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($State | ConvertTo-Json -Depth 10), $utf8NoBom)
}

function Get-StateValue {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Key)
    $prop = $State.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

function Set-StateValue {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Key, $Value)
    if ($State.PSObject.Properties[$Key]) {
        $State.PSObject.Properties[$Key].Value = $Value
    } else {
        $State | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    }
}
