# pi

Configuration and resources for the [pi coding agent](https://pi.dev), managed
the same way as everything else in this repo: a [GNU Stow](https://www.gnu.org/software/stow/)
package whose contents are symlinked into `$HOME`.

## How it's wired

pi auto-discovers global resources from `~/.pi/agent/`:

| pi looks in                  | This repo provides              |
|------------------------------|---------------------------------|
| `~/.pi/agent/settings.json`  | `pi/.pi/agent/settings.json`    |
| `~/.pi/agent/skills/`        | `pi/.pi/agent/skills/`          |
| `~/.pi/agent/extensions/`    | `pi/.pi/agent/extensions/`      |
| `~/.pi/agent/prompts/`       | `pi/.pi/agent/prompts/`         |
| `~/.pi/agent/themes/`        | `pi/.pi/agent/themes/`          |

`install.sh` pre-creates `~/.pi/agent` as a **real** directory, then runs
`stow pi`. Because the directory already exists, stow folds each resource
subdirectory and `settings.json` into individual symlinks pointing back into
this repo:

```
~/.pi/agent/skills      -> ~/dotfiles/pi/.pi/agent/skills
~/.pi/agent/extensions  -> ~/dotfiles/pi/.pi/agent/extensions
~/.pi/agent/prompts     -> ~/dotfiles/pi/.pi/agent/prompts
~/.pi/agent/themes      -> ~/dotfiles/pi/.pi/agent/themes
~/.pi/agent/settings.json -> ~/dotfiles/pi/.pi/agent/settings.json
```

pi's own runtime data (`trust.json`, `auth.json`, `npm/`, sessions, history)
stays as real files inside `~/.pi/agent/` and never lands in the repo. This is
the same trick `install.sh` uses for `~/.emacs.d`.

`settings.json` is edited in place through the symlink, so changing settings
from inside pi (e.g. `/settings`) updates the tracked file in this repo. If pi
had already written its own `settings.json`, `install.sh` moves it aside to
`settings.json.pre-stow.bak` (ignored by git) before linking.

## Always-installed packages

The `packages` array in `settings.json` lists pi packages that should be present
on every machine. pi auto-installs any that are missing on startup (needs
network; skipped with `--offline`). The installed copies land in the **real**
`~/.pi/agent/npm/` and `~/.pi/agent/git/` directories, not in this repo.

Currently bundled:

| Package | Source | What it is |
|---------|--------|------------|
| [ponytail](https://github.com/DietrichGebert/ponytail) | `git:github.com/DietrichGebert/ponytail@v4.7.0` | "Lazy senior dev" ruleset — nudges the agent to write less code. Pinned to a release tag (the npm `ponytail` is an unrelated package). |
| [pi-subagents](https://github.com/nicobailon/pi-subagents) | `npm:pi-subagents` | Delegate tasks to subagents (chains, parallel execution). |
| [rpiv-ask-user-question](https://github.com/juicesharp/rpiv-mono) | `npm:@juicesharp/rpiv-ask-user-question` | Structured questionnaire the model can put to you. |
| [rpiv-todo](https://github.com/juicesharp/rpiv-mono) | `npm:@juicesharp/rpiv-todo` | Live todo-list overlay for the model. |

Manage them declaratively here (edit the array) or with `pi install <source>` /
`pi remove <source>`, which write back through the symlink. Refresh with
`pi update --all`. npm entries are unversioned (track latest); the git entry is
pinned to a tag for stability — bump it with
`pi install git:github.com/DietrichGebert/ponytail@<newtag>`.

> **Security:** packages run with full system access (extensions execute code,
> skills can drive the model). Only list ones you trust.

## Installing a skill

A [skill](https://agentskills.io/specification) is a directory containing a
`SKILL.md`. Drop it under `skills/` and it's live immediately (the directory is
symlinked, so no re-stow needed):

```bash
mkdir -p ~/dotfiles/pi/.pi/agent/skills/my-skill
$EDITOR ~/dotfiles/pi/.pi/agent/skills/my-skill/SKILL.md
```

```markdown
---
name: my-skill
description: What this skill does and when to use it. Be specific — pi loads it on demand based on this text.
---

# My Skill

Instructions, helper scripts, references...
```

Then commit it. pi picks it up on the next start (or `/reload`).

To reuse skills from other agent harnesses (e.g. Claude Code), add their
directories to `settings.json`:

```json
{
  "skills": ["~/.claude/skills", "~/.codex/skills"]
}
```

## Installing an extension

An [extension](https://pi.dev) is a TypeScript module. Single-file extensions
go directly in `extensions/`; multi-file ones use a subdirectory with an
`index.ts`:

```
pi/.pi/agent/extensions/
├── my-extension.ts          # single file
└── my-extension/            # or a directory
    └── index.ts
```

```typescript
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.notify("Extension loaded!", "info");
  });
}
```

If an extension needs npm dependencies, add a `package.json` next to it and run
`npm install` there; the resulting `node_modules/` is git-ignored.

> **Security:** skills can instruct the model to run arbitrary code, and
> extensions run with your full permissions. Only add ones you trust.

## Prompts and themes

- `prompts/` — prompt templates (`.md`). See pi's `prompt-templates` docs.
- `themes/` — custom themes (`.json`). Reference one by name via `"theme"` in
  `settings.json`.

## tmux

pi needs tmux to forward modified keys (so `Shift+Enter` / `Ctrl+Enter` aren't
collapsed to a plain `Enter`). `tmux/.config/tmux/tmux.conf` sets:

```tmux
set -g extended-keys on
set -g extended-keys-format csi-u
```

`extended-keys-format csi-u` requires tmux 3.5+. On older tmux that line is
ignored (with a startup warning); `extended-keys on` alone still works via the
xterm `modifyOtherKeys` format, which pi also understands. After changing the
config, fully restart tmux: `tmux kill-server`.
