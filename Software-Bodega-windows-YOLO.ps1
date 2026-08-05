<#
.SYNOPSIS
  Software Bodega — launcher (Windows, YOLO / unattended test mode)

.DESCRIPTION
  Asks for a project folder, sets it up as a Bodega project if it isn't one
  already, then opens a terminal there with ONE oh-my-pi session running the
  conductor. The conductor interviews you and then runs every other station
  itself — you never type another command.

  YOLO MODE: the run does not stop for you — no tool-approval prompts, no
  signature gates, no between-station questions. For TESTING the pipeline end
  to end. It does NOT relax verification: the contract stays immutable, tests
  are never weakened, held-out exams stay sealed, and the run STOPS BEFORE
  MERGING. Point it at a scratch folder.

  Requires bash: the stations are shell scripts. Git for Windows (Git Bash) or
  WSL both work; the launcher finds whichever is installed.

  ⚠️  UNTESTED ON THIS PLATFORM. Written and syntax-checked, but never run on a
      real Windows machine — only the macOS launcher has been exercised end to
      end. The setup logic is shared and verified; what is unproven here is the
      folder picker, the bash discovery, and the Windows Terminal launch. If it
      misbehaves, the fallback is exact and safe:
          .\Software-Bodega-windows-YOLO.ps1 -Dir <dir> -NoLaunch   # set up only
          cd <dir>; bash scripts/start.sh                       # then start it
      Please report what broke.

.EXAMPLE
  .\Software-Bodega-windows-YOLO.ps1
  .\Software-Bodega-windows-YOLO.ps1 -Dir C:\code\my-project
  .\Software-Bodega-windows-YOLO.ps1 -Dir C:\code\my-project -NoLaunch
#>
[CmdletBinding()]
param(
    [string]$Dir = "",
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"

# The template is this script's own directory — the checked-out repo.
$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Template = if ($env:BODEGA_TEMPLATE) { $env:BODEGA_TEMPLATE } else { $Here }

function Die($msg) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($msg, "Software Bodega",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    Write-Error $msg
    exit 1
}

if (-not (Test-Path (Join-Path $Template "scripts\start.sh"))) {
    Die "This does not look like a Software Bodega checkout:`n$Template`n`nRun the launcher from inside the cloned repo, or set BODEGA_TEMPLATE."
}

# --- bash is required: the stations are shell scripts ----------------------
function Find-Bash {
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}
$Bash = Find-Bash
if (-not $Bash) {
    Die "bash was not found. Software Bodega's stations are shell scripts.`n`nInstall Git for Windows (https://git-scm.com/download/win) or enable WSL, then run this again."
}

# --- 1. pick a folder ------------------------------------------------------
if (-not $Dir) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = "Software Bodega YOLO — pick a SCRATCH folder (unattended)"
    $picker.ShowNewFolderButton = $true
    if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    $Dir = $picker.SelectedPath
}
$Dir = $Dir.TrimEnd('\', '/')
if (-not $Dir) { exit 0 }

# --- 2. is it already a Bodega project? ------------------------------------
$isProject = (Test-Path (Join-Path $Dir "factory\STATE.md")) -and
             (Test-Path (Join-Path $Dir "scripts\start.sh"))
if ($isProject) {
    $Mode = "resume"
} else {
    $count = 0
    if (Test-Path $Dir) { $count = (Get-ChildItem -Force $Dir | Measure-Object).Count }
    if (-not $PSBoundParameters.ContainsKey('Dir')) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "YOLO TEST RUN - unattended, no approval prompts, no signature gates.`n`nSet up a new Software Bodega project in:`n`n$Dir`n`n($count existing item(s) — nothing will be deleted.)",
            "Software Bodega - YOLO",
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    }
    $Mode = "init"
}

# --- 3. initialise from the template (never destructive) -------------------
if ($Mode -eq "init") {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    # Loud, not silent: a swallowed copy error leaves a project with no
    # scripts/ that only fails later with "No such file or directory".
    $failed = @()
    foreach ($item in @("skills", "scripts", "foreman", "docs", "models.env", "AGENTS.md", "README.md", ".github")) {
        $src = Join-Path $Template $item
        if (-not (Test-Path $src)) { $failed += "$item(missing-in-template)"; continue }
        try { Copy-Item -Recurse -Force $src -Destination $Dir -ErrorAction Stop }
        catch { $failed += $item }
    }
    if ($failed.Count) { Die "Could not copy into ${Dir}:`n$($failed -join ', ')" }
    foreach ($must in @("scripts\start.sh", "scripts\nightshift.sh", "skills\conductor\SKILL.md", "models.env")) {
        if (-not (Test-Path (Join-Path $Dir $must))) { Die "Setup incomplete: $Dir\$must is missing after copy." }
    }

    foreach ($d in @("factory\.planning\gate-results", "factory\tasks",
                     "factory\tests\visible", "factory\tests\heldout", "factory\adr")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir $d) | Out-Null
    }
    # LF endings throughout: these files are read by bash and by the stations.
    function Write-Lf($path, $text) {
        [System.IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Lf (Join-Path $Dir "factory\STATE.md")    "STAGE: INTERVIEW`nPOINTER: new project - run the interview`n"
    Write-Lf (Join-Path $Dir "factory\progress.md") "# progress.md - append-only. Format: TASK|status|SHA|tests|note`n"
    Write-Lf (Join-Path $Dir "factory\log.md")      "# log.md - append-only station diary. Format: ISO8601|station|event|detail`n"
    foreach ($f in @("BRIEF", "BLUEPRINT", "CONTRACT", "HANDOFF", "REVIEW", "GUIDE")) {
        $p = Join-Path $Dir "factory\$f.md"
        if (-not (Test-Path $p)) { Write-Lf $p "# $f.md`n`n_Not yet produced._`n" }
    }
    Write-Lf (Join-Path $Dir "factory\.planning\spec.json")      '{"actors":[],"criteria":[],"non_goals":[]}'
    Write-Lf (Join-Path $Dir "factory\.planning\decompose.json") '{"tasks":[]}'
    Write-Lf (Join-Path $Dir "factory\.planning\plan.json")      '{"slices":[]}'

    if (-not (Test-Path (Join-Path $Dir ".git"))) {
        Push-Location $Dir
        try {
            git init -q 2>$null
            $n = (git config --global user.name);  if (-not $n) { $n = "bodega" }
            $e = (git config --global user.email); if (-not $e) { $e = "bodega@localhost" }
            git config user.name  $n 2>$null
            git config user.email $e 2>$null
            git add -A 2>$null
            git commit -qm "Software Bodega: scaffold" 2>$null
        } finally { Pop-Location }
    }
}

# --- 4. open a terminal there and start the conductor ----------------------
if (-not (Get-Command omp -ErrorAction SilentlyContinue)) {
    Die "oh-my-pi (omp) is not on PATH.`n`nSee the README for swapping in a different agent harness."
}
if ($NoLaunch) {
    Write-Host "Software Bodega YOLO: prepared $Dir ($Mode) - not launching a terminal (-NoLaunch)"
    exit 0
}

$title    = "Software Bodega YOLO - " + (Split-Path -Leaf $Dir)
$bashCmd  = "cd '$($Dir -replace '\\', '/')' && bash scripts/start.sh --yolo"

if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
    Start-Process wt.exe -ArgumentList @("--title", "`"$title`"", "-d", "`"$Dir`"", "`"$Bash`"", "-lc", "`"$bashCmd; exec bash`"")
} else {
    Start-Process $Bash -ArgumentList @("-lc", "`"$bashCmd; exec bash`"") -WorkingDirectory $Dir
}

Write-Host "Software Bodega YOLO: launched (unattended) at $Dir ($Mode)"
