# Development

## 0. What this folder is for

**After reading this README you can pick the one development document for the moment you are at, and write or review a development document to the standard in §2.**

---

## 1. Which document for which moment

| You are | Read | Afterwards you can |
|---|---|---|
| On a machine with nothing installed | [`setting-up.md`](setting-up.md) | Claim, build and land work from that machine. `scripts/setup.*` is the mechanised form |
| About to build something, before any code | [`starting-new-work.md`](starting-new-work.md) | Say whether the work is already claimed, and claim it so the next person can see you |
| About to change code | The code-conventions document your project writes to §3. None ships with this set | Read only what pays, and get right the conventions no check enforces |
| About to change documents | The documentation-conventions document your project writes to §3. None ships with this set | Amend a document without silently mutating it |
| Finished, with a branch to land | [`finishing-work.md`](finishing-work.md) | Get the work onto the base branch without destroying it on the way. `scripts/finish.*` is the mechanised form |

The two scripts are the sanctioned path for their documents.

---

## 2. The standard every document here is written to

- **It opens with a capability, not a topic.** §0 states what the reader can do afterwards, and where the moment it covers begins or ends. Do not write: *"This document describes how work is claimed."* Write: *"After reading this you can say whether the work you want to do is already on somebody's branch, and claim it so that their check finds you."*
- **Present tense, current facts only.** No "has since", "until now", "was", "used to", "now", "no longer", "yet", "still" in prose. No anecdote about what once went wrong: do not write *"This has already cost the project one stale finding."* Write: *"Read a file with `git show origin/main:<path>` when you are deciding rather than editing."*
- **No milestone or pull-request number as narration.** Do not write: *"Since the CI change the checks are one workflow."* Write: *"The checks are one workflow with one job."*
- **No count that drifts** — of files, lines, entries or steps. Do not write: *"There are fourteen steps and thirty-one lint entries."* Write: *"The check script's summary lists every step."*
- **Rationale only as a prohibition that names the action it forbids**, in one sentence. The test: if the explanation can be deleted and the prohibition reads on its own, delete the explanation. Do not write: *"Two people can build the same thing in a week without noticing, which is why …"* Write the check, and the stop table.
- **No weighing of alternatives.** Do not write: *"SSH gets you to the same place along a longer road, with four steps each of which …"* Write: *"Choose HTTPS. Answering Yes to the credential prompt makes the one login cover `git` as well."*
- **No status line, no version, no action list, and no sentence about the document itself.** Do not write: *"Two narrowings, for the same reason the previous check has its own."* Write the two narrowings.
- **No summary of another document.** Point at its section by number and heading.
- **A procedure is numbered steps**, each with its command, and a stop table where a step can stop. Every stop condition says *report and wait*.
- **Rules for agents stay**, as a checklist, one section per procedure document. A conventions document with no procedure carries its pre-pull-request checklist in that slot instead.
- **The last section is *What is deliberately not here***, naming where each excluded thing lives.
- **Citations by heading or quoted phrase, never by line number.** A script is cited by path and flag.
- **A section number cited from a script or another document is kept, or every citation to it is amended in the same pull request.** The citers are listed by:

  ```bash
  grep -rnE '(starting-new-work|finishing-work|setting-up\.md|README)[^ )]*[ )]*(§|section|check) *[0-9]' scripts docs AGENTS.md .github
  ```

---

## 3. The skeleton

Copy and fill in.

```markdown
# <Document name>

## 0. What you can do after reading this
<the outcome, per §2, and where the moment begins or ends. The script that mechanises this document, and what a bare run guarantees, goes here or in the first numbered section>

## 1. …
<the procedure: numbered steps with commands, stop tables, report formats>

## N-1. Rules for agents, or the pre-pull-request checklist
<per §2>

## N. What is deliberately not here
<the scope a reader will otherwise assume, and where each excluded thing lives>
```

An empty section says so in one line rather than being omitted.

---

## 4. What belongs

The steps, with the exact command. What a script guarantees and what it refuses. Every stop condition and what to do at it. The report format the reader hands the user. The rule, stated as a prohibition, with the one action it forbids. What no check catches, stated as such.

---

## 5. Keeping it current

**Edited in place, in the same pull request as the script, check or procedure change that made it wrong.** [`finishing-work.md`](finishing-work.md) §2 check 6 is the trigger: a diff that changes what a script does, what a check catches or what a step is updates the document that states it. A change that leaves the procedure alone owes nothing.

**Where one of these documents disagrees with the scripts or the repository, the repository wins and the document is the bug.**

**Edit the sentence. Delete the sentence. Never append a correction to it.**

---

## 6. Reviewing a development document

Any unticked box is a fail.

**From the document alone:**

- [ ] **§0 states an outcome, as a capability** — something a reader can *do*, not a topic
- [ ] **Every §2 rule on what a sentence may say holds** — present tense, no milestone narration, no drifting count, no rationale beyond a prohibition, no weighing of alternatives, nothing about the document itself, no summary of another document
- [ ] **It follows the §3 skeleton**: outcome first, procedure, rules for agents or the pre-pull-request checklist, what is deliberately not here
- [ ] **Every citation is by heading, quoted phrase, or path and flag.** No line numbers
- [ ] **Every section number cited from a script or another document is present, or every citer §2's grep lists is amended in this pull request**

**Beside the repository:**

- [ ] **Every script, flag, path, hook and check it names exists as spelled**
- [ ] **Every stop condition it attributes to a script is one the script stops on**, and every guarantee it attributes to a bare run is one the script keeps
- [ ] **Every cross-reference to another document's section resolves**, and that section says what the citation claims
- [ ] **Attempt the outcome §0 promises using the document alone.** Each script or file you had to open to finish names a missing sentence

---

## 7. What is deliberately not here

- **Decisions.** A sentence that argues for a decision belongs wherever your project keeps them.
- **Plans.** A sentence that says when, or lists what remains to do, belongs in your project's roadmap.
- **Architecture.** A sentence about how the code composes belongs beside the code.
- **Code and documentation conventions.** Your project writes them to §3; §1 routes to them.
