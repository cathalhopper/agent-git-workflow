#!/usr/bin/env bash
#
# Takes a finished branch from "the code works" to "squash-merged and cleaned up".
# This is docs/development/finishing-work.md sections 1 to 7, mechanised.
#
# Usage:
#   ./scripts/finish.sh                        sections 1-2. Reports. Changes nothing
#   ./scripts/finish.sh --pr --testing "..."   sections 3-4. Updates from base, pushes, opens the PR
#   ./scripts/finish.sh --merge                sections 5-6. Verifies, squash-merges, cleans up
#   ./scripts/finish.sh --cleanup              section 6 only. Recovery path after a merge
#
# Add --dry-run to any stage to print the commands without running them.
# Run with -h for the full flag list.
#
# WHAT THE BARE RUN GUARANTEES
#   It creates no commit, no branch and no pull request; it deletes nothing; it changes no
#   local branch, no working tree and nothing on the remote. It does update your
#   remote-tracking refs, because every answer it gives depends on them being current -
#   and section 1 of the document is explicit that a check against a stale remote is worse
#   than no check, since it returns "all clear" with authority.
#
# WHAT IT DELIBERATELY WILL NOT DO
#   It will not judge your diff, run your tests, resolve a merge conflict, or decide whether
#   a change a project scan stopped on was intended. It surfaces those and stops. Section 2
#   of the document is a human judgement and this script gathers the evidence for it,
#   nothing more.
#
# WHAT THE PROJECT SUPPLIES
#   scripts/workflow.conf      KEY=value settings: the base branches, the branch-name
#                              prefixes and any base a prefix maps to, the check
#                              command quoted in messages, and the
#                              path classes flagged for --acknowledge. Every key has a
#                              default, so a missing file changes nothing.
#   scripts/finish-project.sh  optional. Sourced if present; defines project_scans, which
#                              runs after the built-in scans. A scan that needs a human
#                              assertion asks for one by name with is_declared, and the
#                              run supplies it with --declare <name>; the declaration is
#                              written into the pull request body. A name no scan asked
#                              for is a usage error. finish-project.sh.example carries
#                              the contract.
#
# THE COMPLETE SET OF COMMANDS THAT CHANGE ANYTHING
#   Thirteen, and `git fetch` is the only one that is not behind run() - it runs even
#   under --dry-run, because every answer this script gives depends on it. Nothing else
#   in this file mutates anything.
#
#     git fetch --all --prune
#     git merge origin/<base>
#     git merge --abort
#     git push -u origin <branch>
#     gh pr create --base <base> --title <t> --body-file <f> [--draft]
#     gh pr edit <n> --body-file <f>
#     gh pr merge <n> --squash --subject <t> --body-file <f> --match-head-commit <sha>
#     git push origin --delete <branch>
#     git switch <base>
#     git merge --ff-only origin/<base>
#     git worktree remove <path>
#     git worktree prune
#     git branch -D <branch>
#
#   No command this script runs forces, rebases, resets or stashes. The words themselves
#   appear further down, in comments and in the messages that refuse those actions, so the
#   audit is a grep and a read of each hit:
#     grep -n -- '--force\|force-with-lease\|rebase\|reset --hard\|stash' scripts/finish.sh
#   Every hit outside this block is a comment or a refusal message, never a command.
#
# WHY THERE IS NO --force, --skip-checks OR --yes, AND WHY YOU MUST NOT ADD ONE
#   Permission systems match on command prefixes. The moment "finish.sh --merge" is approved,
#   "finish.sh --merge --force" is approved too - by the same rule, without anyone deciding
#   it should be. An override flag on this script is therefore not an escape hatch used in
#   emergencies; it is effectively always on from the moment the tool is trusted. Every stop
#   in this script corresponds to a rule in section 9 of the document. If one fires, the
#   answer is to fix the branch or to do it by hand and take responsibility for it.
#
# See docs/development/finishing-work.md for what this does and why.

set -euo pipefail

# --------------------------------------------------------------------------- arguments

STAGE='report'
STAGE_SET=0
DRYRUN=0
DRAFT=0
TESTING=''
NOTES=''
BASE_ARG=''
SCOPE_ARG=''
TITLE_ARG=''
DECLARE=''
ACK=''
BRANCH_ARG=''
SHA_ARG=''

usage() {
  echo "usage: $0 [--pr --testing <text> | --merge | --cleanup] [--dry-run] [options]" >&2
  echo "       run '$0 -h' for the full list" >&2
}

set_stage() {
  if [ "$STAGE_SET" -eq 1 ]; then
    echo "two stage flags given: only one of --pr, --merge, --cleanup per run" >&2
    echo "each stage does one thing, so that what a run will do is knowable before it runs" >&2
    exit 2
  fi
  STAGE="$1"
  STAGE_SET=1
}

need_value() {
  # $1 is the flag name, $2 is the count of remaining arguments including the flag.
  if [ "$2" -lt 2 ]; then
    echo "$1 needs a value" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)          set_stage pr ;;
    --merge)       set_stage merge ;;
    --cleanup)     set_stage cleanup ;;
    --dry-run)     DRYRUN=1 ;;
    --draft)       DRAFT=1 ;;
    --testing)     need_value "$1" $#; TESTING="$2"; shift ;;
    --notes)       need_value "$1" $#; NOTES="$2"; shift ;;
    --base)        need_value "$1" $#; BASE_ARG="$2"; shift ;;
    --scope)       need_value "$1" $#; SCOPE_ARG="$2"; shift ;;
    --title)       need_value "$1" $#; TITLE_ARG="$2"; shift ;;
    --declare)     need_value "$1" $#; DECLARE="$2"; shift ;;
    --acknowledge) need_value "$1" $#; ACK="$2"; shift ;;
    --branch)      need_value "$1" $#; BRANCH_ARG="$2"; shift ;;
    --sha)         need_value "$1" $#; SHA_ARG="$2"; shift ;;
    -h|--help)
      # Print the header comment block: every comment line after the shebang, up to the
      # first line that is not a comment. No line numbers to drift.
      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

# --------------------------------------------------------------------------- output

if [ -t 1 ]; then
  BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RED=$(printf '\033[31m')
  GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); CYAN=$(printf '\033[36m')
  RESET=$(printf '\033[0m')
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

# Named 'section', not 'head' - a function called head would shadow the head command.
section() {
  printf '\n%s%s%s\n' "$CYAN" "$1" "$RESET"
  printf '%s%s%s\n' "$DIM" "$(printf '%*s' "${#1}" '' | tr ' ' '-')" "$RESET"
}
fine()   { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
action() { printf '  %s%s%s\n' "$YELLOW" "$1" "$RESET"; }
good()   { printf '  %s%s%s\n' "$GREEN" "$1" "$RESET"; }
plain()  { printf '  %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Plain strings rather than arrays: macOS still ships bash 3.2, where ${#arr[@]} on an
# empty array under `set -u` is an unbound-variable error. Same constraint as setup.sh.
FINDINGS=0
FLAGGED=''        # newline separated paths from the suspicious-path scan
CLEANUP_NOTES=''  # comma separated, becomes the Cleanup: line of the section 7 report
NOTES_EXTRA=''    # newline separated, appended to the Notes: field of the pull request
DECLARED=''       # newline separated names given with --declare
DECLARED_ASKED='' # newline separated names a scan asked is_declared about this run
DECLARED_USED=''  # comma separated names a scan asked about and found declared
RAN=''            # newline separated, every state-changing command run() completed
CUR_SECTION=1     # cites finishing-work.md section 1 to 6 by number, one per stage

add_flagged() { FLAGGED="${FLAGGED}${FLAGGED:+$'\n'}$1"; }
add_cleanup() { CLEANUP_NOTES="${CLEANUP_NOTES}${CLEANUP_NOTES:+, }$1"; }
add_note()    { NOTES_EXTRA="${NOTES_EXTRA}${NOTES_EXTRA:+$'\n'}$1"; }

# True when --declare named $1. Only a scan that is about to stop asks, so the set of
# names asked about this run is exactly the set --declare may name: a declaration that
# nothing asked for is refused after the scans, which is what stops --declare being a
# way to pre-authorise a stop that has not fired.
is_declared() {
  local name="$1" d
  DECLARED_ASKED="${DECLARED_ASKED}${DECLARED_ASKED:+$'\n'}$name"
  while IFS= read -r d; do
    if [ "$d" = "$name" ]; then
      DECLARED_USED="${DECLARED_USED}${DECLARED_USED:+, }$name"
      return 0
    fi
  done <<EOF
$DECLARED
EOF
  return 1
}

finding() {
  FINDINGS=$((FINDINGS + 1))
  printf '  %s%-18s%s %s\n' "$YELLOW" "$1" "$RESET" "$2"
}

# Every stop in this script ends here. Nothing is attempted after it. It names what this
# run already changed: a stop after a push that says nothing changed would be believed.
stop() {
  printf '\n%sStop: %s%s\n' "$RED" "$1" "$RESET" >&2
  shift
  # Indent every line of every argument, not just the first: several call sites pass a
  # captured multi-line list and the continuations have to line up with it.
  while [ $# -gt 0 ]; do printf '%s\n' "$1" | sed 's/^/       /' >&2; shift; done
  echo '' >&2
  if [ -z "$RAN" ]; then
    printf '%sNothing was changed.%s\n' "$DIM" "$RESET" >&2
  else
    printf '%sAlready done in this run, and not undone:%s\n' "$YELLOW" "$RESET" >&2
    printf '%s\n' "$RAN" | sed 's/^/  /' >&2
  fi
  printf '%sSee docs/development/finishing-work.md section %s%s\n\n' "$DIM" "$CUR_SECTION" "$RESET" >&2
  exit 1
}

# Not yet, rather than no. Exit 3 so a caller can tell "wait" from "stop".
retry_later() {
  printf '\n%sNot yet: %s%s\n' "$YELLOW" "$1" "$RESET" >&2
  shift
  while [ $# -gt 0 ]; do printf '%s\n' "$1" | sed 's/^/         /' >&2; shift; done
  printf '\n'
  exit 3
}

# ----------------------------------------------------------------- project settings

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# scripts/workflow.conf is the one file a project edits. KEY=value lines, no quoting, no
# expansion, read with a loop rather than sourced so that a settings file can never run
# code. Every key has a default here, so a missing file changes nothing.
PROJECT_NAME='this repository'
DEFAULT_BASE=''
ALT_BASES=''
BASE_BY_PREFIX=''
BRANCH_TYPES='feat,fix,spike,docs,chore'
CHECK_COMMAND='./scripts/check.sh'
LOCKFILES='Cargo.lock,package-lock.json,pnpm-lock.yaml,yarn.lock,poetry.lock,Gemfile.lock,go.sum,composer.lock'
GOVERNING_PATHS='.gitattributes,.gitignore,.github/*,scripts/*'
SCAFFOLDING_PATTERN=''
LARGE_DIFF_LINES=2000

load_config() {
  local conf="$SCRIPT_DIR/workflow.conf" line key value
  [ -r "$conf" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) : ;;
      *) echo "workflow.conf: not a KEY=value line: $line" >&2; exit 2 ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      PROJECT_NAME)          [ -n "$value" ] && PROJECT_NAME="$value" ;;
      DEFAULT_BASE)          DEFAULT_BASE="$value" ;;
      ALT_BASES)             ALT_BASES="$value" ;;
      BASE_BY_PREFIX)        BASE_BY_PREFIX="$value" ;;
      BRANCH_TYPES)          [ -n "$value" ] && BRANCH_TYPES="$value" ;;
      CHECK_COMMAND)         [ -n "$value" ] && CHECK_COMMAND="$value" ;;
      CHECK_COMMAND_WINDOWS) : ;;   # read by the PowerShell twin
      LOCKFILES)             LOCKFILES="$value" ;;
      GOVERNING_PATHS)       GOVERNING_PATHS="$value" ;;
      SCAFFOLDING_PATTERN)   SCAFFOLDING_PATTERN="$value" ;;
      LARGE_DIFF_LINES)      [ -n "$value" ] && LARGE_DIFF_LINES="$value" ;;
      *)
        echo "workflow.conf: unknown key '$key'" >&2
        exit 2 ;;
    esac
  done < "$conf"

  case "$LARGE_DIFF_LINES" in
    ''|*[!0-9]*) echo 'workflow.conf: LARGE_DIFF_LINES must be a whole number' >&2; exit 2 ;;
  esac

  local pair
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    case "$pair" in
      ?*:?*) : ;;
      *) echo "workflow.conf: BASE_BY_PREFIX entries are prefix:base, not '$pair'" >&2; exit 2 ;;
    esac
    if ! safe_ref "${pair%%:*}" || ! safe_ref "${pair#*:}"; then
      echo "workflow.conf: BASE_BY_PREFIX holds an invalid branch name: $pair" >&2
      exit 2
    fi
  done <<EOF
$(each_item "$BASE_BY_PREFIX")
EOF
}

# Prints "prefix base" for each BASE_BY_PREFIX pair, one per line.
each_mapping() {
  local pair
  while IFS= read -r pair; do
    [ -n "$pair" ] && printf '%s %s\n' "${pair%%:*}" "${pair#*:}"
  done <<EOF
$(each_item "$BASE_BY_PREFIX")
EOF
  return 0
}

# Prints a comma-separated value one item per line, trimmed, blanks dropped.
each_item() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' || true
}

# Sourced if present. It defines project_scans, which finished_checks calls after the
# built-in scans. finish-project.sh.example carries the contract.
load_project_scans() {
  if [ -r "$SCRIPT_DIR/finish-project.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/finish-project.sh"
  fi
}

# Runs after the scans. Every name --declare gave must be one a scan asked about.
check_declarations() {
  [ -n "$DECLARE" ] || return 0
  local item found d
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    found=0
    while IFS= read -r d; do
      [ "$d" = "$item" ] && found=1
    done <<EOF
$DECLARED_ASKED
EOF
    if [ "$found" -eq 0 ]; then
      echo "--declare names something no scan asked for: $item" >&2
      echo 'it can only declare what a scan stopped on this run, so that it cannot be used' >&2
      echo 'to pre-authorise anything.' >&2
      if [ -n "$DECLARED_ASKED" ]; then
        echo 'Asked for this run:' >&2
        printf '%s\n' "$DECLARED_ASKED" | sed 's/^/  /' >&2
      else
        echo 'Nothing asked for a declaration this run.' >&2
      fi
      exit 2
    fi
  done <<EOF
$DECLARED
EOF
}

# ------------------------------------------------------------ environment capabilities

# scripts/env-capabilities.sh answers "what can this session actually do", so that a
# session which cannot run gh is routed to the tool that does work there instead of being
# handed an install instruction it cannot follow. See the header of that file for why it
# probes the tool rather than trusting an environment variable.
#
# Sourced lazily: it runs `gh auth status`, which is a network call, and `-h` should not
# pay for one.
CAPS_LOADED=0

load_capabilities() {
  [ "$CAPS_LOADED" -eq 1 ] && return 0
  if [ -r "$SCRIPT_DIR/env-capabilities.sh" ]; then
    # shellcheck source=scripts/env-capabilities.sh
    . "$SCRIPT_DIR/env-capabilities.sh"
  else
    # The probe improves the message; it is never a precondition for the script. A
    # checkout missing it behaves exactly as this script did before the file existed.
    ENV_TIER='workstation-incomplete'
    ENV_LABEL='workstation without a usable gh'
    ENV_ROUTE='gh is not installed, or is installed but not authenticated.

  install     see docs/development/setting-up.md section 3.3
  then        gh auth login'
    CAP_GH=0
    CAP_GITHUB_ROUTE='none'
    CAP_REMOTE_BRANCH_DEL=1
    if have gh && gh auth status >/dev/null 2>&1; then
      ENV_TIER='workstation'; ENV_LABEL='workstation with an authenticated gh'
      ENV_ROUTE=''; CAP_GH=1; CAP_GITHUB_ROUTE='gh'
    fi
  fi
  CAPS_LOADED=1
}

# The gh gate. This was two unconditional stops, which is why a cloud session got told to
# install a tool it cannot install and then had to discover the rest of the wall by hitting
# it. The stop now depends on what this session can do and on which stage needs it.
#
# The bare run is read-only and wants gh for one line of display, so it proceeds everywhere
# and says what it could not show - a session that cannot open a pull request can still get
# the whole of sections 1 and 2, which is the part that carries the judgement.
#
# This grants nothing. --pr stops short of opening the pull request, and --merge cannot
# proceed without a route to GitHub; both name the route that exists here.
require_github_route() {
  [ "$CAP_GH" -eq 1 ] && return 0

  if [ "$STAGE" = 'report' ]; then
    fine "github        no gh here - $ENV_LABEL"
    fine 'every check below is local, so the report is complete either way'
    return 0
  fi

  # --pr without gh is worth running rather than refusing. Section 3 and the push are pure
  # git and work anywhere; what cannot run is the last command of the stage. Stopping in
  # preflight would throw away the part of this stage that is hardest to do by hand - the
  # title and the body, which are where the evidence and the Testing line live - so the
  # stage proceeds and open_pull_request hands off at the point where gh would have run.
  if [ "$STAGE" = 'pr' ]; then
    fine "github        no gh here - $ENV_LABEL"
    fine 'this stage will update from the base, push, and build the pull request, then'
    fine 'hand the pull request itself to you'
    return 0
  fi

  case "$ENV_TIER" in
    cloud-agent|no-github-remote)
      stop \
        "this stage needs a route to GitHub, and there is none in a $ENV_LABEL" \
        '' \
        "$ENV_ROUTE"
      ;;
    *)
      stop \
        'gh is not installed, or is not authenticated' \
        "$ENV_ROUTE"
      ;;
  esac
}

# --------------------------------------------------------------------------- commands

# Read-only query. Never gated by --dry-run: a rehearsal that reports fiction is worse
# than no rehearsal. Failure is the caller's to handle.
q() { "$@"; }

# THE ONLY PLACE IN THIS FILE THAT RUNS SOMETHING WHICH CHANGES STATE.
# Grep for '^\s*run ' and you have every mutation site in the script. Keep it that way.
run() {
  # Quote anything with a space for display only. The real call below passes every
  # argument as a discrete word, so the quoting is never part of what git or gh receives.
  local shown='' a
  for a in "$@"; do
    case "$a" in
      *[!A-Za-z0-9._/=:-]*) shown="$shown \"$a\"" ;;
      *)                    shown="$shown $a" ;;
    esac
  done
  shown="${shown# }"

  if [ "$DRYRUN" -eq 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$DIM" "$RESET" "$shown"
    return 0
  fi
  printf '  %s+ %s%s\n' "$DIM" "$shown" "$RESET"
  local rc=0
  "$@" || rc=$?
  [ "$rc" -eq 0 ] && RAN="${RAN}${RAN:+$'\n'}$shown"
  return "$rc"
}

# Refs and SHAs are validated before they are ever handed to git. No git subcommand or
# flag is ever built from a variable anywhere in this file - variables only ever occupy
# value positions, passed as discrete arguments. There is no eval and no command built
# by string concatenation.
safe_ref() {
  case "$1" in
    ''|-*|*..*|*' '*) return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._/-]+$'
}

safe_title() {
  # PowerShell 5.1's native-argument quoting is genuinely broken for embedded quotes, so
  # the paired script validates rather than escapes. This one matches it so that the two
  # files behave identically rather than merely similarly.
  case "$1" in
    *'"'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ -n "$1" ]
}

BODY_FILE=''
SQUASH_FILE=''
ERR_FILE=$(mktemp)
cleanup_temp() {
  [ -n "$BODY_FILE" ] && rm -f "$BODY_FILE"
  [ -n "$SQUASH_FILE" ] && rm -f "$SQUASH_FILE"
  rm -f "$ERR_FILE"
  return 0
}
trap cleanup_temp EXIT

# The first line gh wrote to stderr on its last call, unless it only said there is no pull
# request - which the caller reports in its own words. Anything else is the real reason,
# such as origin not being a GitHub host, and hiding it would make the stop lie.
gh_error() {
  local line
  line=$(grep -v '^[[:space:]]*$' "$ERR_FILE" 2>/dev/null | head -1 || true)
  case "$line" in
    *'no pull requests found'*|*'no open pull requests'*) line='' ;;
  esac
  printf '%s' "$line"
}

# Everything git wrote to stderr on its last call, blank lines dropped. A stop whose cause
# cannot be read from the repository quotes this instead of naming one: git's words are
# evidence, and they are never matched against, because they are translated.
git_said() {
  # Trimmed, so that the indentation git puts on a command it suggests does not land on
  # top of the stop's own. The paired script reads the same lines the same way.
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$ERR_FILE" 2>/dev/null \
    | grep -v '^$' | head -10 || true
}

# The fetch is the one mutating command --dry-run still performs; the header says why.
# `git fetch --all --prune` exits non-zero when ANY remote fails, so a fork whose upstream
# no longer resolves fails it while origin fetched perfectly. Which of those happened is
# read from the remotes themselves with a read-only `git ls-remote`, never from git's
# message. $1 is a phrase the headline ends with, empty everywhere but after the merge.
fetch_all() {
  local phrase="$1" fetch_said said='' failed='' name
  printf '  %s+ git fetch --all --prune%s\n' "$DIM" "$RESET"
  git fetch --all --prune >/dev/null 2>"$ERR_FILE" && return 0
  fetch_said=$(git_said)

  if ! git ls-remote --heads origin >/dev/null 2>"$ERR_FILE"; then
    said=$(git_said)
    stop \
      "git fetch could not reach origin$phrase" \
      ${said:+"git said:"} ${said:+"$said"} \
      'your view of the remote is stale, so every check that reads it would be answering' \
      'from old information. Fix the connection and re-run - do not proceed on this'
  fi

  while IFS= read -r name; do
    [ -n "$name" ] && [ "$name" != 'origin' ] || continue
    safe_ref "$name" || continue
    if ! git ls-remote --heads "$name" >/dev/null 2>"$ERR_FILE"; then
      failed="${failed}${failed:+, }$name"
      [ -n "$said" ] || said=$(git_said)
    fi
  done <<EOF
$(git remote)
EOF

  if [ -n "$failed" ]; then
    stop \
      "git fetch failed on $failed, not on origin$phrase" \
      ${said:+"git said:"} ${said:+"$said"} \
      'origin answers, so origin is not what failed. This repository has a remote that' \
      'does not resolve - a fork keeps its upstream here - and one failed remote is enough' \
      'to fail the whole fetch. Fix that remote or remove it, then re-run:' \
      '' \
      '  git remote -v' \
      '  git remote remove <name>'
  fi

  stop \
    "git fetch --all --prune failed$phrase" \
    ${fetch_said:+"git said:"} ${fetch_said:+"$fetch_said"} \
    'origin answers, and so does every other remote here, so the connection is not what' \
    'failed. Act on what git said, then re-run - the refs every check below reads are the' \
    'ones this fetch could not update'
}

# --------------------------------------------------------------------------- context

IN_WORKTREE=0
PRIMARY=''
WT_PATH=''
WT_LOCKED=''
ROOT=''
BRANCH=''
BASE=''
BASE_WHY=''
RESOLVED_DEFAULT=''
BASE_NOTES=''     # newline separated, printed by preflight under the base line

repo_context() {
  # Every reason git refuses to read a repository here arrives as the same exit code, and
  # only git knows which one this is: a path outside a repository, and a checkout owned by
  # another user, read identically from here. So git's own line is what the stop carries.
  local said=''
  if ! git rev-parse --git-dir >/dev/null 2>"$ERR_FILE"; then
    said=$(git_said)
    stop \
      'git will not read a repository here' \
      ${said:+"git said:"} ${said:+"$said"} \
      'run the script from inside the repository you are finishing work in. Where git' \
      'names dubious ownership, the checkout belongs to another user - which a container,' \
      'a sandbox, and a network or cloud-synced path all produce - and git reads it once' \
      'the path is listed as safe, with the command it prints above'
  fi

  local gitdir commondir
  gitdir=$(git rev-parse --path-format=absolute --git-dir)
  commondir=$(git rev-parse --path-format=absolute --git-common-dir)
  if [ "$gitdir" != "$commondir" ]; then IN_WORKTREE=1; fi

  ROOT=$(git rev-parse --path-format=absolute --show-toplevel)

  # The primary checkout is always the first record of the porcelain output, from anywhere
  # including inside a worktree. Read paths from here and never construct them: worktree
  # directory names have no reliable relationship to branch names.
  local line path=''
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        path="${line#worktree }"
        [ -n "$PRIMARY" ] || PRIMARY="$path"
        ;;
      'locked'*)
        if [ "$path" = "$ROOT" ]; then
          WT_LOCKED="${line#locked}"
          WT_LOCKED="${WT_LOCKED# }"
          [ -n "$WT_LOCKED" ] || WT_LOCKED='(no reason recorded)'
        fi
        ;;
    esac
  done <<EOF
$(git worktree list --porcelain)
EOF

  [ "$IN_WORKTREE" -eq 1 ] && WT_PATH="$ROOT"
  return 0
}

# Prints the worktree path holding a given branch, or nothing.
worktree_for_branch() {
  local want="refs/heads/$1" line path=''
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path="${line#worktree }" ;;
      'branch '*)   [ "${line#branch }" = "$want" ] && { printf '%s' "$path"; return 0; } ;;
    esac
  done <<EOF
$(git worktree list --porcelain)
EOF
  return 0
}

# Prints the lock reason for a given worktree path, or nothing.
lock_reason_for() {
  local want="$1" line path=''
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path="${line#worktree }" ;;
      'locked'*)
        if [ "$path" = "$want" ]; then
          local r="${line#locked}"
          r="${r# }"
          [ -n "$r" ] || r='(no reason recorded)'
          printf '%s' "$r"
          return 0
        fi
        ;;
    esac
  done <<EOF
$(git worktree list --porcelain)
EOF
  return 0
}

# Which branch this work merges into. Never hardcoded: workflow.conf's DEFAULT_BASE names
# the default (or origin/HEAD does), and ALT_BASES names every long-lived branch a feature
# branch may target instead. A branch whose history contains an alternate base is finished
# onto it. Where the answer is ambiguous the script refuses rather than guessing, because
# pointing a pull request at the wrong base is the one outcome the alternate-base rule
# exists to prevent. See finishing-work.md section 3 and starting-new-work.md section 4.3.
resolve_base() {
  if [ -n "$BASE_ARG" ]; then
    safe_ref "$BASE_ARG" || { echo "--base is not a valid branch name: $BASE_ARG" >&2; exit 2; }
    git rev-parse --verify -q "refs/remotes/origin/$BASE_ARG" >/dev/null 2>&1 || stop \
      "origin/$BASE_ARG does not exist" \
      "--base must name a branch that exists on the remote"
    BASE="$BASE_ARG"
    BASE_WHY='given with --base'
    return 0
  fi

  local default
  if [ -n "$DEFAULT_BASE" ]; then
    safe_ref "$DEFAULT_BASE" || { echo "workflow.conf: DEFAULT_BASE is not a valid branch name: $DEFAULT_BASE" >&2; exit 2; }
    default="$DEFAULT_BASE"
  else
    default=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
    default="${default#origin/}"
    [ -n "$default" ] || default='main'
  fi
  RESOLVED_DEFAULT="$default"

  # A prefix BASE_BY_PREFIX maps names its base outright - a hotfix/ branch that lands on
  # main while everything else lands on develop. Nothing in the history can say that as
  # reliably as the name the branch was given when it was claimed.
  local prefix mapped
  while read -r prefix mapped; do
    [ -n "$prefix" ] || continue
    case "$BRANCH" in
      "$prefix"/*)
        git rev-parse --verify -q "refs/remotes/origin/$mapped" >/dev/null 2>&1 || stop \
          "origin/$mapped does not exist" \
          "BASE_BY_PREFIX in scripts/workflow.conf maps $prefix/ branches to it"
        BASE="$mapped"
        BASE_WHY="the $prefix/ prefix maps to $mapped in workflow.conf"
        return 0 ;;
    esac
  done <<EOF
$(each_mapping)
EOF

  # Every alternate base that exists on the remote and has diverged from the default is a
  # candidate. One that has not diverged is indistinguishable from the default, and the
  # default is the safe reading. So is one the default contains, such as a main that
  # develop merges from: every branch off the default contains it too.
  local alt candidates='' default_sha alt_sha
  default_sha=$(git rev-parse -q --verify "refs/remotes/origin/$default" 2>/dev/null || true)
  while IFS= read -r alt; do
    [ -n "$alt" ] || continue
    safe_ref "$alt" || { echo "workflow.conf: ALT_BASES holds an invalid branch name: $alt" >&2; exit 2; }
    alt_sha=$(git rev-parse -q --verify "refs/remotes/origin/$alt" 2>/dev/null || true)
    [ -n "$alt_sha" ] || continue
    [ "$alt_sha" != "$default_sha" ] || continue
    if [ -n "$default_sha" ] && git merge-base --is-ancestor "$alt_sha" "$default_sha" 2>/dev/null; then
      BASE_NOTES="${BASE_NOTES}${BASE_NOTES:+$'\n'}ALT_BASES lists $alt, which origin/$default contains, so it is ignored: name its branches with BASE_BY_PREFIX"
      continue
    fi
    candidates="${candidates}${candidates:+$'\n'}$alt"
  done <<EOF
$(each_item "$ALT_BASES")
EOF

  if [ -z "$candidates" ]; then
    BASE="$default"
    BASE_WHY='the default branch'
    return 0
  fi

  # An alternate base in this branch's history means the branch was cut from it.
  local contained='' n_contained=0
  while IFS= read -r alt; do
    [ -n "$alt" ] || continue
    if git merge-base --is-ancestor "refs/remotes/origin/$alt" HEAD 2>/dev/null; then
      contained="${contained}${contained:+$'\n'}$alt"
      n_contained=$((n_contained + 1))
    fi
  done <<EOF
$candidates
EOF

  if [ "$n_contained" -eq 1 ]; then
    BASE="$contained"
    BASE_WHY="this branch contains origin/$contained, an alternate base"
    return 0
  fi

  if [ "$n_contained" -eq 0 ] && git merge-base --is-ancestor "refs/remotes/origin/$default" HEAD 2>/dev/null; then
    BASE="$default"
    BASE_WHY='the default branch'
    return 0
  fi

  # Either several alternate bases are in the history, or the branch is behind every tip.
  # Fall back to whichever it diverged from most recently, and refuse a tie.
  local pool best='' best_n='' n tie=0
  pool="$default"$'\n'"$candidates"
  [ "$n_contained" -gt 1 ] && pool="$contained"
  while IFS= read -r alt; do
    [ -n "$alt" ] || continue
    n=$(git rev-list --count "refs/remotes/origin/$alt..HEAD")
    if [ -z "$best_n" ] || [ "$n" -lt "$best_n" ]; then
      best="$alt"; best_n="$n"; tie=0
    elif [ "$n" -eq "$best_n" ]; then
      tie=1
    fi
  done <<EOF
$pool
EOF

  if [ "$tie" -eq 1 ]; then
    stop \
      'cannot tell which base branch this branch targets' \
      'more than one of these is equally distant from HEAD, and guessing would risk' \
      'pointing the pull request at the wrong branch:' \
      "$(printf '%s\n' "$pool" | sed 's/^/  origin\//')" \
      '' \
      'Say which, explicitly:' \
      '  ./scripts/finish.sh --base <branch> ...'
  fi

  BASE="$best"
  if [ "$best" = "$default" ]; then
    BASE_WHY='the default branch'
  else
    BASE_WHY="this branch diverged from origin/$best, an alternate base"
  fi
}

# True when $1 is a branch this script must never finish from: main, master, the
# resolved base, the configured default, or any alternate base.
is_base_branch() {
  local b
  case "$1" in main|master) return 0 ;; esac
  [ "$1" = "$BASE" ] && return 0
  [ -n "$DEFAULT_BASE" ] && [ "$1" = "$DEFAULT_BASE" ] && return 0
  while IFS= read -r b; do
    [ -n "$b" ] && [ "$1" = "$b" ] && return 0
  done <<EOF
$(long_lived_branches)
EOF
  return 1
}

# Every branch this repository treats as long-lived: the default, main and master, the
# alternate bases and the bases BASE_BY_PREFIX maps to. One per line, possibly repeated.
long_lived_branches() {
  local prefix mapped
  printf '%s\n' "$RESOLVED_DEFAULT" main master
  each_item "$ALT_BASES"
  while read -r prefix mapped; do
    [ -n "$mapped" ] && printf '%s\n' "$mapped"
  done <<EOF
$(each_mapping)
EOF
  return 0
}

# A branch cut from one long-lived branch but resolving to another would have the wrong
# base merged into it by section 3, and its pull request would land it on the wrong
# branch. The sign is a fork point with another long-lived branch that the resolved base
# does not contain: the branch carries commits of that branch which are not on the base.
check_cut_from() {
  [ "$BASE_WHY" = 'given with --base' ] && return 0
  local other fork seen=''
  while IFS= read -r other; do
    [ -n "$other" ] && [ "$other" != "$BASE" ] || continue
    case "$seen" in *" $other "*) continue ;; esac
    seen="$seen $other "
    git rev-parse --verify -q "refs/remotes/origin/$other" >/dev/null 2>&1 || continue
    fork=$(git merge-base HEAD "refs/remotes/origin/$other" 2>/dev/null || true)
    [ -n "$fork" ] || continue
    git merge-base --is-ancestor "$fork" "refs/remotes/origin/$BASE" 2>/dev/null && continue
    stop \
      "this branch was cut from origin/$other, but resolves to origin/$BASE" \
      "origin/$BASE is the base here ($BASE_WHY), but the branch" \
      "carries commits of origin/$other that origin/$BASE does not have. Section 3 would" \
      "merge origin/$BASE into it, and its pull request would land all of it on $BASE." \
      '' \
      "If it belongs on $other, say so:  ./scripts/finish.sh --base $other ..." \
      "or give such branches a prefix that BASE_BY_PREFIX in scripts/workflow.conf maps to $other." \
      "If it belongs on $BASE, it was cut from the wrong branch: tell the user and wait"
  done <<EOF
$(long_lived_branches)
EOF
  return 0
}

# --------------------------------------------------------------- section 1: preflight

CLAIM_SHA=''
CLAIM_SUBJECT=''
CLAIM_BODY=''
SCOPE=''
CLAIM_TOUCHES=''
COMMITS=0
GH_LOGIN=''

# Pulls one "Field: value" paragraph out of the claim commit body, joined onto one line.
claim_field() {
  printf '%s\n' "$CLAIM_BODY" | awk -v want="$1:" '
    index($0, want) == 1 { inblock = 1; sub(/^[^:]*:[ \t]*/, ""); buf = $0; next }
    inblock && NF       { buf = buf " " $0; next }
    inblock && !NF      { exit }
    END                 { if (buf != "") print buf }
  '
}

preflight() {
  CUR_SECTION=1
  section 'Preflight'

  git remote | grep -qx origin || stop \
    'there is no remote called origin' \
    'this script talks to origin by name, as the whole document does'

  BRANCH=$(git symbolic-ref -q --short HEAD) || stop \
    'HEAD is detached' \
    'you are not on a branch, so there is nothing to finish' \
    'git switch <your-branch> first'

  load_capabilities
  require_github_route

  # The fetch is the one mutating command --dry-run still performs. Every answer below,
  # the base branch included, depends on remote-tracking refs being current, and the
  # document's own rule is that a check against a stale remote is worse than no check
  # because it answers with authority.
  fetch_all ''

  resolve_base

  if is_base_branch "$BRANCH"; then
    stop \
      "you are on $BRANCH" \
      'this script finishes a feature branch. It never pushes to a base branch, and' \
      'section 5 of the document is explicit that there is no situation where pushing' \
      'straight to a base branch is the answer'
  fi

  if [ -n "$(git status --porcelain)" ]; then
    stop \
      'the working tree is not clean' \
      'uncommitted work exists in exactly one place, so this script will not stash it,' \
      'sweep it into a commit, or switch branches over it. Decide what those changes are' \
      'for, then re-run:' \
      '' \
      "$(git status --porcelain | head -10 | sed 's/^/  /')"
  fi

  git rev-parse --verify -q "refs/remotes/origin/$BASE" >/dev/null 2>&1 || stop \
    "origin/$BASE does not exist" \
    'name the base branch with DEFAULT_BASE in scripts/workflow.conf'

  check_cut_from

  COMMITS=$(git rev-list --count "origin/$BASE..HEAD")
  if [ "$COMMITS" -eq 0 ]; then
    stop \
      "this branch has no commits that origin/$BASE does not already have" \
      'there is nothing here to finish'
  fi

  # The claim commit is the first commit off the base branch.
  CLAIM_SHA=$(git rev-list --reverse --topo-order "origin/$BASE..HEAD" | sed -n '1p')
  CLAIM_SUBJECT=$(git log -1 --format='%s' "$CLAIM_SHA")
  CLAIM_BODY=$(git log -1 --format='%B' "$CLAIM_SHA")

  local claim_author me_name me_email me
  claim_author=$(git log -1 --format='%an <%ae>' "$CLAIM_SHA")
  me_name=$(git config user.name || true)
  me_email=$(git config user.email || true)
  me="$me_name <$me_email>"

  if [ -z "$me_name" ] || [ -z "$me_email" ]; then
    stop \
      'your git identity is not set' \
      'the claim-commit author check cannot run without it:' \
      '  git config --global user.name "Your Name"' \
      '  git config --global user.email "you@example.com"'
  fi

  if [ "$claim_author" != "$me" ]; then
    stop \
      'you did not create this branch' \
      "the claim commit was written by $claim_author" \
      "you are $me" \
      "the claim commit is the first commit after origin/$BASE ($BASE_WHY)" \
      '' \
      "finishing someone else's work is their decision and their timing - they may know" \
      'something about it that you do not. Tell them it looks ready and wait'
  fi

  SCOPE="$SCOPE_ARG"
  if [ -z "$SCOPE" ]; then
    SCOPE=$(claim_field 'Scope')
  fi
  CLAIM_TOUCHES=$(claim_field 'Touches')

  case "$CLAIM_SUBJECT" in
    claim:*) : ;;
    *)
      if [ -z "$SCOPE" ]; then
        stop \
          'the first commit on this branch is not a claim commit' \
          "its subject is: $CLAIM_SUBJECT" \
          'starting-new-work.md section 4.4 says the first commit off the base branch' \
          'declares the scope, and this script reads it to write the pull request body.' \
          'Either that step was skipped, or the base branch resolved wrongly.' \
          '' \
          'If the branch is genuinely fine, supply the scope directly:' \
          '  ./scripts/finish.sh --scope "what this branch does"'
      fi
      ;;
  esac

  # Only reachable without gh on the bare run, which require_github_route lets through.
  # Left empty rather than guessed: merge_pull_request compares it against the pull
  # request's author to enforce "never merge a pull request you did not open", and a
  # fabricated login would defeat that check rather than degrade it.
  if [ "$CAP_GH" -eq 1 ]; then
    local gh_said
    # Judged by exit code and by what came back, so that a gh which fails quietly is
    # caught with the one that says why.
    GH_LOGIN=$(gh api user --jq .login 2>"$ERR_FILE") || GH_LOGIN=''
    if [ -z "$GH_LOGIN" ]; then
      gh_said=$(gh_error)
      stop \
        'gh could not read your GitHub login' \
        ${gh_said:+"gh said: $gh_said"} \
        'it is the gh session that failed here, not your identity: the token may be missing' \
        'the read:user scope, an SSO authorisation may have lapsed, or GitHub may have' \
        'answered with an error. Check the session, and log in again if it asks you to:' \
        '' \
        '  gh auth status' \
        '  gh auth login' \
        '' \
        'docs/development/setting-up.md section 3.3 has the prompts and the answers. The' \
        "merge stage compares this login against the pull request's author to enforce" \
        '"never merge a pull request you did not open", so it is never guessed'
    fi
  fi

  fine "branch        $BRANCH"
  fine "base          origin/$BASE  ($BASE_WHY)"
  if [ -n "$BASE_NOTES" ]; then
    printf '%s\n' "$BASE_NOTES" | while IFS= read -r line; do action "note          $line"; done
  fi
  fine "commits       $COMMITS ahead of origin/$BASE"
  fine "claim         $CLAIM_SUBJECT"
  fine "author        $claim_author"
  [ -n "$GH_LOGIN" ] && fine "github        $GH_LOGIN"
  if [ "$IN_WORKTREE" -eq 1 ]; then
    fine "worktree      $WT_PATH"
    fine "primary       $PRIMARY"
  fi
}

# ------------------------------------------------------- section 2: is it finished?

HAS_CI=0
HAS_BUILD=''

# Emits one line per added line in the diff, as "path:lineno<TAB>content".
added_lines() {
  git diff "origin/$BASE...HEAD" -U0 | awk '
    /^\+\+\+ / { f = $0; sub(/^\+\+\+ b\//, "", f); next }
    /^@@ /     { if (match($0, /\+[0-9]+/)) { ln = substr($0, RSTART + 1, RLENGTH - 1) + 0 } next }
    /^\+/      { print f ":" ln "\t" substr($0, 2); ln++ }
  '
}

# Prints "path:lineno" for every added line whose content matches the extended regular
# expression $1, sorted. $2 is 'i' for a case-insensitive match and empty otherwise. $3 is
# an extended regular expression that excludes a content line from the result, or empty.
#
# The path is not part of the match. added_lines emits "path:lineno<TAB>content", so a
# pattern handed the whole line matches the path too, and a repository with a directory
# named home/ or Users/ has every added line under it reported as scaffolding. The
# PowerShell twin matches the content field, and this is the same rule.
#
# The match stays in grep rather than moving into awk: these patterns use interval
# expressions such as {36}, and the awk that ships with macOS does not support them, so an
# awk secret scan matches nothing there and says so no more loudly than an empty diff.
match_added_content() {
  local re="$1" fold="$2" skip="$3" lines nums
  lines=$(added_lines)
  [ -n "$lines" ] || return 0

  # grep -n numbers the content stream, which holds one line per added line, so the number
  # it prints is the index back into $lines.
  if [ "$fold" = 'i' ]; then
    nums=$(printf '%s\n' "$lines" | cut -f2- | grep -inE "$re" || true)
  else
    nums=$(printf '%s\n' "$lines" | cut -f2- | grep -nE "$re" || true)
  fi
  [ -z "$skip" ] || nums=$(printf '%s\n' "$nums" | grep -ivE "$skip" || true)
  nums=$(printf '%s\n' "$nums" | cut -d: -f1 | grep -v '^$' || true)
  [ -n "$nums" ] || return 0

  # index and substr rather than a regex: nothing here needs one, and the awk that ships
  # with macOS is the reason the matching stayed in grep in the first place.
  printf '%s\n' "$lines" | awk -v nums="$nums" '
    BEGIN { n = split(nums, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i] + 0] = 1 }
    (FNR in want) { i = index($0, "\t"); print (i ? substr($0, 1, i - 1) : $0) }
  ' | sort -u
}

# True when $1 is one of workflow.conf's LOCKFILES, by file name anywhere in the tree.
is_lockfile() {
  local lf
  while IFS= read -r lf; do
    [ -n "$lf" ] || continue
    case "$1" in
      "$lf"|*/"$lf") return 0 ;;
    esac
  done <<EOF
$(each_item "$LOCKFILES")
EOF
  return 1
}

# True when $1 matches one of workflow.conf's GOVERNING_PATHS, which are glob patterns
# from the repository root. An unquoted variable in a case pattern is matched as a glob,
# and in a case pattern `*` also matches `/`, so `.github/*` covers the whole tree.
is_governing_path() {
  local gp
  while IFS= read -r gp; do
    [ -n "$gp" ] || continue
    # shellcheck disable=SC2254
    case "$1" in
      $gp) return 0 ;;
    esac
  done <<EOF
$(each_item "$GOVERNING_PATHS")
EOF
  return 1
}

scan_paths() {
  local added changed path attr
  added=$(git diff --name-only --diff-filter=A "origin/$BASE...HEAD")
  changed=$(git diff --name-only "origin/$BASE...HEAD")

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      .env|.env.*|*/.env|*/.env.*|*.pem|*.key|id_rsa*|*/id_rsa*|*.p12|*.pfx)
        finding 'credentials' "$path - credentials do not belong in the repository"
        add_flagged "$path"
        continue ;;
      .vscode/*|.idea/*|*.swp|.DS_Store|*/.DS_Store|Thumbs.db|*/Thumbs.db)
        finding 'editor or OS' "$path - personal config, not a project change"
        add_flagged "$path"
        continue ;;
    esac
    if is_lockfile "$path"; then
      finding 'lockfile' "$path - a new dependency is a review question, not housekeeping"
      add_flagged "$path"
    elif is_governing_path "$path"; then
      finding 'repo-governing' "$path - changes the rules everyone else works under"
      add_flagged "$path"
    fi
  done <<EOF
$changed
EOF

  # Binary additions, read from the repository's own .gitattributes rather than a
  # hardcoded extension list that would drift away from it. The `binary` attribute is
  # shorthand for -diff -merge -text, and the -merge half is what makes these files a
  # human decision under section 3.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    attr=$(git check-attr binary -- "$path" 2>/dev/null || true)
    case "$attr" in
      *": binary: set")
        finding 'binary file' "$path - marked unmergeable by .gitattributes; single-writer file"
        add_flagged "$path" ;;
    esac
  done <<EOF
$added
EOF

  local shortstat total
  shortstat=$(git diff --shortstat "origin/$BASE...HEAD" || true)
  # `|| true`: an empty diff gives grep nothing to match, and under pipefail that would
  # end the run silently.
  total=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}' || true)
  if [ "${total:-0}" -gt "$LARGE_DIFF_LINES" ]; then
    finding 'large diff' "$total changed lines - large diffs hide things"
  fi
}

scan_scaffolding() {
  local re hits
  # Language-neutral leftovers first, then the common per-language ones. A project adds
  # its own with SCAFFOLDING_PATTERN in workflow.conf rather than by editing this line.
  re='TODO:? ?remove|FIXME|XXX|HACK|debugger;|\.only\(|console\.log\(|C:\\\\|/Users/|/home/'
  re="$re"'|dbg!\(|println!\(|eprintln!\(|todo!\(|unimplemented!\(|#\[ignore\]'
  re="$re"'|breakpoint\(\)|pdb\.set_trace|binding\.pry|byebug'
  [ -n "$SCAFFOLDING_PATTERN" ] && re="$re|$SCAFFOLDING_PATTERN"
  # The shipped scripts quote these patterns in their own text, so adopting or updating
  # them would otherwise report the workflow's own files as leftovers.
  hits=$(match_added_content "$re" '' '' \
    | grep -vE '^scripts/((finish|setup|env-capabilities)\.(sh|ps1)|finish-project\.(sh|ps1)\.example):' \
    || true)
  if [ -n "$hits" ]; then
    local n
    n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
    finding 'debug scaffolding' "$n added line(s) look like leftovers:"
    printf '%s\n' "$hits" | head -12 | while IFS= read -r h; do plain "  $h"; done
  fi
}

scan_secrets() {
  local vendor generic reference hits
  # Deliberately conservative: over-reporting a secret is safe, missing one is not.
  #
  # Two patterns, because only one of them can be narrowed. A vendor prefix is
  # unambiguous: a line carrying one is a hit whatever else the line says.
  vendor='ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|gh[ousr]_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-|AIza[0-9A-Za-z_-]{35}'

  # The generic pattern claims that a value is a literal credential. Its alphabet holds no
  # $, {, ( or <, so ${VAR}, getenv(...), os.environ[...] and <PLACEHOLDER> cannot match.
  generic='(secret|token|passwd|password|api[_-]?key)[[:space:]]*[:=][[:space:]]*'"['\"]"'?[A-Za-z0-9_+/=.-]{12,}'

  # Each entry is a claim about a value that names a credential rather than carrying one:
  # an environment accessor reads it where the program runs and holds nothing itself. This
  # narrows the generic pattern alone, so it can never hide a vendor prefix. Do not widen
  # it to clear a stop - a stop clearable only by asserting something false teaches people
  # to assert it.
  reference='os\.environ|os\.getenv|process\.env|import\.meta\.env|deno\.env|system\.getenv|getenv|env\.fetch'

  hits=$(
    { match_added_content "$vendor" 'i' ''
      match_added_content "$generic" 'i' "$reference"
    } | sort -u || true
  )
  if [ -n "$hits" ]; then
    # The matched text is never printed. A script that echoes a credential into a
    # terminal log, a CI log or an agent transcript has made the problem worse.
    stop \
      'an added line looks like a credential' \
      'the matched text is deliberately not shown - printing it would spread it further.' \
      'Look at these lines yourself:' \
      '' \
      "$(printf '%s\n' "$hits" | head -20 | sed 's/^/  /')" \
      '' \
      'If it is a false positive, the fix is to change the line so it does not read as a' \
      'secret. There is no flag to wave this through, and that is deliberate'
  fi
}

probe_build_system() {
  local f
  HAS_BUILD=''
  for f in Cargo.toml package.json pyproject.toml go.mod pom.xml Makefile; do
    [ -e "$ROOT/$f" ] && HAS_BUILD="${HAS_BUILD}${HAS_BUILD:+, }$f"
  done
  # The project's own check command counts when it is a file in the repository, as the
  # default ./scripts/check.sh is: a repository with one has something to run.
  f="${CHECK_COMMAND%% *}"
  f="${f#./}"
  case "$f" in
    ''|/*|*..*) : ;;
    *) [ -f "$ROOT/$f" ] && HAS_BUILD="${HAS_BUILD}${HAS_BUILD:+, }$f" ;;
  esac
  [ -d "$ROOT/.github/workflows" ] && HAS_CI=1
  return 0
}

finished_checks() {
  CUR_SECTION=2
  local found=''

  section 'Evidence for you to judge - not a verdict'

  plain 'Claim:'
  printf '%s\n' "$CLAIM_BODY" | sed 's/^/    /'
  echo ''

  plain 'Files actually changed:'
  git diff --stat "origin/$BASE...HEAD" | sed 's/^/    /'
  echo ''

  # Claim Touches versus reality, both directions. The difference between the two is
  # often the most informative thing about a branch.
  if [ -n "$CLAIM_TOUCHES" ]; then
    fine "claimed to touch: $CLAIM_TOUCHES"
  else
    finding 'no Touches' 'the claim commit has no Touches: field to compare against'
  fi

  scan_paths
  scan_scaffolding
  scan_secrets
  if command -v project_scans >/dev/null 2>&1; then
    project_scans
  fi
  check_declarations
  # The title is built here rather than at section 4, so that a branch name it cannot use
  # is a finding in the bare report, while there is still time to pass --title.
  build_title
  probe_build_system

  if [ -z "$HAS_BUILD" ] && [ "$HAS_CI" -eq 0 ]; then
    fine 'checks        no build system and no CI on this branch - there is nothing to run'
  else
    found="$HAS_BUILD"
    [ "$HAS_CI" -eq 1 ] && found="${found}${found:+, }.github/workflows"
    fine "checks        found ${found:-none}${found:+ }- this script did not run them, and does not claim to"
    if [ "$HAS_CI" -eq 1 ]; then
      fine '              CI runs them on the pull request, and --merge refuses to land on a failing one'
    fi
  fi

  echo ''
  if [ "$FINDINGS" -eq 0 ]; then
    good 'No findings. That is not an approval - read the diff above.'
  else
    printf '  %s%s finding(s). None of this is an approval.%s\n' "$YELLOW" "$FINDINGS" "$RESET"
  fi
}

# The acknowledgement gate. Not an override: it can only name paths this run flagged,
# it has to be re-supplied every run because the flagged set is recomputed from the
# actual diff, and what was acknowledged is written into the pull request body where a
# human reviewer sees it. Scaffolding findings deliberately do not gate - gating on them
# would train people to acknowledge reflexively, which is how a gate stops working.
ACK_OK=''
check_acknowledgements() {
  [ -n "$FLAGGED" ] || return 0

  local acked='' item found
  if [ -n "$ACK" ]; then
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      found=0
      while IFS= read -r f; do
        [ "$f" = "$item" ] && found=1
      done <<EOF
$FLAGGED
EOF
      if [ "$found" -eq 0 ]; then
        echo "--acknowledge names a path this run did not flag: $item" >&2
        echo "it can only acknowledge findings that actually appeared, so that it cannot be" >&2
        echo "used to pre-authorise anything. Flagged this run:" >&2
        printf '%s\n' "$FLAGGED" | sed 's/^/  /' >&2
        exit 2
      fi
      acked="${acked}${acked:+, }$item"
    done <<EOF
$(printf '%s' "$ACK" | tr ',' '\n' | sed 's/^ *//; s/ *$//')
EOF
  fi

  local unacked='' f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case ",$(printf '%s' "$acked" | tr -d ' ')," in
      *",$f,"*) : ;;
      *) unacked="${unacked}${unacked:+$'\n'}$f" ;;
    esac
  done <<EOF
$FLAGGED
EOF

  if [ -n "$unacked" ]; then
    stop \
      'some changed files need a decision before this opens a pull request' \
      'these were flagged above. Look at each one, and if it belongs in the branch, say so:' \
      '' \
      "$(printf '%s\n' "$unacked" | sed 's/^/  /')" \
      '' \
      "  ./scripts/finish.sh --pr --testing \"$TESTING\" --acknowledge \"$(printf '%s' "$unacked" | tr '\n' ',' | sed 's/,$//')\"" \
      '' \
      'What you acknowledge goes into the pull request body, where a reviewer sees it'
  fi

  ACK_OK="$acked"
}

# --------------------------------------------------- section 3: bring up to date

# Whether a merge is in progress. Git sets MERGE_HEAD for the duration of one and removes
# it when the merge ends, whichever way it ends, so the ref is the whole answer. Read from
# the ref, never from git's message, which is translated.
merge_in_progress() {
  git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1
}

update_from_base() {
  CUR_SECTION=3
  section "Bringing the branch up to date with origin/$BASE"

  # Section 3 opens with `git fetch origin`; preflight already did a wider fetch seconds
  # ago, so repeating it would only add a second way to fail.
  if run git merge "origin/$BASE"; then
    # Do not claim a clean merge that was never attempted. A dry run that reports
    # success it did not earn is worse than no dry run at all.
    if [ "$DRYRUN" -eq 1 ]; then
      fine 'not attempted (dry run) - whether this merges cleanly is still unknown'
    else
      good 'merged cleanly'
    fi
    return 0
  fi

  # Capture the conflict before aborting - afterwards there is nothing left to report. The
  # exit code alone does not say a merge conflicted: a hook that refuses it, histories with
  # nothing in common, a merge driver and local changes the merge would overwrite all fail
  # with no file conflicted. This list is what tells the two apart.
  local conflicted path attr who abort_rc=0 recovery
  conflicted=$(git diff --name-only --diff-filter=U || true)

  if [ -n "$conflicted" ]; then
    echo '' >&2
    printf '%sConflicts:%s\n' "$RED" "$RESET" >&2
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      attr=$(git check-attr binary -- "$path" 2>/dev/null || true)
      who=$(git log -1 --format='%an' "origin/$BASE" -- "$path" 2>/dev/null || true)
      case "$attr" in
        *": binary: set")
          printf '  %-50s binary - these do not merge, one side wins\n' "$path" >&2 ;;
        *)
          printf '  %-50s other side last written by %s\n' "$path" "${who:-unknown}" >&2 ;;
      esac
    done <<EOF
$conflicted
EOF
  fi

  run git merge --abort || abort_rc=$?

  # What the abort left behind is read from the repository, not assumed from having asked
  # for it. An abort can fail - on Windows a process holding one of the files open is
  # enough - and a branch called untouched while a merge is still in progress is a branch
  # walked away from in that state.
  if merge_in_progress; then
    recovery=$(printf '%s\n' \
      'git merge --abort did not end the merge: MERGE_HEAD is still set, so the merge is' \
      'still in progress and the working tree holds part of it. Nothing here touches it' \
      'further. Read what is in the tree, then end the merge yourself:' \
      '  git status' \
      '  git merge --abort')
  elif [ "$abort_rc" -ne 0 ]; then
    recovery=$(printf '%s\n' \
      'git merge --abort failed, and no merge is in progress: what the working tree holds' \
      'is what git left in it. Read that before anything else:' \
      '  git status')
  else
    recovery='the merge has been aborted, so the branch is exactly as it was.'
  fi

  if [ -z "$conflicted" ]; then
    stop \
      'the merge failed without conflicting' \
      "$recovery" \
      '' \
      'No file is conflicted, so there is nothing here to resolve. What refused the merge is' \
      'in git'"'"'s own output above this stop - a hook, histories with nothing in common, a' \
      'merge driver, or local changes the merge would overwrite. This script does not read' \
      'that message for you: it is translated, and a guess at the cause sends you after the' \
      'wrong one.' \
      '' \
      'Act on what git said, following section 3, then run this stage again'
  fi

  stop \
    'the merge conflicts' \
    "$recovery" \
    '' \
    'This script does not resolve conflicts, including in files you wrote. A conflict is a' \
    'question about intent, and resolving one by picking whichever side looks more complete' \
    'is how half a feature disappears without a single error message.' \
    '' \
    'Resolve it yourself following section 3, or talk to whoever wrote the other side'
}

# ------------------------------------------------------ section 4: open the pull request

PR_NUMBER=''
PR_URL=''
PR_TITLE=''

# The branch-name prefix, from workflow.conf's BRANCH_TYPES. Empty when none matches.
pr_type() {
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$BRANCH" in
      "$t"/*) printf '%s' "$t"; return 0 ;;
    esac
  done <<EOF
$(each_item "$BRANCH_TYPES")
$(each_mapping | cut -d' ' -f1)
EOF
  printf ''
}

build_title() {
  if [ -n "$TITLE_ARG" ]; then
    safe_title "$TITLE_ARG" || { echo '--title must not contain a double quote or a newline' >&2; exit 2; }
    PR_TITLE="$TITLE_ARG"
    return 0
  fi
  local type outcome
  type=$(pr_type)
  outcome="${CLAIM_SUBJECT#claim: }"
  if [ -z "$type" ]; then
    finding 'branch name' "$BRANCH does not start with a type from workflow.conf ($BRANCH_TYPES)"
    fine "                   the title will be \"$outcome\" - pass --title to choose it"
    PR_TITLE="$outcome"
  else
    PR_TITLE="$type: $outcome"
  fi
  safe_title "$PR_TITLE" || stop \
    'the claim commit subject cannot be used as a pull request title' \
    'it contains a double quote or a newline. Pass one with --title'
}

# Writes a "Label: value" block, wrapped, with continuations lined up under the value.
field() {
  local label="$1" text="$2"
  [ -n "$text" ] || return 0
  printf '%s\n' "$text" | fold -s -w 88 | awk -v l="$label" '
    NR == 1 { printf "%-10s%s\n", l, $0; next }
            { printf "%-10s%s\n", "", $0 }
  '
}

build_pr_body() {
  local touches shortstat plus minus notes
  touches=$(git diff --name-only "origin/$BASE...HEAD" | paste -sd, - | sed 's/,/, /g' || true)
  shortstat=$(git diff --shortstat "origin/$BASE...HEAD" || true)
  plus=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
  minus=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)

  notes="$NOTES"
  [ -n "$ACK_OK" ] && notes="${notes}${notes:+$'\n'}Reviewed and intended: $ACK_OK"
  [ -n "$DECLARED_USED" ] && notes="${notes}${notes:+$'\n'}Declared with --declare: $DECLARED_USED"
  [ -n "$NOTES_EXTRA" ] && notes="${notes}${notes:+$'\n'}$NOTES_EXTRA"
  if [ -z "$HAS_BUILD" ] && [ "$HAS_CI" -eq 0 ]; then
    notes="${notes}${notes:+$'\n'}No build system or CI on this branch - nothing to run locally."
  fi

  BODY_FILE=$(mktemp)
  {
    field 'Scope:'   "$SCOPE"
    field 'Touches:' "${touches:+$touches }(+${plus:-0} -${minus:-0})"
    field 'Testing:' "$TESTING"
    local line first=1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ "$first" -eq 1 ]; then field 'Notes:' "$line"; first=0; else field '' "$line"; fi
    done <<EOF
$notes
EOF
  } > "$BODY_FILE"
}

open_pull_request() {
  CUR_SECTION=4
  section 'Opening the pull request'

  local existing st
  existing=''
  [ "$CAP_GH" -eq 1 ] && existing=$(gh pr view "$BRANCH" --json number,state,url --jq '[.number,.state,.url]|@tsv' 2>/dev/null || true)
  if [ -n "$existing" ]; then
    IFS=$'\t' read -r PR_NUMBER st PR_URL <<EOF
$existing
EOF
    if [ "$st" = 'OPEN' ]; then
      # Refresh the body rather than leaving it as it was. Touches and the diff counts
      # are computed from the branch, so after another commit the old body is quietly
      # wrong - and a stale Touches line is exactly what section 4 says the body exists
      # to get right.
      [ -n "$PR_TITLE" ] || build_title
      build_pr_body
      run gh pr edit "$PR_NUMBER" --body-file "$BODY_FILE" || stop \
        "gh pr edit failed for pull request #$PR_NUMBER"
      # run() returns success under --dry-run without running anything, so this reports
      # the push and the refresh only where they happened.
      if [ "$DRYRUN" -eq 1 ]; then
        fine "pull request #$PR_NUMBER is already open - not updated (dry run)"
        fine 'a real run pushes the branch and refreshes its body'
      else
        good "pull request #$PR_NUMBER already open - pushed the update and refreshed its body"
      fi
      plain "$PR_URL"
      return 0
    fi
    stop \
      "a pull request already exists for this branch and its state is $st" \
      "$PR_URL" \
      'this script will not reopen it'
  fi

  [ -n "$PR_TITLE" ] || build_title
  build_pr_body

  plain "title  $PR_TITLE"
  echo ''
  sed 's/^/    /' "$BODY_FILE"
  echo ''

  # The hand-off. Everything section 4 needs has been computed and the branch is pushed;
  # only the call that opens the pull request cannot be made from here. Print exactly what
  # to open it with, then exit 3 - "not yet", the same code retry_later uses, so a caller
  # can tell an unfinished stage from a refused one.
  if [ "$CAP_GH" -ne 1 ]; then
    section 'Opening it from here'
    if [ "$DRYRUN" -eq 1 ]; then
      plain 'Dry run: nothing was pushed, so there is nothing to open yet. Re-run without'
      plain '--dry-run first. What that would print is:'
    elif [ "$ENV_TIER" = 'cloud-agent' ]; then
      plain 'The branch is pushed and the body above is what the pull request needs. gh'
      plain "cannot run in a $ENV_LABEL, so open it with your agent's GitHub tool instead"
      plain '(in Claude Code, mcp__github__create_pull_request):'
    else
      plain 'The branch is pushed and the body above is what the pull request needs. gh'
      plain 'cannot open it from here, so open it by hand with these values:'
    fi
    echo ''
    plain "    base   $BASE"
    plain "    head   $BRANCH"
    plain "    title  $PR_TITLE"
    plain "    body   the block printed above, verbatim"
    [ "$DRAFT" -eq 1 ] && plain '    draft  true'
    echo ''
    if [ "$ENV_TIER" = 'cloud-agent' ]; then
      plain 'Then merge it with --merge from a workstation, or with the same tools from here'
      plain '(in Claude Code, mcp__github__merge_pull_request with merge_method "squash") -'
    else
      plain 'Then merge it with --merge once gh works here, or squash-merge it by hand and'
      plain 'retire the branch with --cleanup --sha <the squashed commit> -'
    fi
    plain 'after reading the checks. finishing-work.md section 9 binds either way: never'
    plain 'merge with checks failing, and never merge a pull request you did not open.'
    echo ''
    exit 3
  fi

  if [ "$DRAFT" -eq 1 ]; then
    run gh pr create --base "$BASE" --title "$PR_TITLE" --body-file "$BODY_FILE" --draft || stop 'gh pr create failed'
  else
    run gh pr create --base "$BASE" --title "$PR_TITLE" --body-file "$BODY_FILE" || stop 'gh pr create failed'
  fi

  if [ "$DRYRUN" -eq 1 ]; then
    PR_NUMBER='(none - dry run)'
    return 0
  fi

  PR_NUMBER=$(gh pr view "$BRANCH" --json number --jq .number)
  PR_URL=$(gh pr view "$BRANCH" --json url --jq .url)
  good "opened #$PR_NUMBER"
  plain "$PR_URL"
}

# --------------------------------------------------------------- section 5: merge it

CHECK_LINE=''

# Check state never comes from `gh pr checks`. That command exits 1 when a repository has
# no checks at all, which is indistinguishable from "checks failed" - and with no CI in
# this repository yet, no checks is the normal case. statusCheckRollup gives an empty
# array instead, which is a third state that can be told apart from the other two.
resolve_check_state() {
  local total pending failing failing_names
  total=$(gh pr view "$PR_NUMBER" --json statusCheckRollup --jq '.statusCheckRollup | length' || true)
  if [ -z "$total" ]; then
    stop \
      'could not read the check status for this pull request' \
      'this script does not merge on an answer it failed to obtain'
  fi
  pending=$(gh pr view "$PR_NUMBER" --json statusCheckRollup --jq '
    [ .statusCheckRollup[]
      | select(.status == "QUEUED" or .status == "IN_PROGRESS" or .status == "WAITING"
               or .status == "PENDING" or .state == "PENDING") ] | length')
  failing=$(gh pr view "$PR_NUMBER" --json statusCheckRollup --jq '
    [ .statusCheckRollup[]
      | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "CANCELLED"
               or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE"
               or .state == "FAILURE" or .state == "ERROR") ] | length')

  if [ "$total" -eq 0 ]; then
    if [ "$HAS_CI" -eq 1 ]; then
      stop \
        'this repository has workflows but the pull request has no check runs' \
        'workflows are configured and produced nothing. That is broken CI, not a green' \
        'branch, and merging on it would mean merging unverified'
    fi
    CHECK_LINE='none configured on this repository - nothing was verified'
    fine "checks        $CHECK_LINE"
    return 0
  fi

  if [ "$failing" -gt 0 ]; then
    failing_names=$(gh pr view "$PR_NUMBER" --json statusCheckRollup --jq '
      .statusCheckRollup[]
      | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "CANCELLED"
               or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE"
               or .state == "FAILURE" or .state == "ERROR")
      | (.name // .context // "unnamed")')
    stop \
      "$failing of $total checks are failing" \
      "$(printf '%s\n' "$failing_names" | sed 's/^/  /')" \
      '' \
      'Fix it on the branch and push. Never merge red'
  fi

  if [ "$pending" -gt 0 ]; then
    retry_later \
      "$pending of $total checks are still running" \
      'nothing has been changed. Re-run --merge when they finish'
  fi

  CHECK_LINE="$total check(s) passed"
  good "checks        $CHECK_LINE"
}

SQUASH_SHA=''

merge_pull_request() {
  CUR_SECTION=5
  section 'Merging'

  # One call, one line back, tab separated. gh embeds its own jq, so nothing extra needs
  # to be installed and no JSON is parsed by hand here.
  local json
  json=$(gh pr view "$BRANCH" \
    --json number,state,isDraft,author,baseRefName,headRefOid,mergeable,mergeStateStatus,url,title \
    --jq '[.number, .state, (.isDraft|tostring), .author.login, .baseRefName, .headRefOid,
           .mergeable, .mergeStateStatus, .url, .title] | @tsv' 2>"$ERR_FILE" || true)
  if [ -z "$json" ]; then
    local gh_said
    gh_said=$(gh_error)
    [ -z "$gh_said" ] || stop \
      'gh could not read the pull request for this branch' \
      "gh said: $gh_said"
    stop \
      'there is no pull request for this branch' \
      'open one first:  ./scripts/finish.sh --pr --testing "..."'
  fi

  local state isdraft author baseref headoid mergeable mergestate
  IFS=$'\t' read -r PR_NUMBER state isdraft author baseref headoid mergeable mergestate PR_URL PR_TITLE <<EOF
$json
EOF

  [ "$state" = 'OPEN' ] || stop \
    "pull request #$PR_NUMBER is $state, not OPEN" "$PR_URL"

  [ "$isdraft" != 'true' ] || stop \
    "pull request #$PR_NUMBER is a draft" \
    'a draft says the work is visible but not landable. Mark it ready first:' \
    "  gh pr ready $PR_NUMBER"

  [ "$author" = "$GH_LOGIN" ] || stop \
    "pull request #$PR_NUMBER was opened by $author, not by you ($GH_LOGIN)" \
    'never merge or close a pull request you did not open. Tell them it looks ready'

  [ "$baseref" = "$BASE" ] || stop \
    "pull request #$PR_NUMBER targets $baseref, but this branch resolves to $BASE" \
    'merging it would put this work on the wrong branch. If the pull request is right and' \
    "the resolution is wrong, re-run with --base $baseref"

  local head_local
  head_local=$(git rev-parse HEAD)
  [ "$headoid" = "$head_local" ] || stop \
    'the pull request head is not what you have locally' \
    "  pull request  $headoid" \
    "  your HEAD     $head_local" \
    'either you have commits you did not push, or someone pushed to the branch. Either way' \
    'this script would be merging code it never looked at'

  [ "$mergeable" != 'CONFLICTING' ] || stop \
    "GitHub reports pull request #$PR_NUMBER has conflicts" \
    'bring the branch up to date first:  ./scripts/finish.sh --pr --testing "..."' \
    'do not resolve conflicts in the GitHub web editor'

  case "$mergestate" in
    BEHIND)
      retry_later \
        "pull request #$PR_NUMBER is behind $BASE" \
        'bring it up to date and push, then re-run:' \
        '  ./scripts/finish.sh --pr --testing "..."' ;;
    BLOCKED|DIRTY)
      stop \
        "GitHub reports the merge state as $mergestate" \
        "$PR_URL" \
        'something on the pull request is not satisfied. Look at it before merging' ;;
  esac

  fine "pull request  #$PR_NUMBER  $PR_TITLE"
  fine "head          $headoid"
  resolve_check_state

  # Left alone, gh concatenates every commit message on the branch into the squash body,
  # claim commit included, which reads badly and buries the point. The (#N) suffix is
  # GitHub's own default and every existing squash on main carries it - passing --subject
  # removes it unless it is put back here.
  local subject
  subject="$PR_TITLE (#$PR_NUMBER)"
  SQUASH_FILE=$(mktemp)
  field 'Scope:' "$SCOPE" > "$SQUASH_FILE"

  echo ''
  plain "squash subject  $subject"
  sed 's/^/    /' "$SQUASH_FILE"
  echo ''

  # --match-head-commit closes the window between reading the diff and merging it. Without
  # it, a push landing in that window would be merged unseen.
  run gh pr merge "$PR_NUMBER" --squash --subject "$subject" --body-file "$SQUASH_FILE" \
      --match-head-commit "$headoid" </dev/null || stop \
    "gh pr merge failed for pull request #$PR_NUMBER" \
    'nothing was deleted. If it reports a head-commit mismatch, someone pushed to the' \
    'branch while this was running - re-run the bare script and read the diff again'

  if [ "$DRYRUN" -eq 1 ]; then
    fine 'dry run - stopping before the confirmation and cleanup that depend on a real merge'
    return 0
  fi

  fetch_all ' after the merge'

  SQUASH_SHA=$(gh pr view "$PR_NUMBER" --json mergeCommit --jq '.mergeCommit.oid')
  [ -n "$SQUASH_SHA" ] && [ "$SQUASH_SHA" != 'null' ] || stop \
    'the pull request merged but GitHub did not report a merge commit' \
    'nothing has been deleted. Confirm by hand before removing anything'

  confirm_landed "$SQUASH_SHA"
}

# ------------------------------------------------------------ section 6: clean up

confirm_landed() {
  local sha="$1"
  # `git merge-base --is-ancestor` exits non-zero both for "not an ancestor" and for a name
  # that resolves to nothing, so whether the commit exists is settled first. A --sha with a
  # character missing otherwise reads as a merge that did not land.
  git rev-parse --verify -q "$sha^{commit}" >/dev/null 2>&1 || stop \
    "no commit in this repository is named $sha" \
    'nothing has been deleted, and nothing will be. A name that resolves to no commit says' \
    'nothing about whether the work landed: a truncated or mistyped --sha reads exactly' \
    'like this, and so does a commit this repository has never held. Read the SHA off the' \
    'log and re-run:' \
    '' \
    "  git log --oneline -5 origin/$BASE"

  git merge-base --is-ancestor "$sha" "origin/$BASE" 2>/dev/null || stop \
    "the squashed commit is not on origin/$BASE" \
    "  commit  $sha" \
    'nothing has been deleted, and nothing will be. Section 9 is explicit that no branch' \
    'is deleted until the log has confirmed the work landed. Look at the repository before' \
    'doing anything else'

  good "confirmed $(git rev-parse --short "$sha") is on origin/$BASE"
  git log --oneline -3 "origin/$BASE" | sed 's/^/    /'
}

SIMULATED_SWITCH=0

# Every step below names what the repository holds after it, which is what the Cleanup
# line of section 7 is assembled from. run() returns success under --dry-run without
# running the command, so each note that sits on that success says what a real run does
# instead of reporting a deletion that did not happen.

remove_worktree_for() {
  local branch="$1" wt lock
  wt=$(worktree_for_branch "$branch")
  [ -n "$wt" ] || return 0
  # After a real switch the primary checkout no longer has the branch, so this is only
  # reached under --dry-run, and the primary checkout is never a worktree to remove.
  [ "$SIMULATED_SWITCH" -eq 1 ] && [ "$wt" = "$PRIMARY" ] && return 0

  lock=$(lock_reason_for "$wt")
  if [ -n "$lock" ]; then
    printf '  %sworktree not removed - it is locked:%s %s\n' "$YELLOW" "$RESET" "$lock"
    plain "  $wt"
    plain '  a lock means something else owns this worktree'"'"'s lifecycle. If that is a Claude Code'
    plain '  session, leave it through the session rather than from here. Otherwise:'
    plain "    git -C \"$PRIMARY\" worktree unlock \"$wt\""
    plain "    git -C \"$PRIMARY\" worktree remove \"$wt\""
    add_cleanup 'worktree left in place (locked)'
    return 1
  fi

  # A worktree cannot remove itself while it is any process's current directory - Windows
  # refuses to delete it, and what you get is the half-removed tree section 6 warns about.
  # Moving out first is the whole fix.
  if [ "$wt" = "$ROOT" ]; then
    cd "$PRIMARY"
    fine "moved out of the worktree first (now in $PRIMARY)"
  fi

  if run git -C "$PRIMARY" worktree remove "$wt"; then
    if [ "$DRYRUN" -eq 1 ]; then
      add_cleanup 'worktree would be removed'
    else
      add_cleanup 'worktree removed'
    fi
    return 0
  fi

  # Which failure this was is read from what is on disk, never from git's message, which
  # is translated. Do not test it with `git status` in the worktree either: once the .git
  # file is gone, a worktree inside the repository reports the primary checkout's status.
  [ -e "$wt" ] || { add_cleanup 'worktree removed'; return 0; }

  # Its .git file is still there, so the checkout is intact and still registered.
  if [ -e "$wt/.git" ]; then
    # Never --force. On a partially removed tree that is exactly how the mess gets worse.
    printf '  %sworktree could not be removed%s\n' "$YELLOW" "$RESET"
    plain "  $wt"
    plain '  git refuses when a worktree has modified or untracked files in it. Look, then:'
    plain "    git -C \"$PRIMARY\" worktree remove \"$wt\""
    plain '  do not add --force without looking - it deletes whatever is in there'
    add_cleanup 'worktree not removed'
    return 1
  fi

  # No .git file: git emptied the checkout and deregistered it, then could not delete the
  # directory itself. A process holding a directory open is what does that on Windows.
  printf '  %sworktree emptied, but its directory is still there%s\n' "$YELLOW" "$RESET"
  plain "  $wt"
  plain '  the checkout is gone and git no longer lists it. What is left is a directory that'
  plain '  something held open - on Windows, any process sitting in it, including the shell'
  plain '  this ran from. Leave that directory, look at what is in it, then delete it:'
  plain "    rmdir \"$wt\""
  plain '  git worktree remove does not apply to it any more: it is not a worktree'
  add_cleanup 'worktree emptied, directory left behind'
  return 1
}

update_local_base() {
  local x dirty
  x=$(git -C "$PRIMARY" symbolic-ref -q --short HEAD 2>/dev/null || echo '(detached)')
  [ "$SIMULATED_SWITCH" -eq 1 ] && x="$BASE"
  dirty=$(git -C "$PRIMARY" status --porcelain 2>/dev/null || true)

  if [ "$x" = "$BASE" ]; then
    if [ -n "$dirty" ]; then
      fine "$BASE not updated - the primary checkout has uncommitted changes"
      add_cleanup "$BASE not updated (uncommitted changes there)"
      return 0
    fi
    # --ff-only can only fast-forward, so it cannot invent a merge commit or lose anything.
    # This is the document's `git pull --ff-only` minus the second fetch, which already
    # happened seconds ago.
    if run git -C "$PRIMARY" merge --ff-only "origin/$BASE"; then
      if [ "$DRYRUN" -eq 1 ]; then
        fine "not attempted (dry run) - whether $BASE fast-forwards is still unknown"
        add_cleanup "$BASE would be brought up to date"
      else
        add_cleanup "$BASE up to date"
      fi
    elif git -C "$PRIMARY" merge-base --is-ancestor HEAD "origin/$BASE" 2>/dev/null; then
      # Drift is a claim the history answers: local $BASE is on origin/$BASE's history or
      # it is not. A fast-forward that fails with it still there failed on the working
      # tree, and git has said so in the line above this one.
      fine "$BASE could not be fast-forwarded, and it has not drifted: local $BASE is still"
      fine "on origin/$BASE's history, so the reason is in git's message above - a file the"
      fine 'merge could not write is the usual one. Left alone deliberately'
      add_cleanup "$BASE not updated (the fast-forward failed, $BASE has not drifted)"
    else
      fine "$BASE could not be fast-forwarded - it has drifted. Left alone deliberately"
      add_cleanup "$BASE not updated (local $BASE has drifted)"
    fi
    return 0
  fi

  # Never switch the primary checkout away from whatever someone else left it on.
  fine "$BASE not updated - the primary checkout is on $x"
  fine "per finishing-work.md section 6 that costs nothing: nothing depends on local $BASE"
  add_cleanup "$BASE not updated (primary checkout is on $x)"
}

# What origin says about a branch: present, gone, or unknown. `git ls-remote` prints
# nothing to stdout both when the branch is absent and when the read itself fails, so the
# exit code is what separates them: an empty answer from a failed read is not a retired
# claim. Read-only, so --dry-run does not gate it.
remote_branch_state() {
  local out rc=0
  out=$(git ls-remote --heads origin "$1" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then printf 'unknown'
  elif [ -n "$out" ]; then printf 'present'
  else printf 'gone'
  fi
}

# Whether the local branch exists: present or gone. Read from the ref, never from git's
# message, which is translated.
local_branch_state() {
  if git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$1"; then
    printf 'present'
  else
    printf 'gone'
  fi
}

delete_local_branch() {
  local branch="$1"
  # Read the ref first, as delete_remote_branch reads origin first. On the --cleanup
  # recovery path the branch may already be gone, and -D at a ref that is not there fails
  # with "branch not found" - a failure for a step that needs nothing done to it.
  if [ "$(local_branch_state "$branch")" = 'gone' ]; then
    fine "local branch $branch already gone"
    add_cleanup 'local branch already gone'
  # After a squash merge `git branch -d` refuses with "not fully merged", because the work
  # landed as a new commit with a new SHA and git cannot match them up. -D is correct here
  # and only because confirm_landed already proved the work is on the base branch.
  elif run git -C "$PRIMARY" branch -D "$branch"; then
    if [ "$DRYRUN" -eq 1 ]; then
      add_cleanup 'local branch would be deleted'
    else
      add_cleanup 'local branch deleted'
    fi
  # -D failed. What that means is read from the ref: it is gone when something else
  # removed it alongside this run, and present when git refused - it is checked out in a
  # worktree this run did not remove.
  elif [ "$(local_branch_state "$branch")" = 'gone' ]; then
    fine "local branch $branch already gone"
    add_cleanup 'local branch already gone'
  else
    fine "local branch $branch was not deleted"
    add_cleanup 'local branch not deleted'
  fi
  run git -C "$PRIMARY" worktree prune || true
}

# The remote branch is the claim that starting-new-work.md section 2 reads, so deleting
# it is what retires the claim. Only ever called after confirm_landed.
#
# Origin is read before anything is said about it, and read again after a delete that
# failed, so that every note below is what origin answers rather than what this run
# expected. The capability gate is second for the same reason: it says what this session
# can do, and a branch GitHub has already retired needs nothing done to it.
delete_remote_branch() {
  local branch="$1" state
  state=$(remote_branch_state "$branch")

  if [ "$state" = 'gone' ]; then
    fine 'remote branch already gone'
    add_cleanup 'remote branch already gone'
    return 0
  fi

  if [ "$CAP_REMOTE_BRANCH_DEL" -eq 0 ]; then
    if [ "$state" = 'unknown' ]; then
      fine 'remote branch not deleted - this session cannot delete it (see env-capabilities),'
      fine 'and origin could not be read to say whether it is still there. Read it yourself:'
      fine "  git ls-remote --heads origin $branch"
      add_cleanup 'remote branch not deleted (no route to delete it here, origin unreadable)'
      return 0
    fi
    fine 'remote branch left - this session cannot delete it (see env-capabilities)'
    add_cleanup 'remote branch left (no route to delete it here)'
    return 0
  fi

  if run git push origin --delete "$branch"; then
    if [ "$DRYRUN" -eq 1 ]; then
      add_cleanup 'remote branch would be deleted'
    else
      add_cleanup 'remote branch deleted'
    fi
    return 0
  fi

  # With "Automatically delete head branches" enabled on the repository GitHub retires the
  # branch itself, and it can do so between the read above and this push - which then
  # fails at a ref that is already gone.
  case "$(remote_branch_state "$branch")" in
    gone)
      fine 'remote branch already gone - the delete found nothing left to delete'
      add_cleanup 'remote branch already gone'
      ;;
    present)
      fine "remote branch $branch could not be deleted - it still reads as a claim"
      add_cleanup 'remote branch NOT deleted'
      ;;
    *)
      fine "remote branch $branch could not be deleted, and origin could not be read to say"
      fine 'whether it is still there. Read it before reporting the claim retired:'
      fine "  git ls-remote --heads origin $branch"
      add_cleanup 'remote branch not deleted (origin unreadable)'
      ;;
  esac
}

do_cleanup() {
  CUR_SECTION=6
  section 'Cleaning up'

  local branch="${BRANCH_ARG:-$BRANCH}"
  local on_branch=0
  [ "$(git -C "$PRIMARY" symbolic-ref -q --short HEAD 2>/dev/null || true)" = "$branch" ] && on_branch=1

  if [ "$on_branch" -eq 1 ]; then
    if [ -n "$(git -C "$PRIMARY" status --porcelain 2>/dev/null || true)" ]; then
      stop \
        "the primary checkout is on $branch and has uncommitted changes" \
        'the branch cannot be deleted while it is checked out, and this script will not' \
        'stash or discard anything to make that possible. Decide what those changes are for'
    fi
    run git -C "$PRIMARY" switch "$BASE" || stop "could not switch the primary checkout to $BASE"
    # A dry run printed the switch without making it. Plan the rest as the real run will
    # find things after it, rather than planning to remove the primary checkout.
    [ "$DRYRUN" -eq 1 ] && SIMULATED_SWITCH=1
  fi

  delete_remote_branch "$branch"
  remove_worktree_for "$branch" || true
  update_local_base
  delete_local_branch "$branch"
}

# -------------------------------------------------------------- section 7: report

report_block() {
  local touches shortstat plus minus count
  touches=$(git diff --name-only "$SQUASH_SHA~1...$SQUASH_SHA" 2>/dev/null | head -8 | paste -sd, - | sed 's/,/, /g' || true)
  count=$(git diff --name-only "$SQUASH_SHA~1...$SQUASH_SHA" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ "${count:-0}" -gt 8 ] && touches="$touches (+$((count - 8)) more)"
  shortstat=$(git diff --shortstat "$SQUASH_SHA~1...$SQUASH_SHA" 2>/dev/null || true)
  plus=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
  minus=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)

  section 'Done'
  printf 'Merged:  %s -> %s\n' "$BRANCH" "$BASE"
  printf 'PR:      #%s (squashed, %s commits -> 1)\n' "$PR_NUMBER" "$COMMITS"
  printf 'Files:   %s (+%s -%s)\n' "$touches" "${plus:-0}" "${minus:-0}"
  printf 'Checks:  %s\n' "$CHECK_LINE"
  printf 'Cleanup: %s\n' "$CLEANUP_NOTES"
  echo ''
  [ -n "$PR_URL" ] && printf '%s\n\n' "$PR_URL"
  return 0
}

# --------------------------------------------------------------------------- main

# Everything lives in functions and main runs on the last line, so bash has read and
# parsed the whole file before any of it executes. That matters: this script can delete
# the worktree it is running from, and bash otherwise reads a script incrementally as it
# goes. Do not "tidy" this by moving work to the top level.
main() {
  load_config
  load_project_scans
  DECLARED=$(each_item "$DECLARE")

  printf '\n%s%s - finishing work%s\n' "$BOLD" "$PROJECT_NAME" "$RESET"
  printf '%sSee docs/development/finishing-work.md for what this does and why.%s\n' "$DIM" "$RESET"
  if [ "$DRYRUN" -eq 1 ]; then
    printf '%sDry run: the fetch still happens, because every answer depends on it.%s\n' "$YELLOW" "$RESET"
    printf '%sNothing else that changes anything will be executed.%s\n' "$YELLOW" "$RESET"
  fi

  repo_context

  if [ "$STAGE" = 'cleanup' ]; then
    BRANCH=$(git symbolic-ref -q --short HEAD || true)
    [ -n "$BRANCH_ARG" ] && BRANCH="$BRANCH_ARG"
    [ -n "$BRANCH" ] || stop '--cleanup needs a branch: pass --branch <name>'
    safe_ref "$BRANCH" || { echo "not a valid branch name: $BRANCH" >&2; exit 2; }
    CUR_SECTION=6
    resolve_base
    load_capabilities

    fetch_all ''

    local sha="$SHA_ARG" gh_said=''
    if [ -z "$sha" ] && [ "$CAP_GH" -eq 1 ]; then
      sha=$(gh pr view "$BRANCH" --json mergeCommit --jq '.mergeCommit.oid' 2>"$ERR_FILE" || true)
      gh_said=$(gh_error)
    fi
    if [ -z "$sha" ] || [ "$sha" = 'null' ]; then
      stop \
        'cannot confirm this branch was merged' \
        'there is no pull request for it with a merge commit, and no --sha was given.' \
        ${gh_said:+"gh said: $gh_said"} \
        'Nothing has been deleted and nothing will be: section 9 does not allow deleting a' \
        'branch until the log has confirmed the work landed.' \
        '' \
        'If you know the squashed commit, name it:  --sha <commit>'
    fi
    safe_ref "$sha" || { echo "not a valid commit: $sha" >&2; exit 2; }

    section 'Confirming the work landed'
    confirm_landed "$sha"
    SQUASH_SHA="$sha"
    do_cleanup

    section 'Done'
    printf 'Cleanup: %s\n' "$CLEANUP_NOTES"
    if [ "$DRYRUN" -eq 1 ]; then
      fine 'dry run complete - nothing was deleted, removed or changed'
    fi
    echo ''
    exit 0
  fi

  preflight

  if [ "$STAGE" = 'merge' ]; then
    # The evidence was the -Pr stage's job and the pull request records it. What matters
    # here is that the branch and the pull request still agree, which merge_pull_request
    # checks by SHA.
    probe_build_system
    merge_pull_request
    if [ "$DRYRUN" -eq 1 ]; then
      echo ''
      fine 'dry run complete - nothing was merged, deleted or changed'
      echo ''
      exit 0
    fi
    do_cleanup
    report_block
    exit 0
  fi

  finished_checks

  if [ "$STAGE" = 'report' ]; then
    echo ''
    plain 'Next, when you have read the above and you are satisfied:'
    if [ -n "$FLAGGED" ]; then
      printf '  %s./scripts/finish.sh --pr --testing "<what you actually ran>" --acknowledge "%s"%s\n' \
        "$BOLD" "$(printf '%s\n' "$FLAGGED" | awk '!seen[$0]++' | paste -sd, -)" "$RESET"
      fine '--acknowledge names the flagged paths above - only the ones you have looked at'
    else
      printf '  %s./scripts/finish.sh --pr --testing "<what you actually ran>"%s\n' "$BOLD" "$RESET"
    fi
    fine 'add --notes "..." if a reader would otherwise have to reconstruct something'
    fine 'add --draft to open it visible but not landable'
    echo ''
    printf '%sExit 0 here means the checks ran. It does not mean the branch is ready -%s\n' "$DIM" "$RESET"
    printf '%sthat judgement is yours.%s\n\n' "$DIM" "$RESET"
    exit 0
  fi

  # --pr
  if [ -z "$TESTING" ]; then
    echo '' >&2
    echo '--pr needs --testing "<what you ran>"' >&2
    echo '' >&2
    echo 'The Testing line of the pull request body says what was actually run, not what' >&2
    echo 'anyone believes. This script cannot know it and will not invent it.' >&2
    echo '' >&2
    if [ -z "$HAS_BUILD" ] && [ "$HAS_CI" -eq 0 ]; then
      echo 'There is no build system in this repository yet, so something like:' >&2
      echo '  --testing "no build system in the repository; nothing to run"' >&2
      echo '' >&2
    else
      echo "The local check command is: $CHECK_COMMAND" >&2
      echo '' >&2
    fi
    exit 2
  fi

  check_acknowledgements
  update_from_base
  run git push -u origin "$BRANCH" || stop \
    'git push was rejected' \
    'if it says non-fast-forward, the remote branch has commits yours does not. This script' \
    'will not force anything - force-pushing is the one everyday git operation that can' \
    'permanently destroy work that exists nowhere else.' \
    '' \
    'Fetch and merge first, then push again'
  open_pull_request

  echo ''
  if [ "$DRYRUN" -eq 1 ]; then
    fine 'dry run complete - nothing was pushed, opened or changed'
  else
    plain 'Next, once you are happy with it:'
    printf '  %s./scripts/finish.sh --merge%s\n' "$BOLD" "$RESET"
  fi
  echo ''
}

main "$@"
