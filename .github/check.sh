#!/usr/bin/env bash
#
# Every invariant this repository states about itself, as one command.
#
# This repository is a template. It has no build system and nothing to compile, so what
# there is to verify is exactly what AGENTS.md asks a person to run before committing,
# plus the rules the documents and scripts state about each other. All of it is
# mechanical, and none of it survives being left to a human on a deadline.
#
# It lives in .github/ rather than in scripts/. Everything under docs/development/,
# scripts/ and templates/ is copied into an adopting repository unedited, and these
# checks are about this repository alone. scripts/workflow.conf keeps CHECK_COMMAND at
# the shipped default that an adopter fills in; it does not name this file.
#
# Every check runs even when an earlier one fails, so that one run shows every fault.
# The summary at the end names each step and its result.
#
# Usage: bash .github/check.sh

set -euo pipefail

cd "$(dirname "$0")/.."

DOCS='docs/development'
FAILURES=0
SUMMARY=''

# ------------------------------------------------------------------ reporting

step() { printf '\n== %s\n' "$1"; }
detail() { printf '   %s\n' "$1"; }

record() {
  # $1 is OK, FAIL or SKIP; $2 is the step name; $3 is the one-line result.
  SUMMARY="${SUMMARY}$(printf '%-4s  %-26s  %s' "$1" "$2" "$3")
"
  case "$1" in
    FAIL) FAILURES=$((FAILURES + 1)); printf '   FAIL: %s\n' "$3" ;;
    SKIP) printf '   SKIP: %s\n' "$3" ;;
    *)    printf '   ok: %s\n' "$3" ;;
  esac
}

# ------------------------------------------------------------------ helpers

# A document's lines with fenced code blocks removed. docs/development/README.md §3 is a
# skeleton whose fence holds literal "## 0." and "## N." lines; counting those as
# headings would let a deleted section resolve against the template that describes it.
strip_fences() {
  awk '/^```/ { f = !f; next } !f' "$1"
}

# True when $1 (a document path) has the section $2, which is either N or N.M.
# Sections are "## N. Title"; subsections are "### N.M Title", with no dot after the M.
has_section() {
  local doc="$1" num="$2" pattern
  if [ ! -f "$doc" ]; then
    return 1
  fi
  case "$num" in
    *.*) pattern="^### ${num//./\\.} " ;;
    *)   pattern="^## ${num}\. " ;;
  esac
  strip_fences "$doc" | grep -qE "$pattern"
}

# The body of section $2 of document $1, up to the next top-level section.
section_body() {
  strip_fences "$1" | awk -v n="$2" '
    $0 ~ "^## " n "\\." { inside = 1; next }
    /^## / { if (inside) exit }
    inside { print }
  '
}

# True when section $2 of document $1 holds the numbered check $3, written "**M. ...".
has_check() {
  section_body "$1" "$2" | grep -qE "^\*\*${3}\. "
}

# A script's executable content: the PowerShell <# #> help block removed, then quoted
# strings emptied, then trailing comments dropped. What remains is what actually runs.
# Strings go before comments so that a # inside a message does not truncate the line.
executable_lines() {
  awk '
    /^<#/ { blk = 1 }
    blk == 1 { if (/^#>/) blk = 0; next }
    { print }
  ' "$1" \
    | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g' -e 's/#.*$//'
}

# ------------------------------------------------------------------ 1. bash syntax

step 'bash syntax'
bad=''
for f in $(git ls-files '*.sh' '*.sh.example'); do
  if ! bash -n "$f" 2>/dev/null; then
    detail "$f"
    # || true: the failing parse is the point, and set -e would end the run here,
    # before the remaining steps have reported.
    { bash -n "$f" 2>&1 || true; } | sed 's/^/     /'
    bad="${bad}${bad:+, }$f"
  fi
done
if [ -n "$bad" ]; then
  record FAIL 'bash syntax' "does not parse: $bad"
else
  record OK 'bash syntax' "$(git ls-files '*.sh' '*.sh.example' | wc -l | tr -d ' ') files parse"
fi

# ------------------------------------------------------------------ 2. powershell syntax

step 'powershell syntax'
ps_files=$(git ls-files '*.ps1' '*.ps1.example')
if ! command -v pwsh >/dev/null 2>&1; then
  record SKIP 'powershell syntax' 'pwsh is not on PATH - CI parses these on ubuntu-latest'
else
  ps_list=$(printf '%s' "$ps_files" | tr '\n' ';')
  if out=$(pwsh -NoProfile -NonInteractive -Command "
      \$bad = @()
      foreach (\$rel in ('$ps_list' -split ';' | Where-Object { \$_ })) {
        \$errs = \$null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
          (Resolve-Path -LiteralPath \$rel).Path, [ref]\$null, [ref]\$errs)
        if (\$errs.Count) { \$bad += \$rel; \$errs | ForEach-Object { Write-Output (\"  \" + \$rel + \": \" + \$_.Message) } }
      }
      if (\$bad.Count) { exit 1 }
    " 2>&1); then
    record OK 'powershell syntax' "$(printf '%s' "$ps_files" | grep -c . || true) files parse"
  else
    printf '%s\n' "$out" | sed 's/^/     /'
    record FAIL 'powershell syntax' 'a file does not parse'
  fi
fi

# ------------------------------------------------------------------ 3. nothing project-specific

step 'no project-specific content'
# AGENTS.md: docs/development/, scripts/ and templates/ land in someone else's repository
# unedited, so none of them may name this repository or any one project. examples/ is
# where project-specific material is allowed to live, so it is not scanned.
if leaked=$(grep -rniE 'tsunami|golden|crates/|spike/a0' docs scripts templates 2>/dev/null); then
  printf '%s\n' "$leaked" | sed 's/^/     /'
  record FAIL 'no project content' 'a shipped path names a specific project'
else
  record OK 'no project content' 'docs, scripts and templates name no project'
fi

# ------------------------------------------------------------------ 4. shell pair parity

step 'bash and powershell pairs'
# AGENTS.md: the bash and PowerShell halves behave identically, so a change to finish.sh
# is a change to finish.ps1. That governs the shipped pairs under scripts/ and the worked
# example. This file is not one of them: it is bash only, and runs on a Linux runner.
paired=$(git ls-files scripts examples)
orphans=''
for f in $(printf '%s\n' "$paired" | grep -E '\.sh$' || true); do
  [ -f "${f%.sh}.ps1" ] || orphans="${orphans}${orphans:+, }${f} has no .ps1"
done
for f in $(printf '%s\n' "$paired" | grep -E '\.ps1$' || true); do
  [ -f "${f%.ps1}.sh" ] || orphans="${orphans}${orphans:+, }${f} has no .sh"
done
for f in $(printf '%s\n' "$paired" | grep -E '\.sh\.example$' || true); do
  [ -f "${f%.sh.example}.ps1.example" ] || orphans="${orphans}${orphans:+, }${f} has no .ps1.example"
done
for f in $(printf '%s\n' "$paired" | grep -E '\.ps1\.example$' || true); do
  [ -f "${f%.ps1.example}.sh.example" ] || orphans="${orphans}${orphans:+, }${f} has no .sh.example"
done
if [ -n "$orphans" ]; then
  detail "$orphans"
  record FAIL 'shell pair parity' 'a script has no twin in the other shell'
else
  record OK 'shell pair parity' 'every script has its twin'
fi

# ------------------------------------------------------------------ 5. cited sections resolve

step 'cited sections resolve'
# The citers are the ones docs/development/README.md §2 lists. A section number cited from
# a script or another document is kept, or every citation to it is amended with it.
unresolved=''
citations=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  where="${hit%%:*}"; rest="${hit#*:}"
  line="${rest%%:*}"; text="${rest#*:}"
  doc=$(printf '%s' "$text" | grep -oE 'starting-new-work|finishing-work|setting-up|README' | head -1 || true)
  num=$(printf '%s' "$text" | grep -oE '[0-9]+(\.[0-9]+)?$' || true)
  [ -n "$doc" ] && [ -n "$num" ] || continue
  citations=$((citations + 1))
  if ! has_section "$DOCS/$doc.md" "$num"; then
    unresolved="${unresolved}${unresolved:+
}     $where:$line cites $doc.md section $num, which does not exist"
  fi
done <<EOF
$(grep -rnoE '(starting-new-work|finishing-work|setting-up\.md|README)[^ )]*[ )]*(§|section) *[0-9]+(\.[0-9]+)?' \
    scripts docs AGENTS.md .github 2>/dev/null || true)
EOF

# A citation may name a numbered check inside a section - "§2 check 6" - which is a second
# thing that can rot. Resolve the check number against the section it names.
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  where="${hit%%:*}"; rest="${hit#*:}"
  line="${rest%%:*}"; text="${rest#*:}"
  doc=$(printf '%s' "$text" | grep -oE 'starting-new-work|finishing-work|setting-up|README' | head -1 || true)
  sec=$(printf '%s' "$text" | grep -oE '(§|section) *[0-9]+' | grep -oE '[0-9]+' || true)
  chk=$(printf '%s' "$text" | grep -oE 'check *[0-9]+' | grep -oE '[0-9]+' || true)
  [ -n "$doc" ] && [ -n "$sec" ] && [ -n "$chk" ] || continue
  citations=$((citations + 1))
  if ! has_check "$DOCS/$doc.md" "$sec" "$chk"; then
    unresolved="${unresolved}${unresolved:+
}     $where:$line cites $doc.md §$sec check $chk, which does not exist"
  fi
done <<EOF
$(grep -rnoE '(starting-new-work|finishing-work|setting-up\.md|README)[^ )]*[ )]*(§|section) *[0-9]+ check *[0-9]+' \
    scripts docs AGENTS.md .github 2>/dev/null || true)
EOF

if [ -n "$unresolved" ]; then
  printf '%s\n' "$unresolved"
  record FAIL 'cited sections' 'a citation names a section that does not exist'
else
  record OK 'cited sections' "$citations citations resolve"
fi

# ------------------------------------------------------------------ 6. executable bit

step 'executable bit on shell scripts'
# Git on Windows records a new file as 100644, and a Linux runner then refuses to run it.
unset_bit=''
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  mode="${entry%% *}"
  path="${entry#*	}"
  [ "$mode" = '100755' ] || unset_bit="${unset_bit}${unset_bit:+ }$path"
done <<EOF
$(git ls-files -s '*.sh' '*.sh.example')
EOF
if [ -n "$unset_bit" ]; then
  detail 'not executable in the index:'
  detail "$unset_bit"
  detail 'fix it with:'
  detail "  git update-index --chmod=+x $unset_bit"
  record FAIL 'executable bit' 'a shell script is not 100755 in the index'
else
  record OK 'executable bit' 'every shell script is 100755'
fi

# ------------------------------------------------------------------ 7. the finish scripts mutate nothing they must not

step 'finish scripts: forbidden operations'
# The header of scripts/finish.sh names the operations that must never run from it, and
# lists every command in it that changes state. A message that tells a person not to
# rebase is not a rebase, so the audit reads what executes: comments and quoted strings
# are removed first. Remove-Item -Force is not git --force, so the patterns name git's.
offenders=''
for f in scripts/finish.sh scripts/finish.ps1; do
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    offenders="${offenders}${offenders:+
}     $f:$n executes a forbidden operation"
  done <<EOF
$(executable_lines "$f" | grep -niE -- '--force|force-with-lease|(^|[^-[:alnum:]])rebase|reset --hard|git stash' | cut -d: -f1 || true)
EOF
done
if [ -n "$offenders" ]; then
  printf '%s\n' "$offenders"
  record FAIL 'forbidden operations' 'a finish script executes force, rebase, reset --hard or stash'
else
  record OK 'forbidden operations' 'neither finish script forces, rebases, resets or stashes'
fi

step 'finish scripts: no override flag'
# Permission systems match on command prefixes: once --merge is approved, --merge --force
# is approved with it. The header of scripts/finish.sh says why there must be no such flag.
overrides=''
if hits=$(grep -nE '^[[:space:]]*--(force|yes|skip-checks)\)' scripts/finish.sh); then
  overrides="${overrides}${overrides:+
}$(printf '%s' "$hits" | sed 's/^/     scripts\/finish.sh:/')"
fi
if hits=$(grep -niE '^[[:space:]]*\[switch\]\$(Force|Yes|SkipChecks)' scripts/finish.ps1); then
  overrides="${overrides}${overrides:+
}$(printf '%s' "$hits" | sed 's/^/     scripts\/finish.ps1:/')"
fi
if [ -n "$overrides" ]; then
  printf '%s\n' "$overrides"
  record FAIL 'no override flag' 'a finish script accepts an override flag'
else
  record OK 'no override flag' 'neither finish script accepts one'
fi

# ------------------------------------------------------------------ summary

printf '\n----------------------------------------------------------------------\n'
printf '%s' "$SUMMARY"
printf -- '----------------------------------------------------------------------\n'

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s step(s) failed.\n' "$FAILURES"
  exit 1
fi
printf '\nAll steps passed.\n'
