#!/usr/bin/env bash
#
# Project scans for a deterministic simulation whose behaviour is pinned by
# golden hashes. Copy to scripts/finish-project.sh to activate.
#
# A golden hash is a digest of simulation state, written by a --bless step into
# crates/sim/tests/golden/<scenario>.hash. Moving one is a simulation-version
# bump, not a test update, so this scan stops on it unless the run declares it:
#
#   ./scripts/finish.sh --pr --declare golden-hash --testing "..."
#
# The contract this file is written to is scripts/finish-project.sh.example.
#
# WHAT IT LOOKS AT
#   Paths: any changed file under a `golden` path segment, or ending in `.hash`.
#   A segment, not a substring: golden_harness/mod.rs computes the hash and is
#   ordinary code.
#
#   Lines: any added or removed 64-character hex token, the net for a pin copied
#   somewhere unexpected.
#
# THE THREE EXCLUSIONS, EACH A CLAIM ABOUT WHAT A FILE CLASS CAN CONTAIN
#   Lockfiles record a checksum of somebody else's package on every line.
#   A crate's src/ tree is the code a pin describes, not a place one is recorded.
#   tests/fixtures/ holds frozen input documents whose digests are not
#   simulation state, and has no --bless path.
#
#   Each exclusion exists because without it the stop fired on ordinary work,
#   and --declare golden-hash became the routine way past a stop that was wrong.
#   A stop clearable only by asserting something false teaches people to assert
#   it. Do not widen the exclusions to make a stop go away; narrow the claim.

project_scans() {
  local paths lines
  local -a exclude=(':!*.lock' ':!package-lock.json' ':!crates/*/src/**' ':!crates/*/tests/fixtures/**')

  paths=$(q git diff --name-only "origin/$BASE...HEAD" |
    grep -iE '(^|/)golden/|\.hash$' |
    grep -vE '(^|/)tests/fixtures/' || true)

  lines=$(q git diff "origin/$BASE...HEAD" -U0 -- "${exclude[@]}" |
    grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -oE '\b[0-9a-f]{64}\b' || true)

  if [ -z "$paths" ] && [ -n "$lines" ]; then
    paths=$(q git diff --name-only "origin/$BASE...HEAD" -G'[0-9a-f]{64}' -- "${exclude[@]}" || true)
  fi

  [ -n "$paths" ] || [ -n "$lines" ] || return 0

  if is_declared golden-hash; then
    finding 'golden hash' 'moved, declared intended with --declare golden-hash'
    add_note 'Golden hash moved; declared intended. This is a simulation-version bump.'
    return 0
  fi

  stop \
    'this branch appears to move a golden hash' \
    'the pinned golden hash defines a simulation version. Moving it is a version bump,' \
    'not an incidental test update, and re-pinning silently invalidates every result' \
    'recorded against the old one.' \
    '' \
    "$([ -n "$paths" ] && printf '%s\n' "$paths" | sed 's/^/  /' || echo '  (64-hex values changed in the diff)')" \
    '' \
    'If the change was intended, say so and it goes into the pull request body:' \
    '  ./scripts/finish.sh --pr --declare golden-hash --testing "..."' \
    '' \
    'If it was not intended, the simulation moved when you did not think you were' \
    'touching it. That is a stop-and-investigate, not a re-pin'
}
