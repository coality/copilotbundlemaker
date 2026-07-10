<#
.SYNOPSIS
    Rebuild a directory tree from a Copilot-bundle .txt (the reply from Copilot).

.DESCRIPTION
    Parses the bundle markers, recreates every file under -Output. Tolerant parser:
    missing END lines do not break reconstruction. Path-traversal is blocked.
    Supports a no-write -Preview, a -ShowDiff of the changes, and an optional git commit.

.EXAMPLE
    .\unbundle.ps1 .\reply.txt .\my-project -Preview -ShowDiff
    .\unbundle.ps1 .\reply.txt .\my-project -GitCommit -CommitMessage "apply copilot changes"
    .\unbundle.ps1 .\reply.txt              # rebuilds into .\unbundled
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$Output = ".\unbundled",

    # Show what would change but write nothing.
    [Alias('DryRun')]
    [switch]$Preview,

    # Print a diff (created/modified files) before/after applying.
    [switch]$ShowDiff,

    # After writing, git add -A + git commit inside -Output (must be a git repo).
    [switch]$GitCommit,

    # Commit message (default: timestamped).
    [string]$CommitMessage,

    # Allow writing into a non-empty target folder.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$FileBeginRx = '^<<<<< FILE:\s*(.+?)\s*>>>>>\s*$'
$FileEndRx   = '^<<<<< END FILE:\s*(.+?)\s*>>>>>\s*$'

function New-Utf8NoBom { return (New-Object System.Text.UTF8Encoding($false)) }

function Test-SafeRelative([string]$Rel) {
    if ([string]::IsNullOrWhiteSpace($Rel)) { return $false }
    if ($Rel -match '^[a-zA-Z]:' -or $Rel.StartsWith('/') -or $Rel.StartsWith('\')) { return $false }
    foreach ($seg in ($Rel -split '[\\/]+')) { if ($seg -eq '..') { return $false } }
    return $true
}

function Show-Diff([string]$OldFullPath, [string[]]$NewLines, [string]$Rel) {
    Write-Host "  --- diff: $Rel ---" -ForegroundColor Magenta
    $git = Get-Command git -ErrorAction SilentlyContinue
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllLines($tmp, [string[]]$NewLines, (New-Utf8NoBom))
        $oldForDiff = if (Test-Path -LiteralPath $OldFullPath) { $OldFullPath } else { $null }
        if ($git) {
            $ref = if ($oldForDiff) { $oldForDiff } else { 'NUL' }
            # --no-index works outside a repo; exit code 1 just means "differences found"
            & git --no-pager diff --no-index --no-color --unified=1 -- "$ref" "$tmp" 2>$null | ForEach-Object {
                $line = $_
                # drop noisy header lines (temp paths, index, mode) - keep hunks and content
                if ($line -match '^(diff --git|index |new file|deleted file|--- |\+\+\+ |similarity|rename )') { return }
                if ($line -match '^@@') { Write-Host "  $line" -ForegroundColor Cyan }
                elseif ($line -match '^\+') { Write-Host "  $line" -ForegroundColor Green }
                elseif ($line -match '^-') { Write-Host "  $line" -ForegroundColor Red }
                else { Write-Host "  $line" -ForegroundColor DarkGray }
            }
            $global:LASTEXITCODE = 0   # git diff returns 1 on differences; not an error for us
        } else {
            $old = if ($oldForDiff) { @(Get-Content -LiteralPath $oldForDiff -Encoding UTF8) } else { @() }
            $cmp = Compare-Object -ReferenceObject $old -DifferenceObject $NewLines
            foreach ($c in $cmp) {
                if ($c.SideIndicator -eq '=>') { Write-Host "  + $($c.InputObject)" -ForegroundColor Green }
                else { Write-Host "  - $($c.InputObject)" -ForegroundColor Red }
            }
        }
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

# ---- read & parse -----------------------------------------------------------
if (-not (Test-Path -LiteralPath $InputPath)) { throw "Bundle not found: $InputPath" }
$lines = @(Get-Content -LiteralPath $InputPath -Encoding UTF8)

$files = New-Object System.Collections.Generic.List[object]
$current = $null
$buffer = New-Object System.Collections.Generic.List[string]

function Close-Current([bool]$Trim) {
    if ($null -ne $script:current) {
        $buf = @($script:buffer.ToArray())
        if ($Trim) {
            # Degraded bundle (END marker missing): drop the trailing blank
            # separator lines that would otherwise be absorbed into the content.
            $end = $buf.Count
            while ($end -gt 0 -and $buf[$end - 1] -eq '') { $end-- }
            if ($end -eq 0) { $buf = @() } elseif ($end -lt $buf.Count) { $buf = $buf[0..($end - 1)] }
        }
        $script:files.Add([pscustomobject]@{ Path = $script:current; Lines = $buf })
        $script:current = $null
        $script:buffer.Clear()
    }
}

foreach ($line in $lines) {
    if ($line -match $FileBeginRx) {
        Close-Current $true    # END may be missing before this FILE: trim separators
        $current = $Matches[1]
        continue
    }
    if ($line -match $FileEndRx) {
        Close-Current $false   # proper END marker: keep content exactly
        continue
    }
    if ($null -ne $current) { $buffer.Add($line) }
    # lines outside any block (header/manifest/stray prose) are ignored
}
Close-Current $true

if ($files.Count -eq 0) { throw "No file blocks found in $InputPath (is it a valid bundle?)" }

# ---- prepare output ---------------------------------------------------------
$outFull = if (Test-Path -LiteralPath $Output) { (Resolve-Path -LiteralPath $Output).Path } else { $Output }
if (-not $Preview) {
    if (-not (Test-Path -LiteralPath $outFull)) {
        New-Item -ItemType Directory -Force -Path $outFull | Out-Null
    } elseif (-not $Force) {
        $existing = Get-ChildItem -LiteralPath $outFull -Force -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Target '$outFull' is not empty; files will be created/overwritten in place." -ForegroundColor DarkYellow
        }
    }
    $outFull = (Resolve-Path -LiteralPath $outFull).Path
}

# ---- apply ------------------------------------------------------------------
$created = 0; $modified = 0; $unchanged = 0; $rejected = 0

foreach ($f in $files) {
    $rel = $f.Path -replace '\\', '/'
    if (-not (Test-SafeRelative $rel)) {
        Write-Host "REJECTED (unsafe path): $rel" -ForegroundColor Red
        $rejected++
        continue
    }
    $target = Join-Path $outFull ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)

    $exists = Test-Path -LiteralPath $target
    $status = 'created'
    if ($exists) {
        $old = @(Get-Content -LiteralPath $target -Encoding UTF8)
        if (($old -join "`n") -eq ($f.Lines -join "`n")) { $status = 'unchanged' } else { $status = 'modified' }
    }

    switch ($status) {
        'created'   { $created++ }
        'modified'  { $modified++ }
        'unchanged' { $unchanged++ }
    }

    $tag = if ($Preview) { '[preview] ' } else { '' }
    $color = switch ($status) { 'created' { 'Green' } 'modified' { 'Yellow' } default { 'DarkGray' } }
    Write-Host "$tag$status`: $rel" -ForegroundColor $color

    if ($ShowDiff -and $status -ne 'unchanged') { Show-Diff $target $f.Lines $rel }

    if (-not $Preview -and $status -ne 'unchanged') {
        $dir = Split-Path -Parent $target
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllLines($target, [string[]]$f.Lines, (New-Utf8NoBom))
    }
}

Write-Host ''
$verb = if ($Preview) { 'Would apply' } else { 'Applied' }
Write-Host "$verb`: $created created, $modified modified, $unchanged unchanged, $rejected rejected -> $outFull" -ForegroundColor Green

# ---- optional git commit ----------------------------------------------------
if ($GitCommit) {
    if ($Preview) { Write-Host 'Skipping commit in -Preview mode.' -ForegroundColor DarkYellow; return }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { Write-Warning 'git not found on PATH; cannot commit.'; return }
    # git writes to stderr on non-repos; keep that from becoming a terminating error.
    $ErrorActionPreference = 'Continue'
    $isRepo = $false
    try {
        $res = & git -C "$outFull" rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -eq 0 -and $res -eq 'true') { $isRepo = $true }
    } catch { $isRepo = $false }
    $global:LASTEXITCODE = 0
    if (-not $isRepo) {
        Write-Warning "Target is not a git repo. Run 'git init' inside '$outFull' first."
        exit 0
    }
    if (-not $CommitMessage) { $CommitMessage = "copilot-unbundle: $(Split-Path -Leaf $InputPath) @ $(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    & git -C "$outFull" add -A
    & git -C "$outFull" commit -m "$CommitMessage"
    Write-Host "Committed to git: $CommitMessage" -ForegroundColor Green
}

exit 0
