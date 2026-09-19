#!/usr/bin/env bash
#
# Answers one question: what can this session actually do?
#
# The repository's scripts were written for a workstation - a shell, a clone, and an
# authenticated `gh`. A coding agent running in a Claude Code cloud session has the first
# two and cannot have the third, and the failure mode is expensive: the agent reads
# "gh is not installed - see setting-up.md section 3.3", tries to follow an install
# instruction it cannot follow, then discovers the rest of the wall one 403 at a time.
#
# This file is the thing that knows better. Source it, read ENV_TIER, and route.
#
#   . scripts/env-capabilities.sh
#   [ "$CAP_GH" -eq 1 ] || echo "$ENV_ROUTE"
#
# Run it directly for the human-readable version:
#
#   ./scripts/env-capabilities.sh            what this session is and what it can do
#   ./scripts/env-capabilities.sh --export   KEY=value lines, for another script to eval
#
# WHAT THIS IS NOT
#   It is not a permission check and it grants nothing. Every rule in
#   docs/development/finishing-work.md section 9 applies identically in every tier: the
#   cloud route opens and merges the same pull request, with the same evidence, under the
#   same stops. What changes is which tool performs the step - never whether the step is
#   allowed to be skipped.
#
# WHY IT PROBES RATHER THAN TRUSTS
#   The CLAUDE_CODE_* variables below are the host's internals and can be renamed without
#   notice. So they are never the decisive test. The decisive test is always "does the tool
#   work" - `have gh` and `gh auth status`. The environment variables only choose the
#   message shown when it does not, and if they ever stop being set the answer degrades to
#   workstation-incomplete, which is exactly the behaviour these scripts had before this
#   file existed. A detection miss therefore costs the old message, never a wrong action.

# Deliberately no `set -euo pipefail`: this file is meant to be sourced, and imposing shell
# options on a caller that did not ask for them is how a sourced file breaks its host.

# Plain strings and no arrays throughout - macOS still ships bash 3.2, the same constraint
# setup.sh and finish.sh already work under.

env_cap_have() { command -v "$1" >/dev/null 2>&1; }

# True when this shell is running inside a Claude Code cloud session (the web and mobile
# clients both land here). Each signal is checked independently: any one of them is enough,
# and none of them is required, so a rename upstream costs one signal rather than the answer.
env_cap_is_cloud_session() {
  [ "${CLAUDE_CODE_REMOTE:-}" = 'true' ] && return 0
  [ -n "${CLAUDE_CODE_CONTAINER_ID:-}" ] && return 0
  [ -n "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" ] && return 0
  case "${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}" in
    ?*) return 0 ;;
  esac
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    remote*|cloud*) return 0 ;;
  esac
  return 1
}

# Windows is the other half of the portability story: there the .ps1 variant is the one to
# run. Reported rather than acted on - nothing here chooses a script for you.
env_cap_platform() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux*)                 echo 'linux'   ;;
    Darwin*)                echo 'macos'   ;;
    MINGW*|MSYS*|CYGWIN*)   echo 'windows' ;;
    *)                      echo 'unknown' ;;
  esac
}

ENV_PLATFORM=$(env_cap_platform)

# The host part of a remote URL: https://host/..., ssh://user@host:port/..., user@host:path.
# Empty for a local path, which no gh can open a pull request against.
env_cap_host_of() {
  local url="$1"
  case "$url" in
    *://*) url="${url#*://}"; url="${url#*@}"; printf '%s' "${url%%[/:]*}" ;;
    *@*:*) url="${url#*@}"; printf '%s' "${url%%:*}" ;;
    *)     printf '' ;;
  esac
}

ENV_ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
ENV_ORIGIN_HOST=$(env_cap_host_of "$ENV_ORIGIN_URL")

# CAP_GH is the only capability established by trying the tool rather than by inference.
# `gh auth status` is a network call; it is the same call preflight already made, so this
# costs nothing that was not already being spent.
#
# gh that works is not enough: it has to work against origin. A gh logged in to github.com
# cannot open a pull request on a remote hosted anywhere else, and saying "no pull request
# for this branch" there would name the wrong cause. Outside a repository there is no
# origin to ask about, and gh working is the whole answer.
CAP_GH=0
ENV_ORIGIN_NOT_GITHUB=0
if env_cap_have gh; then
  if [ -z "$ENV_ORIGIN_URL" ]; then
    gh auth status >/dev/null 2>&1 && CAP_GH=1
  elif [ -n "$ENV_ORIGIN_HOST" ] && gh auth status --hostname "$ENV_ORIGIN_HOST" >/dev/null 2>&1; then
    CAP_GH=1
  elif gh auth status >/dev/null 2>&1; then
    ENV_ORIGIN_NOT_GITHUB=1
  fi
fi

if [ "$CAP_GH" -eq 1 ]; then
  ENV_TIER='workstation'
elif env_cap_is_cloud_session; then
  ENV_TIER='cloud-agent'
elif [ "$ENV_ORIGIN_NOT_GITHUB" -eq 1 ]; then
  ENV_TIER='no-github-remote'
else
  ENV_TIER='workstation-incomplete'
fi

# What the tier means for the operations these scripts perform.
#
#   CAP_GITHUB_ROUTE       how pull requests get opened and merged: gh | mcp | none
#   CAP_REMOTE_BRANCH_DEL  whether this session can delete a branch on the remote
#
# CAP_REMOTE_BRANCH_DEL is 0 in a cloud session as a matter of fact, not of policy. The
# egress proxy answers `git push origin --delete` with HTTP 403, the GitHub REST API is not
# reachable at all, and the GitHub MCP server exposes no delete-branch tool and no
# delete_branch option on its merge tool. There is no route, so the honest thing is to say
# so once, up front, rather than let a caller find it out by failing.
#
# With "Automatically delete head branches" enabled on the repository this costs nothing:
# GitHub retires the branch itself on merge, which is the step that retires the claim that
# docs/development/starting-new-work.md section 2 reads.
case "$ENV_TIER" in
  workstation)
    CAP_GITHUB_ROUTE='gh'
    CAP_REMOTE_BRANCH_DEL=1
    ENV_LABEL='workstation with an authenticated gh'
    ENV_ROUTE=''
    ;;
  cloud-agent)
    CAP_GITHUB_ROUTE='mcp'
    CAP_REMOTE_BRANCH_DEL=0
    ENV_LABEL='Claude Code cloud session'
    ENV_ROUTE='gh cannot work in a Claude Code cloud session, and installing it would not help:
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

and if it is still there, say so rather than retrying - it will not succeed.'
    ;;
  no-github-remote)
    CAP_GITHUB_ROUTE='none'
    CAP_REMOTE_BRANCH_DEL=1
    ENV_LABEL='repository whose origin gh cannot reach'
    ENV_ROUTE="gh works, but origin is not on a GitHub host it is logged in to:

  origin      ${ENV_ORIGIN_URL}

so there is no pull request to open or merge from here. Everything this script
does with git still works. If origin is on a GitHub Enterprise host, log in to it:

  gh auth login --hostname <host>

Otherwise land the branch through whatever review this remote's host provides,
never by pushing to the base branch, then retire it with:

  ./scripts/finish.sh --cleanup --sha <the squashed commit>"
    ;;
  *)
    CAP_GITHUB_ROUTE='none'
    CAP_REMOTE_BRANCH_DEL=1
    ENV_LABEL='workstation without a usable gh'
    ENV_ROUTE='gh is not installed, or is installed but not authenticated.

  install     see docs/development/setting-up.md section 3.3
  then        gh auth login'
    ;;
esac

env_capabilities_report() {
  echo "environment   $ENV_LABEL"
  echo "tier          $ENV_TIER"
  echo "platform      $ENV_PLATFORM"
  echo "scripts       $([ "$ENV_PLATFORM" = 'windows' ] && echo 'scripts/*.ps1' || echo 'scripts/*.sh')"
  echo "git           available (fetch, merge, push to your own branch)"
  echo "pull requests $(case "$CAP_GITHUB_ROUTE" in
                          gh)  echo 'gh' ;;
                          mcp) echo 'GitHub MCP tools - gh is not usable here' ;;
                          *)   if [ "$ENV_TIER" = 'no-github-remote' ]; then
                                 echo 'no route - origin is not a GitHub host gh is logged in to'
                               else
                                 echo 'no route - gh is missing or unauthenticated'
                               fi ;;
                        esac)"
  echo "branch delete $([ "$CAP_REMOTE_BRANCH_DEL" -eq 1 ] \
                          && echo 'remote and local' \
                          || echo 'local only - the remote branch is GitHub'"'"'s to delete on merge')"
  if [ -n "$ENV_ROUTE" ]; then
    echo ''
    echo "$ENV_ROUTE"
  fi
}

env_capabilities_export() {
  echo "ENV_TIER=$ENV_TIER"
  echo "ENV_PLATFORM=$ENV_PLATFORM"
  echo "ENV_LABEL=$ENV_LABEL"
  echo "CAP_GH=$CAP_GH"
  echo "CAP_GITHUB_ROUTE=$CAP_GITHUB_ROUTE"
  echo "CAP_REMOTE_BRANCH_DEL=$CAP_REMOTE_BRANCH_DEL"
  echo "ENV_ORIGIN_HOST=$ENV_ORIGIN_HOST"
}

# Sourced or executed? ${BASH_SOURCE[0]} is this file either way; $0 is the caller's name
# when sourced and this file's name when run. Only act on the second.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    --export) env_capabilities_export ;;
    -h|--help)
      echo "usage: $0 [--export]"
      echo "       reports what this session can do. Changes nothing."
      ;;
    *) env_capabilities_report ;;
  esac
fi
