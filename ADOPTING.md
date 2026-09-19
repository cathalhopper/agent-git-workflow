# Adopting

After reading this you can install the workflow into your own repository, fit it to your branches and your risky files, and prove it works before anyone relies on it.

Every step is something you do once. Nothing here edits the shipped scripts or procedures: your project's shape goes into one settings file and, optionally, one hook script per shell.

## 0. Ask before copying anything

The workflow needs a GitHub `origin` and `gh`. Without `gh`, only the bare run of `scripts/finish.*` works.

An agent adopting this asks the user each question below and waits for the answers. On a new repository most answers are "none yet", and the default stands.

| Ask | It decides |
|---|---|
| Which branch does work land on? Does another long-lived branch take merges, such as `release` or `hotfix`? Is `main` a release branch that work reaches through `develop`? | `DEFAULT_BASE`, `ALT_BASES` and `BASE_BY_PREFIX`, §3 |
| Do the project's branch prefixes, ticket IDs and pull-request title format stay? | `BRANCH_TYPES`, §3, and whether titles need `--title` |
| This workflow never rebases and always squash-merges. Does that replace the project's rule, and does everyone who works here agree? | Whether to adopt. The repository settings must allow squash merging |
| What one command runs every local check? Does CI run it on pull requests to every base? | `CHECK_COMMAND`, §3 and §9 |
| Which shipped files already exist here, and what happens to each? | §1 |
| Do the existing `AGENTS.md`, `CLAUDE.md` and `CONTRIBUTING.md` merge with the template, or stay as they are? | §5 |
| Does the adoption land as a direct commit, or through a pull request? | §10 |

## 1. Copy two directories

From the root of your repository, list every shipped file that already exists here:

```bash
(cd <path-to-agent-git-workflow> && find docs/development scripts -type f) | while read -r f; do [ -e "$f" ] && echo "$f"; done; true
for f in AGENTS.md CLAUDE.md CONTRIBUTING.md .gitattributes .github/workflows; do [ -e "$f" ] && echo "$f"; done; true
```

```powershell
$src = (Resolve-Path '<path-to-agent-git-workflow>').Path
Get-ChildItem -Recurse -File "$src\docs\development", "$src\scripts" | ForEach-Object { $_.FullName.Substring($src.Length + 1) } | Where-Object { Test-Path $_ }
'AGENTS.md', 'CLAUDE.md', 'CONTRIBUTING.md', '.gitattributes', '.github\workflows' | Where-Object { Test-Path $_ }
```

Printing nothing is the clean result. The first list is what the copy overwrites; the second is what §5, §6 and §9 merge into rather than replace.

The copy overwrites each file the first list prints. Stop and ask the user whether to merge the two or rename theirs. The documents cite `scripts/setup.*` and `docs/development/README.md` by path, so rename the project's file, never the shipped one.

Then copy:

```bash
mkdir -p docs/development scripts
cp -r <path-to-agent-git-workflow>/docs/development/. docs/development/
cp -r <path-to-agent-git-workflow>/scripts/. scripts/
```

```powershell
New-Item -ItemType Directory -Force docs\development, scripts | Out-Null
Copy-Item -Recurse <path-to-agent-git-workflow>\docs\development\* docs\development\
Copy-Item -Recurse <path-to-agent-git-workflow>\scripts\* scripts\
```

The paths are fixed. The scripts cite `docs/development/finishing-work.md` by path in their stop messages, so keep the documents where they land.

## 2. Set the executable bit on the shell scripts

On Windows, git records new files as `100644` and a Linux CI runner then refuses to execute them. Set the bit explicitly, whatever platform you are on, naming the files so the command works from either shell:

```bash
git add scripts/finish.sh scripts/setup.sh scripts/env-capabilities.sh
git update-index --chmod=+x scripts/finish.sh scripts/setup.sh scripts/env-capabilities.sh
```

Do the same for `scripts/check.sh` when §3 writes it: CI runs it.

## 3. Fill in `scripts/workflow.conf`

Every key has a default, so start with the ones that are wrong for you.

| Key | Set it when |
|---|---|
| `PROJECT_NAME` | Always. It is the banner text |
| `DEFAULT_BASE` | Your base branch is not `origin/HEAD` |
| `ALT_BASES` | Some work lands on a long-lived branch other than the default, such as a prototype branch. A branch the default contains, such as a `main` that `develop` merges from, is ignored here with a note: use `BASE_BY_PREFIX` for it |
| `BASE_BY_PREFIX` | A branch prefix always lands on one base, such as `hotfix:main` when work lands on `develop` and `main` is released from it. Comma-separated `prefix:base` pairs; each prefix also counts as a branch type. [`finishing-work.md`](docs/development/finishing-work.md) §5 has the release and back-merge that go with it |
| `BRANCH_TYPES` | Your branch prefixes are not `feat`, `fix`, `spike`, `docs`, `chore` |
| `CHECK_COMMAND`, `CHECK_COMMAND_WINDOWS` | Your one local check command is not `scripts/check.*`. None ships with this set: write it, or name yours here |
| `LOCKFILES` | Your ecosystem's lockfile is not in the list |
| `GOVERNING_PATHS` | A file changes the rules for everyone, such as a pinned toolchain file. Narrow `scripts/*` to the shipped scripts if the project keeps others there |
| `SCAFFOLDING_PATTERN` | Your language has a debug leftover the built-in pattern misses, such as `print\(` in Python or `fmt\.Println` in Go |
| `LARGE_DIFF_LINES` | 2000 changed lines is the wrong threshold for a finding |

With `DEFAULT_BASE=develop`, the adoption lands on `develop`, and `scripts/finish.*` reaches `main` only with the next release. A `hotfix/` branch cut from `main` before that has no scripts: release first.

`starting-new-work.md` quotes 14 days as the dormant-branch threshold, under "Dormant branches" and in §3. Change both if yours differs.

## 4. Fill in the two slots in `setting-up.md`

- **§3.4** — replace `<owner>/<repo>` in both clone commands.
- **§4** — write the project's own build toolchain: each tool, its install command per platform, and a verify checklist.

Each slot carries an `ADOPTER` comment. Delete the comment once the slot is filled.

## 5. Add the entry file

Copy `templates/AGENTS.md` to the root of your repository and write its two closing sections. Most coding agents read `AGENTS.md` at the root.

If the repository has an `AGENTS.md`, merge instead of copying: add the template's sections to it, and where one of its rules contradicts one of the template's, ask the user which stands.

Claude Code reads `CLAUDE.md`. Point it at the same file with one line, added to any `CLAUDE.md` that exists:

```markdown
@AGENTS.md
```

`docs/development/README.md` §1 routes code and document changes to conventions documents your project writes to its §3. Write them, moving in the conventions an existing `AGENTS.md` or `CONTRIBUTING.md` holds, or delete those two rows until they exist, together with the "Before changing code or documents" section of `AGENTS.md` that points at them.

Where an existing `CONTRIBUTING.md` or `AGENTS.md` states a rule these documents contradict, such as "rebase and merge", ask the user which stands. Replace the losing rule with a pointer to the document that holds the winning one; never leave both.

## 6. Mark files that must not merge

`scripts/finish.*` flags any added file that `.gitattributes` marks `binary`, and a conflict in one is a stop in `finishing-work.md` §3. The `binary` attribute is what tells git to refuse an automatic merge, so mark every file class where a merged result would be corrupt:

```gitattributes
* text=auto
*.sh  text eol=lf
*.example text eol=lf
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

On a throwaway branch cut from a base that carries the scripts, from the primary checkout. Replace `main` with your base branch. An adoption that lands through a pull request rehearses on its own branch instead, per §10:

```bash
./scripts/setup.sh                 # .\scripts\setup.ps1 on Windows
./scripts/env-capabilities.sh      # what this session can do: gh, and whether origin is on GitHub
git switch -c chore/rehearse-finish origin/main
git commit --allow-empty -m "claim: rehearse the finish script" -m "Scope: Rehearsal only." -m "Touches: nothing" -m "Split: No"
./scripts/finish.sh
./scripts/finish.sh --pr --dry-run --testing "rehearsal"
```

Repeat from a git worktree, which is the only way to exercise the worktree removal path. Delete the branch afterwards.

If you wrote a project scan, make a change it should stop on, and confirm the bare run stops and `--declare` clears it.

## 9. Run the check command in CI

The finish scripts refuse to merge on a failing check, and read "workflows but no check runs" as broken CI, so the workflow runs on pull requests to every base branch. One job that runs the same command contributors run locally is enough:

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]   # your base branch
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

Without CI, nothing enforces the check command: `scripts/finish.*` quotes it and never runs it, and `--merge` finds no checks to refuse on. The `Testing` line is then the only record that it ran.

## 10. Land the adoption

- **A new repository with no other contributors:** commit it straight to the base branch, then rehearse per §8.
- **Otherwise:** land it the way it tells everyone else to. Claim a `chore/` branch per `starting-new-work.md`, commit the adoption on it, and finish it with `scripts/finish.*`. The diff adds governing paths, so the bare run lists them for `--acknowledge`.

## Keeping it in step

- **A change to a script updates the document that states it, in the same pull request.** `docs/development/README.md` §5 is the rule.
- **A new document under `docs/development/` follows the skeleton** in `docs/development/README.md` §3, and is reviewed against its §6.
- **The bash and PowerShell halves of every script behave identically.** A change to one is a change to both.
