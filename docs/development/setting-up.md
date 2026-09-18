# Setting Up

**Scope:** From a machine with nothing installed to a clone that can claim, build and land work. Read once on arrival, and again only when something is missing.
**Audience:** Every contributor, and every coding agent acting on their behalf.
**Companion documents:** [`README.md`](README.md) — the charter · [`starting-new-work.md`](starting-new-work.md) — the first document that assumes the tools below · [`finishing-work.md`](finishing-work.md) — the one that cannot run without `gh`

---

## 0. What you can do after reading this

**After reading this you can claim and land work from a machine that had nothing installed, and you know where the project's own build toolchain is described.**

---

## 1. What you need, and when

Two tiers. Install the first today; install the second when you pick up work that needs it.

| Tier | What | Who needs it | When |
|---|---|---|---|
| **1** | git, a git identity, `gh`, a clone | Everyone, without exception | Now — [`starting-new-work.md`](starting-new-work.md) §2 and [`finishing-work.md`](finishing-work.md) §4 to §6 are commands that need these four things |
| **2** | Whatever this project builds with — §4 | Anyone building or running code | When you claim your first branch that changes code |

---

## 2. The fast path — run the script

From the root of your clone. On Windows:

```powershell
.\scripts\setup.ps1
```

On macOS or Linux:

```bash
./scripts/setup.sh
```

The script installs tier 1 only. It detects what you already have, installs only what is missing, and prints a table of where you stand; a second run installs nothing and reports.

Two steps it prints and stops at, for you to finish by hand: `gh auth login` (§3.3), which needs a browser, and your git identity (§3.2), which a script must not guess.

If you would rather not run the script, or it fails on your machine, §3 is the same steps written out.

---

## 3. Tier 1 — everyone

### 3.1 git

```powershell
winget install --id Git.Git
```

```bash
brew install git                 # macOS
sudo apt install git             # Debian / Ubuntu
```

Restart your shell after every install in this document, so the new `PATH` is picked up.

```bash
git --version
```

### 3.2 Your git identity

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

[`starting-new-work.md`](starting-new-work.md) §2 and [`finishing-work.md`](finishing-work.md) §1 read it to identify you; set it wrong and neither errors.

**Use an email GitHub knows about.** It must match a verified address on your GitHub account, or your commits do not link back to you. GitHub issues a `@users.noreply.github.com` address under Settings → Emails for anyone who would rather not publish a personal one.

```bash
git config --global --get user.name
git config --global --get user.email
```

### 3.3 `gh`, the GitHub CLI

```powershell
winget install --id GitHub.cli
```

```bash
brew install gh                  # macOS
sudo apt install gh              # Debian / Ubuntu
```

Restart your shell, then authenticate. Four prompts matter:

```bash
gh auth login
```

| Prompt | Answer | Why |
|---|---|---|
| What account do you want to log into? | **GitHub.com** | Not an enterprise server |
| What is your preferred protocol for Git operations? | **HTTPS** | One login covers `git` as well as `gh` |
| Authenticate Git with your GitHub credentials? | **Yes** | This installs `gh` as the git credential helper, so `git push`, `pull` and `fetch` need nothing further |
| How would you like to authenticate GitHub CLI? | **Login with a web browser** | Copy the one-time code, press Enter, approve in the browser |

```bash
gh auth status
```

### 3.4 Clone the repo

<!-- ADOPTER: replace <owner>/<repo> in both commands with your repository. -->

```bash
gh repo clone <owner>/<repo>
```

```bash
git clone https://github.com/<owner>/<repo>.git
```

Either works. The first uses the credentials you just configured.

### 3.5 Verify tier 1

Run all four. Every one should answer without error.

- [ ] **git is installed.** `git --version`
- [ ] **Your identity is set.** `git config --global --get user.email` returns your address.
- [ ] **`gh` is authenticated.** `gh auth status` reports a logged-in account.
- [ ] **The remote is reachable.** `git fetch --all --prune` from inside the clone succeeds.

That fourth one is [`starting-new-work.md`](starting-new-work.md) §1's second precondition. If it works, go there next.

---

## 4. Tier 2 — building and running this project

<!-- ADOPTER: write this section. List each tool the project builds with, the exact install command per platform, the command that verifies it, and a verify checklist in the shape of §3.5. Name the file that pins each version, and say never to change a pin to make something build. -->

Nothing in tier 2 is required to claim or land work.

---

## 5. When something is wrong

| Symptom | Cause | Fix |
|---|---|---|
| "not recognised" / "command not found", right after installing | Your shell captured `PATH` before the install | Close the terminal and open a new one. Try this before anything else |
| `setup.ps1 cannot be loaded because running scripts is disabled` | PowerShell's execution policy | `powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1` — this affects that one run only |
| `permission denied: ./scripts/setup.sh` | The executable bit did not survive | `bash scripts/setup.sh` works regardless |
| `winget` itself is not recognised | Older Windows build, or App Installer is missing | Install "App Installer" from the Microsoft Store |
| `gh auth status` says you are not logged in | `gh` installed, never authenticated | §3.3. Installing and authenticating are two steps |
| `git push` asks for a password every time | The credential helper is not configured | Re-run `gh auth login` and answer **Yes** to "Authenticate Git with your GitHub credentials?" |
| Your commits do not link to your GitHub account | `user.email` is not a verified address on your account | §3.2 — use your verified or `noreply` address |
| Any install fails behind a corporate network | TLS interception or a proxy | Report it rather than working around it — a proxy that breaks an install also breaks CI |
| `scripts/finish.*` stops or reports a finding | See [`finishing-work.md`](finishing-work.md) §8 *When `scripts/finish.*` stops* | |

**If a fix is not here, say so rather than improvising one.**

---

## 6. Rules for agents

- [ ] Tell the user what you are about to install and why, **before** installing it
- [ ] Never run an install that needs elevation or a password without asking first
- [ ] Never run `gh auth login` on the user's behalf — it needs a browser and it is their account
- [ ] Never set `user.name` or `user.email` from a guess. Ask
- [ ] If a tool is missing, say so and point the user at this document — do not improvise an alternative install path
- [ ] Never change a pinned toolchain version to make something build — stop and report it
- [ ] If an install fails, report the actual error. Never report success from a failed command
- [ ] After installing anything, tell the user their shell needs restarting

---

## 7. What is deliberately not here

- **Editor and IDE choice, extensions, or per-person productivity tooling** — bring what you like
- **CI configuration** — the workflow files under `.github/workflows/`
