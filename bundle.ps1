<#
.SYNOPSIS
    Bundle a source tree into a single .txt file for GitHub Copilot (or any chat AI).

.DESCRIPTION
    Walks a root directory, skips binaries / junk folders / oversized files, and writes
    every text file into ONE timestamped .txt using distinctive delimiter markers.
    Also prints (and copies) an English prompt telling Copilot how to reply so that the
    reply can be turned back into files with unbundle.ps1.

.EXAMPLE
    .\bundle.ps1 .\my-project
    .\bundle.ps1 .\my-project -Task "add error handling in data_loader.py"
    .\bundle.ps1 .\src -IncludeExt .py,.md -MaxSizeKB 512
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Root = ".",

    # Exact output path. If omitted, a timestamped file is created under -OutDir.
    [string]$Output,

    # Folder that receives the timestamped bundles.
    [string]$OutDir = ".\bundles",

    # Skip files larger than this many KB.
    [int]$MaxSizeKB = 1024,

    # If given, ONLY include these extensions (e.g. .py,.md). Otherwise include all text.
    [string[]]$IncludeExt,

    # Extra folder names / relative-path wildcards to exclude.
    [string[]]$ExtraExclude,

    # The task to hand to Copilot; injected into the generated prompt.
    [string]$Task,

    # Also write the generated prompt to this file.
    [string]$PromptOut,

    # Only print/copy the Copilot prompt, do not bundle anything.
    [switch]$EmitPromptOnly
)

$ErrorActionPreference = 'Stop'

# ---- constants --------------------------------------------------------------
$ExcludedDirs = @(
    '.git', '.svn', '.hg', 'node_modules', '__pycache__', '.venv', 'venv', 'env',
    '.idea', '.vscode', 'dist', 'build', 'target', 'bin', 'obj',
    '.pytest_cache', '.mypy_cache', '.tox', '.next', '.nuxt', 'coverage'
)
$BinaryExt = @(
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.tif', '.tiff',
    '.pdf', '.zip', '.gz', '.tar', '.7z', '.rar', '.jar', '.war',
    '.exe', '.dll', '.so', '.dylib', '.o', '.obj', '.a', '.lib', '.class', '.pyc', '.pyd',
    '.mp3', '.mp4', '.avi', '.mov', '.wav', '.flac', '.ogg',
    '.woff', '.woff2', '.ttf', '.otf', '.eot',
    '.db', '.sqlite', '.pack', '.bin', '.dat'
)

$FileBegin = '<<<<< FILE:'
$FileEnd   = '<<<<< END FILE:'

# ---- helpers ----------------------------------------------------------------
function New-Utf8NoBom { return (New-Object System.Text.UTF8Encoding($false)) }

function Test-IsBinary([string]$Path) {
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 8000
            $read = $fs.Read($buf, 0, $buf.Length)
            for ($i = 0; $i -lt $read; $i++) { if ($buf[$i] -eq 0) { return $true } }
            return $false
        } finally { $fs.Close() }
    } catch { return $true }
}

function Get-CopilotPrompt([string]$TaskText) {
    if ([string]::IsNullOrWhiteSpace($TaskText)) { $TaskText = '<DESCRIBE YOUR REQUEST HERE>' }
    return @"
You are working on a software project delivered as a single text "bundle".
Each file is wrapped between delimiter lines:

  $FileBegin relative/path/file.ext >>>>>
  ...file content...
  $FileEnd relative/path/file.ext >>>>>

Reply rules (IMPORTANT):
1. Return the FULL updated project in the exact same bundle format.
2. Keep the delimiter lines EXACTLY: same markers, same relative paths, '/' separators.
3. Put ONLY file content between the markers - no comments or prose outside the blocks.
4. To modify a file, change only the content between its markers.
5. To create a file, add a new block with a new relative path.
6. Do NOT wrap the output in Markdown code fences (no triple-backtick blocks).

Task:
$TaskText
"@
}

function Publish-Prompt([string]$PromptText, [string]$OutFile) {
    Write-Host ''
    Write-Host '================= COPILOT PROMPT (copy everything below) =================' -ForegroundColor Cyan
    Write-Host $PromptText
    Write-Host '=========================================================================' -ForegroundColor Cyan
    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
        try { Set-Clipboard -Value $PromptText; Write-Host '(prompt copied to clipboard)' -ForegroundColor DarkGray } catch {}
    }
    if ($OutFile) {
        [System.IO.File]::WriteAllText((New-Item -ItemType File -Force -Path $OutFile).FullName, $PromptText, (New-Utf8NoBom))
        Write-Host "(prompt written to $OutFile)" -ForegroundColor DarkGray
    }
}

# ---- emit-prompt-only shortcut ---------------------------------------------
if ($EmitPromptOnly) {
    Publish-Prompt (Get-CopilotPrompt $Task) $PromptOut
    return
}

# ---- resolve root -----------------------------------------------------------
if (-not (Test-Path -LiteralPath $Root)) { throw "Root not found: $Root" }
$rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')

# normalize IncludeExt to lowercase with leading dot
$includeSet = $null
if ($IncludeExt) {
    $includeSet = $IncludeExt | ForEach-Object { $e = $_.ToLower(); if ($e[0] -ne '.') { ".$e" } else { $e } }
}

# ---- walk & collect ---------------------------------------------------------
$blocks = New-Object System.Collections.Generic.List[string]
$included = 0
$skipped = New-Object System.Collections.Generic.List[string]

Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force | ForEach-Object {
    $file = $_
    $rel = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
    $segments = $rel -split '/'

    # excluded folders
    foreach ($seg in $segments) { if ($ExcludedDirs -contains $seg) { return } }
    if ($ExtraExclude) {
        foreach ($seg in $segments) { if ($ExtraExclude -contains $seg) { return } }
        foreach ($pat in $ExtraExclude) { if ($rel -like $pat) { return } }
    }

    $ext = $file.Extension.ToLower()

    if ($includeSet) {
        if ($includeSet -notcontains $ext) { return }
    } else {
        if ($BinaryExt -contains $ext) { $skipped.Add("$rel (binary ext)"); return }
    }

    if ($file.Length -gt ($MaxSizeKB * 1KB)) {
        $skipped.Add("$rel ($([math]::Round($file.Length/1KB)) KB > $MaxSizeKB KB)"); return
    }
    if (Test-IsBinary $file.FullName) { $skipped.Add("$rel (binary content)"); return }

    $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)
    $blocks.Add("$FileBegin $rel >>>>>")
    foreach ($l in $lines) { $blocks.Add($l) }
    $blocks.Add("$FileEnd $rel >>>>>")
    $blocks.Add('')
    $included++
}

if ($included -eq 0) { Write-Warning "No files bundled from $rootFull (all excluded/skipped)." }

# ---- assemble output --------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $Output) {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $Output = Join-Path $OutDir "bundle-$stamp.txt"
}

$out = New-Object System.Collections.Generic.List[string]
$out.Add('##### COPILOT-BUNDLE v1 #####')
$out.Add('# Instructions for the AI:')
$out.Add('# - Each file is wrapped by a BEGIN line and an END line.')
$out.Add('# - DO NOT modify these delimiter lines; keep them EXACTLY as-is.')
$out.Add('# - To edit a file: change only the content between its markers.')
$out.Add('# - To create a file: add a new block with a relative path.')
$out.Add("# - Paths are ALWAYS relative to the root, using '/' separators.")
$out.Add('##### BEGIN MANIFEST #####')
$out.Add("# $included files, generated from $rootFull at $stamp")
$out.Add('##### END MANIFEST #####')
$out.Add('')
foreach ($b in $blocks) { $out.Add($b) }

[System.IO.File]::WriteAllLines((New-Item -ItemType File -Force -Path $Output).FullName, [string[]]$out, (New-Utf8NoBom))

$sizeKb = [math]::Round((Get-Item -LiteralPath $Output).Length / 1KB, 1)
Write-Host ''
Write-Host "Bundle written: $Output" -ForegroundColor Green
Write-Host "  $included file(s) included, $($skipped.Count) skipped, $sizeKb KB" -ForegroundColor Green
if ($skipped.Count -gt 0) {
    Write-Host '  Skipped:' -ForegroundColor DarkYellow
    $skipped | Select-Object -First 20 | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }
    if ($skipped.Count -gt 20) { Write-Host "    ... and $($skipped.Count - 20) more" -ForegroundColor DarkYellow }
}

Publish-Prompt (Get-CopilotPrompt $Task) $PromptOut

Write-Host ''
Write-Host 'Next: paste the bundle file AND the prompt above into Copilot, then run' -ForegroundColor Gray
Write-Host '      unbundle.ps1 on its reply.' -ForegroundColor Gray
