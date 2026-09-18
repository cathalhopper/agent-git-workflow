# Adopting

After reading this you can install the workflow into your own repository, fit it to your branches and your risky files, and prove it works before anyone relies on it.

Every step is something you do once. Nothing here edits the shipped scripts or procedures: your project's shape goes into one settings file and, optionally, one hook script per shell.

## 1. Copy two directories

From the root of your repository:

```bash
cp -r <path-to-agent-git-workflow>/docs/development docs/
cp -r <path-to-agent-git-workflow>/scripts/. scripts/
```

The paths are fixed. The scripts cite `docs/development/finishing-work.md` by path in their stop messages, so keep the documents where they land.

If your repository already has a `scripts/check.sh` or a `docs/development/README.md`, read both before copying over them.

## 2. Set the executable bit on the shell scripts

On Windows, git records new files as `100644` and a Linux CI runner then refuses to execute them. Set the bit explicitly, whatever platform you are on:

```bash
git add scripts/*.sh
git update-index --chmod=+x scripts/*.sh
```

## 3. Fill in `scripts/workflow.conf`

Every key has a default, so start with the ones that are wrong for you.

| Key | Set it when |
|---|---|
| `PROJECT_NAME` | Always. It is the banner text |
| `DEFAULT_BASE` | Your base branch is not `origin/HEAD` |
| `ALT_BASES` | Some work lands on a long-lived branch other than the default, such as a prototype branch |
| `BRANCH_TYPES` | Your branch prefixes are not `feat`, `fix`, `spike`, `docs`, `chore` |
| `CHECK_COMMAND`, `CHECK_COMMAND_WINDOWS` | Your one local check command is not `scripts/check.*` |
| `LOCKFILES` | Your ecosystem's lockfile is not in the list |
| `GOVERNING_PATHS` | A file changes the rules for everyone, such as a pinned toolchain file |
| `SCAFFOLDING_PATTERN` | Your language has a debug leftover the built-in pattern misses |
| `LARGE_DIFF_LINES` | 2000 changed lines is the wrong threshold for a finding |

`starting-new-work.md` quotes 14 days as the dormant-branch threshold. Change the number there if yours differs.

## 4. Fill in the two slots in `setting-up.md`

- **§3.4** — replace `<owner>/<repo>` in both clone commands.
- **§4** — write the project's own build toolchain: each tool, its install command per platform, and a verify checklist.

Each slot carries an `ADOPTER` comment. Delete the comment once the slot is filled.

## 5. Add the entry file

Copy `templates/AGENTS.md` to the root of your repository and write its two closing sections. Most coding agents read `AGENTS.md` at the root.

Claude Code reads `CLAUDE.md`. Point it at the same file with one line:

```markdown
@AGENTS.md
```

## 6. Mark files that must not merge

`scripts/finish.*` flags any added file that `.gitattributes` marks `binary`, and a conflict in one is a stop in `finishing-work.md` §3. The `binary` attribute is what tells git to refuse an automatic merge, so mark every file class where a merged result would be corrupt:

```gitattributes
* text=auto
*.sh  text eol=lf
*.ps1 text eol=crlf

*.png  binary
*.jpg  binary
*.zip  binary
# your generated, frozen or single-writer files here
```

## 7. Add project scans, if a file class needs a stop

If changing some class of file is a decision rather than housekeeping, write a project scan:

```bash
cp scripts/finish-project.sh.example  scripts/finish-project.sh
cp scripts/finish-project.ps1.example scripts/finish-project.ps1
```

Each `.example` file's header carries the contract. The scan stops unless the run declares the change by name with `--declare`, and the declaration goes into the pull-request body.

`examples/tsunami-defence/` is a worked example: an alternate base branch, and a stop on moved golden hashes with three exclusions.

Write both files, or neither. The two shells must behave identically.

## 8. Rehearse before anyone relies on it

On a throwaway branch, from the primary checkout:

```bash
git switch -c chore/rehearse-finish origin/main
git commit --allow-empty -m "claim: rehearse the finish script" -m "Scope: Rehearsal only." -m "Touches: nothing" -m "Split: No"
./scripts/finish.sh
./scripts/finish.sh --pr --dry-run --testing "rehearsal"
```

Repeat from a git worktree, which is the only way to exercise the worktree removal path. Delete the branch afterwards.

If you wrote a project scan, make a change it should stop on, and confirm the bare run stops and `--declare` clears it.

## 9. Run the check command in CI

The finish scripts refuse to merge on a failing check, and read "workflows but no check runs" as broken CI. One job that runs the same command contributors run locally is enough:

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - run: ./scripts/check.sh
```

Pin the action by commit SHA rather than tag once you have chosen a version.

## Keeping it in step

- **A change to a script updates the document that states it, in the same pull request.** `docs/development/README.md` §5 is the rule.
- **A new document under `docs/development/` follows the skeleton** in `docs/development/README.md` §3, and is reviewed against its §6.
- **The bash and PowerShell halves of every script behave identically.** A change to one is a change to both.
