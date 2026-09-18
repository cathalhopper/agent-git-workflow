# Starting New Work

**Scope:** From "I want to build X" to "the branch is claimed and pushed". Ends before the first line of feature code.
**Audience:** Every contributor, and every coding agent acting on their behalf.
**Companion documents:** [`README.md`](README.md) — the charter · [`setting-up.md`](setting-up.md) — the tools this document assumes · [`finishing-work.md`](finishing-work.md) — how it lands

---

## 0. What you can do after reading this

**After reading this you can say whether the work you want to do is already on somebody's branch, and claim it so that the next person's check finds you.** The branch list is the registry: there is no board and no tooling to maintain.

---

## 1. Before you check anything

Four preconditions. If any fails, stop and resolve it before §2.

- [ ] **Working tree is clean.** `git status --porcelain` returns nothing.
- [ ] **Your view of the remote is current.** `git fetch --all --prune`. Everything below reads `origin/main`, which only `fetch` moves; a stale local `main` is fine, and `git status` will not tell you it is stale.
- [ ] **`origin` is reachable.** If the fetch failed, everything below is unreliable.
- [ ] **`gh auth status`** — optional here, required for [`finishing-work.md`](finishing-work.md). It enables check 4 in §2. If it is not installed, see [`setting-up.md`](setting-up.md) §3.3.

If the working tree is dirty, **stop and ask the user what to do with those changes.** Do not stash them, do not commit them alongside unrelated work, do not switch branches over them.

Where this document says `main`, read the `DEFAULT_BASE` in `scripts/workflow.conf` if your project sets one.

---

## 2. The check — is this already being worked on?

Run all six; none is optional.

**1. List every branch, newest first, with its owner.**

```bash
git for-each-ref --sort=-committerdate refs/remotes/origin \
  --exclude refs/remotes/origin/HEAD \
  --format='%(refname:short) | %(committerdate:relative) | %(authorname)'
```

```
origin/feat/api-rate-limiting | 6 hours ago | Sam Rivera
origin/main                   | 2 days ago  | Alex Chen
```

**2. Read the claims.** For any branch that looks even loosely related, its claim commit is the first commit off `main`:

```bash
git log main..origin/<branch> --reverse --format='%an <%ae>%n%ad%n%n%B' | head -40
```

This is the owner, the date, and the `Scope`, `Touches` and `Split` fields.

**3. Check file-level overlap.**

```bash
git diff --stat main...origin/<branch>
```

Two branches editing the same file are in conflict whatever their names say.

**4. Check open and draft pull requests.**

```bash
gh pr list --state open --json number,title,headRefName,author,isDraft
```

If `gh` is not installed, skip this and say so, and point the user at [`setting-up.md`](setting-up.md) §3.3. Every open PR has a remote branch that check 1 surfaced; what you lose is the review status and the draft flag.

**5. Check whether it is already done.**

```bash
git log main --oneline -30
git log --all --oneline -i --grep='<keyword>'
```

**6. Check whether it already exists in the code.** Grep the working tree for the feature's key identifiers — function names, type names, config keys. A partial implementation is itself an overlap signal.

### Judge overlap by meaning, not by string match

Branch names will not match. Ask instead: *would these two branches edit the same code?*

| Your task | Existing branch | Overlap? |
|---|---|---|
| `feat/api-rate-limiting` | `fix/api-429-retry-storm` | **Yes** — the retry storm is what rate limiting answers. Same code path, same bug |
| `feat/editor-copy-paste` | `feat/editor-undo-redo-stack` | **Yes** — both add commands to the same command stack |
| `feat/billing-invoice-pdf` | `feat/search-fuzzy-match` | **No** — different subsystems, no shared files |
| `feat/pricing-tiers` | `feat/hot-reload-config-files` | **Probably** — pricing tiers are one of the config files being made hot-reloadable. Ask |

When you are unsure, treat it as overlap.

### Dormant branches

No commits for 14 days or more means dormant, not free.

---

## 3. What you found → what you do

| What the check found | What happens |
|---|---|
| Nothing related | Claim it — go to §4 |
| A branch doing the same thing | **Stop.** Report owner, scope and age. Recommend the user picks up something else |
| A branch touching the same files, different goal | **Stop.** Report it. Recommend the user agrees a boundary with the owner before either of them starts |
| A large branch your work is a slice of | **Stop.** Report it. Recommend the user asks the owner to split the slice off |
| An open PR that supersedes this | **Stop.** Report the PR. Recommend reviewing it rather than rebuilding it |
| Already merged into `main`, or partly built there already | **Stop.** Show the commits or the existing code. Establish what is actually missing before building anything |
| A dormant branch (14+ days) | **Stop.** Report it. Recommend the user asks the owner before adopting or abandoning it |

> **On any "Stop": create no branch, write no code, check out nothing. Report, recommend, and wait for the user to decide.**

The user may say "proceed anyway" — that is their call to make.

### Never, under any circumstances

- Commit to a branch you did not create
- Rebase, amend, force-push, rename or delete a branch you did not create
- Push to `main`

### Report in this format

```
Overlap: origin/feat/api-rate-limiting
Owner:   Sam Rivera <sam@example.com>
Claimed: 3 days ago  (last commit: 6 hours ago)
Scope:   "Token-bucket rate limiting on the public API, per key."
Files:   src/api/limits.*, src/api/middleware.*
Why:     your task also needs to change src/api/middleware.*

Recommendation: <one sentence>
Contact:        Sam Rivera — agree a boundary before starting
```

---

## 4. Claiming the work

You are here because the check came back clear.

### 4.1 Size it before you name it

A branch is days of work, not weeks. If you cannot describe the outcome in one sentence, it is too big — split it, and claim only the first slice.

**A cleanup, retirement or deletion pass over existing code or documents is its own claim**, never a rider on a branch that came to do something else. Bundled into a feature branch, a deletion is not reviewed.

### 4.2 Name it

```
<type>/<short-description>
```

| Type | For |
|---|---|
| `feat` | New capability |
| `fix` | Something is broken |
| `spike` | Time-boxed investigation, expected to be thrown away |
| `docs` | Documentation only |
| `chore` | Tooling, CI, dependencies, repo hygiene |

`BRANCH_TYPES` in `scripts/workflow.conf` holds this list; `scripts/finish.*` builds the pull-request title from it.

Lowercase, hyphen-separated. **Name the outcome, not the area.**

```
bad:  feat/api                    area, not outcome — nobody can judge overlap from this
bad:  feat/improvements           says nothing at all
bad:  feat/sam-branch-2           tells the next person nothing
good: feat/api-rate-limiting
good: feat/editor-undo-redo-stack
good: fix/api-429-retry-storm
good: spike/websocket-transport
```

### 4.3 Branch from `origin/main`

```bash
git fetch origin
git switch -c feat/api-rate-limiting origin/main
```

Branch from `origin/main`, not from your local `main`, and the form above also works in a git worktree, where `main` cannot be checked out.

**If `git switch -c` cannot find `origin/main`, stop.** The fetch did not do what you think it did. Do not branch from local `main` instead.

Keeping local `main` current is hygiene, not a precondition, and only possible where `main` is not checked out elsewhere:

```bash
git switch main
git pull --ff-only origin main
```

`--ff-only` fails loudly if local `main` has drifted; if it fails, stop and ask rather than retrying without the flag.

When you are reading a file to decide something rather than to edit it, `git show origin/main:<path>` is the spelling that does not depend on local `main`.

### Alternate base branches

`ALT_BASES` in `scripts/workflow.conf` names any long-lived branch that work may target instead of `main` — a prototype branch that never merges to `main`, for instance. Work destined for one branches from it and merges back into it:

```bash
git fetch origin
git switch -c spike/websocket-transport origin/<alternate-base>
```

`scripts/finish.*` reads which base a branch was cut from, and refuses to guess when it cannot tell. With `ALT_BASES` empty, this section does not apply. Everything else in this document applies unchanged.

### 4.4 Write the claim commit

An empty commit whose body declares what you are doing:

```bash
git commit --allow-empty \
  -m "claim: rate limiting on the public API" \
  -m "Scope: Token-bucket rate limiting per API key, with 429 responses and a Retry-After header." \
  -m "Touches: src/api/limits.*, src/api/middleware.*" \
  -m "Split: Yes - the admin dashboard for limits is separable."
```

In PowerShell the same command works with a backtick (`` ` ``) as the line-continuation character, or with every argument on one line. Keep each `-m` value on a single line and it behaves identically in every shell.

Each `-m` becomes its own paragraph, so the claim reads back cleanly under check 2. Three fields, each read by a later check:

| Field | Who reads it | What it holds |
|---|---|---|
| `Scope` | Check 2, and the pull-request body | One or two sentences |
| `Touches` | Check 3 | Your best guess at the files |
| `Split` | §3 | `Yes`/`No`. Whether the next person should ask you for a slice or back off entirely |

### 4.5 Push immediately

```bash
git push -u origin feat/api-rate-limiting
```

An unpushed branch is invisible to check 1.

### 4.6 Tell the user

```
Claimed: feat/api-rate-limiting
Pushed:  origin/feat/api-rate-limiting
Scope:   Token-bucket rate limiting per API key.
No overlapping branches or open PRs found.
```

---

## 5. While the work is in progress

- **Push at least once a day.** It keeps your claim current and your work backed up.
- **Merge `origin/main` into your branch as it moves, not just at the end.** `git fetch origin` then `git merge origin/main`. A branch that meets a fortnight of drift at once meets it as one large conflict, often in files someone else wrote, which is a **Stop** in [`finishing-work.md`](finishing-work.md) §3. Merge, never rebase. On a branch off an alternate base, the upstream is `origin/<alternate-base>`.
- **If scope grows past the claim, update the claim.** An empty follow-up commit is enough.
- **If you abandon a branch, say so.** A dead claim blocks people as effectively as a live one. Delete the branch or push a commit saying it is abandoned.
- **Re-run §2 if you return after a week away.**

---

## 6. If you already started on `main`

```bash
git switch -c feat/<name>       # your commits come with you
git log --oneline -5            # confirm your commits are here
git switch main
git reset --hard origin/main    # only safe once the line above confirmed it
git switch feat/<name>
```

Then pick up from §4.4 — you owe a claim commit and a push.

If uncommitted changes are also in play, stop and ask.

---

## 7. Rules for agents

- [ ] Run §2 before writing any code — every time, including for changes that look small
- [ ] Never commit directly to `main`
- [ ] On any Stop condition, report and wait. Do not proceed on your own judgement
- [ ] Never modify a branch you did not create — no commits, rebases, amends, force-pushes, renames or deletions
- [ ] Never force-push anything
- [ ] Never `git stash`, reset or discard a user's uncommitted work to make a checkout possible — ask
- [ ] If `git fetch` fails, say so. Never report "no overlap found" from a stale remote
- [ ] Always tell the user the branch name you created and confirm that you pushed it
- [ ] Write the claim commit before writing feature code, not after

---

## 8. What is deliberately not here

- **Merging, conflict resolution, pull requests and getting work onto `main`** — [`finishing-work.md`](finishing-work.md)
- **What to read once the work is claimed** — the code-conventions and documentation-conventions documents [`README.md`](README.md) §1 routes to
- **Commit message conventions beyond the claim commit** — the pull-request title and body are [`finishing-work.md`](finishing-work.md) §4's
