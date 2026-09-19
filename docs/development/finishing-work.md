# Finishing Work

## 0. What you can do after reading this

**You can take a finished branch onto `main` as one squashed commit without destroying it on the way, and stop at every point where the next command would.** Start after the last line of feature code. [`README.md`](README.md) §1 routes to the other development documents.

Where this document says `main`, read the base branch `scripts/finish.*` resolves: `DEFAULT_BASE` in `scripts/workflow.conf`, or an alternate base per [`starting-new-work.md`](starting-new-work.md) §4.3.

### The fast path — run the script

Sections 1 to 7 are the steps the script runs; run them by hand if it fails. Three commands, in order, and you never touch `main`:

```powershell
.\scripts\finish.ps1                                    # sections 1-2: reports, changes nothing
.\scripts\finish.ps1 -Pr -Testing "what you ran"        # sections 3-4: updates, pushes, opens the PR
.\scripts\finish.ps1 -Merge                             # sections 5-6: verifies, squashes, cleans up
```

```bash
./scripts/finish.sh
./scripts/finish.sh --pr --testing "what you ran"
./scripts/finish.sh --merge
```

Add `-DryRun` / `--dry-run` to any stage to print the commands without running them. `-Cleanup` / `--cleanup` is the recovery path if a merge landed but cleanup did not: it confirms the squashed commit is on the base, then deletes the remote branch, the worktree and the local branch. A file the bare run flagged that the branch means to include is acknowledged on the `--pr` run with `--acknowledge <path,...>` (`-Acknowledge` in PowerShell); it accepts only paths that run flagged, and writes what you acknowledged into the pull-request body where a reviewer sees it. A project stop that needs a human assertion is answered with `--declare <name,...>` (`-Declare`), per §2 check 5.

**Every stop names the section of this document that explains it**, and says whether this run already changed anything — `Nothing was changed`, or the commands under `Already done in this run`, which are not undone.

**What the bare run guarantees.** It creates no commit, no branch and no pull request; it deletes nothing; it changes no local branch, no working tree and nothing on the remote. It *does* update your remote-tracking refs, which is what makes its answers true.

**What it deliberately will not do.** It will not judge your diff, run your tests, resolve a merge conflict, or decide whether a change a project scan stopped on was intended. **It has no override flag — no `-Force`, no `-Yes`, no `--skip-checks` — and nobody adds one**, because permission systems match on command prefixes: the moment `-Merge` is approved, `-Merge -Force` is approved too.

Two places where the script differs from the literal commands below:

- It does not pass `--delete-branch` to `gh pr merge`. That flag deletes the *local* branch before the squashed commit is confirmed on the base, which §9 forbids. The script deletes the remote branch with `git push origin --delete` after confirming.
- It resolves the base branch from `scripts/workflow.conf` rather than assuming `main`. Where it cannot tell which base a branch belongs to, it refuses and asks.

**After any change to `scripts/finish.*`, rehearse it on a throwaway branch from the primary checkout and from a worktree.** Only the second exercises the worktree removal path.

---

## 1. Before you open anything

Five preconditions. If any fails, stop and resolve it before going further.

- [ ] **Working tree is clean.** `git status --porcelain` returns nothing.
- [ ] **Your view of the remote is current.** `git fetch --all --prune`. If the fetch fails, stop.
- [ ] **You are on the branch you are finishing.** `git rev-parse --abbrev-ref HEAD`
- [ ] **You created this branch.** The claim commit's author is you: `git log origin/main..HEAD --reverse --format='%an <%ae>' | head -1`
- [ ] **`gh` is installed and authenticated.** `gh auth status` — see [`setting-up.md`](setting-up.md) §3.3 if not.

If the working tree is dirty, **stop and ask the user what to do with those changes.** Never stash them, never sweep them into the commit, never switch branches over them.

If the branch is not yours, stop. Report the owner and wait.

**A branch created before this repository adopted these documents** has no `scripts/finish.*` and no claim commit. Its owner merges the base in first, which brings the scripts, then passes the scope on every stage:

```bash
git merge origin/main
./scripts/finish.sh --scope "what this branch does"
```

Without `--scope` the script stops at `the first commit on this branch is not a claim commit`.

---

## 2. Is it actually finished?

Run all of it and report what you found before opening anything.

**1. Does the work match the claim?**

```bash
git log origin/main..HEAD --reverse --format='%B' | head -20
```

If the scope changed while you worked, add an empty follow-up commit updating it *before* opening the PR, so the claim and the PR tell the same story.

**2. Is every changed file one you meant to change?**

```bash
git diff --stat origin/main...HEAD
```

Read the whole list. Editor config, a lockfile, a stray `.env`, a file you opened to look at and reformatted.

**3. Read your own diff.**

```bash
git diff origin/main...HEAD
```

Looking for: debug scaffolding, commented-out blocks, `TODO: remove before merge`, print statements, hardcoded local paths, secrets or tokens, and unrelated formatting churn burying the real change.

**4. Do the checks pass locally?** Run the project's check command, `CHECK_COMMAND` in `scripts/workflow.conf`:

```bash
./scripts/check.sh          # scripts\check.ps1 on Windows
```

Do not open a PR you already know is red.

**5. Did you change a file that needs a decision?** `scripts/finish.*` reports these and gates the `--pr` run on them.

**What the script looks at, on every repository:**

| Finding | Matches | Gate |
|---|---|---|
| `credentials` | `.env`, `*.pem`, `*.key`, `id_rsa*`, `*.p12`, `*.pfx` | `--acknowledge` |
| `editor or OS` | `.vscode/`, `.idea/`, `*.swp`, `.DS_Store`, `Thumbs.db` | `--acknowledge` |
| `lockfile` | the file names in `LOCKFILES` | `--acknowledge` |
| `repo-governing` | the patterns in `GOVERNING_PATHS` | `--acknowledge` |
| `binary file` | an added file `.gitattributes` marks `binary` | `--acknowledge` |
| `debug scaffolding` | the content of an added line matching the built-in leftover pattern or `SCAFFOLDING_PATTERN`, outside the shipped `scripts/finish.*`, `setup.*` and `env-capabilities.*` | none — a finding only |
| `large diff` | more changed lines than `LARGE_DIFF_LINES` | none — a finding only |
| a credential in an added line | a vendor token prefix or a private key header anywhere in the content, and a secret, token or password assigned a literal value. A value that reads a credential from the environment is not one | **a stop, with no flag.** Change the line |

**What a project adds.** `scripts/finish-project.sh` and `scripts/finish-project.ps1`, when present, run the project's own scans after these. A project scan that needs a human assertion stops unless the run declares it by name with `--declare <name>`, and the declaration is written into the pull-request body. `--declare` refuses any name no scan asked for on that run, so it cannot pre-authorise a stop that has not fired. `scripts/finish-project.sh.example` carries the contract.

If a project scan stopped and the change was not intended, the branch changed something you did not think you were touching. That is a stop-and-investigate, not a declaration.

**6. Did you change what a script, a check or a procedure does?** If the diff changes what `scripts/*` does, what a check catches, what a stop condition is, or what a step in a procedure is, then the document under `docs/development/` that states it is wrong — edit it in place **in this pull request**. [`README.md`](README.md) §5 is the rule.

- **A finding, not a stop, and no script checks it.** The reviewer reads the diff against [`README.md`](README.md) §6.

---

## 3. Bring your branch up to date with `main`

```bash
git fetch origin
git merge origin/main
```

**On a branch off an alternate base, substitute `origin/<alternate-base>` for `origin/main` here and everywhere below.**

### Merge, never rebase

Never rebase, and never force-push: a rebase needs a force-push, which can destroy work existing nowhere else. §5 squashes the branch anyway, so `main` stays linear.

### If there are conflicts

`git merge --abort` is always available and always safe. Use it the moment you are unsure.

| Situation | What happens |
|---|---|
| Merge is clean | Continue to §4 |
| Every conflicting hunk is one where you can state what both sides intended, and the resolution keeps both | Resolve it, then **show the user the resolution before committing it** |
| A conflicting hunk whose other side you cannot explain | **Stop.** Report the file, the hunk and who wrote the other side, and wait |
| Conflicts you cannot resolve with confidence | **Stop.** `git merge --abort`, report, wait |
| Conflicts in a binary, generated, scene or asset file | **Stop.** These do not merge. One side wins and that is a human decision |

Never resolve a conflict by picking whichever side looks more complete, and never with `git checkout --ours`/`--theirs` or by taking one side of a file whole. After resolving, read `git diff origin/main...HEAD` and confirm every line the other side added is in the result.

---

## 4. Open the pull request

```bash
gh pr create --base main --title "<type>: <outcome>" --body "..."
```

The title uses the same `<type>: <outcome>` shape as the branch name, with a type from `BRANCH_TYPES`.

**A branch off an alternate base targets that base, not `main`:** `gh pr create --base <alternate-base>`. Check the base before you create, not after.

The body mirrors the claim commit:

```
Scope:    Token-bucket rate limiting per API key, with 429 responses and a Retry-After header.
Touches:  src/api/limits.ts, src/api/middleware.ts (+218 -11)
Testing:  the check script passes; burst and refill tests added.
Notes:    Bucket size left as a named constant - tuning is a follow-up, not this branch.
```

`Touches` is the **actual** file list from `git diff --stat`, not the guess in the claim. `Testing` says what you ran, not what you believe. `Notes` carries anything a reader would otherwise have to reconstruct — deliberate omissions, follow-up work, decisions that could reasonably have gone the other way. The script adds what you acknowledged and what you declared.

**If `gh` cannot run here**, the `--pr` run merges the base in and pushes, then prints the title and body and exits 3. Open the pull request with those values: by hand at the `pull/new/<branch>` URL git prints, or, in an agent session with GitHub tools, with those tools. The web form is not a reason to skip §2. Where `origin` is not on a GitHub host `gh` is logged in to, `scripts/env-capabilities.*` says so, and `--merge` stops naming that as the cause.

**Draft PRs.** Use `--draft` for work you want visible but not landable. A draft tells the next person's [`starting-new-work.md`](starting-new-work.md) §2 check 4 that the work exists *and* that it is not finished.

---

## 5. Merge it

```bash
gh pr checks
gh pr merge --squash --delete-branch
```

Where branch protection is unavailable, enforcement is script-side: `scripts/finish.*` refuses on any failing check, and a hand-run `gh pr merge` does not.

**Squash, always.** Every commit on your branch becomes one commit on `main`; `main` reads as one entry per piece of work, and stays linear.

Set the squash commit message deliberately: title `<type>: <outcome>` matching the PR, body carrying the `Scope` line. Left alone, `gh` concatenates every commit message on the branch, claim commit included.

### What can go wrong here

| Situation | What happens |
|---|---|
| GitHub reports the PR has conflicts | Back to §3. **Do not** resolve conflicts in the GitHub web editor |
| A check is failing | Fix it on the branch and push. Never merge red |
| The PR is not yours | **Stop.** Never merge or close a PR you did not open |
| It is urgent and pushing straight to `main` would be faster | **Stop.** There is no situation in this document where that is the answer |

### Release and back-merge, when `main` is released from `develop`

Where `BASE_BY_PREFIX` maps a hotfix prefix to `main` ([`starting-new-work.md`](starting-new-work.md) §4.3), two merges move work between the long-lived branches. `scripts/finish.*` performs neither: it refuses to run on a base branch. A maintainer the user names performs them, each through a pull request, **with a merge commit, never a squash**.

1. **Release.** Open `develop` into `main`, and merge it once its checks pass:

   ```bash
   gh pr create --base main --head develop --title "release: <version or date>" --body "<what is in it>"
   gh pr merge <number> --merge
   ```

2. **Back-merge, after every hotfix lands on `main`.** Open `main` into `develop` the same way, with `--head main --base develop`, and merge it with `--merge`.

| Situation | What happens |
|---|---|
| The release or back-merge pull request has conflicts | **Stop.** Report the files and wait for the maintainer. Never resolve them on `main` or `develop` directly |
| Anyone proposes squashing a release or a back-merge | **Stop.** Merge commits only |

---

## 6. Clean up locally

```bash
git switch main
git pull --ff-only origin main
git log --oneline -3
git branch -D feat/api-rate-limiting
```

Confirm your squashed commit is on `main` before deleting anything. `git branch -d` refuses after a squash merge because the squashed commit has a new SHA; once the log shows it, `-D` is correct.

`--delete-branch` in §5 removed the remote branch, and that is the step that retires your claim. `scripts/finish.*` deletes it on `--merge` and on `--cleanup`, after confirming the squashed commit. A merged branch left on the remote reads as an active claim to the next person running [`starting-new-work.md`](starting-new-work.md) §2.

### If you were working in a git worktree

The block above does not run there: `main` is checked out in the primary checkout, and nothing depends on local `main` being current.

From the worktree, confirm the work landed against the remote-tracking ref:

```bash
git fetch origin
git log --oneline -3 origin/main
```

Then leave the worktree, and finish from the primary checkout:

```bash
git worktree remove <path-to-worktree>
git branch -D feat/api-rate-limiting
```

A worktree cannot remove itself, and git will not delete the branch you have checked out.

Local `main` catches up the next time anyone runs the block at the top of this section from the primary checkout.

---

## 7. Tell the user

```
Merged:  feat/api-rate-limiting -> main
PR:      #12 (squashed, 4 commits -> 1)
Files:   src/api/limits.ts, src/api/middleware.ts (+218 -11)
Checks:  2 check(s) passed
Cleanup: remote branch deleted, local branch deleted, main up to date
```

Plain ASCII arrows and hyphens: `scripts/finish.*` prints this block verbatim, and PowerShell 5.1's console encoding makes non-ASCII output unreliable. The `Cleanup` line is assembled from what happened, so a skipped step says so — `main not updated (primary checkout is on chore/other)`.

---

## 8. When it has already gone wrong

Almost everything in git is recoverable, provided you stop before doing the second thing.

**You committed to `main` by accident.** [`starting-new-work.md`](starting-new-work.md) §6. Do not improvise a fix.

**You merged the wrong branch.** Revert it on a new branch and open a PR for the revert: `git revert -m 1 <merge-sha>`. Never `reset --hard` a `main` that has been pushed — that breaks the repository for everyone who has pulled it.

**You force-pushed something.** Stop touching the branch immediately and tell the team. The old commits are in `git reflog` on whichever machine created them; reflog expires and clones do not share it.

**You deleted an unmerged branch.** The SHA is recoverable from `git reflog`, or from the GitHub PR page if one exists. Act before the next `git gc`.

**You are not sure what you did.** `git reflog` shows every position HEAD has held, including ones no branch points at. Read it before running anything else, and if the situation involves someone else's work, ask before acting.

### When `scripts/finish.*` stops

| It says | Cause | What to do |
|---|---|---|
| `the working tree is not clean` | Uncommitted changes exist in exactly one place | Decide what they are for and commit or remove them yourself. The script never stashes them |
| `you did not create this branch` | The claim commit's author is not your git identity | Tell the owner it looks ready, and wait. If the base the stop names is wrong, re-run with `--base <branch>` instead |
| `origin/<base> does not exist` | The resolved base is not on the remote, usually because `origin/HEAD` is unset and the base is not `main` | Set `DEFAULT_BASE` in `scripts/workflow.conf` |
| `cannot tell which base branch this branch targets` | Two candidate bases are equally distant from `HEAD`, and the script does not guess | Say which: `--base <branch>` (`-Base` in PowerShell). See [`starting-new-work.md`](starting-new-work.md) §4.3 |
| `some changed files need a decision` | A path from the §2 check 5 table was flagged | Look at each one. If it belongs, re-run with `--acknowledge <path,...>` |
| a project scan stops, naming a `--declare` value | `scripts/finish-project.*` found a change that needs a human assertion | If intended, re-run with `--declare <name>`. If not, investigate before anything else |
| `--declare names something no scan asked for` (exit 2) | The declared name matched no stop on this run | Remove it. A declaration only answers a stop that fired |
| `an added line looks like a credential` | The secret scan matched an added line | Change the line. There is no flag to wave it through |
| `this repository has workflows but the pull request has no check runs` | CI is configured and produced nothing | Broken CI, not a green branch. Do not merge; report it |
| `checks none configured on this repository - nothing was verified` (a finding, not a stop) | The checkout carries no `.github/workflows` tree | Expected on a repository without CI. On one that has CI, it means the workflow is missing: stop and report it |
| `you are on <base>` | The checkout is on a base branch, not on a claimed branch | Claim the work per [`starting-new-work.md`](starting-new-work.md) §4, or §6 there if you already committed to the base |
| `the first commit on this branch is not a claim commit` | The first commit off the base does not start `claim:`, or the base resolved wrongly | Check the resolved base on the `base` line. If it is right and the branch predates the workflow, pass `--scope "<what it does>"` on every stage |
| `gh pr create failed` | `gh` refused after the branch was pushed | Read gh's message above the stop. The branch is pushed, as `Already done in this run` lists; fix the cause and re-run `--pr` |
| `there is no pull request for this branch` | `--merge` ran before `--pr` opened one | Run `--pr` first |
| `gh could not read the pull request for this branch` | `gh` failed for a reason it names, such as `origin` not being a GitHub host | Act on what gh said. Where no GitHub route exists, land the branch through the remote's own review and run `--cleanup --sha <commit>` |
| `this stage needs a route to GitHub, and there is none` | No usable `gh`: a cloud session, or `origin` not on a host `gh` is logged in to | Follow the route the stop prints |
| `this branch was cut from origin/<a>, but resolves to origin/<b>` | The branch carries commits of one long-lived branch that its resolved base lacks: a hotfix cut from `develop`, or a feature cut from `main` | If it belongs on `<a>`, re-run with `--base <a>`. If it belongs on `<b>`, it was cut from the wrong branch: report it and wait |
| `note  ALT_BASES lists <branch>, which origin/<default> contains` (a note, not a stop) | `ALT_BASES` names a branch the default merges from, so no branch can be told apart by it | Move it to `BASE_BY_PREFIX` in `scripts/workflow.conf` |
| `worktree not removed - it is locked` (after the merge) | Another tool owns that worktree's lifecycle, such as an agent session | Leave it through that tool. Otherwise `git worktree unlock <path>` from the primary checkout first. The script does not unlock it for you |

---

## 9. Rules for agents

- [ ] Run §2 in full and report the findings **before** opening a PR
- [ ] Never push directly to `main`
- [ ] Never force-push. Never `git rebase`. `--force-with-lease` is not an exception
- [ ] Bring branches up to date with `git merge origin/main`, never by rebasing
- [ ] Never merge or close a pull request you did not open
- [ ] Never open or merge a pull request that targets a different base than the branch was cut from (§4)
- [ ] Never resolve a conflicting hunk whose other side you cannot explain — stop and report it
- [ ] Never resolve a conflict with `--ours`/`--theirs` or by taking one side of a file whole
- [ ] Never resolve a conflict in a binary, generated, scene or asset file — stop and report it
- [ ] Show the user any conflict resolution before committing it
- [ ] Never `git branch -D` until `git log` has confirmed the work is on `main`
- [ ] Never stash, reset or discard uncommitted work to make an operation possible — ask
- [ ] Never merge with checks failing
- [ ] Never `--declare` a change you did not intend, and never `--acknowledge` a path you did not look at
- [ ] If `git fetch` or a `gh` command fails, say so. Never report success from a failed or stale command
- [ ] Always give the user the PR URL and the §7 report block

---

## 10. What is deliberately not here

- **Release, tagging and versioning** — no document in this set owns these
- **CI configuration** — what the checks *are* is your workflow files and the check command; this document holds only the rule that they are green
- **Commit message conventions beyond the PR title and the claim commit**
- **Long-lived branches** other than the default, the alternate bases and the `BASE_BY_PREFIX` bases in `scripts/workflow.conf`
- **Hotfix procedure** beyond its base — a hotfix is a branch through this same procedure, landing on `main` where `BASE_BY_PREFIX` maps its prefix there (§5)
