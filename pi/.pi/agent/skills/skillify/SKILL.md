---
name: skillify
description: >-
  Turn the work done in the current session into a reusable skill in
  ~/workspace/dotfiles. Load this when Rodda says "make a skill from this",
  "skillify this session", or asks to capture a repeatable workflow as a
  skill. Prompts for the skill's name, description, install location, and
  scope, then writes SKILL.md to the dotfiles skill trees and commits.
---

# Skillify a session

Convert a completed session workflow into a skill under
`~/workspace/dotfiles`. The value is in the corrections, not the commands:
what Rodda had to tell you mid-flight is what the skill must encode so the
next session never has to learn it again.

---

## 1. Mine the session

Reconstruct what actually happened before asking anything: the original ask,
the steps taken, every correction Rodda made, and every failure that cost a
cycle. Corrections are mandatory content; a failure hit once will be hit
again unless the skill names it. Separate the reusable workflow from
one-off session specifics — specifics become examples at most, not
requirements.

## 2. Ask before writing

Use AskUserQuestion for: the skill's name (offer a kebab-case default), the
description (or confirm a drafted one — it is the trigger surface and must
name the domain and the situations that should cause a load), and the scope
emphasis (gotchas and failure modes, conventions, repo-specific facts, or a
lean checklist over a narrative).

## 3. Write the SKILL.md

Match the existing dotfiles skills: frontmatter with `name` and a folded
`description`, one-paragraph framing, then numbered workflow steps with
gotchas inline. Concrete over abstract: real paths, real commands, real
failure signatures. Encode decisions as defaults with their reason, not as
open questions. Keep it an overview of the steps — no session-specific state
(run ids, temp paths) and no war stories.

## 4. Install and commit

Write the skill to `pi/.pi/agent/skills/<name>/SKILL.md` under
`~/workspace/dotfiles` — pi files only. Never hand-create claude copies: a
commit hook in the dotfiles repo mirrors every pi skill into
`claude/.claude/skills/` at commit time. Commit with a short imperative
message; do not push unless asked. Report the path and note the skill loads
on the next session via its description.
