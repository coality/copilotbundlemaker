# copilotbundlemaker

Work around Copilot's context limit by **bundling** a whole source tree (e.g. a Python
project) into a **single `.txt`** you can paste into Copilot. Copilot edits the text and
replies with a `.txt` in the same format, which you **unbundle** back into files.

Pure **PowerShell** — no install, no admin rights, works on any Windows machine.

```
   your project ──(bundle.ps1)──▶ bundle-*.txt ──▶ paste into Copilot
                                                        │
   rebuilt files ◀──(unbundle.ps1)──◀ reply .txt ◀──────┘
```

## Requirements

- Windows with PowerShell (built in — nothing to install).
- Optional: `git` on PATH (enables nicer diffs and the `-GitCommit` option).

## Quick start (drag & drop)

1. **Drag your project folder** onto `bundle.cmd`.
   → a timestamped `bundles\bundle-YYYYMMDD-HHmmss.txt` is created and an English
   **Copilot prompt** is printed and copied to your clipboard.
2. In Copilot, paste the **prompt**, then paste the **bundle file contents**. Add your
   request. Copilot replies with an updated bundle — save it as `reply.txt`.
3. **Drag `reply.txt`** onto `unbundle.cmd` → files are rebuilt under `unbundled\`.

## Command-line usage

```powershell
# Bundle the current folder / a project (timestamped output + prompt)
.\bundle.ps1 .\my-project

# Bundle and bake your request into the prompt
.\bundle.ps1 .\my-project -Task "add error handling in data_loader.py"

# Only some file types, smaller size cap
.\bundle.ps1 .\src -IncludeExt .py,.md -MaxSizeKB 512

# Just (re)generate the Copilot prompt, no bundling
.\bundle.ps1 -EmitPromptOnly -Task "refactor the parser"

# Preview what Copilot's reply would change, writing nothing
.\unbundle.ps1 .\reply.txt .\my-project -Preview -ShowDiff

# Apply the reply over your project and commit it
.\unbundle.ps1 .\reply.txt .\my-project -GitCommit -CommitMessage "apply copilot changes"

# Rebuild into a fresh folder (default when no target given: .\unbundled)
.\unbundle.ps1 .\reply.txt
```

> If PowerShell blocks the script, run it via:
> `powershell -ExecutionPolicy Bypass -File .\bundle.ps1 .\my-project`
> (the `.cmd` wrappers already do this for you).

## Keeping a history with git (recommended)

Point `unbundle.ps1` at your **existing project folder** (a git repo) so every Copilot
round-trip becomes a reviewable change:

```powershell
.\unbundle.ps1 .\reply.txt .\my-project -Preview -ShowDiff   # 1. review, nothing written
.\unbundle.ps1 .\reply.txt .\my-project                      # 2. apply
git -C .\my-project diff                                     # 3. inspect
.\unbundle.ps1 .\reply.txt .\my-project -GitCommit           # or commit via the tool
git -C .\my-project checkout .                               # undo if unhappy
```

## Bundle format

```
##### COPILOT-BUNDLE v1 #####
# Instructions for the AI: ...
##### BEGIN MANIFEST #####
# <n> files, generated from <root>
##### END MANIFEST #####

<<<<< FILE: src/app.py >>>>>
...file content...
<<<<< END FILE: src/app.py >>>>>
```

Paths are relative, using `/`. The parser is tolerant: if Copilot drops the `END FILE`
lines, reconstruction still works (a new `FILE` line starts the next file).

## Options

### `bundle.ps1`

| Option | Default | Description |
| --- | --- | --- |
| `-Root` (pos. 1) | `.` | Folder to bundle. |
| `-Output` | timestamped | Exact output path (overrides the timestamped name). |
| `-OutDir` | `.\bundles` | Folder for timestamped bundles. |
| `-MaxSizeKB` | `1024` | Skip files larger than this. |
| `-IncludeExt` | (all text) | Whitelist of extensions, e.g. `.py,.md`. |
| `-ExtraExclude` | — | Extra folder names / path wildcards to skip. |
| `-Task` | placeholder | Your request, injected into the prompt. |
| `-PromptOut` | — | Also write the prompt to this file. |
| `-EmitPromptOnly` | — | Print/copy the prompt only, don't bundle. |

### `unbundle.ps1`

| Option | Default | Description |
| --- | --- | --- |
| `-InputPath` (pos. 1) | — | The bundle `.txt` (Copilot's reply). |
| `-Output` (pos. 2) | `.\unbundled` | Target folder (use your project for git history). |
| `-Preview` / `-DryRun` | — | Show changes, write nothing. |
| `-ShowDiff` | — | Print a diff of created/modified files. |
| `-GitCommit` | — | `git add -A` + commit in the target (git repo required). |
| `-CommitMessage` | timestamped | Commit message. |
| `-Force` | — | Allow writing into a non-empty folder without warning. |

## Notes & limits

- Binary files (by extension **and** null-byte sniffing) and oversized files are skipped.
- Junk folders are excluded by default: `.git`, `node_modules`, `__pycache__`, `venv`,
  `dist`, `build`, `.idea`, `.vscode`, and more.
- `unbundle` is **non-destructive**: it writes/overwrites files present in the `.txt`; it
  never deletes files that are absent from it.
- Path-traversal (`..`, absolute paths) is rejected on unbundle.
- Line endings are normalized to the platform default; a trailing-newline byte may differ.
  Harmless for source code.

## Push to GitHub

This repo is already initialized locally. To publish it:

```powershell
git remote add origin https://github.com/<you>/copilotbundlemaker.git
git push -u origin main
```

Or, if you have the GitHub CLI authenticated:

```powershell
gh repo create copilotbundlemaker --public --source . --push
```

## License

MIT — see [LICENSE](LICENSE).
