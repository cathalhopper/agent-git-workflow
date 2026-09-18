<!-- ADOPTER: copy this file to the root of your repository as AGENTS.md. Replace <Project name> and write the two sections at the end. -->

# <Project name>

Several people work out of this repo at once, most of them driving a coding agent.

## Before starting any feature work — mandatory

**Read `docs/development/starting-new-work.md` and follow it before writing any code.** Every time, including for changes that look small.

It is a short procedure: check whether the work is already claimed on another branch, and either stop and route the user to that person, or claim the work yourself with a named branch and a claim commit.

The rules that matter most:

- Run the overlap check in section 2 before writing code
- On any Stop condition, report to the user and **wait** — do not create a branch, write code, or check anything out
- Never commit directly to `main`
- Work destined for an alternate base branch, listed in `ALT_BASES` in `scripts/workflow.conf`, branches from that base and never reaches `main`
- Never modify a branch you did not create — no commits, rebases, amends, force-pushes, renames or deletions
- Never force-push anything
- Never stash, reset or discard a user's uncommitted work to make a checkout possible — ask them
- If `git fetch` fails, say so. Never report "no overlap found" from a stale remote

## Before changing code or documents

**Read the conventions document for what you are changing**, listed in `docs/development/README.md` section 1. It holds what no check enforces.

## Before merging any work — mandatory

**Read `docs/development/finishing-work.md` and follow it before opening a pull request or merging anything.**

It is a short procedure: check the branch is genuinely finished and in scope, bring it up to date with its base, open a PR, squash-merge it, and clean up.

**Run it with `scripts/finish.ps1` / `scripts/finish.sh`.** That is the sanctioned way to perform this procedure. A bare run reports and changes nothing; `-Pr`, `-Merge` and `-Cleanup` each do one stage. Read `finishing-work.md` section 0 before the first use.

**The script is the safe path, not a bypass.** It enforces every rule below, and it has no override flag. If it stops, it stopped for a reason in section 9 — report it to the user and wait. Do not work around it by running the same operation by hand.

The rules that matter most:

- Never push directly to `main`
- Never open or merge a pull request against a different base than the branch was cut from
- Never force-push, and never rebase — bring branches up to date with `git merge origin/main`
- Never merge or close a pull request you did not open
- Never resolve a conflict in a file you did not write — stop and report it
- Never resolve a conflict in a binary, generated, scene or asset file — these do not merge
- After a squash merge, confirm the work is on the base with `git log` before deleting the local branch
- Never merge with checks failing
- Never `--declare` a change you did not intend, and never `--acknowledge` a path you did not look at

## Missing tools

If a required tool is missing or not authenticated, say so and point the user at `docs/development/setting-up.md` — do not improvise an install, and never change a pinned toolchain version to make something build.

## Where the code is

<!-- ADOPTER: a short table of the top-level directories and what each holds. -->

## Which document answers your question

<!-- ADOPTER: one row per question a contributor asks, naming the one document that answers it. Start from these rows. -->

| Your question | Read |
|---|---|
| "Is this work already claimed, and how do I claim it?" | `docs/development/starting-new-work.md` |
| "How do I land finished work?" | `docs/development/finishing-work.md` |
| "What do I install?" | `docs/development/setting-up.md` |
| "Which development document is for this moment, and how is one written?" | `docs/development/README.md` |
