# agent-git-workflow

A git workflow for repositories where several people work at once, most of them driving a coding agent. It stops two people building the same thing, and it stops finished work being destroyed on the way to `main`.

It is two procedures, written so a person or an agent can follow them exactly, and a script that performs the second one and refuses at every point where the next command would do damage.

## What is in it

| Path | What it is |
|---|---|
| `docs/development/starting-new-work.md` | **Claiming work.** Check every branch and open pull request for overlap, then claim the work with a named branch and an empty claim commit. The branch list is the registry |
| `docs/development/finishing-work.md` | **Landing work.** Review the branch against its claim, merge the base in, open a pull request, squash-merge, and clean up |
| `docs/development/setting-up.md` | The tools both procedures need, with a slot for your project's own toolchain |
| `docs/development/README.md` | Which document for which moment, and the standard every document in the folder is written to |
| `scripts/finish.sh`, `scripts/finish.ps1` | `finishing-work.md` mechanised, for bash and PowerShell |
| `scripts/workflow.conf` | The one file you edit: your base branches, branch prefixes, check command and flagged file classes |
| `scripts/finish-project.*.example` | The contract for adding your own stops |
| `scripts/setup.*`, `scripts/env-capabilities.*` | Tier 1 install, and the probe that tells the finish script what this session can do |
| `templates/AGENTS.md` | The entry file an agent reads first |
| `examples/tsunami-defence/` | A worked example: an alternate base branch, and a stop on moved golden hashes |

## The rules that matter most

- Check for overlap before writing code. On any overlap, stop and ask
- Never commit or push directly to `main`
- Never force-push, and never rebase. Bring branches up to date with `git merge`
- Never modify a branch you did not create, and never merge a pull request you did not open
- Never resolve a conflict in a file you did not write, or in a file that does not merge
- Never stash or discard someone's uncommitted work to make a command possible
- Never delete a branch until `git log` confirms the work landed
- Never report "all clear" from a failed or stale `git fetch`

## Landing work with the script

```bash
./scripts/finish.sh                                # reports. Changes nothing
./scripts/finish.sh --pr --testing "what you ran"  # updates, pushes, opens the pull request
./scripts/finish.sh --merge                        # verifies, squash-merges, cleans up
```

```powershell
.\scripts\finish.ps1
.\scripts\finish.ps1 -Pr -Testing "what you ran"
.\scripts\finish.ps1 -Merge
```

The script has no override flag. Permission systems match on command prefixes, so once `finish.sh --merge` is approved, `finish.sh --merge --force` would be approved too. Every stop names the section of `finishing-work.md` that explains it.

It needs git, an `origin` remote, and an authenticated `gh` for the pull-request stages. The bare run works without `gh`.

## Adopting it

[`ADOPTING.md`](ADOPTING.md) has each step with its commands, the questions to ask before copying anything, and how to add your own stops.

## What it does not cover

- **Release, tagging and versioning.**
- **CI configuration.** The script reads check results; it does not define checks. `ADOPTING.md` §9 has a minimal workflow.
- **Hosts other than GitHub.** The pull-request stages use `gh`.
- **Code and documentation conventions.** `docs/development/README.md` §3 is the skeleton for writing your own.

## Licence

MIT. See [`LICENSE`](LICENSE).
