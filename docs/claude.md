# claude

Configuration for [Claude Code](https://claude.com/claude-code), **generated from
the pi config** so there is a single source of truth. Everything under
`claude/.claude/` is produced by `scripts/sync-claude-from-pi.sh` — never edit it
by hand; edit the pi source and re-run the sync.

## What gets converted

pi and Claude Code both read the [agentskills.io](https://agentskills.io/specification)
`SKILL.md` format and a plain-markdown instruction file, so the port is mostly a
copy:

| pi source (`pi/.pi/agent/`) | Claude Code (`claude/.claude/`) | Claude Code reads it at |
|-----------------------------|----------------------------------|--------------------------|
| `AGENTS.md`                 | `CLAUDE.md`                      | `~/.claude/CLAUDE.md` (global memory) |
| `skills/<name>/`            | `skills/<name>/`                 | `~/.claude/skills/<name>/` |

`settings.json`, `packages`, `extensions/`, `prompts/`, and `themes/` are
pi-specific and are **not** ported — Claude Code has no equivalent, or configures
it differently (`~/.claude/settings.json` is managed by Claude Code itself).

Claude Code requires each skill's frontmatter `name:` to match its directory
name, so keep the pi sources that way (the sync does no rewriting).

## Sync

```bash
scripts/sync-claude-from-pi.sh          # regenerate claude/.claude/ from pi/
scripts/sync-claude-from-pi.sh --check  # verify it's up to date (non-zero if stale)
```

A tracked git hook keeps them from drifting: `.githooks/pre-commit` runs the sync
whenever a commit touches `pi/.pi/agent/` and stages the regenerated output.
`install.sh` points git at it with `git config core.hooksPath .githooks`.

## How it's wired (stow)

Like the `pi` package, `install.sh` pre-creates a **real** `~/.claude` directory
before `stow claude`, so stow links only the tracked entries into it:

```
~/.claude/CLAUDE.md -> ~/dotfiles/claude/.claude/CLAUDE.md
~/.claude/skills    -> ~/dotfiles/claude/.claude/skills
```

Claude Code's own runtime data (`sessions/`, `cache/`, `history.jsonl`,
`settings.json`, `projects/`) stays as real files in `~/.claude/` and never lands
in the repo.

## Adding or changing a skill

Edit it under `pi/.pi/agent/skills/` (the pi source of truth), then run the sync —
or just commit, and the pre-commit hook does it for you. See [pi.md](pi.md) for the
skill format.
