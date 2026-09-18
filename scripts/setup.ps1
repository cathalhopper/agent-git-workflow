#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the tier 1 contributor tools on Windows: git and gh.

.DESCRIPTION
    Detects what is already present, installs only what is missing via winget, and
    prints a table of where you stand.

    Running it twice is safe: the second run installs nothing and just reports.

    Two steps are deliberately NOT automated, because they cannot be:
      - gh auth login   needs a browser and a one-time code
      - git identity    is your name and your email, not something to guess
    Both are reported as ACTION NEEDED with the exact command to run.

    The project's own build toolchain is tier 2, and this script does not install it.
    docs/development/setting-up.md section 4 says what it is.

.EXAMPLE
    .\scripts\setup.ps1

.LINK
    docs/development/setting-up.md
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

# A failing cmdlet must abort here exactly as it does in setup.sh under
# `set -euo pipefail`. The two helpers that expect a failure -- Get-ToolVersion and the
# `gh auth status` probe -- each narrow $ErrorActionPreference themselves and restore it.
$ErrorActionPreference = 'Stop'

$script:Installed = @()
$script:StalePath = @()
$script:Failed = @()

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# Returns a version string, or $null if the tool is absent or does not answer.
function Get-ToolVersion {
    param(
        [string]$Name,
        [string[]]$Arguments = @('--version')
    )

    if (-not (Test-CommandExists $Name)) { return $null }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $output = & $Name @Arguments
        if ($null -eq $output) { return 'installed' }
        $text = ($output | Select-Object -First 1 | Out-String).Trim()
        $match = [regex]::Match($text, '\d+\.\d+(\.\d+)?')
        if ($match.Success) { return $match.Value }
        return 'installed'
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $previous
    }
}

# Installs a winget package only if its command is not already on PATH.
function Install-IfMissing {
    param(
        [string]$Command,
        [string]$PackageId,
        [string]$Label
    )

    if (Test-CommandExists $Command) {
        $version = Get-ToolVersion -Name $Command
        Write-Host ("  {0,-12} already installed ({1})" -f $Label, $version) -ForegroundColor DarkGray
        return
    }

    Write-Host ("  {0,-12} installing via winget ({1})..." -f $Label, $PackageId) -ForegroundColor Yellow

    winget install --id $PackageId --exact --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE

    # winget returns 0 on a real install. -1978335189 is "update not applicable":
    # the package is already registered, so the binary exists but this shell's PATH
    # predates it. That is a restart-your-shell situation, not an install.
    if ($code -eq 0) {
        Write-Host ("  {0,-12} installed" -f $Label) -ForegroundColor Green
        $script:Installed += $Label
    } elseif ($code -eq -1978335189) {
        Write-Host ("  {0,-12} already installed, but not on this shell's PATH" -f $Label) -ForegroundColor Yellow
        $script:StalePath += $Label
    } else {
        Write-Host ("  {0,-12} FAILED (winget exit code {1})" -f $Label, $code) -ForegroundColor Red
        $script:Failed += ("{0} (winget exit {1})" -f $Label, $code)
    }
}

# The banner reads PROJECT_NAME from workflow.conf, without dot-sourcing it.
$projectName = 'this repository'
$conf = Join-Path $PSScriptRoot 'workflow.conf'
if (Test-Path -LiteralPath $conf) {
    foreach ($l in @(Get-Content -LiteralPath $conf)) {
        if ("$l" -match '^PROJECT_NAME=(.+)$') { $projectName = $Matches[1].Trim(); break }
    }
}

Write-Host ''
Write-Host "$projectName - contributor setup" -ForegroundColor White
Write-Host 'See docs/development/setting-up.md for what this does and why.' -ForegroundColor DarkGray

if (-not (Test-CommandExists 'winget')) {
    Write-Host ''
    Write-Host 'winget is not available on this machine.' -ForegroundColor Red
    Write-Host 'Install "App Installer" from the Microsoft Store, then re-run this script.'
    Write-Host 'Or follow docs/development/setting-up.md section 3 by hand - the steps are the same.'
    exit 1
}

# ---------------------------------------------------------------- tier 1

Write-Head 'Tier 1 - everyone'

Install-IfMissing -Command 'git' -PackageId 'Git.Git'    -Label 'git'
Install-IfMissing -Command 'gh'  -PackageId 'GitHub.cli' -Label 'gh'

# ------------------------------------------------- the two manual steps

Write-Head 'Steps this script will not do for you'

$actions = @()

$gitName  = git config --global --get user.name
$gitEmail = git config --global --get user.email

if ([string]::IsNullOrWhiteSpace($gitName) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
    Write-Host '  Your git identity is not fully set.' -ForegroundColor Yellow
    Write-Host '  It is read by name in two checks: the overlap report in starting-new-work.md'
    Write-Host '  section 2, and the claim-commit author check in finishing-work.md section 1.'
    Write-Host ''
    Write-Host '    git config --global user.name "Your Name"' -ForegroundColor White
    Write-Host '    git config --global user.email "you@example.com"' -ForegroundColor White
    Write-Host ''
    Write-Host '  Use an address GitHub has verified, or your @users.noreply.github.com one.' -ForegroundColor DarkGray
    $actions += 'set your git identity'
} else {
    Write-Host ("  git identity  {0} <{1}>" -f $gitName, $gitEmail) -ForegroundColor DarkGray
}

$ghAuthed = $false
if (Test-CommandExists 'gh') {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    gh auth status | Out-Null
    $ghAuthed = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $previous
}

if (-not $ghAuthed) {
    Write-Host ''
    Write-Host '  gh is not authenticated. This needs a browser, so it is yours to run:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '    gh auth login' -ForegroundColor White
    Write-Host ''
    Write-Host '  Answer: GitHub.com, then HTTPS, then YES to "Authenticate Git with your' -ForegroundColor DarkGray
    Write-Host '  GitHub credentials?", then login with a web browser.' -ForegroundColor DarkGray
    Write-Host '  That YES is what makes git push work without a separate credential setup.' -ForegroundColor DarkGray
    $actions += 'run gh auth login'
} else {
    Write-Host '  gh auth      authenticated' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- report

Write-Head 'Where you stand'

function Show-Row {
    param([string]$Name, [string]$Version, [string]$Status)
    $colour = 'Green'
    if ($Status -ne 'OK') { $colour = 'Yellow' }
    Write-Host ("  {0,-11}{1,-12}{2}" -f $Name, $Version, $Status) -ForegroundColor $colour
}

$rows = @(
    @{ Name = 'git'; Command = 'git' },
    @{ Name = 'gh';  Command = 'gh'  }
)

foreach ($row in $rows) {
    $version = Get-ToolVersion -Name $row.Command
    if ($null -eq $version) {
        Show-Row -Name $row.Name -Version '-' -Status 'MISSING - restart your shell, then re-run'
    } else {
        Show-Row -Name $row.Name -Version $version -Status 'OK'
    }
}

if ([string]::IsNullOrWhiteSpace($gitEmail)) {
    Show-Row -Name 'identity' -Version 'unset' -Status 'ACTION NEEDED - see above'
} else {
    Show-Row -Name 'identity' -Version 'set' -Status 'OK'
}

if ($ghAuthed) {
    Show-Row -Name 'gh auth' -Version 'yes' -Status 'OK'
} else {
    Show-Row -Name 'gh auth' -Version '-' -Status 'ACTION NEEDED - run gh auth login'
}

Write-Host ''

if ($script:Installed.Count -gt 0) {
    Write-Host ('Installed this run: {0}' -f ($script:Installed -join ', '))
    Write-Host 'Restart your shell so the new PATH is picked up, then re-run to confirm.' -ForegroundColor Yellow
    Write-Host ''
}

if ($script:StalePath.Count -gt 0) {
    Write-Host ('Already installed but not visible to this shell: {0}' -f ($script:StalePath -join ', '))
    Write-Host 'Nothing to install - your PATH is just older than the install.' -ForegroundColor Yellow
    Write-Host 'Close this terminal, open a new one, and re-run to confirm.' -ForegroundColor Yellow
    Write-Host ''
}

if ($script:Failed.Count -gt 0) {
    Write-Host 'Some installs failed:' -ForegroundColor Red
    foreach ($failure in $script:Failed) { Write-Host ("  - {0}" -f $failure) -ForegroundColor Red }
    Write-Host 'See docs/development/setting-up.md section 5, and report anything not listed there.'
    Write-Host ''
    exit 1
}

if ($actions.Count -gt 0) {
    Write-Host ('Still to do by hand: {0}.' -f ($actions -join ', and '))
    Write-Host ''
    exit 0
}

Write-Host 'Tier 1 complete. Next: docs/development/starting-new-work.md' -ForegroundColor Green
Write-Host ''
