#Requires -Version 5.1
<#
.SYNOPSIS
    Takes a finished branch from "the code works" to "squash-merged and cleaned up".

.DESCRIPTION
    This is docs/development/finishing-work.md sections 1 to 7, mechanised.

    WHAT THE BARE RUN GUARANTEES
    It creates no commit, no branch and no pull request; it deletes nothing; it changes
    no local branch, no working tree and nothing on the remote. It does update your
    remote-tracking refs, because every answer it gives depends on them being current -
    and section 1 of the document is explicit that a check against a stale remote is
    worse than no check, since it returns "all clear" with authority.

    WHAT IT DELIBERATELY WILL NOT DO
    It will not judge your diff, run your tests, resolve a merge conflict, or decide
    whether a change a project scan stopped on was intended. It surfaces those and
    stops. Section 2 of the document is a human judgement and this script gathers the
    evidence for it, nothing more.

    WHAT THE PROJECT SUPPLIES
    scripts\workflow.conf       KEY=value settings: the base branches, the branch-name
                                prefixes and any base a prefix maps to, the check
                                command quoted in messages, and the
                                path classes flagged for -Acknowledge. Every key has a
                                default, so a missing file changes nothing.
    scripts\finish-project.ps1  optional. Dot-sourced if present; defines
                                Invoke-ProjectScans, which runs after the built-in scans.
                                A scan that needs a human assertion asks for one by name
                                with Test-Declared, and the run supplies it with
                                -Declare <name>; the declaration is written into the
                                pull request body. A name no scan asked for is a usage
                                error. finish-project.ps1.example carries the contract.

    THE COMPLETE SET OF COMMANDS THAT CHANGE ANYTHING
    Thirteen, and `git fetch` is the only one not behind Invoke-Mutating - it runs even
    under -DryRun, because every answer this script gives depends on it. Nothing else in
    this file mutates anything.

      git fetch --all --prune
      git merge origin/<base>
      git merge --abort
      git push -u origin <branch>
      gh pr create --base <base> --title <t> --body-file <f> [--draft]
      gh pr edit <n> --body-file <f>
      gh pr merge <n> --squash --subject <t> --body-file <f> --match-head-commit <sha>
      git push origin --delete <branch>
      git switch <base>
      git merge --ff-only origin/<base>
      git worktree remove <path>
      git worktree prune
      git branch -D <branch>

    No command this script runs forces, rebases, resets or stashes. The words themselves
    appear further down, in comments and in the messages that refuse those actions, so
    the audit is a Select-String and a read of each hit:
      Select-String -Path scripts/finish.ps1 -Pattern '--force|rebase|reset --hard|stash'
    Every hit outside this help block is a comment or a refusal message, never a command.

    WHY THERE IS NO -Force, -SkipChecks OR -Yes, AND WHY YOU MUST NOT ADD ONE
    Permission systems match on command prefixes. The moment "finish.ps1 -Merge" is
    approved, "finish.ps1 -Merge -Force" is approved too - by the same rule, without
    anyone deciding it should be. An override flag on this script is therefore not an
    escape hatch used in emergencies; it is effectively always on from the moment the
    tool is trusted. Every stop in this script corresponds to a rule in section 9 of the
    document. If one fires, the answer is to fix the branch, or to do it by hand and take
    responsibility for it.

    EXIT CODES
      0  the stage completed. For a bare run: the checks ran. That is not an approval
      1  hard stop - a refusal fired or a command failed. Nothing further was attempted
      2  usage error
      3  not yet, retryable - checks still running, or the pull request is behind

.PARAMETER Pr
    Sections 3 and 4. Brings the branch up to date with its base, pushes, and opens the
    pull request. Requires -Testing.

.PARAMETER Merge
    Sections 5 and 6. Verifies the pull request is yours, green and unchanged since you
    read it, squash-merges it, then cleans up the branch and worktree.

.PARAMETER Cleanup
    Section 6 only. The recovery path when a merge already happened but cleanup did not.

.PARAMETER DryRun
    Print every command that would change something, and run none of them. The fetch
    still happens, because every answer depends on it.

.PARAMETER Testing
    What you actually ran, verbatim, for the Testing line of the pull request body.
    Required by -Pr: this script cannot know it and will not invent it.

.PARAMETER Notes
    Anything a reader would otherwise have to reconstruct - deliberate omissions,
    follow-up work, decisions that could reasonably have gone the other way.

.PARAMETER Base
    The branch this work merges into. Resolved automatically from workflow.conf; pass it
    when the automatic answer is refused as ambiguous, or to target an alternate base
    explicitly.

.PARAMETER Scope
    Overrides the Scope line normally read from the claim commit.

.PARAMETER Title
    Overrides the pull request title normally built from the branch type and the claim.

.PARAMETER Draft
    Open the pull request as a draft: visible, but not landable.

.PARAMETER Declare
    Comma-separated names, each one a declaration a project scan asked for on this run.
    A name no scan asked for is a usage error. What you declare is written into the pull
    request body where a reviewer sees it. There is deliberately no value meaning
    "unintended, proceed anyway".

.PARAMETER Acknowledge
    Comma-separated paths, which may only name files this run actually flagged. What you
    acknowledge is written into the pull request body where a reviewer sees it.

.PARAMETER Branch
    The branch to clean up, when -Cleanup runs from somewhere else.

.PARAMETER Sha
    The squashed commit, for -Cleanup when there is no pull request to read it from.

.EXAMPLE
    .\scripts\finish.ps1

.EXAMPLE
    .\scripts\finish.ps1 -Pr -Testing "the check script passes; new endpoint test added"

.EXAMPLE
    .\scripts\finish.ps1 -Merge

.EXAMPLE
    .\scripts\finish.ps1 -Merge -DryRun

.LINK
    docs/development/finishing-work.md
#>
[CmdletBinding()]
param(
    [switch]$Pr,
    [switch]$Merge,
    [switch]$Cleanup,
    [switch]$DryRun,
    [switch]$Draft,
    [string]$Testing = '',
    [string]$Notes = '',
    [string]$Base = '',
    [string]$Scope = '',
    [string]$Title = '',
    [string]$Declare = '',
    [string]$Acknowledge = '',
    [string]$Branch = '',
    [string]$Sha = ''
)

Set-StrictMode -Version Latest

# Both halves of a script pair must abort on the same conditions. $LASTEXITCODE covers
# the native commands below, but a *cmdlet* that fails writes to the error stream and
# execution continues, where `set -euo pipefail` in finish.sh would have stopped -- and
# this is the script that pushes, opens pull requests and merges.
#
# The two places that genuinely continue past a failure say so locally -- the
# -ErrorAction SilentlyContinue at the Remove-Item and the gh probe. A native command
# whose stderr is redirected runs inside Invoke-Quiet, which judges it by exit code.
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- arguments

$stages = @()
if ($Pr)      { $stages += 'pr' }
if ($Merge)   { $stages += 'merge' }
if ($Cleanup) { $stages += 'cleanup' }

if ($stages.Count -gt 1) {
    Write-Host 'two stage flags given: only one of -Pr, -Merge, -Cleanup per run' -ForegroundColor Red
    Write-Host 'each stage does one thing, so that what a run will do is knowable before it runs'
    exit 2
}

$script:Stage = if ($stages.Count -eq 1) { $stages[0] } else { 'report' }

# --------------------------------------------------------------------------- output

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Write-Fine   { param([string]$Text) Write-Host ("  {0}" -f $Text) -ForegroundColor DarkGray }
function Write-Action { param([string]$Text) Write-Host ("  {0}" -f $Text) -ForegroundColor Yellow }
function Write-Good   { param([string]$Text) Write-Host ("  {0}" -f $Text) -ForegroundColor Green }
function Write-Plain  { param([string]$Text) Write-Host ("  {0}" -f $Text) }

$script:Findings      = 0
$script:Flagged       = @()   # paths from the suspicious-path scan
$script:CleanupNotes  = @()   # becomes the Cleanup: line of the section 7 report
$script:NotesExtra    = @()   # appended to the Notes: field of the pull request
$script:Declared      = @()   # names given with -Declare
$script:DeclaredAsked = @()   # names a scan asked Test-Declared about this run
$script:DeclaredUsed  = @()   # names a scan asked about and found declared
$script:Ran           = @()   # every state-changing command Invoke-Mutating completed
$script:CurSection    = 1     # cites finishing-work.md section 1 to 6 by number, one per stage

function Add-Finding {
    param([string]$Class, [string]$Detail)
    $script:Findings++
    Write-Host ("  {0,-18} {1}" -f $Class, $Detail) -ForegroundColor Yellow
}

function Add-Flagged { param([string]$Path) $script:Flagged += $Path }
function Add-Note    { param([string]$Text) $script:NotesExtra += $Text }

# True when -Declare named $Name. Only a scan that is about to stop asks, so the set of
# names asked about this run is exactly the set -Declare may name: a declaration that
# nothing asked for is refused after the scans, which is what stops -Declare being a way
# to pre-authorise a stop that has not fired.
function Test-Declared {
    param([string]$Name)
    $script:DeclaredAsked += $Name
    if ($script:Declared -contains $Name) {
        $script:DeclaredUsed += $Name
        return $true
    }
    return $false
}

# Every stop in this script ends here. Nothing is attempted after it. It names what this
# run already changed: a stop after a push that says nothing changed would be believed.
function Stop-Now {
    param([string]$Reason, [string[]]$Detail = @())
    Write-Host ''
    Write-Host ("Stop: {0}" -f $Reason) -ForegroundColor Red
    foreach ($d in $Detail) {
        foreach ($line in ($d -split "`n")) { Write-Host ("       {0}" -f $line) }
    }
    Write-Host ''
    if ($script:Ran.Count -eq 0) {
        Write-Host 'Nothing was changed.' -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Already done in this run, and not undone:' -ForegroundColor Yellow
        foreach ($r in $script:Ran) { Write-Host ("  {0}" -f $r) }
    }
    Write-Host ("See docs/development/finishing-work.md section {0}" -f $script:CurSection) -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

# Not yet, rather than no. Exit 3 so a caller can tell "wait" from "stop".
function Stop-RetryLater {
    param([string]$Reason, [string[]]$Detail = @())
    Write-Host ''
    Write-Host ("Not yet: {0}" -f $Reason) -ForegroundColor Yellow
    foreach ($d in $Detail) {
        foreach ($line in ($d -split "`n")) { Write-Host ("         {0}" -f $line) }
    }
    Write-Host ''
    exit 3
}

# --------------------------------------------------------------------------- commands

# THE ONLY PLACE IN THIS FILE THAT RUNS SOMETHING WHICH CHANGES STATE.
# Search for 'Invoke-Mutating' and you have every mutation site in the script. Keep it
# that way. Returns the exit code; callers decide what a failure means.
function Invoke-Mutating {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    # Quote anything with a space for display only. The real call passes every argument
    # as a discrete word, so the quoting is never part of what git or gh receives.
    $shown = ($Arguments | ForEach-Object {
        if ($_ -match '[^A-Za-z0-9._/=:-]') { '"' + $_ + '"' } else { $_ }
    }) -join ' '

    if ($DryRun) {
        Write-Host ("  [dry-run] {0} {1}" -f $Exe, $shown) -ForegroundColor DarkGray
        return 0
    }

    Write-Host ("  + {0} {1}" -f $Exe, $shown) -ForegroundColor DarkGray

    # Out-Host, not a bare call. A native command's stdout goes to the PowerShell
    # pipeline, so a bare `& $Exe @Arguments` makes this function return that output
    # *and* the exit code as an array - and `@('Already up to date.', 0) -eq 0` gives
    # `@(0)`, which PowerShell then treats as false. A successful merge read as a
    # conflict. Out-Host writes to the console and puts nothing on the pipeline, so the
    # exit code below is the only thing this function returns.
    #
    # 'Continue' in here, and stderr merged and turned back into plain text: when the
    # caller captures this script's output with 2>&1, Windows PowerShell 5.1 makes every
    # stderr line of a native command an error record, and under 'Stop' the first one -
    # git push's "Everything up-to-date" - would end the script. Judged by exit code only.
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { $script:Ran += ("{0} {1}" -f $Exe, $shown) }
    return $rc
}

# Runs a read-only native command whose stderr the call site redirects. Windows
# PowerShell 5.1 turns redirected stderr into error records, and under 'Stop' the first
# one ends the script: `git fetch` writes its progress there, and `gh pr view` writes
# "no pull requests found" there. The preference is 'Continue' in here only; callers
# read $LASTEXITCODE, as they would after a bare call.
function Invoke-Quiet {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $ErrorActionPreference = 'Continue'
    & $Command
}

# A gh call run through Invoke-Quiet with 2>&1 returns stdout lines as strings and stderr
# lines as error records. These split them apart again.
function Get-GhOutput {
    param([object[]]$Lines)
    @($Lines | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
}

# The first line gh wrote to stderr, unless it only said there is no pull request - which
# the caller reports in its own words. Anything else is the real reason, such as origin not
# being a GitHub host, and hiding it would make the stop lie.
function Get-GhError {
    param([object[]]$Lines)
    $first = @($Lines | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -First 1
    if (-not $first) { return '' }
    if ($first -match 'no pull requests found|no open pull requests') { return '' }
    return $first
}

# Everything git wrote to stderr on that call, blank lines dropped, as the lines a stop
# quotes under "git said:". A stop whose cause cannot be read from the repository carries
# this instead of naming one: git's words are evidence, and they are never matched
# against, because they are translated.
function Get-GitSaid {
    param([object[]]$Lines)
    # A blank stderr line arrives as an error record holding nothing, whose ToString() is
    # the type name rather than the line. The line itself is TargetObject, so read that
    # where it is there, and the blank ones drop out with the empties.
    @($Lines | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
        ForEach-Object {
            if ($null -ne $_.TargetObject) { "$($_.TargetObject)".Trim() } else { "$_".Trim() }
        } | Where-Object { $_ } | Select-Object -First 10)
}

# Prefixes what git said for a stop's detail lines, and is empty when git said nothing.
function Format-GitSaid {
    param([string[]]$Said)
    if (-not $Said -or $Said.Count -eq 0) { return @() }
    return @('git said:') + $Said
}

# The fetch is the one mutating command -DryRun still performs; the header says why.
# `git fetch --all --prune` exits non-zero when ANY remote fails, so a fork whose upstream
# no longer resolves fails it while origin fetched perfectly. Which of those happened is
# read from the remotes themselves with a read-only `git ls-remote`, never from git's
# message. $Phrase ends the headline, and is empty everywhere but after the merge.
function Invoke-FetchAll {
    param([string]$Phrase = '')

    Write-Host '  + git fetch --all --prune' -ForegroundColor DarkGray
    $out = @(Invoke-Quiet { git fetch --all --prune 2>&1 })
    if ($LASTEXITCODE -eq 0) { return }
    $fetchSaid = Get-GitSaid $out

    $originOut = @(Invoke-Quiet { git ls-remote --heads origin 2>&1 })
    if ($LASTEXITCODE -ne 0) {
        Stop-Now "git fetch could not reach origin$Phrase" ((Format-GitSaid (Get-GitSaid $originOut)) + @(
            'your view of the remote is stale, so every check that reads it would be answering',
            'from old information. Fix the connection and re-run - do not proceed on this'))
    }

    $failed = @()
    $said = @()
    foreach ($name in @(git remote)) {
        if (-not $name -or $name -eq 'origin') { continue }
        if (-not (Test-SafeRef $name)) { continue }
        $probe = @(Invoke-Quiet { git ls-remote --heads $name 2>&1 })
        if ($LASTEXITCODE -ne 0) {
            $failed += $name
            if ($said.Count -eq 0) { $said = Get-GitSaid $probe }
        }
    }

    if ($failed.Count -gt 0) {
        Stop-Now ("git fetch failed on {0}, not on origin{1}" -f ($failed -join ', '), $Phrase) `
            ((Format-GitSaid $said) + @(
            'origin answers, so origin is not what failed. This repository has a remote that',
            'does not resolve - a fork keeps its upstream here - and one failed remote is enough',
            'to fail the whole fetch. Fix that remote or remove it, then re-run:',
            '',
            '  git remote -v',
            '  git remote remove <name>'))
    }

    Stop-Now "git fetch --all --prune failed$Phrase" ((Format-GitSaid $fetchSaid) + @(
        'origin answers, and so does every other remote here, so the connection is not what',
        'failed. Act on what git said, then re-run - the refs every check below reads are the',
        'ones this fetch could not update'))
}

# Refs and SHAs are validated before they are ever handed to git. No git subcommand or
# flag is ever built from a variable anywhere in this file - variables only ever occupy
# value positions, passed as discrete arguments. There is no Invoke-Expression.
function Test-SafeRef {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.StartsWith('-')) { return $false }
    if ($Value -like '*..*') { return $false }
    return ($Value -match '^[A-Za-z0-9._/-]+$')
}

function Test-SafeTitle {
    param([string]$Value)
    # PowerShell 5.1's native-argument quoting is genuinely broken for embedded quotes,
    # so this validates rather than escapes, and the paired shell script matches it so
    # that the two behave identically rather than merely similarly.
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -notmatch '["\r\n]')
}

$script:BodyFile   = ''
$script:SquashFile = ''

function New-BodyFile {
    param([string[]]$Lines)
    $path = [System.IO.Path]::GetTempFileName()
    # UTF-8 without a BOM: gh reads the file as-is, and a BOM ends up in the pull request.
    [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Remove-BodyFiles {
    foreach ($f in @($script:BodyFile, $script:SquashFile)) {
        if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

# Writes a "Label: value" block, wrapped, with continuations lined up under the value.
function Format-Field {
    param([string]$Label, [string]$Text, [int]$Width = 88)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $lines = @()
    $current = ''
    foreach ($word in ($Text -split '\s+')) {
        if ($word -eq '') { continue }
        if ($current -eq '') { $current = $word }
        elseif (($current.Length + 1 + $word.Length) -le $Width) { $current = "$current $word" }
        else { $lines += $current; $current = $word }
    }
    if ($current -ne '') { $lines += $current }

    $out = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $label = if ($i -eq 0) { $Label } else { '' }
        $out += ('{0,-10}{1}' -f $label, $lines[$i])
    }
    return $out
}

# --------------------------------------------------------------------------- context

$script:InWorktree  = $false
$script:Primary     = ''
$script:Root        = ''
$script:WtLocked    = ''
$script:BranchName  = ''
$script:BaseName    = ''
$script:BaseWhy     = ''
$script:ResolvedDefault = ''
$script:BaseNotes   = @()   # printed by preflight under the base line

function Get-RepoContext {
    # Every reason git refuses to read a repository here arrives as the same exit code,
    # and only git knows which one this is: a path outside a repository, and a checkout
    # owned by another user, read identically from here. So git's own line is what the
    # stop carries.
    $rev = @(Invoke-Quiet { git rev-parse --git-dir 2>&1 })
    if ($LASTEXITCODE -ne 0) {
        Stop-Now 'git will not read a repository here' ((Format-GitSaid (Get-GitSaid $rev)) + @(
            'run the script from inside the repository you are finishing work in. Where git',
            'names dubious ownership, the checkout belongs to another user - which a container,',
            'a sandbox, and a network or cloud-synced path all produce - and git reads it once',
            'the path is listed as safe, with the command it prints above'))
    }

    $gitDir    = (git rev-parse --path-format=absolute --git-dir)        | Select-Object -First 1
    $commonDir = (git rev-parse --path-format=absolute --git-common-dir) | Select-Object -First 1
    if ($gitDir -ne $commonDir) { $script:InWorktree = $true }

    $script:Root = (git rev-parse --path-format=absolute --show-toplevel) | Select-Object -First 1

    # The primary checkout is always the first record of the porcelain output, from
    # anywhere including inside a worktree. Read paths from here and never construct
    # them: worktree directory names have no reliable relationship to branch names.
    $path = ''
    foreach ($line in @(git worktree list --porcelain)) {
        if ($line -like 'worktree *') {
            $path = $line.Substring(9)
            if (-not $script:Primary) { $script:Primary = $path }
        }
        elseif ($line -like 'locked*' -and $path -eq $script:Root) {
            $reason = $line.Substring(6).Trim()
            $script:WtLocked = if ($reason) { $reason } else { '(no reason recorded)' }
        }
    }
}

function Get-WorktreeForBranch {
    param([string]$BranchRef)
    $want = "branch refs/heads/$BranchRef"
    $path = ''
    foreach ($line in @(git worktree list --porcelain)) {
        if ($line -like 'worktree *') { $path = $line.Substring(9) }
        elseif ($line -eq $want) { return $path }
    }
    return ''
}

function Get-LockReasonFor {
    param([string]$WorktreePath)
    $path = ''
    foreach ($line in @(git worktree list --porcelain)) {
        if ($line -like 'worktree *') { $path = $line.Substring(9) }
        elseif ($line -like 'locked*' -and $path -eq $WorktreePath) {
            $reason = $line.Substring(6).Trim()
            return $(if ($reason) { $reason } else { '(no reason recorded)' })
        }
    }
    return ''
}

function Test-RemoteRef {
    param([string]$Name)
    Invoke-Quiet { git rev-parse --verify -q "refs/remotes/origin/$Name" *> $null }
    return ($LASTEXITCODE -eq 0)
}

# Which branch this work merges into. Never hardcoded: workflow.conf's DEFAULT_BASE names
# the default (or origin/HEAD does), and ALT_BASES names every long-lived branch a feature
# branch may target instead. A branch whose history contains an alternate base is finished
# onto it. Where the answer is ambiguous the script refuses rather than guessing, because
# pointing a pull request at the wrong base is the one outcome the alternate-base rule
# exists to prevent. See finishing-work.md section 3 and starting-new-work.md section 4.3.
function Resolve-Base {
    if ($Base) {
        if (-not (Test-SafeRef $Base)) {
            Write-Host "-Base is not a valid branch name: $Base" -ForegroundColor Red
            exit 2
        }
        if (-not (Test-RemoteRef $Base)) {
            Stop-Now "origin/$Base does not exist" @('-Base must name a branch that exists on the remote')
        }
        $script:BaseName = $Base
        $script:BaseWhy  = 'given with -Base'
        return
    }

    if ($script:DefaultBase) {
        if (-not (Test-SafeRef $script:DefaultBase)) {
            Write-Host "workflow.conf: DEFAULT_BASE is not a valid branch name: $($script:DefaultBase)" -ForegroundColor Red
            exit 2
        }
        $default = $script:DefaultBase
    }
    else {
        $default = (git symbolic-ref -q --short refs/remotes/origin/HEAD) | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or -not $default) { $default = 'main' } else { $default = $default -replace '^origin/', '' }
    }
    $script:ResolvedDefault = $default

    # A prefix BASE_BY_PREFIX maps names its base outright - a hotfix/ branch that lands on
    # main while everything else lands on develop. Nothing in the history can say that as
    # reliably as the name the branch was given when it was claimed.
    foreach ($m in (Get-BaseMappings)) {
        if ($script:BranchName.StartsWith("$($m.Prefix)/")) {
            if (-not (Test-RemoteRef $m.Base)) {
                Stop-Now "origin/$($m.Base) does not exist" @(
                    "BASE_BY_PREFIX in scripts/workflow.conf maps $($m.Prefix)/ branches to it")
            }
            $script:BaseName = $m.Base
            $script:BaseWhy  = "the $($m.Prefix)/ prefix maps to $($m.Base) in workflow.conf"
            return
        }
    }

    # Every alternate base that exists on the remote and has diverged from the default is
    # a candidate. One that has not diverged is indistinguishable from the default, and
    # the default is the safe reading. So is one the default contains, such as a main that
    # develop merges from: every branch off the default contains it too.
    $defaultSha = ''
    if (Test-RemoteRef $default) { $defaultSha = (git rev-parse "refs/remotes/origin/$default") | Select-Object -First 1 }

    $candidates = @()
    foreach ($alt in (Get-ConfigItems $script:AltBases)) {
        if (-not (Test-SafeRef $alt)) {
            Write-Host "workflow.conf: ALT_BASES holds an invalid branch name: $alt" -ForegroundColor Red
            exit 2
        }
        if (-not (Test-RemoteRef $alt)) { continue }
        $altSha = (git rev-parse "refs/remotes/origin/$alt") | Select-Object -First 1
        if ($altSha -eq $defaultSha) { continue }
        if ($defaultSha) {
            Invoke-Quiet { git merge-base --is-ancestor $altSha $defaultSha *> $null }
            if ($LASTEXITCODE -eq 0) {
                $script:BaseNotes += "ALT_BASES lists $alt, which origin/$default contains, so it is ignored: name its branches with BASE_BY_PREFIX"
                continue
            }
        }
        $candidates += $alt
    }

    if ($candidates.Count -eq 0) {
        $script:BaseName = $default
        $script:BaseWhy  = 'the default branch'
        return
    }

    # An alternate base in this branch's history means the branch was cut from it.
    $contained = @()
    foreach ($alt in $candidates) {
        Invoke-Quiet { git merge-base --is-ancestor "refs/remotes/origin/$alt" HEAD *> $null }
        if ($LASTEXITCODE -eq 0) { $contained += $alt }
    }

    if ($contained.Count -eq 1) {
        $script:BaseName = $contained[0]
        $script:BaseWhy  = "this branch contains origin/$($contained[0]), an alternate base"
        return
    }

    if ($contained.Count -eq 0) {
        Invoke-Quiet { git merge-base --is-ancestor "refs/remotes/origin/$default" HEAD *> $null }
        if ($LASTEXITCODE -eq 0) {
            $script:BaseName = $default
            $script:BaseWhy  = 'the default branch'
            return
        }
    }

    # Either several alternate bases are in the history, or the branch is behind every
    # tip. Fall back to whichever it diverged from most recently, and refuse a tie.
    $pool = @($default) + $candidates
    if ($contained.Count -gt 1) { $pool = $contained }

    $best = ''; $bestN = -1; $tie = $false
    foreach ($alt in $pool) {
        $n = [int]((git rev-list --count "refs/remotes/origin/$alt..HEAD") | Select-Object -First 1)
        if ($bestN -lt 0 -or $n -lt $bestN) { $best = $alt; $bestN = $n; $tie = $false }
        elseif ($n -eq $bestN) { $tie = $true }
    }

    if ($tie) {
        Stop-Now 'cannot tell which base branch this branch targets' @(
            'more than one of these is equally distant from HEAD, and guessing would risk',
            'pointing the pull request at the wrong branch:',
            (($pool | ForEach-Object { "  origin/$_" }) -join "`n"),
            '',
            'Say which, explicitly:',
            '  .\scripts\finish.ps1 -Base <branch> ...')
    }

    $script:BaseName = $best
    $script:BaseWhy  = if ($best -eq $default) { 'the default branch' } else { "this branch diverged from origin/$best, an alternate base" }
}

# True when $Name is a branch this script must never finish from: main, master, the
# resolved base, the configured default, or any alternate base.
function Test-BaseBranch {
    param([string]$Name)
    if ($Name -in @('main', 'master', $script:BaseName)) { return $true }
    if ($script:DefaultBase -and $Name -eq $script:DefaultBase) { return $true }
    if ((Get-LongLivedBranches) -contains $Name) { return $true }
    return $false
}

# Every branch this repository treats as long-lived: the default, main and master, the
# alternate bases and the bases BASE_BY_PREFIX maps to.
function Get-LongLivedBranches {
    $all = @($script:ResolvedDefault, 'main', 'master') + @(Get-ConfigItems $script:AltBases) +
        @(Get-BaseMappings | ForEach-Object { $_.Base })
    return @($all | Where-Object { $_ } | Select-Object -Unique)
}

# A branch cut from one long-lived branch but resolving to another would have the wrong
# base merged into it by section 3, and its pull request would land it on the wrong
# branch. The sign is a fork point with another long-lived branch that the resolved base
# does not contain: the branch carries commits of that branch which are not on the base.
function Test-CutFrom {
    if ($script:BaseWhy -eq 'given with -Base') { return }
    foreach ($other in (Get-LongLivedBranches)) {
        if ($other -eq $script:BaseName) { continue }
        if (-not (Test-RemoteRef $other)) { continue }
        $fork = (Invoke-Quiet { git merge-base HEAD "refs/remotes/origin/$other" 2>$null }) | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or -not $fork) { continue }
        Invoke-Quiet { git merge-base --is-ancestor $fork "refs/remotes/origin/$($script:BaseName)" *> $null }
        if ($LASTEXITCODE -eq 0) { continue }
        $b = $script:BaseName
        Stop-Now "this branch was cut from origin/$other, but resolves to origin/$b" @(
            "origin/$b is the base here ($($script:BaseWhy)), but the branch",
            "carries commits of origin/$other that origin/$b does not have. Section 3 would",
            "merge origin/$b into it, and its pull request would land all of it on $b.",
            '',
            "If it belongs on $other, say so:  .\scripts\finish.ps1 -Base $other ...",
            "or give such branches a prefix that BASE_BY_PREFIX in scripts/workflow.conf maps to $other.",
            "If it belongs on $b, it was cut from the wrong branch: tell the user and wait")
    }
}

# --------------------------------------------------------------- section 1: preflight

$script:ClaimSha     = ''
$script:ClaimSubject = ''
$script:ClaimBody    = ''
$script:ScopeText    = ''
$script:ClaimTouches = ''
$script:Commits      = 0
$script:GhLogin      = ''

# Pulls one "Field: value" paragraph out of the claim commit body, joined onto one line.
function Get-ClaimField {
    param([string]$Name)
    $inBlock = $false
    $buffer  = ''
    foreach ($line in ($script:ClaimBody -split "`n")) {
        $line = $line.TrimEnd("`r")
        if (-not $inBlock -and $line -like "${Name}:*") {
            $inBlock = $true
            $buffer = ($line -replace "^${Name}:\s*", '')
            continue
        }
        if ($inBlock) {
            if ($line.Trim() -eq '') { break }
            $buffer = "$buffer $($line.Trim())"
        }
    }
    return $buffer.Trim()
}

# ----------------------------------------------------------------- project settings

# scripts\workflow.conf is the one file a project edits. KEY=value lines, no quoting, no
# expansion, read with a loop rather than dot-sourced so that a settings file can never
# run code. Every key has a default here, so a missing file changes nothing. The bash
# twin reads the same file.
$script:ProjectName        = 'this repository'
$script:DefaultBase        = ''
$script:AltBases           = ''
$script:BaseByPrefix       = ''
$script:BranchTypes        = 'feat,fix,spike,docs,chore'
$script:CheckCommand       = '.\scripts\check.ps1'
$script:Lockfiles          = 'Cargo.lock,package-lock.json,pnpm-lock.yaml,yarn.lock,poetry.lock,Gemfile.lock,go.sum,composer.lock'
$script:GoverningPaths     = '.gitattributes,.gitignore,.github/*,scripts/*'
$script:ScaffoldingPattern = ''
$script:LargeDiffLines     = 2000

function Import-WorkflowConfig {
    $conf = Join-Path $PSScriptRoot 'workflow.conf'
    if (-not (Test-Path -LiteralPath $conf)) { return }

    foreach ($raw in @(Get-Content -LiteralPath $conf)) {
        $line = "$raw".TrimEnd("`r")
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) {
            Write-Host "workflow.conf: not a KEY=value line: $line" -ForegroundColor Red
            exit 2
        }
        $key   = $line.Substring(0, $eq)
        $value = $line.Substring($eq + 1)
        switch ($key) {
            'PROJECT_NAME'          { if ($value) { $script:ProjectName = $value } }
            'DEFAULT_BASE'          { $script:DefaultBase = $value }
            'ALT_BASES'             { $script:AltBases = $value }
            'BASE_BY_PREFIX'        { $script:BaseByPrefix = $value }
            'BRANCH_TYPES'          { if ($value) { $script:BranchTypes = $value } }
            'CHECK_COMMAND'         { }   # read by the bash twin
            'CHECK_COMMAND_WINDOWS' { if ($value) { $script:CheckCommand = $value } }
            'LOCKFILES'             { $script:Lockfiles = $value }
            'GOVERNING_PATHS'       { $script:GoverningPaths = $value }
            'SCAFFOLDING_PATTERN'   { $script:ScaffoldingPattern = $value }
            'LARGE_DIFF_LINES'      { if ($value) { $script:LargeDiffLines = $value } }
            default {
                Write-Host "workflow.conf: unknown key '$key'" -ForegroundColor Red
                exit 2
            }
        }
    }

    if ("$($script:LargeDiffLines)" -notmatch '^[0-9]+$') {
        Write-Host 'workflow.conf: LARGE_DIFF_LINES must be a whole number' -ForegroundColor Red
        exit 2
    }
    $script:LargeDiffLines = [int]$script:LargeDiffLines

    foreach ($pair in (Get-ConfigItems $script:BaseByPrefix)) {
        if ($pair -notmatch '^[^:]+:[^:]+$') {
            Write-Host "workflow.conf: BASE_BY_PREFIX entries are prefix:base, not '$pair'" -ForegroundColor Red
            exit 2
        }
        $parts = $pair -split ':'
        if (-not (Test-SafeRef $parts[0]) -or -not (Test-SafeRef $parts[1])) {
            Write-Host "workflow.conf: BASE_BY_PREFIX holds an invalid branch name: $pair" -ForegroundColor Red
            exit 2
        }
    }
}

# The BASE_BY_PREFIX pairs, as objects with a Prefix and a Base.
function Get-BaseMappings {
    foreach ($pair in (Get-ConfigItems $script:BaseByPrefix)) {
        $parts = $pair -split ':', 2
        [pscustomobject]@{ Prefix = $parts[0]; Base = $parts[1] }
    }
}

# A comma-separated value as an array of trimmed, non-empty items.
function Get-ConfigItems {
    param([string]$Value)
    return @(($Value -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

# Runs after the scans. Every name -Declare gave must be one a scan asked about.
function Test-Declarations {
    if ($script:Declared.Count -eq 0) { return }
    foreach ($item in $script:Declared) {
        if ($script:DeclaredAsked -contains $item) { continue }
        Write-Host "-Declare names something no scan asked for: $item" -ForegroundColor Red
        Write-Host 'it can only declare what a scan stopped on this run, so that it cannot be used'
        Write-Host 'to pre-authorise anything.'
        if ($script:DeclaredAsked.Count -gt 0) {
            Write-Host 'Asked for this run:'
            foreach ($a in $script:DeclaredAsked) { Write-Host "  $a" }
        } else {
            Write-Host 'Nothing asked for a declaration this run.'
        }
        exit 2
    }
}

# ------------------------------------------------------- environment capabilities

# scripts/env-capabilities.ps1 answers "what can this session actually do", so that a
# session which cannot run gh is routed to the tool that does work there instead of being
# handed an install instruction it cannot follow. See the header of that file for why it
# probes the tool rather than trusting an environment variable.
#
# The bash twin of this block is in scripts/finish.sh and the two must stay in step.
$script:CapsLoaded           = $false
$script:CapGh                = 0
$script:EnvTier              = 'workstation-incomplete'
$script:EnvLabel             = 'workstation without a usable gh'
$script:EnvRoute             = ''
$script:CapRemoteBranchDel   = 1

function Import-Capabilities {
    if ($script:CapsLoaded) { return }

    $probe = Join-Path $PSScriptRoot 'env-capabilities.ps1'
    if (Test-Path -LiteralPath $probe) {
        . $probe
        $script:CapGh              = $CapGh
        $script:EnvTier            = $EnvTier
        $script:EnvLabel           = $EnvLabel
        $script:EnvRoute           = $EnvRoute
        $script:CapRemoteBranchDel = $CapRemoteBranchDelete
    }
    else {
        # The probe improves the message; it is never a precondition for the script. A
        # checkout missing it behaves exactly as this script did before the file existed.
        $script:EnvRoute = @'
gh is not installed, or is installed but not authenticated.

  install     see docs/development/setting-up.md section 3.3
  then        gh auth login
'@
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            Invoke-Quiet { gh auth status *> $null }
            if ($LASTEXITCODE -eq 0) {
                $script:CapGh    = 1
                $script:EnvTier  = 'workstation'
                $script:EnvLabel = 'workstation with an authenticated gh'
                $script:EnvRoute = ''
            }
        }
    }
    $script:CapsLoaded = $true
}

# The gh gate. This was two unconditional stops, which is why a cloud session got told to
# install a tool it cannot install and then had to discover the rest of the wall by
# hitting it. The stop now depends on what this session can do and on which stage needs it.
#
# This grants nothing. -Pr stops short of opening the pull request, and -Merge cannot
# proceed without a route to GitHub; both name the route that exists here.
function Assert-GithubRoute {
    if ($script:CapGh -eq 1) { return }

    if ($script:Stage -eq 'report') {
        Write-Fine ("github        no gh here - {0}" -f $script:EnvLabel)
        Write-Fine 'every check below is local, so the report is complete either way'
        return
    }

    # -Pr without gh is worth running rather than refusing. Section 3 and the push are pure
    # git and work anywhere; what cannot run is the last command of the stage. Stopping in
    # preflight would throw away the part of this stage that is hardest to do by hand - the
    # title and the body, where the evidence and the Testing line live - so the stage
    # proceeds and New-PullRequest hands off where gh would have run.
    if ($script:Stage -eq 'pr') {
        Write-Fine ("github        no gh here - {0}" -f $script:EnvLabel)
        Write-Fine 'this stage will update from the base, push, and build the pull request, then'
        Write-Fine 'hand the pull request itself to you'
        return
    }

    # Split on "\r?\n" rather than "`n": .gitattributes checks .ps1 files out CRLF, so the
    # here-string this came from carries carriage returns that would otherwise survive
    # into the middle of the printed lines.
    if ($script:EnvTier -eq 'cloud-agent' -or $script:EnvTier -eq 'no-github-remote') {
        Stop-Now ("this stage needs a route to GitHub, and there is none in a {0}" -f $script:EnvLabel) `
            (@('') + ($script:EnvRoute -split "\r?\n"))
    }
    else {
        Stop-Now 'gh is not installed, or is not authenticated' ($script:EnvRoute -split "\r?\n")
    }
}

function Invoke-Preflight {
    $script:CurSection = 1
    Write-Head 'Preflight'

    $remotes = @(git remote)
    if ($remotes -notcontains 'origin') {
        Stop-Now 'there is no remote called origin' @(
            'this script talks to origin by name, as the whole document does')
    }

    $script:BranchName = (git symbolic-ref -q --short HEAD) | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or -not $script:BranchName) {
        Stop-Now 'HEAD is detached' @(
            'you are not on a branch, so there is nothing to finish',
            'git switch <your-branch> first')
    }

    Import-Capabilities
    Assert-GithubRoute

    # The fetch is the one mutating command -DryRun still performs. Every answer below,
    # the base branch included, depends on remote-tracking refs being current, and the
    # document's own rule is that a check against a stale remote is worse than no check
    # because it answers with authority.
    Invoke-FetchAll

    Resolve-Base

    if (Test-BaseBranch $script:BranchName) {
        Stop-Now "you are on $($script:BranchName)" @(
            'this script finishes a feature branch. It never pushes to a base branch, and',
            'section 5 of the document is explicit that there is no situation where pushing',
            'straight to a base branch is the answer')
    }

    $dirty = @(git status --porcelain)
    if ($dirty.Count -gt 0) {
        Stop-Now 'the working tree is not clean' @(
            'uncommitted work exists in exactly one place, so this script will not stash it,',
            'sweep it into a commit, or switch branches over it. Decide what those changes are',
            'for, then re-run:',
            '',
            (($dirty | Select-Object -First 10 | ForEach-Object { "  $_" }) -join "`n"))
    }

    if (-not (Test-RemoteRef $script:BaseName)) {
        Stop-Now "origin/$($script:BaseName) does not exist" @(
            'name the base branch with DEFAULT_BASE in scripts/workflow.conf')
    }

    Test-CutFrom

    $script:Commits = [int]((git rev-list --count "origin/$($script:BaseName)..HEAD") | Select-Object -First 1)
    if ($script:Commits -eq 0) {
        Stop-Now "this branch has no commits that origin/$($script:BaseName) does not already have" @(
            'there is nothing here to finish')
    }

    # The claim commit is the first commit off the base branch.
    $script:ClaimSha     = @(git rev-list --reverse --topo-order "origin/$($script:BaseName)..HEAD")[0]
    $script:ClaimSubject = (git log -1 --format=%s $script:ClaimSha) | Select-Object -First 1
    $script:ClaimBody    = (git log -1 --format=%B $script:ClaimSha) -join "`n"

    $claimAuthor = (git log -1 --format='%an <%ae>' $script:ClaimSha) | Select-Object -First 1
    $meName  = (git config user.name)  | Select-Object -First 1
    $meEmail = (git config user.email) | Select-Object -First 1

    if (-not $meName -or -not $meEmail) {
        Stop-Now 'your git identity is not set' @(
            'the claim-commit author check cannot run without it:',
            '  git config --global user.name "Your Name"',
            '  git config --global user.email "you@example.com"')
    }

    $me = "$meName <$meEmail>"
    if ($claimAuthor -ne $me) {
        Stop-Now 'you did not create this branch' @(
            "the claim commit was written by $claimAuthor",
            "you are $me",
            "the claim commit is the first commit after origin/$($script:BaseName) ($($script:BaseWhy))",
            '',
            "finishing someone else's work is their decision and their timing - they may know",
            'something about it that you do not. Tell them it looks ready and wait')
    }

    $script:ScopeText = if ($Scope) { $Scope } else { Get-ClaimField 'Scope' }
    $script:ClaimTouches = Get-ClaimField 'Touches'

    if ($script:ClaimSubject -notlike 'claim:*' -and -not $script:ScopeText) {
        Stop-Now 'the first commit on this branch is not a claim commit' @(
            "its subject is: $($script:ClaimSubject)",
            'starting-new-work.md section 4.4 says the first commit off the base branch',
            'declares the scope, and this script reads it to write the pull request body.',
            'Either that step was skipped, or the base branch resolved wrongly.',
            '',
            'If the branch is genuinely fine, supply the scope directly:',
            '  .\scripts\finish.ps1 -Scope "what this branch does"')
    }

    # Only reachable without gh on the bare run, which Assert-GithubRoute lets through.
    # Left empty rather than guessed: the merge stage compares it against the pull
    # request's author to enforce "never merge a pull request you did not open", and a
    # fabricated login would defeat that check rather than degrade it.
    if ($script:CapGh -eq 1) {
        # Judged by exit code and by what came back: Windows PowerShell 5.1 does not apply
        # $ErrorActionPreference to a native command, so a failed `gh api user` would
        # otherwise leave this empty and let the run continue.
        $userOut = @(Invoke-Quiet { gh api user --jq .login 2>&1 })
        $userRc  = $LASTEXITCODE
        $script:GhLogin = Get-GhOutput $userOut | Select-Object -First 1
        if ($userRc -ne 0 -or -not $script:GhLogin) {
            $ghSaid = Get-GhError $userOut
            $said = @()
            if ($ghSaid) { $said = @("gh said: $ghSaid") }
            Stop-Now 'gh could not read your GitHub login' ($said + @(
                'it is the gh session that failed here, not your identity: the token may be missing',
                'the read:user scope, an SSO authorisation may have lapsed, or GitHub may have',
                'answered with an error. Check the session, and log in again if it asks you to:',
                '',
                '  gh auth status',
                '  gh auth login',
                '',
                'docs/development/setting-up.md section 3.3 has the prompts and the answers. The',
                "merge stage compares this login against the pull request's author to enforce",
                '"never merge a pull request you did not open", so it is never guessed'))
        }
    }

    Write-Fine ("branch        {0}" -f $script:BranchName)
    Write-Fine ("base          origin/{0}  ({1})" -f $script:BaseName, $script:BaseWhy)
    foreach ($n in $script:BaseNotes) { Write-Action ("note          {0}" -f $n) }
    Write-Fine ("commits       {0} ahead of origin/{1}" -f $script:Commits, $script:BaseName)
    Write-Fine ("claim         {0}" -f $script:ClaimSubject)
    Write-Fine ("author        {0}" -f $claimAuthor)
    if ($script:GhLogin) { Write-Fine ("github        {0}" -f $script:GhLogin) }
    if ($script:InWorktree) {
        Write-Fine ("worktree      {0}" -f $script:Root)
        Write-Fine ("primary       {0}" -f $script:Primary)
    }
}

# ------------------------------------------------------- section 2: is it finished?

$script:HasCi       = $false
$script:HasBuild    = @()

# Returns one object per added line in the diff: Path, Line, Content.
function Get-AddedLines {
    $file = ''
    $ln   = 0
    $out  = New-Object System.Collections.ArrayList
    foreach ($raw in @(git diff "origin/$($script:BaseName)...HEAD" -U0)) {
        if ($raw -like '+++ *') {
            $file = $raw -replace '^\+\+\+ b/', ''
            continue
        }
        if ($raw -like '@@ *') {
            if ($raw -match '\+(\d+)') { $ln = [int]$Matches[1] }
            continue
        }
        if ($raw.StartsWith('+')) {
            [void]$out.Add([pscustomobject]@{ Path = $file; Line = $ln; Content = $raw.Substring(1) })
            $ln++
        }
    }
    return $out
}

function Test-BinaryAttr {
    param([string]$Path)
    $attr = (git check-attr binary -- $Path) | Select-Object -First 1
    return ($attr -like '*: binary: set')
}

# True when $Path is one of workflow.conf's LOCKFILES, by file name anywhere in the tree.
function Test-Lockfile {
    param([string]$Path)
    $name  = $Path
    $slash = $Path.LastIndexOf('/')
    if ($slash -ge 0) { $name = $Path.Substring($slash + 1) }
    return ((Get-ConfigItems $script:Lockfiles) -ccontains $name)
}

# True when $Path matches one of workflow.conf's GOVERNING_PATHS, which are glob patterns
# from the repository root. -like's `*` also matches `/`, so `.github/*` covers the tree.
function Test-GoverningPath {
    param([string]$Path)
    foreach ($gp in (Get-ConfigItems $script:GoverningPaths)) {
        if ($Path -clike $gp) { return $true }
    }
    return $false
}

function Invoke-PathScan {
    $added   = @(git diff --name-only --diff-filter=A "origin/$($script:BaseName)...HEAD")
    $changed = @(git diff --name-only "origin/$($script:BaseName)...HEAD")

    foreach ($path in $changed) {
        if (-not $path) { continue }
        if ($path -match '(^|/)\.env($|\.)|\.pem$|\.key$|(^|/)id_rsa|\.p12$|\.pfx$') {
            Add-Finding 'credentials' "$path - credentials do not belong in the repository"
            Add-Flagged $path
            continue
        }
        if ($path -match '^\.vscode/|^\.idea/|\.swp$|(^|/)\.DS_Store$|(^|/)Thumbs\.db$') {
            Add-Finding 'editor or OS' "$path - personal config, not a project change"
            Add-Flagged $path
            continue
        }
        if (Test-Lockfile $path) {
            Add-Finding 'lockfile' "$path - a new dependency is a review question, not housekeeping"
            Add-Flagged $path
        }
        elseif (Test-GoverningPath $path) {
            Add-Finding 'repo-governing' "$path - changes the rules everyone else works under"
            Add-Flagged $path
        }
    }

    # Binary additions, read from the repository's own .gitattributes rather than a
    # hardcoded extension list that would drift away from it. The `binary` attribute is
    # shorthand for -diff -merge -text, and the -merge half is what makes these files a
    # human decision under section 3.
    foreach ($path in $added) {
        if (-not $path) { continue }
        if (Test-BinaryAttr $path) {
            Add-Finding 'binary file' "$path - marked unmergeable by .gitattributes; single-writer file"
            $script:Flagged += $path
        }
    }

    $shortstat = (git diff --shortstat "origin/$($script:BaseName)...HEAD") | Select-Object -First 1
    if ($shortstat) {
        $total = 0
        foreach ($m in [regex]::Matches($shortstat, '(\d+) (?:insertion|deletion)')) {
            $total += [int]$m.Groups[1].Value
        }
        if ($total -gt $script:LargeDiffLines) {
            Add-Finding 'large diff' "$total changed lines - large diffs hide things"
        }
    }
}

function Invoke-ScaffoldingScan {
    # Language-neutral leftovers first, then the common per-language ones. A project adds
    # its own with SCAFFOLDING_PATTERN in workflow.conf rather than by editing this line.
    $re  = 'TODO:? ?remove|FIXME|XXX|HACK|debugger;|\.only\(|console\.log\(|C:\\\\|/Users/|/home/'
    $re += '|dbg!\(|println!\(|eprintln!\(|todo!\(|unimplemented!\(|#\[ignore\]'
    $re += '|breakpoint\(\)|pdb\.set_trace|binding\.pry|byebug'
    if ($script:ScaffoldingPattern) { $re += '|' + $script:ScaffoldingPattern }
    # The shipped scripts quote these patterns in their own text, so adopting or updating
    # them would otherwise report the workflow's own files as leftovers.
    $shipped = '^scripts/((finish|setup|env-capabilities)\.(sh|ps1)|finish-project\.(sh|ps1)\.example)$'
    # The content field, never the path: a repository with a directory named home/ or
    # Users/ would otherwise have every added line under it reported as scaffolding.
    $hits = @(Get-AddedLines | Where-Object { $_.Path -cnotmatch $shipped -and $_.Content -cmatch $re } |
              ForEach-Object { "$($_.Path):$($_.Line)" } | Select-Object -Unique)
    if ($hits.Count -gt 0) {
        Add-Finding 'debug scaffolding' "$($hits.Count) added line(s) look like leftovers:"
        foreach ($h in ($hits | Select-Object -First 12)) { Write-Plain "  $h" }
    }
}

function Invoke-SecretScan {
    # Deliberately conservative: over-reporting a secret is safe, missing one is not.
    #
    # Two patterns, because only one of them can be narrowed. A vendor prefix is
    # unambiguous: a line carrying one is a hit whatever else the line says.
    $vendor = 'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|gh[ousr]_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-|AIza[0-9A-Za-z_-]{35}'

    # The generic pattern claims that a value is a literal credential. Its alphabet holds no
    # $, {, ( or <, so ${VAR}, getenv(...), os.environ[...] and <PLACEHOLDER> cannot match.
    $generic = '(secret|token|passwd|password|api[_-]?key)\s*[:=]\s*["'']?[A-Za-z0-9_+/=.-]{12,}'

    # Each entry is a claim about a value that names a credential rather than carrying one:
    # an environment accessor reads it where the program runs and holds nothing itself. This
    # narrows the generic pattern alone, so it can never hide a vendor prefix. Do not widen
    # it to clear a stop - a stop clearable only by asserting something false teaches people
    # to assert it.
    $reference = 'os\.environ|os\.getenv|process\.env|import\.meta\.env|deno\.env|system\.getenv|getenv|env\.fetch'

    $hits = @(Get-AddedLines | Where-Object {
                  ($_.Content -imatch $vendor) -or
                  (($_.Content -imatch $generic) -and ($_.Content -inotmatch $reference))
              } | ForEach-Object { "$($_.Path):$($_.Line)" } | Select-Object -Unique)
    if ($hits.Count -gt 0) {
        # The matched text is never printed. A script that echoes a credential into a
        # terminal log, a CI log or an agent transcript has made the problem worse.
        Stop-Now 'an added line looks like a credential' @(
            'the matched text is deliberately not shown - printing it would spread it further.',
            'Look at these lines yourself:',
            '',
            (($hits | Select-Object -First 20 | ForEach-Object { "  $_" }) -join "`n"),
            '',
            'If it is a false positive, the fix is to change the line so it does not read as a',
            'secret. There is no flag to wave this through, and that is deliberate')
    }
}


function Test-BuildSystem {
    $script:HasBuild = @()
    foreach ($f in @('Cargo.toml', 'package.json', 'pyproject.toml', 'go.mod', 'pom.xml', 'Makefile')) {
        if (Test-Path -LiteralPath (Join-Path $script:Root $f)) { $script:HasBuild += $f }
    }
    # The project's own check command counts when it is a file in the repository, as the
    # default .\scripts\check.ps1 is: a repository with one has something to run.
    $first = (($script:CheckCommand -split ' ')[0]) -replace '^\.[\\/]', ''
    if ($first -and -not [System.IO.Path]::IsPathRooted($first) -and $first -notlike '*..*') {
        if (Test-Path -LiteralPath (Join-Path $script:Root $first) -PathType Leaf) {
            $script:HasBuild += ($first -replace '\\', '/')
        }
    }
    if (Test-Path -LiteralPath (Join-Path $script:Root '.github/workflows')) { $script:HasCi = $true }
}

function Invoke-FinishedChecks {
    $script:CurSection = 2
    Write-Head 'Evidence for you to judge - not a verdict'

    Write-Plain 'Claim:'
    foreach ($line in ($script:ClaimBody.TrimEnd() -split "`n")) { Write-Host ("    {0}" -f $line.TrimEnd()) }
    Write-Host ''

    Write-Plain 'Files actually changed:'
    foreach ($line in @(git diff --stat "origin/$($script:BaseName)...HEAD")) { Write-Host ("    {0}" -f $line) }
    Write-Host ''

    # Claim Touches versus reality. The difference between the two is often the most
    # informative thing about a branch.
    if ($script:ClaimTouches) {
        Write-Fine ("claimed to touch: {0}" -f $script:ClaimTouches)
    } else {
        Add-Finding 'no Touches' 'the claim commit has no Touches: field to compare against'
    }

    Invoke-PathScan
    Invoke-ScaffoldingScan
    Invoke-SecretScan
    if (Get-Command Invoke-ProjectScans -ErrorAction SilentlyContinue) { Invoke-ProjectScans }
    Test-Declarations
    # The title is built here rather than at section 4, so that a branch name it cannot use
    # is a finding in the bare report, while there is still time to pass -Title.
    Build-PrTitle
    Test-BuildSystem

    if ($script:HasBuild.Count -eq 0 -and -not $script:HasCi) {
        Write-Fine 'checks        no build system and no CI on this branch - there is nothing to run'
    } else {
        $found = @($script:HasBuild)
        if ($script:HasCi) { $found += '.github/workflows' }
        Write-Fine ("checks        found {0} - this script did not run them, and does not claim to" -f ($found -join ', '))
        if ($script:HasCi) {
            Write-Fine '              CI runs them on the pull request, and -Merge refuses to land on a failing one'
        }
    }

    Write-Host ''
    if ($script:Findings -eq 0) {
        Write-Good 'No findings. That is not an approval - read the diff above.'
    } else {
        Write-Action ("{0} finding(s). None of this is an approval." -f $script:Findings)
    }
}

# The acknowledgement gate. Not an override: it can only name paths this run flagged, it
# has to be re-supplied every run because the flagged set is recomputed from the actual
# diff, and what was acknowledged is written into the pull request body where a human
# reviewer sees it. Scaffolding findings deliberately do not gate - gating on them would
# train people to acknowledge reflexively, which is how a gate stops working.
$script:Acknowledged = @()

function Test-Acknowledgements {
    if ($script:Flagged.Count -eq 0) { return }

    if ($Acknowledge) {
        foreach ($item in ($Acknowledge -split ',')) {
            $item = $item.Trim()
            if (-not $item) { continue }
            if ($script:Flagged -notcontains $item) {
                Write-Host "-Acknowledge names a path this run did not flag: $item" -ForegroundColor Red
                Write-Host 'it can only acknowledge findings that actually appeared, so that it cannot be'
                Write-Host 'used to pre-authorise anything. Flagged this run:'
                foreach ($f in $script:Flagged) { Write-Host "  $f" }
                exit 2
            }
            $script:Acknowledged += $item
        }
    }

    $unacked = @($script:Flagged | Where-Object { $script:Acknowledged -notcontains $_ } | Select-Object -Unique)
    if ($unacked.Count -gt 0) {
        Stop-Now 'some changed files need a decision before this opens a pull request' @(
            'these were flagged above. Look at each one, and if it belongs in the branch, say so:',
            '',
            (($unacked | ForEach-Object { "  $_" }) -join "`n"),
            '',
            ('  .\scripts\finish.ps1 -Pr -Testing "{0}" -Acknowledge "{1}"' -f $Testing, ($unacked -join ',')),
            '',
            'What you acknowledge goes into the pull request body, where a reviewer sees it')
    }
}

# --------------------------------------------------- section 3: bring up to date

# Whether a merge is in progress. Git sets MERGE_HEAD for the duration of one and removes
# it when the merge ends, whichever way it ends, so the ref is the whole answer. Read from
# the ref, never from git's message, which is translated.
function Test-MergeInProgress {
    Invoke-Quiet { git rev-parse -q --verify MERGE_HEAD *> $null }
    return ($LASTEXITCODE -eq 0)
}

function Update-FromBase {
    $script:CurSection = 3
    Write-Head "Bringing the branch up to date with origin/$($script:BaseName)"

    # Section 3 opens with `git fetch origin`; preflight already did a wider fetch seconds
    # ago, so repeating it would only add a second way to fail.
    $rc = Invoke-Mutating 'git' @('merge', "origin/$($script:BaseName)")
    if ($rc -eq 0) {
        # Do not claim a clean merge that was never attempted. A dry run that reports
        # success it did not earn is worse than no dry run at all.
        if ($DryRun) {
            Write-Fine 'not attempted (dry run) - whether this merges cleanly is still unknown'
        } else {
            Write-Good 'merged cleanly'
        }
        return
    }

    # Capture the conflict before aborting - afterwards there is nothing left to report. The
    # exit code alone does not say a merge conflicted: a hook that refuses it, histories with
    # nothing in common, a merge driver and local changes the merge would overwrite all fail
    # with no file conflicted. This list is what tells the two apart.
    $conflicted = @(git diff --name-only --diff-filter=U | Where-Object { $_ })

    if ($conflicted.Count -gt 0) {
        Write-Host ''
        Write-Host 'Conflicts:' -ForegroundColor Red
        foreach ($path in $conflicted) {
            if (Test-BinaryAttr $path) {
                Write-Host ("  {0,-50} binary - these do not merge, one side wins" -f $path)
            } else {
                $who = (git log -1 --format=%an "origin/$($script:BaseName)" -- $path) | Select-Object -First 1
                if (-not $who) { $who = 'unknown' }
                Write-Host ("  {0,-50} other side last written by {1}" -f $path, $who)
            }
        }
    }

    $abortRc = Invoke-Mutating 'git' @('merge', '--abort')

    # What the abort left behind is read from the repository, not assumed from having asked
    # for it. An abort can fail - on Windows a process holding one of the files open is
    # enough - and a branch called untouched while a merge is still in progress is a branch
    # walked away from in that state.
    if (Test-MergeInProgress) {
        $recovery = @(
            'git merge --abort did not end the merge: MERGE_HEAD is still set, so the merge is',
            'still in progress and the working tree holds part of it. Nothing here touches it',
            'further. Read what is in the tree, then end the merge yourself:',
            '  git status',
            '  git merge --abort')
    }
    elseif ($abortRc -ne 0) {
        $recovery = @(
            'git merge --abort failed, and no merge is in progress: what the working tree holds',
            'is what git left in it. Read that before anything else:',
            '  git status')
    }
    else {
        $recovery = @('the merge has been aborted, so the branch is exactly as it was.')
    }

    if ($conflicted.Count -eq 0) {
        Stop-Now 'the merge failed without conflicting' ($recovery + @(
            '',
            'No file is conflicted, so there is nothing here to resolve. What refused the merge is',
            "in git's own output above this stop - a hook, histories with nothing in common, a",
            'merge driver, or local changes the merge would overwrite. This script does not read',
            'that message for you: it is translated, and a guess at the cause sends you after the',
            'wrong one.',
            '',
            'Act on what git said, following section 3, then run this stage again'))
    }

    Stop-Now 'the merge conflicts' ($recovery + @(
        '',
        'This script does not resolve conflicts, including in files you wrote. A conflict is a',
        'question about intent, and resolving one by picking whichever side looks more complete',
        'is how half a feature disappears without a single error message.',
        '',
        'Resolve it yourself following section 3, or talk to whoever wrote the other side'))
}

# ------------------------------------------------------ section 4: open the pull request

$script:PrNumber = ''
$script:PrUrl    = ''
$script:PrTitle  = ''

# The branch-name prefix, from workflow.conf's BRANCH_TYPES. Empty when none matches.
function Get-PrType {
    foreach ($t in (@(Get-ConfigItems $script:BranchTypes) + @(Get-BaseMappings | ForEach-Object { $_.Prefix }))) {
        if ($script:BranchName.StartsWith("$t/")) { return $t }
    }
    return ''
}

function Build-PrTitle {
    if ($Title) {
        if (-not (Test-SafeTitle $Title)) {
            Write-Host '-Title must not contain a double quote or a newline' -ForegroundColor Red
            exit 2
        }
        $script:PrTitle = $Title
        return
    }

    $type    = Get-PrType
    $outcome = $script:ClaimSubject -replace '^claim:\s*', ''

    if (-not $type) {
        Add-Finding 'branch name' "$($script:BranchName) does not start with a type from workflow.conf ($($script:BranchTypes))"
        Write-Fine ('                   the title will be "{0}" - pass -Title to choose it' -f $outcome)
        $script:PrTitle = $outcome
    } else {
        $script:PrTitle = "${type}: $outcome"
    }

    if (-not (Test-SafeTitle $script:PrTitle)) {
        Stop-Now 'the claim commit subject cannot be used as a pull request title' @(
            'it contains a double quote or a newline. Pass one with -Title')
    }
}

function Build-PrBody {
    $touches   = (@(git diff --name-only "origin/$($script:BaseName)...HEAD")) -join ', '
    $shortstat = (git diff --shortstat "origin/$($script:BaseName)...HEAD") | Select-Object -First 1

    $plus = 0; $minus = 0
    if ($shortstat) {
        if ($shortstat -match '(\d+) insertion') { $plus  = [int]$Matches[1] }
        if ($shortstat -match '(\d+) deletion')  { $minus = [int]$Matches[1] }
    }

    # $noteLines, not $notes. PowerShell variable names are case-insensitive, so a local
    # called $notes IS the $Notes parameter - `$notes = @()` would silently empty it and
    # the caller's -Notes text would vanish from the pull request without any error.
    # Every local in this file is named so that it cannot collide with a parameter.
    $noteLines = @()
    if ($Notes) { $noteLines += $Notes }
    if ($script:Acknowledged.Count -gt 0) { $noteLines += "Reviewed and intended: $($script:Acknowledged -join ', ')" }
    if ($script:DeclaredUsed.Count -gt 0) { $noteLines += "Declared with -Declare: $($script:DeclaredUsed -join ', ')" }
    foreach ($extra in $script:NotesExtra) { $noteLines += $extra }
    if ($script:HasBuild.Count -eq 0 -and -not $script:HasCi) {
        $noteLines += 'No build system or CI on this branch - nothing to run locally.'
    }

    $lines = @()
    $lines += Format-Field 'Scope:'   $script:ScopeText
    $lines += Format-Field 'Touches:' ("$touches (+$plus -$minus)").Trim()
    $lines += Format-Field 'Testing:' $Testing
    for ($i = 0; $i -lt $noteLines.Count; $i++) {
        $lines += Format-Field $(if ($i -eq 0) { 'Notes:' } else { '' }) $noteLines[$i]
    }

    $script:BodyFile = New-BodyFile $lines
    return $lines
}

function New-PullRequest {
    $script:CurSection = 4
    Write-Head 'Opening the pull request'

    # @tsv, not a hand-built "\(.a)`t\(.b)" string: inside single quotes PowerShell does
    # not interpret backtick escapes, so the tab would reach jq as a literal backtick-t
    # and the whole expression would fail - leaving the script about to open a duplicate
    # pull request.
    $existing = $null
    if ($script:CapGh -eq 1) {
        $existing = (Invoke-Quiet { gh pr view $script:BranchName --json number,state,url --jq '[.number,.state,.url]|@tsv' 2>$null }) | Select-Object -First 1
    }
    if ($script:CapGh -eq 1 -and $LASTEXITCODE -eq 0 -and $existing) {
        $parts = $existing -split "`t"
        $script:PrNumber = $parts[0]
        $script:PrUrl    = $parts[2]
        if ($parts[1] -eq 'OPEN') {
            # Refresh the body rather than leaving it as it was. Touches and the diff
            # counts are computed from the branch, so after another commit the old body
            # is quietly wrong - and a stale Touches line is exactly what section 4 says
            # the body exists to get right.
            if (-not $script:PrTitle) { Build-PrTitle }
            [void](Build-PrBody)
            $rc = Invoke-Mutating 'gh' @('pr', 'edit', $script:PrNumber, '--body-file', $script:BodyFile)
            if ($rc -ne 0) { Stop-Now "gh pr edit failed for pull request #$($script:PrNumber)" }
            # Invoke-Mutating returns success under -DryRun without running anything, so
            # this reports the push and the refresh only where they happened.
            if ($DryRun) {
                Write-Fine "pull request #$($script:PrNumber) is already open - not updated (dry run)"
                Write-Fine 'a real run pushes the branch and refreshes its body'
            } else {
                Write-Good "pull request #$($script:PrNumber) already open - pushed the update and refreshed its body"
            }
            Write-Plain $script:PrUrl
            return
        }
        Stop-Now "a pull request already exists for this branch and its state is $($parts[1])" @(
            $script:PrUrl,
            'this script will not reopen it')
    }

    if (-not $script:PrTitle) { Build-PrTitle }
    $bodyLines = Build-PrBody

    Write-Plain ("title  {0}" -f $script:PrTitle)
    Write-Host ''
    foreach ($line in $bodyLines) { Write-Host ("    {0}" -f $line) }
    Write-Host ''

    # The hand-off. Everything section 4 needs has been computed and the branch is pushed;
    # only the call that opens the pull request cannot be made from here. Print exactly
    # what to open it with, then exit 3 - "not yet", the same code Stop-RetryLater uses,
    # so a caller can tell an unfinished stage from a refused one.
    if ($script:CapGh -ne 1) {
        Write-Head 'Opening it from here'
        if ($DryRun) {
            Write-Plain 'Dry run: nothing was pushed, so there is nothing to open yet. Re-run without'
            Write-Plain '-DryRun first. What that would print is:'
        }
        elseif ($script:EnvTier -eq 'cloud-agent') {
            Write-Plain 'The branch is pushed and the body above is what the pull request needs. gh'
            Write-Plain ("cannot run in a {0}, so open it with your agent's GitHub tool instead" -f $script:EnvLabel)
            Write-Plain '(in Claude Code, mcp__github__create_pull_request):'
        }
        else {
            Write-Plain 'The branch is pushed and the body above is what the pull request needs. gh'
            Write-Plain 'cannot open it from here, so open it by hand with these values:'
        }
        Write-Host ''
        Write-Plain ("    base   {0}" -f $script:BaseName)
        Write-Plain ("    head   {0}" -f $script:BranchName)
        Write-Plain ("    title  {0}" -f $script:PrTitle)
        Write-Plain '    body   the block printed above, verbatim'
        if ($Draft) { Write-Plain '    draft  true' }
        Write-Host ''
        if ($script:EnvTier -eq 'cloud-agent') {
            Write-Plain 'Then merge it with -Merge from a workstation, or with the same tools from here'
            Write-Plain '(in Claude Code, mcp__github__merge_pull_request with merge_method "squash") -'
        }
        else {
            Write-Plain 'Then merge it with -Merge once gh works here, or squash-merge it by hand and'
            Write-Plain 'retire the branch with -Cleanup -Sha <the squashed commit> -'
        }
        Write-Plain 'after reading the checks. finishing-work.md section 9 binds either way: never'
        Write-Plain 'merge with checks failing, and never merge a pull request you did not open.'
        Write-Host ''
        exit 3
    }

    # Not $args - that is an automatic variable in PowerShell and assigning to it is a
    # good way to produce a bug that only shows up somewhere else.
    $ghArgs = @('pr', 'create', '--base', $script:BaseName, '--title', $script:PrTitle, '--body-file', $script:BodyFile)
    if ($Draft) { $ghArgs += '--draft' }

    $rc = Invoke-Mutating 'gh' $ghArgs
    if ($rc -ne 0) { Stop-Now 'gh pr create failed' }

    if ($DryRun) { $script:PrNumber = '(none - dry run)'; return }

    $script:PrNumber = (gh pr view $script:BranchName --json number --jq .number) | Select-Object -First 1
    $script:PrUrl    = (gh pr view $script:BranchName --json url --jq .url)       | Select-Object -First 1
    Write-Good "opened #$($script:PrNumber)"
    Write-Plain $script:PrUrl
}

# --------------------------------------------------------------- section 5: merge it

$script:CheckLine = ''
$script:SquashSha = ''

# Check state never comes from `gh pr checks`. That command exits 1 when a repository has
# no checks at all, which is indistinguishable from "checks failed" - and with no CI in
# this repository yet, no checks is the normal case. statusCheckRollup gives an empty
# array instead, which is a third state that can be told apart from the other two.
# Reads a property that may not be there. Set-StrictMode turns a missing property into
# an exception rather than $null, and a check run and a status context carry different
# fields - one has .status/.conclusion, the other has .state.
function Get-RollupProp {
    param($Item, [string]$Name)
    if ($Item.PSObject.Properties.Name -contains $Name) {
        $value = $Item.$Name
        if ($null -ne $value) { return [string]$value }
    }
    return ''
}

function Resolve-CheckState {
    # The classification happens here rather than in a jq expression, on purpose.
    # PowerShell 5.1 mangles embedded double quotes when handing an argument to a native
    # command, so --jq '.status == "QUEUED"' reaches jq as `.status == QUEUED`, which jq
    # reads as a call to an undefined function. jq then fails, the count comes back
    # empty, and an empty count is zero - so a pull request with failing checks would
    # have reported zero failures and merged. ConvertFrom-Json has no quoting to get
    # wrong. Measured, not assumed.
    $raw = (gh pr view $script:PrNumber --json statusCheckRollup) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        Stop-Now 'could not read the check status for this pull request' @(
            'this script does not merge on an answer it failed to obtain')
    }

    $rollup = @()
    $parsed = $raw | ConvertFrom-Json
    if ($parsed.PSObject.Properties.Name -contains 'statusCheckRollup' -and $null -ne $parsed.statusCheckRollup) {
        $rollup = @($parsed.statusCheckRollup)
    }

    $pendingStates = @('QUEUED', 'IN_PROGRESS', 'WAITING', 'PENDING')
    $failedStates  = @('FAILURE', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE')

    $total     = $rollup.Count
    $pendingCk = @($rollup | Where-Object {
        (Get-RollupProp $_ 'status') -in $pendingStates -or (Get-RollupProp $_ 'state') -eq 'PENDING' })
    $failedCk  = @($rollup | Where-Object {
        (Get-RollupProp $_ 'conclusion') -in $failedStates -or (Get-RollupProp $_ 'state') -in @('FAILURE', 'ERROR') })

    $pending = $pendingCk.Count
    $failing = $failedCk.Count

    if ($total -eq 0) {
        if ($script:HasCi) {
            Stop-Now 'this repository has workflows but the pull request has no check runs' @(
                'workflows are configured and produced nothing. That is broken CI, not a green',
                'branch, and merging on it would mean merging unverified')
        }
        $script:CheckLine = 'none configured on this repository - nothing was verified'
        Write-Fine ("checks        {0}" -f $script:CheckLine)
        return
    }

    if ($failing -gt 0) {
        $names = @($failedCk | ForEach-Object {
            $n = Get-RollupProp $_ 'name'
            if (-not $n) { $n = Get-RollupProp $_ 'context' }
            if (-not $n) { $n = 'unnamed' }
            $n
        })
        Stop-Now "$failing of $total checks are failing" @(
            (($names | ForEach-Object { "  $_" }) -join "`n"),
            '',
            'Fix it on the branch and push. Never merge red')
    }

    if ($pending -gt 0) {
        Stop-RetryLater "$pending of $total checks are still running" @(
            'nothing has been changed. Re-run -Merge when they finish')
    }

    $script:CheckLine = "$total check(s) passed"
    Write-Good ("checks        {0}" -f $script:CheckLine)
}

function Merge-PullRequest {
    $script:CurSection = 5
    Write-Head 'Merging'

    # One call, one line back, tab separated. gh embeds its own jq, so nothing extra
    # needs to be installed and no JSON is parsed by hand here.
    $jq = '[.number, .state, (.isDraft|tostring), .author.login, .baseRefName, .headRefOid, .mergeable, .mergeStateStatus, .url, .title] | @tsv'
    $out = @(Invoke-Quiet { gh pr view $script:BranchName --json number,state,isDraft,author,baseRefName,headRefOid,mergeable,mergeStateStatus,url,title --jq $jq 2>&1 })
    $rc = $LASTEXITCODE
    $line = Get-GhOutput $out | Select-Object -First 1
    if ($rc -ne 0 -or -not $line) {
        $ghSaid = Get-GhError $out
        if ($ghSaid) {
            Stop-Now 'gh could not read the pull request for this branch' @("gh said: $ghSaid")
        }
        Stop-Now 'there is no pull request for this branch' @(
            'open one first:  .\scripts\finish.ps1 -Pr -Testing "..."')
    }

    $f = $line -split "`t"
    $script:PrNumber = $f[0]
    $state           = $f[1]
    $isDraft         = $f[2]
    $author          = $f[3]
    $baseRef         = $f[4]
    $headOid         = $f[5]
    $mergeable       = $f[6]
    $mergeState      = $f[7]
    $script:PrUrl    = $f[8]
    $script:PrTitle  = $f[9]

    if ($state -ne 'OPEN') {
        Stop-Now "pull request #$($script:PrNumber) is $state, not OPEN" @($script:PrUrl)
    }

    if ($isDraft -eq 'true') {
        Stop-Now "pull request #$($script:PrNumber) is a draft" @(
            'a draft says the work is visible but not landable. Mark it ready first:',
            "  gh pr ready $($script:PrNumber)")
    }

    if ($author -ne $script:GhLogin) {
        Stop-Now "pull request #$($script:PrNumber) was opened by $author, not by you ($($script:GhLogin))" @(
            'never merge or close a pull request you did not open. Tell them it looks ready')
    }

    if ($baseRef -ne $script:BaseName) {
        Stop-Now "pull request #$($script:PrNumber) targets $baseRef, but this branch resolves to $($script:BaseName)" @(
            'merging it would put this work on the wrong branch. If the pull request is right and',
            "the resolution is wrong, re-run with -Base $baseRef")
    }

    $headLocal = (git rev-parse HEAD) | Select-Object -First 1
    if ($headOid -ne $headLocal) {
        Stop-Now 'the pull request head is not what you have locally' @(
            "  pull request  $headOid",
            "  your HEAD     $headLocal",
            'either you have commits you did not push, or someone pushed to the branch. Either way',
            'this script would be merging code it never looked at')
    }

    if ($mergeable -eq 'CONFLICTING') {
        Stop-Now "GitHub reports pull request #$($script:PrNumber) has conflicts" @(
            'bring the branch up to date first:  .\scripts\finish.ps1 -Pr -Testing "..."',
            'do not resolve conflicts in the GitHub web editor')
    }

    if ($mergeState -eq 'BEHIND') {
        Stop-RetryLater "pull request #$($script:PrNumber) is behind $($script:BaseName)" @(
            'bring it up to date and push, then re-run:',
            '  .\scripts\finish.ps1 -Pr -Testing "..."')
    }
    if ($mergeState -in @('BLOCKED', 'DIRTY')) {
        Stop-Now "GitHub reports the merge state as $mergeState" @(
            $script:PrUrl,
            'something on the pull request is not satisfied. Look at it before merging')
    }

    Write-Fine ("pull request  #{0}  {1}" -f $script:PrNumber, $script:PrTitle)
    Write-Fine ("head          {0}" -f $headOid)
    Resolve-CheckState

    # Left alone, gh concatenates every commit message on the branch into the squash body,
    # claim commit included, which reads badly and buries the point. The (#N) suffix is
    # GitHub's own default and every existing squash on main carries it - passing
    # --subject removes it unless it is put back here.
    $subject = "$($script:PrTitle) (#$($script:PrNumber))"
    $script:SquashFile = New-BodyFile (Format-Field 'Scope:' $script:ScopeText)

    Write-Host ''
    Write-Plain ("squash subject  {0}" -f $subject)
    foreach ($l in (Format-Field 'Scope:' $script:ScopeText)) { Write-Host ("    {0}" -f $l) }
    Write-Host ''

    # --match-head-commit closes the window between reading the diff and merging it.
    # Without it, a push landing in that window would be merged unseen.
    $rc = Invoke-Mutating 'gh' @('pr', 'merge', $script:PrNumber, '--squash',
        '--subject', $subject, '--body-file', $script:SquashFile, '--match-head-commit', $headOid)
    if ($rc -ne 0) {
        Stop-Now "gh pr merge failed for pull request #$($script:PrNumber)" @(
            'nothing was deleted. If it reports a head-commit mismatch, someone pushed to the',
            'branch while this was running - re-run the bare script and read the diff again')
    }

    if ($DryRun) {
        Write-Fine 'dry run - stopping before the confirmation and cleanup that depend on a real merge'
        return
    }

    Invoke-FetchAll ' after the merge'

    $script:SquashSha = (gh pr view $script:PrNumber --json mergeCommit --jq '.mergeCommit.oid') | Select-Object -First 1
    if (-not $script:SquashSha -or $script:SquashSha -eq 'null') {
        Stop-Now 'the pull request merged but GitHub did not report a merge commit' @(
            'nothing has been deleted. Confirm by hand before removing anything')
    }

    Confirm-Landed $script:SquashSha
}

# ------------------------------------------------------------ section 6: clean up

function Confirm-Landed {
    param([string]$CommitSha)

    # `git merge-base --is-ancestor` exits non-zero both for "not an ancestor" and for a
    # name that resolves to nothing, so whether the commit exists is settled first. A -Sha
    # with a character missing otherwise reads as a merge that did not land.
    Invoke-Quiet { git rev-parse --verify -q "$CommitSha^{commit}" *> $null }
    if ($LASTEXITCODE -ne 0) {
        Stop-Now "no commit in this repository is named $CommitSha" @(
            'nothing has been deleted, and nothing will be. A name that resolves to no commit says',
            'nothing about whether the work landed: a truncated or mistyped -Sha reads exactly',
            'like this, and so does a commit this repository has never held. Read the SHA off the',
            'log and re-run:',
            '',
            "  git log --oneline -5 origin/$($script:BaseName)")
    }

    Invoke-Quiet { git merge-base --is-ancestor $CommitSha "origin/$($script:BaseName)" *> $null }
    if ($LASTEXITCODE -ne 0) {
        Stop-Now "the squashed commit is not on origin/$($script:BaseName)" @(
            "  commit  $CommitSha",
            'nothing has been deleted, and nothing will be. Section 9 is explicit that no branch',
            'is deleted until the log has confirmed the work landed. Look at the repository before',
            'doing anything else')
    }

    $short = (git rev-parse --short $CommitSha) | Select-Object -First 1
    Write-Good "confirmed $short is on origin/$($script:BaseName)"
    foreach ($l in @(git log --oneline -3 "origin/$($script:BaseName)")) { Write-Host ("    {0}" -f $l) }
}

$script:SimulatedSwitch = $false

# Every step below names what the repository holds after it, which is what the Cleanup
# line of section 7 is assembled from. Invoke-Mutating returns success under -DryRun
# without running the command, so each note that sits on that success says what a real run
# does instead of reporting a deletion that did not happen.

function Remove-WorktreeFor {
    param([string]$BranchRef)

    $wt = Get-WorktreeForBranch $BranchRef
    if (-not $wt) { return $true }
    # After a real switch the primary checkout no longer has the branch, so this is only
    # reached under -DryRun, and the primary checkout is never a worktree to remove.
    if ($script:SimulatedSwitch -and $wt -eq $script:Primary) { return $true }

    $lock = Get-LockReasonFor $wt
    if ($lock) {
        Write-Action "worktree not removed - it is locked: $lock"
        Write-Plain "  $wt"
        Write-Plain "  a lock means something else owns this worktree's lifecycle. If that is a Claude Code"
        Write-Plain '  session, leave it through the session rather than from here. Otherwise:'
        Write-Plain "    git -C `"$($script:Primary)`" worktree unlock `"$wt`""
        Write-Plain "    git -C `"$($script:Primary)`" worktree remove `"$wt`""
        $script:CleanupNotes += 'worktree left in place (locked)'
        return $false
    }

    # A worktree cannot be removed while it is any process's current directory - Windows
    # refuses, and what you get is the half-removed tree section 6 warns about.
    #
    # Set-Location alone is NOT enough. It changes PowerShell's own location but leaves
    # the process's Win32 working directory where it was, and it is the Win32 one that
    # blocks the delete. SetCurrentDirectory is the line that actually makes this work.
    # Measured, not assumed. Do not remove it.
    if ($wt -eq $script:Root) {
        Set-Location -LiteralPath $script:Primary
        [System.IO.Directory]::SetCurrentDirectory($script:Primary)
        Write-Fine "moved out of the worktree first (now in $($script:Primary))"
    }

    $rc = Invoke-Mutating 'git' @('-C', $script:Primary, 'worktree', 'remove', $wt)
    if ($rc -eq 0) {
        if ($DryRun) {
            $script:CleanupNotes += 'worktree would be removed'
        } else {
            $script:CleanupNotes += 'worktree removed'
        }
        return $true
    }

    # Which failure this was is read from what is on disk, never from git's message, which
    # is translated. Do not test it with `git status` in the worktree either: once the .git
    # file is gone, a worktree inside the repository reports the primary checkout's status.
    if (-not (Test-Path -LiteralPath $wt)) {
        $script:CleanupNotes += 'worktree removed'
        return $true
    }

    # Its .git file is still there, so the checkout is intact and still registered.
    if (Test-Path -LiteralPath (Join-Path $wt '.git')) {
        # Never --force. On a partially removed tree that is exactly how the mess gets worse.
        Write-Action 'worktree could not be removed'
        Write-Plain "  $wt"
        Write-Plain '  git refuses when a worktree has modified or untracked files in it. Look, then:'
        Write-Plain "    git -C `"$($script:Primary)`" worktree remove `"$wt`""
        Write-Plain '  do not add --force without looking - it deletes whatever is in there'
        $script:CleanupNotes += 'worktree not removed'
        return $false
    }

    # No .git file: git emptied the checkout and deregistered it, then could not delete the
    # directory itself. A process holding a directory open is what does that on Windows.
    Write-Action 'worktree emptied, but its directory is still there'
    Write-Plain "  $wt"
    Write-Plain '  the checkout is gone and git no longer lists it. What is left is a directory that'
    Write-Plain '  something held open - on Windows, any process sitting in it, including the shell'
    Write-Plain '  this ran from. Leave that directory, look at what is in it, then delete it:'
    Write-Plain "    Remove-Item -LiteralPath `"$wt`""
    Write-Plain '  git worktree remove does not apply to it any more: it is not a worktree'
    $script:CleanupNotes += 'worktree emptied, directory left behind'
    return $false
}

function Update-LocalBase {
    $x = (git -C $script:Primary symbolic-ref -q --short HEAD) | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or -not $x) { $x = '(detached)' }
    if ($script:SimulatedSwitch) { $x = $script:BaseName }
    $dirty = @(git -C $script:Primary status --porcelain)

    if ($x -eq $script:BaseName) {
        if ($dirty.Count -gt 0) {
            Write-Fine "$($script:BaseName) not updated - the primary checkout has uncommitted changes"
            $script:CleanupNotes += "$($script:BaseName) not updated (uncommitted changes there)"
            return
        }
        # --ff-only can only fast-forward, so it cannot invent a merge commit or lose
        # anything. This is the document's `git pull --ff-only` minus the second fetch,
        # which already happened seconds ago.
        $rc = Invoke-Mutating 'git' @('-C', $script:Primary, 'merge', '--ff-only', "origin/$($script:BaseName)")
        if ($rc -eq 0) {
            if ($DryRun) {
                Write-Fine "not attempted (dry run) - whether $($script:BaseName) fast-forwards is still unknown"
                $script:CleanupNotes += "$($script:BaseName) would be brought up to date"
            } else {
                $script:CleanupNotes += "$($script:BaseName) up to date"
            }
        } else {
            # Drift is a claim the history answers: local base is on origin/<base>'s
            # history or it is not. A fast-forward that fails with it still there failed
            # on the working tree, and git has said so in the line above this one.
            Invoke-Quiet { git -C $script:Primary merge-base --is-ancestor HEAD "origin/$($script:BaseName)" *> $null }
            if ($LASTEXITCODE -eq 0) {
                Write-Fine "$($script:BaseName) could not be fast-forwarded, and it has not drifted: local $($script:BaseName) is still"
                Write-Fine "on origin/$($script:BaseName)'s history, so the reason is in git's message above - a file the"
                Write-Fine 'merge could not write is the usual one. Left alone deliberately'
                $script:CleanupNotes += "$($script:BaseName) not updated (the fast-forward failed, $($script:BaseName) has not drifted)"
            } else {
                Write-Fine "$($script:BaseName) could not be fast-forwarded - it has drifted. Left alone deliberately"
                $script:CleanupNotes += "$($script:BaseName) not updated (local $($script:BaseName) has drifted)"
            }
        }
        return
    }

    # Never switch the primary checkout away from whatever someone else left it on.
    Write-Fine "$($script:BaseName) not updated - the primary checkout is on $x"
    Write-Fine "per finishing-work.md section 6 that costs nothing: nothing depends on local $($script:BaseName)"
    $script:CleanupNotes += "$($script:BaseName) not updated (primary checkout is on $x)"
}

# What origin says about a branch: present, gone, or unknown. `git ls-remote` prints
# nothing to stdout both when the branch is absent and when the read itself fails, so the
# exit code is what separates them: an empty answer from a failed read is not a retired
# claim. Read-only, so -DryRun does not gate it.
function Get-RemoteBranchState {
    param([string]$Name)
    $lines = @(Invoke-Quiet { git ls-remote --heads origin $Name 2>$null })
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { return 'unknown' }
    if (@($lines | Where-Object { "$_".Trim() }).Count -gt 0) { return 'present' }
    return 'gone'
}

# Whether the local branch exists: present or gone. Read from the ref, never from git's
# message, which is translated.
function Get-LocalBranchState {
    param([string]$Name)
    Invoke-Quiet { git -C $script:Primary show-ref --verify --quiet "refs/heads/$Name" *> $null }
    if ($LASTEXITCODE -eq 0) { return 'present' }
    return 'gone'
}

function Remove-LocalBranch {
    param([string]$BranchRef)
    # Read the ref first, as Remove-RemoteBranch reads origin first. On the -Cleanup
    # recovery path the branch may already be gone, and -D at a ref that is not there
    # fails with "branch not found" - a failure for a step that needs nothing done to it.
    if ((Get-LocalBranchState $BranchRef) -eq 'gone') {
        Write-Fine "local branch $BranchRef already gone"
        $script:CleanupNotes += 'local branch already gone'
    }
    else {
        # After a squash merge `git branch -d` refuses with "not fully merged", because
        # the work landed as a new commit with a new SHA and git cannot match them up. -D
        # is correct here, and only because Confirm-Landed already proved the work landed.
        $rc = Invoke-Mutating 'git' @('-C', $script:Primary, 'branch', '-D', $BranchRef)
        if ($rc -eq 0) {
            if ($DryRun) {
                $script:CleanupNotes += 'local branch would be deleted'
            } else {
                $script:CleanupNotes += 'local branch deleted'
            }
        }
        # -D failed. What that means is read from the ref: it is gone when something else
        # removed it alongside this run, and present when git refused - it is checked out
        # in a worktree this run did not remove.
        elseif ((Get-LocalBranchState $BranchRef) -eq 'gone') {
            Write-Fine "local branch $BranchRef already gone"
            $script:CleanupNotes += 'local branch already gone'
        }
        else {
            Write-Fine "local branch $BranchRef was not deleted"
            $script:CleanupNotes += 'local branch not deleted'
        }
    }

    [void](Invoke-Mutating 'git' @('-C', $script:Primary, 'worktree', 'prune'))
}

# The remote branch is the claim that starting-new-work.md section 2 reads, so deleting it
# is what retires the claim. Only ever called after Confirm-Landed.
#
# Origin is read before anything is said about it, and read again after a delete that
# failed, so that every note below is what origin answers rather than what this run
# expected. The capability gate is second for the same reason: it says what this session
# can do, and a branch GitHub has already retired needs nothing done to it.
function Remove-RemoteBranch {
    param([string]$BranchRef)
    $state = Get-RemoteBranchState $BranchRef

    if ($state -eq 'gone') {
        Write-Fine 'remote branch already gone'
        $script:CleanupNotes += 'remote branch already gone'
        return
    }

    if ($script:CapRemoteBranchDel -eq 0) {
        if ($state -eq 'unknown') {
            Write-Fine 'remote branch not deleted - this session cannot delete it (see env-capabilities),'
            Write-Fine 'and origin could not be read to say whether it is still there. Read it yourself:'
            Write-Fine "  git ls-remote --heads origin $BranchRef"
            $script:CleanupNotes += 'remote branch not deleted (no route to delete it here, origin unreadable)'
            return
        }
        Write-Fine 'remote branch left - this session cannot delete it (see env-capabilities)'
        $script:CleanupNotes += 'remote branch left (no route to delete it here)'
        return
    }

    $rc = Invoke-Mutating 'git' @('push', 'origin', '--delete', $BranchRef)
    if ($rc -eq 0) {
        if ($DryRun) {
            $script:CleanupNotes += 'remote branch would be deleted'
        } else {
            $script:CleanupNotes += 'remote branch deleted'
        }
        return
    }

    # With "Automatically delete head branches" enabled on the repository GitHub retires
    # the branch itself, and it can do so between the read above and this push - which
    # then fails at a ref that is already gone.
    switch (Get-RemoteBranchState $BranchRef) {
        'gone' {
            Write-Fine 'remote branch already gone - the delete found nothing left to delete'
            $script:CleanupNotes += 'remote branch already gone'
        }
        'present' {
            Write-Fine "remote branch $BranchRef could not be deleted - it still reads as a claim"
            $script:CleanupNotes += 'remote branch NOT deleted'
        }
        default {
            Write-Fine "remote branch $BranchRef could not be deleted, and origin could not be read to say"
            Write-Fine 'whether it is still there. Read it before reporting the claim retired:'
            Write-Fine "  git ls-remote --heads origin $BranchRef"
            $script:CleanupNotes += 'remote branch not deleted (origin unreadable)'
        }
    }
}

function Invoke-Cleanup {
    $script:CurSection = 6
    Write-Head 'Cleaning up'

    # $target, not $branch: case-insensitive names mean a local $branch would be the
    # $Branch parameter itself.
    $target = if ($Branch) { $Branch } else { $script:BranchName }

    $primaryHead = (git -C $script:Primary symbolic-ref -q --short HEAD) | Select-Object -First 1
    if ($primaryHead -eq $target) {
        $dirty = @(git -C $script:Primary status --porcelain)
        if ($dirty.Count -gt 0) {
            Stop-Now "the primary checkout is on $target and has uncommitted changes" @(
                'the branch cannot be deleted while it is checked out, and this script will not',
                'stash or discard anything to make that possible. Decide what those changes are for')
        }
        $rc = Invoke-Mutating 'git' @('-C', $script:Primary, 'switch', $script:BaseName)
        if ($rc -ne 0) { Stop-Now "could not switch the primary checkout to $($script:BaseName)" }
        # A dry run printed the switch without making it. Plan the rest as the real run
        # will find things after it, rather than planning to remove the primary checkout.
        if ($DryRun) { $script:SimulatedSwitch = $true }
    }

    Remove-RemoteBranch $target
    [void](Remove-WorktreeFor $target)
    Update-LocalBase
    Remove-LocalBranch $target
}

# -------------------------------------------------------------- section 7: report

function Write-ReportBlock {
    $range  = "$($script:SquashSha)~1...$($script:SquashSha)"
    $files  = @(git diff --name-only $range)
    $shown  = ($files | Select-Object -First 8) -join ', '
    if ($files.Count -gt 8) { $shown = "$shown (+$($files.Count - 8) more)" }

    $shortstat = (git diff --shortstat $range) | Select-Object -First 1
    $plus = 0; $minus = 0
    if ($shortstat) {
        if ($shortstat -match '(\d+) insertion') { $plus  = [int]$Matches[1] }
        if ($shortstat -match '(\d+) deletion')  { $minus = [int]$Matches[1] }
    }

    Write-Head 'Done'
    Write-Host ("Merged:  {0} -> {1}" -f $script:BranchName, $script:BaseName)
    Write-Host ("PR:      #{0} (squashed, {1} commits -> 1)" -f $script:PrNumber, $script:Commits)
    Write-Host ("Files:   {0} (+{1} -{2})" -f $shown, $plus, $minus)
    Write-Host ("Checks:  {0}" -f $script:CheckLine)
    Write-Host ("Cleanup: {0}" -f ($script:CleanupNotes -join ', '))
    Write-Host ''
    if ($script:PrUrl) { Write-Host $script:PrUrl; Write-Host '' }
}

# --------------------------------------------------------------------------- main

try {
    Import-WorkflowConfig

    # Dot-sourced here at script scope rather than inside a function, so that the
    # Invoke-ProjectScans it defines is visible to Invoke-FinishedChecks.
    $projectHook = Join-Path $PSScriptRoot 'finish-project.ps1'
    if (Test-Path -LiteralPath $projectHook) { . $projectHook }

    # @() because PowerShell unwraps an empty or one-item array returned from a function,
    # and strict mode then refuses .Count on what is left.
    $script:Declared = @(Get-ConfigItems $Declare)

    Write-Host ''
    Write-Host "$($script:ProjectName) - finishing work" -ForegroundColor White
    Write-Host 'See docs/development/finishing-work.md for what this does and why.' -ForegroundColor DarkGray
    if ($DryRun) {
        Write-Host 'Dry run: the fetch still happens, because every answer depends on it.' -ForegroundColor Yellow
        Write-Host 'Nothing else that changes anything will be executed.' -ForegroundColor Yellow
    }

    Get-RepoContext

    if ($script:Stage -eq 'cleanup') {
        $script:BranchName = (git symbolic-ref -q --short HEAD) | Select-Object -First 1
        if ($Branch) { $script:BranchName = $Branch }
        if (-not $script:BranchName) { Stop-Now '-Cleanup needs a branch: pass -Branch <name>' }
        if (-not (Test-SafeRef $script:BranchName)) {
            Write-Host "not a valid branch name: $($script:BranchName)" -ForegroundColor Red
            exit 2
        }
        $script:CurSection = 6
        Resolve-Base
        Import-Capabilities

        Invoke-FetchAll

        # $landed, not $sha: case-insensitive names mean a local $sha would be the $Sha
        # parameter itself.
        $landed = $Sha
        $ghSaid = ''
        if (-not $landed -and $script:CapGh -eq 1) {
            $out = @(Invoke-Quiet { gh pr view $script:BranchName --json mergeCommit --jq '.mergeCommit.oid' 2>&1 })
            $landed = Get-GhOutput $out | Select-Object -First 1
            $ghSaid = Get-GhError $out
        }
        if (-not $landed -or $landed -eq 'null') {
            $why = @('there is no pull request for it with a merge commit, and no -Sha was given.')
            if ($ghSaid) { $why += "gh said: $ghSaid" }
            Stop-Now 'cannot confirm this branch was merged' ($why + @(
                'Nothing has been deleted and nothing will be: section 9 does not allow deleting a',
                'branch until the log has confirmed the work landed.',
                '',
                'If you know the squashed commit, name it:  -Sha <commit>'))
        }
        if (-not (Test-SafeRef $landed)) {
            Write-Host "not a valid commit: $landed" -ForegroundColor Red
            exit 2
        }

        Write-Head 'Confirming the work landed'
        Confirm-Landed $landed
        $script:SquashSha = $landed
        Invoke-Cleanup

        Write-Head 'Done'
        Write-Host ("Cleanup: {0}" -f ($script:CleanupNotes -join ', '))
        if ($DryRun) { Write-Fine 'dry run complete - nothing was deleted, removed or changed' }
        Write-Host ''
        exit 0
    }

    Invoke-Preflight

    if ($script:Stage -eq 'merge') {
        # The evidence was the -Pr stage's job and the pull request records it. What
        # matters here is that the branch and the pull request still agree, which
        # Merge-PullRequest checks by SHA.
        Test-BuildSystem
        Merge-PullRequest
        if ($DryRun) {
            Write-Host ''
            Write-Fine 'dry run complete - nothing was merged, deleted or changed'
            Write-Host ''
            exit 0
        }
        Invoke-Cleanup
        Write-ReportBlock
        exit 0
    }

    Invoke-FinishedChecks

    if ($script:Stage -eq 'report') {
        Write-Host ''
        Write-Plain 'Next, when you have read the above and you are satisfied:'
        if ($script:Flagged.Count -gt 0) {
            Write-Host ('  .\scripts\finish.ps1 -Pr -Testing "<what you actually ran>" -Acknowledge "{0}"' -f `
                (@($script:Flagged | Select-Object -Unique) -join ',')) -ForegroundColor White
            Write-Fine '-Acknowledge names the flagged paths above - only the ones you have looked at'
        }
        else {
            Write-Host '  .\scripts\finish.ps1 -Pr -Testing "<what you actually ran>"' -ForegroundColor White
        }
        Write-Fine 'add -Notes "..." if a reader would otherwise have to reconstruct something'
        Write-Fine 'add -Draft to open it visible but not landable'
        Write-Host ''
        Write-Host 'Exit 0 here means the checks ran. It does not mean the branch is ready -' -ForegroundColor DarkGray
        Write-Host 'that judgement is yours.' -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }

    # -Pr
    if (-not $Testing) {
        Write-Host ''
        Write-Host '-Pr needs -Testing "<what you ran>"' -ForegroundColor Red
        Write-Host ''
        Write-Host 'The Testing line of the pull request body says what was actually run, not what'
        Write-Host 'anyone believes. This script cannot know it and will not invent it.'
        Write-Host ''
        if ($script:HasBuild.Count -eq 0 -and -not $script:HasCi) {
            Write-Host 'There is no build system in this repository yet, so something like:'
            Write-Host '  -Testing "no build system in the repository; nothing to run"'
            Write-Host ''
        } else {
            Write-Host "The local check command is: $($script:CheckCommand)"
            Write-Host ''
        }
        exit 2
    }

    Test-Acknowledgements
    Update-FromBase

    $rc = Invoke-Mutating 'git' @('push', '-u', 'origin', $script:BranchName)
    if ($rc -ne 0) {
        Stop-Now 'git push was rejected' @(
            'if it says non-fast-forward, the remote branch has commits yours does not. This script',
            'will not force anything - force-pushing is the one everyday git operation that can',
            'permanently destroy work that exists nowhere else.',
            '',
            'Fetch and merge first, then push again')
    }

    New-PullRequest

    Write-Host ''
    if ($DryRun) {
        Write-Fine 'dry run complete - nothing was pushed, opened or changed'
    } else {
        Write-Plain 'Next, once you are happy with it:'
        Write-Host '  .\scripts\finish.ps1 -Merge' -ForegroundColor White
    }
    Write-Host ''
}
finally {
    Remove-BodyFiles
}
