# Example: a simulation with pinned golden hashes

After reading this you can see how a project with two unusual rules fills the slots the workflow leaves open, and copy the pattern for your own.

This is the project the workflow was first written for. It has two rules the shipped scripts do not know about.

- **Throwaway prototype code never reaches `main`.** It lives on `spike/a0-prototype`, and branches cut from it land back on it.
- **A moved golden hash is a version bump.** The simulation's behaviour is pinned by digests under `crates/sim/tests/golden/`, and a change to one needs a person to say it was intended.

## What each file does

| File | Copy to | What it demonstrates |
|---|---|---|
| `workflow.conf` | `scripts/workflow.conf` | `ALT_BASES` for the prototype branch, and a pinned toolchain file added to `GOVERNING_PATHS` |
| `finish-project.sh` | `scripts/finish-project.sh` | A project scan that stops on a file class and clears only with `--declare golden-hash` |
| `finish-project.ps1` | `scripts/finish-project.ps1` | The same scan for PowerShell |

## What to take from it

- **The alternate base needs no code.** One line of `workflow.conf` is enough, and the finish scripts refuse a branch they cannot place.
- **A project stop is a claim about a file class.** The scan's header names three exclusions, and each one says what a class of file can possibly contain. Write yours the same way.
- **The declaration goes into the pull request body.** A reviewer sees what was asserted, and `--declare` refuses any name the scan did not ask for.
