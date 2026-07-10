<#
.SYNOPSIS
    Self-contained end-to-end test suite for bundle.ps1 / unbundle.ps1.

.DESCRIPTION
    No external dependencies (no Pester). Each test runs the real scripts in a separate
    powershell.exe process - exactly like a user - against isolated temp fixtures, then
    asserts on the produced files, exit codes, and console output.

    Run:   powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
    Exit code = number of failed tests (0 = all passed).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Repo   = Split-Path $PSScriptRoot -Parent
$Bundle = Join-Path $Repo 'bundle.ps1'
$Unbund = Join-Path $Repo 'unbundle.ps1'
$Root   = Join-Path ([System.IO.Path]::GetTempPath()) 'cbm-e2e'
$HasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

# ---- tiny test framework ----------------------------------------------------
$script:total = 0; $script:passed = 0; $script:failed = 0; $script:skipped = 0
$script:failures = New-Object System.Collections.Generic.List[string]
$script:wsCounter = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:total++
    try {
        & $Body
        $script:passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        $script:failures.Add("$Name :: $($_.Exception.Message)")
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}

function Skip-Case([string]$Name, [string]$Why) {
    $script:total++; $script:skipped++
    Write-Host "  SKIP  $Name ($Why)" -ForegroundColor DarkYellow
}

function Assert-True([bool]$Cond, [string]$Msg = 'expected true') { if (-not $Cond) { throw $Msg } }
function Assert-Eq($Expected, $Actual, [string]$Msg = '') { if ($Expected -ne $Actual) { throw "Expected [$Expected] but got [$Actual]. $Msg" } }
function Assert-Match([string]$Text, [string]$Pat, [string]$Msg = '') { if ($Text -notmatch $Pat) { throw "Pattern [$Pat] not found. $Msg" } }
function Assert-NoMatch([string]$Text, [string]$Pat, [string]$Msg = '') { if ($Text -match $Pat) { throw "Pattern [$Pat] unexpectedly present. $Msg" } }
function Assert-FileExists([string]$P) { if (-not (Test-Path -LiteralPath $P)) { throw "Expected file to exist: $P" } }
function Assert-FileMissing([string]$P) { if (Test-Path -LiteralPath $P) { throw "Expected file NOT to exist: $P" } }
function Assert-SameContent([string]$A, [string]$B) {
    $x = @(Get-Content -LiteralPath $A -Encoding UTF8)
    $y = @(Get-Content -LiteralPath $B -Encoding UTF8)
    if (($x -join "`n") -ne ($y -join "`n")) { throw "Content differs: $A vs $B" }
}

# ---- helpers ----------------------------------------------------------------
function New-Ws {
    $script:wsCounter++
    $p = Join-Path $Root ("ws{0:000}" -f $script:wsCounter)
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

function New-Sample([string]$Dir) {
    New-Item -ItemType Directory -Force -Path "$Dir\src\pkg" | Out-Null
    Set-Content "$Dir\src\app.py"        "# module app`nimport pkg.util`nprint(pkg.util.hello())" -Encoding UTF8
    Set-Content "$Dir\src\pkg\util.py"   "def hello():`n    return 'hi'" -Encoding UTF8
    Set-Content "$Dir\README.md"         "# Sample`nHello" -Encoding UTF8
    New-Item -ItemType Directory -Force -Path "$Dir\__pycache__" | Out-Null
    Set-Content "$Dir\__pycache__\junk.txt" "excluded" -Encoding UTF8
    New-Item -ItemType Directory -Force -Path "$Dir\node_modules\x" | Out-Null
    Set-Content "$Dir\node_modules\x\index.js" "module.exports=1" -Encoding UTF8
    [System.IO.File]::WriteAllBytes("$Dir\logo.png", ([byte[]](137, 80, 78, 71, 0, 13, 10, 26, 10)))
}

# Run a script in a REAL separate process; returns {Output, Code}.
function Invoke-Script([string]$Script, [string[]]$ScriptArgs) {
    # A child's stderr merged via 2>&1 wraps as a NativeCommandError; under EAP=Stop that
    # would terminate this runner. Keep it non-terminating so we can inspect the exit code.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @ScriptArgs 2>&1 | Out-String
    return [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
}
function Invoke-Bundle([string[]]$A) { return (Invoke-Script $Bundle $A) }
function Invoke-Unbundle([string[]]$A) { return (Invoke-Script $Unbund $A) }

# ---- setup ------------------------------------------------------------------
Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Root | Out-Null
Write-Host "E2E tests for copilotbundlemaker" -ForegroundColor Cyan
Write-Host "Repo: $Repo" -ForegroundColor DarkGray
Write-Host "Temp: $Root  (git: $HasGit)" -ForegroundColor DarkGray
Write-Host ''

# =============================================================================
# BUNDLE
# =============================================================================
Write-Host 'bundle.ps1' -ForegroundColor White

Test-Case 'bundle: includes text files, excludes junk dirs & binaries' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"
    $r = Invoke-Bundle @($src, '-Output', $b)
    Assert-Eq 0 $r.Code 'exit code'
    Assert-FileExists $b
    $t = Get-Content $b -Raw -Encoding UTF8
    Assert-Match $t 'FILE: src/app.py'          'app.py included'
    Assert-Match $t 'FILE: src/pkg/util.py'     'nested file included'
    Assert-Match $t 'FILE: README.md'           'readme included'
    Assert-NoMatch $t '__pycache__'             'pycache excluded'
    Assert-NoMatch $t 'node_modules'            'node_modules excluded'
    Assert-NoMatch $t 'logo.png'                'png excluded'
    Assert-Match $t '# 3 files, generated from' 'manifest count = 3'
}

Test-Case 'bundle: header + markers present, forward-slash paths' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; Invoke-Bundle @($src, '-Output', $b) | Out-Null
    $t = Get-Content $b -Raw -Encoding UTF8
    Assert-Match $t '##### COPILOT-BUNDLE v1 #####'
    Assert-Match $t '##### BEGIN MANIFEST #####'
    Assert-Match $t '<<<<< END FILE: src/pkg/util.py >>>>>'
    Assert-NoMatch $t 'FILE: src\\pkg'  'no backslashes in paths'
}

Test-Case 'bundle: -IncludeExt whitelist keeps only listed extensions' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"
    Invoke-Bundle @($src, '-Output', $b, '-IncludeExt', '.py') | Out-Null
    $t = Get-Content $b -Raw -Encoding UTF8
    Assert-Match  $t 'FILE: src/app.py'
    Assert-NoMatch $t 'README.md'  'md excluded by whitelist'
}

Test-Case 'bundle: -MaxSizeKB skips oversized files' {
    $ws = New-Ws; $src = "$ws\proj"; New-Item -ItemType Directory -Force -Path $src | Out-Null
    Set-Content "$src\small.py" "print(1)" -Encoding UTF8
    Set-Content "$src\big.py" ('x' * 4096) -Encoding UTF8
    $b = "$ws\out.txt"
    Invoke-Bundle @($src, '-Output', $b, '-MaxSizeKB', '1') | Out-Null
    $t = Get-Content $b -Raw -Encoding UTF8
    Assert-Match  $t 'FILE: small.py'
    Assert-NoMatch $t 'FILE: big.py'  'big file skipped'
}

Test-Case 'bundle: skips text-extension file with null-byte content' {
    $ws = New-Ws; $src = "$ws\proj"; New-Item -ItemType Directory -Force -Path $src | Out-Null
    Set-Content "$src\ok.txt" "clean text" -Encoding UTF8
    [System.IO.File]::WriteAllBytes("$src\fake.txt", ([byte[]](104, 105, 0, 116, 104, 101, 114, 101)))
    $b = "$ws\out.txt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    $t = Get-Content $b -Raw -Encoding UTF8
    Assert-Match  $t 'FILE: ok.txt'
    Assert-NoMatch $t 'FILE: fake.txt'  'null-byte file skipped'
}

Test-Case 'bundle: -ExtraExclude removes a folder' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"
    Invoke-Bundle @($src, '-Output', $b, '-ExtraExclude', 'pkg') | Out-Null
    $t = Get-Content $b -Raw -Encoding UTF8
    Assert-Match  $t 'FILE: src/app.py'
    Assert-NoMatch $t 'util.py'  'pkg folder excluded'
}

Test-Case 'bundle: default name is timestamped under -OutDir' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $od = "$ws\bundles"
    $r = Invoke-Bundle @($src, '-OutDir', $od)
    Assert-Eq 0 $r.Code
    $made = Get-ChildItem "$od\bundle-*.txt" -ErrorAction SilentlyContinue
    Assert-True ($made.Count -ge 1) 'timestamped bundle created'
    Assert-Match $made[0].Name '^bundle-\d{8}-\d{6}\.txt$' 'timestamp format'
}

Test-Case 'bundle: -Task is injected into the prompt' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; $p = "$ws\prompt.txt"
    Invoke-Bundle @($src, '-Output', $b, '-Task', 'refactor the parser', '-PromptOut', $p) | Out-Null
    Assert-FileExists $p
    $pr = Get-Content $p -Raw -Encoding UTF8
    Assert-Match $pr 'refactor the parser'
    Assert-Match $pr 'Return the FULL updated project'
}

Test-Case 'bundle: no -Task yields placeholder in prompt' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; $p = "$ws\prompt.txt"
    Invoke-Bundle @($src, '-Output', $b, '-PromptOut', $p) | Out-Null
    Assert-Match (Get-Content $p -Raw -Encoding UTF8) 'DESCRIBE YOUR REQUEST HERE'
}

Test-Case 'bundle: -EmitPromptOnly writes prompt, no bundle' {
    $ws = New-Ws; $p = "$ws\prompt.txt"; $b = "$ws\should-not-exist.txt"
    $r = Invoke-Bundle @('-EmitPromptOnly', '-Task', 'do X', '-PromptOut', $p, '-Output', $b)
    Assert-Eq 0 $r.Code
    Assert-FileExists $p
    Assert-FileMissing $b  'no bundle produced in emit-prompt-only mode'
}

# =============================================================================
# UNBUNDLE + ROUND-TRIP
# =============================================================================
Write-Host ''
Write-Host 'unbundle.ps1 / round-trip' -ForegroundColor White

Test-Case 'round-trip: files & tree reproduced with identical content' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; $dst = "$ws\rebuilt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    $r = Invoke-Unbundle @($b, $dst)
    Assert-Eq 0 $r.Code
    Assert-SameContent "$src\src\app.py"      "$dst\src\app.py"
    Assert-SameContent "$src\src\pkg\util.py" "$dst\src\pkg\util.py"
    Assert-SameContent "$src\README.md"       "$dst\README.md"
    Assert-FileMissing "$dst\logo.png"        # binary was never bundled
}

Test-Case 'round-trip: non-ASCII (accents) preserved' {
    $ws = New-Ws; $src = "$ws\proj"; New-Item -ItemType Directory -Force -Path $src | Out-Null
    # Build the accented literal from code points so this test file stays pure ASCII
    # (Windows PowerShell 5.1 mis-decodes non-ASCII in a BOM-less .ps1).
    $accents = "s = '" + [char]0xE9 + [char]0xE0 + [char]0xFC + [char]0xE7 + [char]0xF1 + ' ' + [char]0x2013 + ' ' + [char]0x2713 + "'"
    Set-Content "$src\accents.py" $accents -Encoding UTF8
    $b = "$ws\out.txt"; $dst = "$ws\rebuilt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    Invoke-Unbundle @($b, $dst) | Out-Null
    Assert-SameContent "$src\accents.py" "$dst\accents.py"
}

Test-Case 'unbundle: -Preview writes nothing' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; $dst = "$ws\rebuilt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    $r = Invoke-Unbundle @($b, $dst, '-Preview')
    Assert-Eq 0 $r.Code
    Assert-FileMissing "$dst\src\app.py"  'preview must not write'
    Assert-Match $r.Output 'Would apply'
}

Test-Case 'unbundle: -ShowDiff prints a diff and exits 0' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; $dst = "$ws\rebuilt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    $r = Invoke-Unbundle @($b, $dst, '-Preview', '-ShowDiff')
    Assert-Eq 0 $r.Code
    Assert-Match $r.Output '--- diff:'
}

Test-Case 'unbundle: status = created / modified / unchanged' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; $dst = "$ws\rebuilt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    $r1 = Invoke-Unbundle @($b, $dst)
    Assert-Match $r1.Output 'Applied: 3 created, 0 modified, 0 unchanged'
    # re-apply same bundle -> all unchanged
    $r2 = Invoke-Unbundle @($b, $dst)
    Assert-Match $r2.Output 'Applied: 0 created, 0 modified, 3 unchanged'
    # change one file in the bundle -> exactly 1 modified
    $mod = (Get-Content $b -Raw -Encoding UTF8) -replace "return 'hi'", "return 'yo'"
    $b2 = "$ws\out2.txt"; Set-Content $b2 $mod -Encoding UTF8
    $r3 = Invoke-Unbundle @($b2, $dst)
    Assert-Match $r3.Output 'Applied: 0 created, 1 modified, 2 unchanged'
    Assert-Match (Get-Content "$dst\src\pkg\util.py" -Raw -Encoding UTF8) "return 'yo'"
}

Test-Case 'unbundle: tolerant parser rebuilds even with END markers removed' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; $dst = "$ws\rebuilt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    $stripped = (Get-Content $b -Raw -Encoding UTF8) -replace '(?m)^<<<<< END FILE:.*$', ''
    $b2 = "$ws\stripped.txt"; Set-Content $b2 $stripped -Encoding UTF8
    $r = Invoke-Unbundle @($b2, $dst)
    Assert-Eq 0 $r.Code
    Assert-SameContent "$src\src\app.py"      "$dst\src\app.py"
    Assert-SameContent "$src\src\pkg\util.py" "$dst\src\pkg\util.py"
}

Test-Case 'unbundle: new-file block creates a new file' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"; $dst = "$ws\rebuilt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    Add-Content $b "`n<<<<< FILE: src/new_mod.py >>>>>`ndef added():`n    return 42`n<<<<< END FILE: src/new_mod.py >>>>>`n" -Encoding UTF8
    Invoke-Unbundle @($b, $dst) | Out-Null
    Assert-FileExists "$dst\src\new_mod.py"
    Assert-Match (Get-Content "$dst\src\new_mod.py" -Raw -Encoding UTF8) 'return 42'
}

Test-Case 'security: path traversal & absolute paths are rejected' {
    $ws = New-Ws; $dst = "$ws\rebuilt"
    $b = "$ws\evil.txt"
    $lines = @(
        '<<<<< FILE: ../evil1.py >>>>>', 'print(1)', '<<<<< END FILE: ../evil1.py >>>>>',
        '<<<<< FILE: sub/../../evil2.py >>>>>', 'print(2)', '<<<<< END FILE: sub/../../evil2.py >>>>>',
        '<<<<< FILE: C:/evil3.py >>>>>', 'print(3)', '<<<<< END FILE: C:/evil3.py >>>>>',
        '<<<<< FILE: /evil4.py >>>>>', 'print(4)', '<<<<< END FILE: /evil4.py >>>>>',
        '<<<<< FILE: ok.py >>>>>', 'print(0)', '<<<<< END FILE: ok.py >>>>>'
    )
    Set-Content $b $lines -Encoding UTF8
    $r = Invoke-Unbundle @($b, $dst)
    Assert-Eq 0 $r.Code
    Assert-Match $r.Output 'Applied: 1 created, 0 modified, 0 unchanged, 4 rejected'
    Assert-FileExists  "$dst\ok.py"
    Assert-FileMissing "$ws\evil1.py"
    Assert-FileMissing "$ws\evil2.py"
    Assert-FileMissing "C:\evil3.py"
}

Test-Case 'unbundle: invalid bundle (no blocks) errors with non-zero exit' {
    $ws = New-Ws; $b = "$ws\garbage.txt"; $dst = "$ws\rebuilt"
    Set-Content $b "just some prose, no markers here" -Encoding UTF8
    $r = Invoke-Unbundle @($b, $dst)
    Assert-True ($r.Code -ne 0) 'should exit non-zero on invalid bundle'
    Assert-FileMissing "$dst\garbage.txt"
}

Test-Case 'unbundle: missing input path errors with non-zero exit' {
    $ws = New-Ws
    $r = Invoke-Unbundle @("$ws\does-not-exist.txt", "$ws\rebuilt")
    Assert-True ($r.Code -ne 0) 'should exit non-zero for missing input'
}

Test-Case 'unbundle: default target is .\unbundled when omitted' {
    $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
    $b = "$ws\out.txt"
    Invoke-Bundle @($src, '-Output', $b) | Out-Null
    # run child with working dir = $ws so .\unbundled resolves there
    $global:LASTEXITCODE = 0
    Push-Location $ws
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File $Unbund $b 2>&1 | Out-Null } finally { Pop-Location }
    Assert-FileExists "$ws\unbundled\src\app.py"
}

# ---- git integration --------------------------------------------------------
Write-Host ''
Write-Host 'git integration' -ForegroundColor White

if ($HasGit) {
    Test-Case 'git: -GitCommit commits changes into a repo target' {
        $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
        $b = "$ws\out.txt"; $proj = "$ws\gitproj"
        New-Item -ItemType Directory -Force -Path $proj | Out-Null
        & git -C $proj init -q
        & git -C $proj config user.email 't@t.com'
        & git -C $proj config user.name 'tester'
        Invoke-Bundle @($src, '-Output', $b) | Out-Null
        $r = Invoke-Unbundle @($b, $proj, '-GitCommit', '-CommitMessage', 'e2e commit')
        Assert-Eq 0 $r.Code
        $log = (& git -C $proj log --oneline) | Out-String
        Assert-Match $log 'e2e commit'
    }

    Test-Case 'git: -GitCommit on non-repo warns and still exits 0' {
        $ws = New-Ws; $src = "$ws\proj"; New-Sample $src
        $b = "$ws\out.txt"; $dst = "$ws\plain"
        Invoke-Bundle @($src, '-Output', $b) | Out-Null
        $r = Invoke-Unbundle @($b, $dst, '-GitCommit')
        Assert-Eq 0 $r.Code
        Assert-Match $r.Output 'not a git repo'
        Assert-FileExists "$dst\src\app.py"   # files still written
    }
} else {
    Skip-Case 'git: -GitCommit commits changes into a repo target' 'git not on PATH'
    Skip-Case 'git: -GitCommit on non-repo warns and still exits 0' 'git not on PATH'
}

# ---- teardown & report ------------------------------------------------------
Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
$color = if ($script:failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "Total: $($script:total)  Passed: $($script:passed)  Failed: $($script:failed)  Skipped: $($script:skipped)" -ForegroundColor $color
if ($script:failed -gt 0) {
    Write-Host ''
    Write-Host 'Failures:' -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host ('=' * 60) -ForegroundColor Cyan

exit $script:failed
