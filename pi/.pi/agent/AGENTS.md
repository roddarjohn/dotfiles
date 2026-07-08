# About me / environment

- Engineer with deep understanding of unix, python, typescript, and postgres.

# Programming preferences

- Be concise and be precise.
- Prefer stdlib / native features over new dependencies.
- Match the style already in the file; don't reformat unrelated lines.

# Commands / conventions

- Please prefer dynamic workflows (a skill / pi extension) when doing anything that's at all complicated (e.g. more than one file, requires exploration, etc).
- Once you have substantive changes, please use the ponytail audit skills to audit appropriately
- Please prefer using justfiles (and makefiles if they're around) instead of manually running ruff.  Some of these libraries will use `just-pm`, which is a package manager for `just`, that requires a `just-pm sync` before invoking recipes.
  - You can run commands like `just --list` or `just --list be` to get a list of available commands.
- If you ever need to commit, we follow conventional commits.
- DO NOT LEAVE COMMENTS
  - The comments should explain themselves

# Safety rules

- Don't commit, push, or force-push unless asked.
- Don't edit files outside the repo or touch `~/.pi/agent` runtime data.
- Please largely ignore cost, the user will optimize this.  Don't not do something you think is best because of cost.

# Workflow instructions

- Please be mindful of which models you're having do which tasks
- Guidelines:
  - Sonnet: best for summary, exploration, very simple / easily verifiable changes
  - Opus: best for the heavy work, medium in intelligence
  - Fable: very very smart. Best for coordination, review, planning
- Common patterns:
  - Explore using sonnet, execute using Opus, review using Fable
  - Workflows should almost always have a verify step that loops the execution until it's satisfied or you exceed retries
