#Requires -Version 5.1
<#
.SYNOPSIS
    Answers one question: what can this session actually do?

.DESCRIPTION
    The repository's scripts were written for a workstation - a shell, a clone, and an
    authenticated gh. A coding agent running in a Claude Code cloud session has the first
    two and cannot have the third, and the failure mode is expensive: the agent reads
    "gh is not installed - see setting-up.md section 3.3", tries to follow an install
    instruction it cannot follow, then discovers the rest of the wall one 403 at a time.

    This file is the thing that knows better. Dot-source it and read $EnvTier, or run it
    for the human-readable version.

    WHAT THIS IS NOT
    It is not a permission check and it grants nothing. Every rule in
    docs/development/finishing-work.md section 9 applies identically in every tier: the
    cloud route opens and merges the same pull request, with the same evidence, under the
    same stops. What changes is which tool performs the step - never whether the step is
    allowed to be skipped.

    WHY IT PROBES RATHER THAN TRUSTS
    The CLAUDE_CODE_* variables are the host's internals and can be renamed without notice,
    so they are never the decisive test. The decisive test is always "does the tool work".
    The environment variables only choose the message shown when it does not, and if they
    ever stop being set the answer degrades to WorkstationIncomplete - exactly the behaviour
    these scripts had before this file existed. A detection miss costs the old message,
    never a wrong action.

    The bash twin is scripts/env-capabilities.sh and the two must agree.

.PARAMETER Export
    Emit KEY=value lines instead of the report, for another script to consume.

.EXAMPLE
    .\scripts\env-capabilities.ps1

.LINK
    docs/development/finishing-work.md
#>
[CmdletBinding()]
param(
    [switch]$Export
)

Set-StrictMode -Version Latest

# True when this is running inside a Claude Code cloud session (the web and mobile clients
# both land here). Each signal is checked independently: any one is enough, none is
# required, so a rename upstream costs one signal rather than the answer.
function Test-CloudSession {
    if ($env:CLAUDE_CODE_REMOTE -eq 'true')             { return $true }
    if ($env:CLAUDE_CODE_CONTAINER_ID)                  { return $true }
    if ($env:CLAUDE_CODE_REMOTE_SESSION_ID)             { return $true }
    if ($env:CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE)       { return $true }
    if ($env:CLAUDE_CODE_ENTRYPOINT -and
        $env:CLAUDE_CODE_ENTRYPOINT -match '^(remote|cloud)') { return $true }
    return $false
}

function Get-EnvPlatform {
    # $IsWindows exists on PowerShell 6+; on 5.1 the host is Windows by definition.
    if ($PSVersionTable.PSVersion.Major -lt 6) { return 'windows' }
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS)   { return 'macos'   }
    if ($IsLinux)   { return 'linux'   }
    return 'unknown'
}

$EnvPlatform = Get-EnvPlatform

# The only capability established by trying the tool rather than by inference.
$CapGh = 0
if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh auth status *> $null
    if ($LASTEXITCODE -eq 0) { $CapGh = 1 }
}

if ($CapGh -eq 1)         { $EnvTier = 'workstation' }
elseif (Test-CloudSession) { $EnvTier = 'cloud-agent' }
else                       { $EnvTier = 'workstation-incomplete' }

# CapRemoteBranchDelete is 0 in a cloud session as a matter of fact, not of policy. The
# egress proxy answers `git push origin --delete` with HTTP 403, the GitHub REST API is not
# reachable at all, and the GitHub MCP server exposes no delete-branch tool and no
# delete_branch option on its merge tool. There is no route, so the honest thing is to say
# so once, up front, rather than let a caller find it out by failing.
#
# With "Automatically delete head branches" enabled on the repository this costs nothing:
# GitHub retires the branch itself on merge, which is the step that retires the claim that
# docs/development/starting-new-work.md section 2 reads.
switch ($EnvTier) {
    'workstation' {
        $CapGithubRoute = 'gh'
        $CapRemoteBranchDelete = 1
        $EnvLabel = 'workstation with an authenticated gh'
        $EnvRoute = ''
    }
    'cloud-agent' {
        $CapGithubRoute = 'mcp'
        $CapRemoteBranchDelete = 0
        $EnvLabel = 'Claude Code cloud session'
        $EnvRoute = @'
gh cannot work in a Claude Code cloud session, and installing it would not help:
the GitHub REST API is blocked by the egress proxy for this session, so an
authenticated gh is not reachable from here either.

Everything this script does with git still works. What needs a different tool is
the pull request itself. In this session, use the GitHub tools your agent has. In
Claude Code those are the GitHub MCP tools:

  open      mcp__github__create_pull_request
  inspect   mcp__github__pull_request_read
  merge     mcp__github__merge_pull_request   (merge_method: "squash")

Every rule in finishing-work.md section 9 still binds. In particular: read the
bare report above before opening anything, never merge with checks failing, and
never merge a pull request you did not open.

The remote branch cannot be deleted from this session by any available route.
With "Automatically delete head branches" enabled on the repository, GitHub
deletes it on merge and no one needs to. Confirm it is gone with:

  git ls-remote --heads origin <branch>

and if it is still there, say so rather than retrying - it will not succeed.
'@
    }
    default {
        $CapGithubRoute = 'none'
        $CapRemoteBranchDelete = 1
        $EnvLabel = 'workstation without a usable gh'
        $EnvRoute = @'
gh is not installed, or is installed but not authenticated.

  install     see docs/development/setting-up.md section 3.3
  then        gh auth login
'@
    }
}

function Write-EnvCapabilitiesReport {
    $prs = switch ($CapGithubRoute) {
        'gh'  { 'gh' }
        'mcp' { 'GitHub MCP tools - gh is not usable here' }
        default { 'no route - gh is missing or unauthenticated' }
    }
    $del = if ($CapRemoteBranchDelete -eq 1) { 'remote and local' }
           else { "local only - the remote branch is GitHub's to delete on merge" }
    $variant = if ($EnvPlatform -eq 'windows') { 'scripts/*.ps1' } else { 'scripts/*.sh' }

    Write-Host "environment   $EnvLabel"
    Write-Host "tier          $EnvTier"
    Write-Host "platform      $EnvPlatform"
    Write-Host "scripts       $variant"
    Write-Host "git           available (fetch, merge, push to your own branch)"
    Write-Host "pull requests $prs"
    Write-Host "branch delete $del"
    if ($EnvRoute) {
        Write-Host ''
        Write-Host $EnvRoute
    }
}

function Write-EnvCapabilitiesExport {
    Write-Output "ENV_TIER=$EnvTier"
    Write-Output "ENV_PLATFORM=$EnvPlatform"
    Write-Output "ENV_LABEL=$EnvLabel"
    Write-Output "CAP_GH=$CapGh"
    Write-Output "CAP_GITHUB_ROUTE=$CapGithubRoute"
    Write-Output "CAP_REMOTE_BRANCH_DEL=$CapRemoteBranchDelete"
}

# Dot-sourced or invoked? $MyInvocation.InvocationName is '.' when dot-sourced. Only the
# invoked case prints; the dot-sourced case just leaves the variables and functions behind.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Export) { Write-EnvCapabilitiesExport } else { Write-EnvCapabilitiesReport }
}
