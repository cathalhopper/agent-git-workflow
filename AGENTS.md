# agent-git-workflow

This repository is a template other projects copy. Everything under `docs/development/`, `scripts/` and `templates/` lands in someone else's repository unedited, so none of it may name this repository or any one project. Project-specific material lives only under `examples/`.

## Before changing a document

- **Read `docs/development/README.md`.** Every document under `docs/development/` is written to its §2 standard and reviewed against its §6 list.
- **A section number a script cites is kept**, or every citation to it changes in the same commit. §2 of that README has the grep that lists them.

## Before changing a script

- **The bash and PowerShell halves behave identically.** A change to `finish.sh` is a change to `finish.ps1`, and the same for every pair.
- **Never add an override flag** to `finish.*` — no `--force`, `--yes` or `--skip-checks`. The header of `finish.sh` says why.
- **Every command that changes state goes through `run` in `finish.sh` and `Invoke-Mutating` in `finish.ps1`.** The header lists them, and the list is kept complete.
- **A change to what a script does updates the document that states it**, in the same commit.

## Before committing

Run both parsers, and the grep that proves nothing project-specific leaked:

```bash
bash -n scripts/finish.sh scripts/setup.sh scripts/env-capabilities.sh examples/tsunami-defence/finish-project.sh
grep -rniE 'tsunami|golden|crates/|spike/a0' docs scripts templates
```

The grep returns nothing.
