#!/usr/bin/env bash
#
# Installs the tier 1 contributor tools on macOS and Linux: git and gh.
#
# Detects what is already present, installs only what is missing, and prints a
# table of where you stand. Running it twice is safe: the second run installs
# nothing and just reports.
#
# Two steps are deliberately NOT automated, because they cannot be:
#   - gh auth login   needs a browser and a one-time code
#   - git identity    is your name and your email, not something to guess
# Both are reported as ACTION NEEDED with the exact command to run.
#
# The project's own build toolchain is tier 2, and this script does not install
# it. docs/development/setting-up.md section 4 says what it is.
#
# Usage:
#   ./scripts/setup.sh
#
# See docs/development/setting-up.md for what this does and why.

set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      # Print the header comment block: every comment line after the shebang, up
      # to the first line that is not a comment. No line numbers to drift.
      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: $0" >&2
      exit 2
      ;;
  esac
done

if [ -t 1 ]; then
  BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RED=$(printf '\033[31m')
  GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); CYAN=$(printf '\033[36m')
  RESET=$(printf '\033[0m')
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

# The banner reads PROJECT_NAME from workflow.conf, without sourcing it.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_NAME=$(sed -n 's/^PROJECT_NAME=//p' "$SCRIPT_DIR/workflow.conf" 2>/dev/null | head -n1 | tr -d '\r' || true)
[ -n "$PROJECT_NAME" ] || PROJECT_NAME='this repository'

# Plain strings rather than arrays on purpose: macOS still ships bash 3.2, where
# ${#arr[@]} on an empty array under `set -u` is an unbound-variable error.
INSTALLED=''   # comma separated
FAILED=''      # newline separated, printed one per line
ACTIONS=''     # joined with " and "

add_installed() { INSTALLED="${INSTALLED}${INSTALLED:+, }$1"; }
add_failed()    { FAILED="${FAILED}${FAILED:+$'\n'}$1"; }
add_action()    { ACTIONS="${ACTIONS}${ACTIONS:+ and }$1"; }

# Named 'section', not 'head' - a function called head would shadow the head
# command that tool_version below depends on.
section() { printf '\n%s%s%s\n' "$CYAN" "$1" "$RESET"; printf '%s%s%s\n' "$DIM" "$(printf '%*s' "${#1}" '' | tr ' ' '-')" "$RESET"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Prints a version number, or nothing if the tool is absent or does not answer.
tool_version() {
  local cmd="$1"
  have "$cmd" || return 0
  local raw
  raw=$("$cmd" --version 2>/dev/null | head -n1 || true)
  local version
  version=$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)
  if [ -n "$version" ]; then printf '%s' "$version"; else printf 'installed'; fi
}

# ------------------------------------------------------- platform detection

OS="$(uname -s)"
PM=''

case "$OS" in
  Darwin)
    if have brew; then
      PM='brew'
    else
      printf '%sHomebrew is not installed.%s\n' "$RED" "$RESET"
      echo 'Install it from https://brew.sh, then re-run this script.'
      echo 'Or follow docs/development/setting-up.md section 3 by hand - the steps are the same.'
      exit 1
    fi
    ;;
  Linux)
    if   have apt-get; then PM='apt'
    elif have dnf;     then PM='dnf'
    elif have pacman;  then PM='pacman'
    else
      printf '%sNo supported package manager found (apt, dnf or pacman).%s\n' "$RED" "$RESET"
      echo 'Follow docs/development/setting-up.md section 3 by hand.'
      exit 1
    fi
    ;;
  *)
    printf '%sUnsupported platform: %s%s\n' "$RED" "$OS" "$RESET"
    echo 'On Windows use scripts/setup.ps1 instead.'
    exit 1
    ;;
esac

pm_install() {
  local package="$1"
  case "$PM" in
    brew)   brew install "$package" ;;
    apt)    sudo apt-get install -y "$package" ;;
    dnf)    sudo dnf install -y "$package" ;;
    pacman) sudo pacman -S --needed --noconfirm "$package" ;;
  esac
}

# Installs a package only if its command is not already on PATH.
install_if_missing() {
  local cmd="$1" package="$2" label="$3"

  if have "$cmd"; then
    printf '  %-12s already installed (%s)\n' "$label" "$(tool_version "$cmd")"
    return 0
  fi

  printf '  %s%-12s installing via %s...%s\n' "$YELLOW" "$label" "$PM" "$RESET"
  if pm_install "$package"; then
    printf '  %s%-12s installed%s\n' "$GREEN" "$label" "$RESET"
    add_installed "$label"
  else
    printf '  %s%-12s FAILED%s\n' "$RED" "$label" "$RESET"
    add_failed "$label"
  fi
}

printf '\n%s%s - contributor setup%s\n' "$BOLD" "$PROJECT_NAME" "$RESET"
printf '%sSee docs/development/setting-up.md for what this does and why.%s\n' "$DIM" "$RESET"
printf '%sPlatform: %s, package manager: %s%s\n' "$DIM" "$OS" "$PM" "$RESET"

# -------------------------------------------------------------------- tier 1

section 'Tier 1 - everyone'

install_if_missing git git git

if have gh; then
  printf '  %-12s already installed (%s)\n' 'gh' "$(tool_version gh)"
else
  # gh is in Homebrew and in recent Debian/Ubuntu and Fedora repos, but not in
  # older ones. If the package manager does not have it, send the user to the
  # official instructions rather than silently adding a third-party apt source.
  printf '  %s%-12s installing via %s...%s\n' "$YELLOW" 'gh' "$PM" "$RESET"
  if pm_install gh; then
    printf '  %s%-12s installed%s\n' "$GREEN" 'gh' "$RESET"
    add_installed 'gh'
  else
    printf '  %s%-12s not available from %s%s\n' "$YELLOW" 'gh' "$PM" "$RESET"
    echo '               Install it from https://github.com/cli/cli#installation'
    add_failed 'gh (not in package manager - see link above)'
  fi
fi

# --------------------------------------------- the two manual steps

section 'Steps this script will not do for you'

GIT_NAME=$(git config --global --get user.name || true)
GIT_EMAIL=$(git config --global --get user.email || true)

if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
  printf '  %sYour git identity is not fully set.%s\n' "$YELLOW" "$RESET"
  echo '  It is read by name in two checks: the overlap report in starting-new-work.md'
  echo '  section 2, and the claim-commit author check in finishing-work.md section 1.'
  echo ''
  printf '    %sgit config --global user.name "Your Name"%s\n' "$BOLD" "$RESET"
  printf '    %sgit config --global user.email "you@example.com"%s\n' "$BOLD" "$RESET"
  echo ''
  printf '  %sUse an address GitHub has verified, or your @users.noreply.github.com one.%s\n' "$DIM" "$RESET"
  add_action 'set your git identity'
else
  printf '  %sgit identity  %s <%s>%s\n' "$DIM" "$GIT_NAME" "$GIT_EMAIL" "$RESET"
fi

GH_AUTHED=0
if have gh && gh auth status >/dev/null 2>&1; then
  GH_AUTHED=1
fi

if [ "$GH_AUTHED" -eq 0 ]; then
  echo ''
  printf '  %sgh is not authenticated. This needs a browser, so it is yours to run:%s\n' "$YELLOW" "$RESET"
  echo ''
  printf '    %sgh auth login%s\n' "$BOLD" "$RESET"
  echo ''
  printf '  %sAnswer: GitHub.com, then HTTPS, then YES to "Authenticate Git with your%s\n' "$DIM" "$RESET"
  printf '  %sGitHub credentials?", then login with a web browser.%s\n' "$DIM" "$RESET"
  printf '  %sThat YES is what makes git push work without a separate credential setup.%s\n' "$DIM" "$RESET"
  add_action 'run gh auth login'
else
  printf '  %sgh auth       authenticated%s\n' "$DIM" "$RESET"
fi

# -------------------------------------------------------------------- report

section 'Where you stand'

row() {
  local name="$1" version="$2" status="$3" colour="$GREEN"
  [ "$status" = 'OK' ] || colour="$YELLOW"
  printf '  %s%-11s%-12s%s%s\n' "$colour" "$name" "$version" "$status" "$RESET"
}

report_tool() {
  local name="$1" cmd="$2" version
  version=$(tool_version "$cmd")
  if [ -z "$version" ]; then
    row "$name" '-' 'MISSING - open a new shell, then re-run'
  else
    row "$name" "$version" 'OK'
  fi
}

report_tool git git
report_tool gh  gh

if [ -z "$GIT_EMAIL" ]; then
  row 'identity' 'unset' 'ACTION NEEDED - see above'
else
  row 'identity' 'set' 'OK'
fi

if [ "$GH_AUTHED" -eq 1 ]; then
  row 'gh auth' 'yes' 'OK'
else
  row 'gh auth' '-' 'ACTION NEEDED - run gh auth login'
fi

echo ''

if [ -n "$INSTALLED" ]; then
  printf 'Installed this run: %s\n' "$INSTALLED"
  printf '%sOpen a new shell so the new PATH is picked up, then re-run to confirm.%s\n\n' "$YELLOW" "$RESET"
fi

if [ -n "$FAILED" ]; then
  printf '%sSome installs failed:%s\n' "$RED" "$RESET"
  printf '%s\n' "$FAILED" | while IFS= read -r failure; do printf '  - %s\n' "$failure"; done
  echo 'See docs/development/setting-up.md section 5, and report anything not listed there.'
  echo ''
  exit 1
fi

if [ -n "$ACTIONS" ]; then
  printf 'Still to do by hand: %s.\n\n' "$ACTIONS"
  exit 0
fi

printf '%sTier 1 complete. Next: docs/development/starting-new-work.md%s\n\n' "$GREEN" "$RESET"
