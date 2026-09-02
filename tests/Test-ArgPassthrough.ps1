# Test-ArgPassthrough.ps1
# Task 1.5 verification: confirm Invoke-NotebookLM (in _common.ps1) carries
# quotes, embedded newlines, and CJK text through argv and stdin without
# truncation or corruption in PowerShell 5.1.
#
# notebooklm.exe itself cannot be used as the target process for this test
# right now: the local credential file has a broken ACL (see VERIFY.md /
# final report) that makes every notebooklm.exe invocation fail identically
# before it ever parses arguments, so it would prove nothing either way.
# Instead this points Invoke-NotebookLM's exe at a small Python echo script
# that prints back exactly what it received on argv and stdin -- this
# exercises the same ProcessStartInfo.ArgumentList + raw-UTF8-stdin code
# path that ships in _common.ps1, independent of notebooklm.exe.

. (Join-Path $PSScriptRoot '..\_common.ps1')

# Resolve python from PATH rather than hardcoding one machine's install path,
# so this test runs for anyone who clones the repo.
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pythonCmd) { $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not $pythonCmd) { throw "python not found on PATH; this test needs it to run the echo script." }
$pythonExe = $pythonCmd.Source
$echoScript = $args[0]
if (-not $echoScript) {
    throw "Usage: Test-ArgPassthrough.ps1 <path-to-echo_argv_stdin.py>"
}

# Redirect the shared invoker at "python echo_argv_stdin.py <rest of args>"
# by wrapping: FileName = python.exe, first ArgumentList entry = script path.
function Invoke-Python {
    param([string[]]$ExtraArgs, [string]$StdinInput)
    $realExe = $script:NotebookLMExe
    try {
        $script:NotebookLMExe = $pythonExe
        $allArgs = @($echoScript) + $ExtraArgs
        return Invoke-NotebookLM -Arguments $allArgs -StdinInput $StdinInput
    } finally {
        $script:NotebookLMExe = $realExe
    }
}

$fail = 0

# Non-ASCII characters are built from numeric code points rather than typed
# as literals: PowerShell 5.1 reads a .ps1 file with no BOM using the system
# codepage, not UTF-8. This file has no BOM, so a literal CJK/emoji character
# here would already be mangled before the test even runs. (This is itself a
# finding: any future edit that adds literal non-ASCII text to a .ps1 file in
# this toolkit must save the file with a UTF-8 BOM, or use this same
# code-point construction, or it will silently corrupt at parse time.)
$cjk = [string]([char]0x4E2D) + ([char]0x6587) + ([char]0x5B57)      # "chinese characters"
$emoji = [string]([char]0xD83C) + ([char]0xDF89)                     # U+1F389 party emoji (surrogate pair)

# Case 1: argv with embedded double quotes, single quotes, and CJK text.
$argvCase = "he said ""hello"" and it's a test with $cjk and emoji $emoji"
$r1 = Invoke-Python -ExtraArgs @($argvCase) -StdinInput $null
Write-Host "--- Case 1: argv passthrough ---"
Write-Host $r1.StdOut
# Python's repr() re-escapes quote characters (choice of ' vs " delimiter,
# backslash-escaping), so compare content pieces rather than the raw literal.
if ($r1.StdOut -notmatch 'hello' -or
    $r1.StdOut -notmatch [regex]::Escape($cjk) -or
    $r1.StdOut -notmatch [regex]::Escape($emoji) -or
    $r1.StdOut -notmatch 'a test with') {
    Write-NbError "Case 1 FAILED: argv value not found intact in echoed output"
    $fail++
} else {
    Write-NbInfo "Case 1 PASSED"
}

# Case 2: stdin with embedded newlines, quotes, and CJK text (the actual
# nb-digest question-passing path, design D3).
$stdinCase = "Question with `"quotes`" and 'apostrophes'`nsecond line $cjk`nthird line"
$r2 = Invoke-Python -ExtraArgs @('--stdin-mode') -StdinInput $stdinCase
Write-Host "--- Case 2: stdin passthrough ---"
Write-Host $r2.StdOut
$expectedRepr = $stdinCase
if ($r2.StdOut -notmatch [regex]::Escape("second line $cjk") -or $r2.StdOut -notmatch 'third line' -or $r2.StdOut -notmatch [regex]::Escape('quotes')) {
    Write-NbError "Case 2 FAILED: stdin value not found intact (newlines/quotes/CJK)"
    $fail++
} else {
    Write-NbInfo "Case 2 PASSED"
}

# Case 3: empty-string argument must be rejected, not silently dropped.
Write-Host "--- Case 3: empty-string argument guard ---"
try {
    Invoke-Python -ExtraArgs @('ok', '') -StdinInput $null | Out-Null
    Write-NbError "Case 3 FAILED: empty-string argument was not rejected"
    $fail++
} catch {
    Write-NbInfo "Case 3 PASSED (rejected as expected: $($_.Exception.Message))"
}

if ($fail -eq 0) {
    Write-NbInfo "All passthrough checks passed."
    exit 0
} else {
    Write-NbError "$fail check(s) failed."
    exit 1
}
