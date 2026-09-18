# Development

**Scope:** What `docs/development/` is for, which document to read at which moment, and the standard every document here is written and reviewed to.
**Audience:** Every contributor, and every coding agent acting on their behalf.
**Companion documents:** `AGENTS.md` at the repository root — the routing file every agent reads first · [`finishing-work.md`](finishing-work.md) — §2 check 6, which keeps these documents current

---

## 0. What this folder is for

**After reading this README you can pick the one development document for the moment you are at, and write or review a development document to the standard in §2 and §4.**

Two principles bind every file here:

**A document here holds current, relevant information; it is not an archive of findings, decisions or milestones.** When a script, a check or a procedure changes, the document is edited in place in the same pull request, and **where one of these documents disagrees with the scripts or the repository, the repository wins and the document is the bug.**

What this folder is **not**: not a record of decisions — a sentence that argues for a decision belongs wherever your project keeps them. Not a plan — a sentence that says when, or lists what remains to do, belongs in your project's roadmap. Not an architecture description — a sentence about how the code composes belongs beside the code.

---

## 1. Which document for which moment

| You are | Read | Afterwards you can |
|---|---|---|
| On a machine with nothing installed | [`setting-up.md`](setting-up.md) | Claim, build and land work from that machine. `scripts/setup.*` is the mechanised form |
| About to build something, before any code | [`starting-new-work.md`](starting-new-work.md) | Say whether the work is already claimed, and claim it so the next person can see you |
| About to change code | The code-conventions document your project writes to §3. None ships with this set | Read only what pays, and get right the conventions no check enforces |
| About to change documents | The documentation-conventions document your project writes to §3. None ships with this set | Amend a document without silently mutating it |
| Finished, with a branch to land | [`finishing-work.md`](finishing-work.md) | Get the work onto the base branch without destroying it on the way. `scripts/finish.*` is the mechanised form |

The two scripts are the sanctioned path for their documents. When one stops, the document names the section or the flag that clears it.

---

## 2. The standard every document here is written to

- **It opens with a capability, not a topic.** The first paragraph after the header block states what the reader can do afterwards. Do not write: *"This document describes how work is claimed."* Write: *"After reading this you can say whether the work you want to do is already on somebody's branch, and claim it so that their check finds you."*
- **Present tense, current facts only.** No "has since", "until now", "was", "used to", "now", "no longer", "yet", "still" in prose. No milestone or pull-request number as narration. No anecdote about what once went wrong. No count of files, lines or entries that drifts as the repository grows — name the thing that lists them instead.
- **Rationale only as a prohibition that names the action it forbids**, in one sentence. The test: if the explanation can be deleted and the prohibition reads on its own, delete the explanation.
- **A procedure is numbered steps**, each with its command, and a stop table where a step can stop. Every stop condition says *report and wait*.
- **Rules for agents stay**, as a checklist, one section per procedure document. A conventions document with no procedure carries its pre-pull-request checklist in that slot instead.
- **No status line, no version, no action list, and no sentence about the document itself.**
- **The last section is *What is deliberately not here***, naming where each excluded thing lives.
- **Citations by heading or quoted phrase, never by line number.** A script is cited by path and flag.
- **A section number cited from a script or another document is kept, or every citation to it is amended in the same pull request.** Renumbering breaks a citation silently. The citers are listed by:

  ```bash
  grep -rnE '(starting-new-work|finishing-work|setting-up\.md)[^ )]*[ )]*(§|section|check) *[0-9]' scripts docs AGENTS.md .github
  ```

---

## 3. The skeleton

Copy and fill in. The headings are numbered so scripts and other documents can cite a section.

```markdown
# <Document name>

**Scope:** <the moment this covers, in one sentence: where it begins and where it ends>
**Audience:** Every contributor, and every coding agent acting on their behalf.
**Companion documents:** [`README.md`](README.md) — the charter · <the document before this moment> · <the document after it>

---

## 0. What you can do after reading this
<the outcome, per §2. The script that mechanises this document, and what a bare run guarantees, goes here or in the first numbered section>

## 1. …
<the procedure: numbered steps with commands, stop tables, report formats>

## N-1. Rules for agents, or the pre-pull-request checklist
<a checklist. A procedure document carries its rules for agents here; a conventions document with no procedure carries its pre-pull-request checklist here instead>

## N. What is deliberately not here
<the scope a reader will otherwise assume, and where each excluded thing lives>
```

An empty section says so in one line rather than being omitted.

---

## 4. What belongs, and what does not

**Belongs:** the steps, with the exact command. What a script guarantees and what it refuses. Every stop condition and what to do at it. The report format the reader hands the user. The rule, stated as a prohibition, with the one action it forbids. What no check catches, stated as such.

**Does not belong:**

- **Why the document exists.** Do not write: *"Two people can build the same thing in a week without noticing, which is why …"* Write the check, and the stop table.
- **What once went wrong.** Do not write: *"This has already cost the project one stale finding."* Write: *"Read a file with `git show origin/main:<path>` when you are deciding rather than editing."*
- **A milestone or pull request as narration.** Do not write: *"Since the CI change the checks are one workflow."* Write: *"The checks are one workflow with one job."*
- **A count that drifts.** Do not write: *"There are fourteen steps and thirty-one lint entries."* Write: *"The check script's summary lists every step."*
- **Commentary on the document's own structure.** Do not write: *"Two narrowings, for the same reason the previous check has its own."* Write the two narrowings.
- **A weighing of alternatives.** Do not write: *"SSH gets you to the same place along a longer road, with four steps each of which …"* Write: *"Choose HTTPS. Answering Yes to the credential prompt makes the one login cover `git` as well."*
- **A status line, a version, or an action list.**
- **A summary of another document.** Point at its section by number and heading.

---

## 5. Keeping it current

**Edited in place, in the same pull request as the script, check or procedure change that made it wrong.** [`finishing-work.md`](finishing-work.md) §2 check 6 is the trigger: a diff that changes what a script does, what a check catches or what a step is updates the document that states it. A change that leaves the procedure alone owes nothing.

**Edit the sentence. Delete the sentence. Never append a correction to it.** A *"has since …"* block is the history §2 forbids.

---

## 6. Reviewing a development document

Any unticked box is a fail.

**From the document alone:**

- [ ] **§0 states an outcome, as a capability** — something a reader can *do*, not a topic
- [ ] **Present tense throughout.** No "has since", "until now", "was", "used to", "now", "no longer", "yet", "still" in prose; no milestone or pull-request number outside a citation; no anecdote
- [ ] **No rationale beyond a prohibition that names the action it forbids**
- [ ] **No count that drifts** — files, lines, entries, steps
- [ ] **It follows the §3 skeleton**: outcome first, procedure, rules for agents or the pre-pull-request checklist, what is deliberately not here
- [ ] **No status line, no version, no action list, no sentence about the document itself**
- [ ] **Every citation is by heading, quoted phrase, or path and flag.** No line numbers
- [ ] **Every section number cited from a script or another document is present, or every citer §2's grep lists is amended in this pull request**

**Beside the repository:**

- [ ] **Every script, flag, path, hook and check it names exists as spelled**
- [ ] **Every stop condition it attributes to a script is one the script stops on**, and every guarantee it attributes to a bare run is one the script keeps
- [ ] **Every cross-reference to another document's section resolves**, and that section says what the citation claims
- [ ] **Attempt the outcome §0 promises using the document alone.** Each script or file you had to open to finish names a missing sentence
