# agent-git-workflow

**This file governs changes to this repository only.** If you were asked to install this workflow into another repository, nothing below applies: follow `ADOPTING.md`, and the file you copy is `templates/AGENTS.md`.

This repository is a template other projects copy. Everything under `docs/development/`, `scripts/` and `templates/` lands in someone else's repository unedited, so none of it may name this repository or any one project. Project-specific material lives only under `examples/`.

## Before changing any file in this repository

**Follow `docs/development/starting-new-work.md` as written**: check for overlap, then claim the work with a named branch and a claim commit before the first edit.

## Before landing any change

**Follow `docs/development/finishing-work.md` as written, and run it with `scripts/finish.sh` or `scripts/finish.ps1`.** If the script stops, report the stop and wait. Never perform the same operation by hand.

## Before changing a document

- **Read `docs/development/README.md`.** Every document under `docs/development/` is written to its §2 standard and reviewed against its §6 list.
- **A section number a script cites is kept**, or every citation to it changes in the same commit. §2 of that README has the grep that lists them.

## Before changing a script

- **The bash and PowerShell halves behave identically.** A change to `finish.sh` is a change to `finish.ps1`, and the same for every pair.
- **Never add an override flag** to `finish.*` — no `--force`, `--yes` or `--skip-checks`. The header of `finish.sh` says why.
- **Every command that changes state goes through `run` in `finish.sh` and `Invoke-Mutating` in `finish.ps1`.** The header lists them, and the list is kept complete.
- **A change to what a script does updates the document that states it**, in the same commit.

## Before committing

This repository's check command is `bash .github/check.sh`. Run it wherever `finishing-work.md` says to run `CHECK_COMMAND` or `scripts/check.sh`. It runs both parsers, the grep that proves nothing project-specific leaked, and every other invariant this repository states, and its summary names each step.
