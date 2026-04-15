# `my-org-*` modules

Custom org layer for category-scoped capture/agenda with a first-class
"project" concept, persistent repo/branch → project mappings, auto-
switching of the current project based on the selected buffer's git
context, and a small interview note-taking mode.

Every file in here defines functions and variables only. All invocation
— requires, keybindings, hooks, refile config, modeline install, state
load, minor-mode enablement — is wired up from `../init.org` in the
`org-capture / org-agenda` section, so the whole shape of the system is
visible in one place.

## Files

### `my-org-core.el`
Shared data and path helpers used by everything else.

- `my/org-capture-categories` — the `(KEY NAME SUBDIR)` tuples that
  drive both capture and agenda (work/personal/talos/debate by default).
- Project path helpers: `my/org-projects-dir`,
  `my/org-project-index-file`, `my/org-project-root-file`,
  `my/org-project-whiteboard-file`.
- `my/org-project--read-index` — regex walker that parses
  `projects/index.org` into plists with `:slug :status :created
  :archived-at :repos`. Chosen over real org-mode parsing so the rest of
  the system can query project metadata without pulling in org at load
  time.
- `my/org-project-active-slugs` — sorted list of active project slugs.
- `my/org-toplevel-file-alist` — label → path alist for the
  category-based top-level org files.
- `my/org-category-files` — every file reachable from the capture setup,
  used as the refile target set.

### `my-org-projects.el`
Project CRUD, current-project state, and the repo/branch → project
mapping layer.

- Current project: `my/org-current-project`, persisted to
  `~/.emacs.d/my-org-current-project.el` via `my/org-current-project-load`
  and `my/org-current-project-save`.
- CRUD: `my/org-project-new` (seeds both `root.org` and
  `whiteboard.org`), `my/org-project-archive` (also stamps
  `:ARCHIVED_AT:`), `my/org-project-list`, `my/org-project-goto`
  (active only), `my/org-project-goto-all` (includes archived, with
  `[archived]` annotation in the completion list),
  `my/org-project-set-current`, `my/org-project-clear-current`,
  `my/org-goto-toplevel-file`. Both goto commands read `[r]oot` or
  `[w]hiteboard` after picking a slug, so `jXw`-style capture and
  direct navigation share one entry point.
- Clocking: `my/org-project-clock-in` (clocks in on the `* <slug>`
  heading in `projects/index.org`, defaulting to the current project
  and prompting if unset), `my/org-project-clock-out`,
  `my/org-project-clock-goto`, `my/org-project-clock-in-last`. All
  clock entries accumulate in a single LOGBOOK drawer per project
  inside index.org, so "time spent on project X" is always one place.
  The index regex walker tolerates LOGBOOK drawers alongside
  PROPERTIES.
- Letter-key allocation: `my/org-project--allocate-letter-keys` is
  shared by capture and agenda so both surfaces use the same single-
  letter shortcut for a given slug.
- Mapping helpers:
  - `my/org-project-git-context` — `(REPO . BRANCH)` for the current
    buffer, or nil.
  - `my/org-project-find-by-context` — look a `(repo, branch)` up in
    active projects. Branch-specific mappings outrank any-branch ones.
  - `my/org-project-add-mapping` / `remove-mapping` — read/write
    `:REPOS:` as an org multi-value property. `add-mapping` first
    removes any conflicting mapping from other projects so the lookup
    is unambiguous.
  - `my/org-project-mapping-add-here` / `mapping-remove-here` —
    interactive commands wired into the project transient.
- `my/org-project-set-current` also prompts `[y]es-this-branch
  [a]ny-branch [n]o` to persist a mapping when invoked inside a git
  repo.
- `my/org-project-transient` — the `M-j` transient.

### `my-org-interview.el`
Interview-style note taking. Defines the `:INTERVIEW_MODE:` subtree
property, the capture template body that embeds it, and the buffer-
local `my/org-interview-mode` that rebinds `C-<return>` inside such
subtrees.

- `my/org-interview-property` — `"INTERVIEW_MODE"`.
- `my/org-interview-capture-template-body` — consumed by
  `my-org-capture` for the `interview` kind.
- `my/org-interview-c-return` — mode-local `C-<return>` handler:
  inserts a timestamped list item (`- HH:MM `) inside an
  `INTERVIEW_MODE` subtree, falls back to
  `org-insert-heading-respect-content` elsewhere.
- `my/org-interview-maybe-enable` — hook function; turns the mode on
  whenever the current buffer contains any `INTERVIEW_MODE` property
  line. Wired to both `org-mode-hook` (on-disk files) and
  `org-capture-mode-hook` (freshly-captured interviews, since the
  template is inserted before `org-capture-mode` activates).

### `my-org-capture.el`
Capture template builders and the current-project capture entry point.

- `my/org-capture-category` — builds a capture group from a
  `(KEY NAME SUBDIR)` tuple plus an optional list of `kinds`
  (`thought`, `journal`, `deadline`, `meeting`, `interview`,
  `whiteboard`, `miscellaneous`).
- `my/org-capture-project-templates` — generates `j`-prefixed templates
  for every active project, both digit slots (`j1`…`j9`) and single-
  letter shortcuts where available. Each group carries todo/reference/
  pointer plus a whiteboard entry into `<project>/whiteboard.org`.
- `my/org-current-project-capture-templates` — generates the `.`-prefix
  templates for the current project, if any (includes `.w` for
  whiteboard).
- `my/org-rebuild-capture-templates` — rebuilds `org-capture-templates`
  from scratch. Wired as a `:before` advice on `org-capture` and also
  called from `org`'s post-load hook.
- `my/org-project-capture` — reads
  `[t]odo [r]eference [p]ointer [w]hiteboard` and delegates to
  `(org-capture nil ".<c>")`. If no current project is set, runs
  `my/org-project-set-current` first (which may persist a mapping).

### `my-org-agenda.el`
Agenda dispatcher scoped to the capture layout.

- Agenda files: the top-level inbox, each `<category>/inbox.org`, and
  every active project's `root.org`. Journals and notes are excluded to
  keep the view focused on actual tasks.
- Commands: `my/org-agenda-everything-week`,
  `my/org-agenda-everything-todo`, `my/org-agenda-dispatch`.
- Category sub-transient: one dynamic suffix per category entry, in
  either weekly or TODO mode.
- Project sub-transient: one dynamic suffix per active project, keyed
  by its letter shortcut (falling back to a digit).
- `my/org-agenda-transient` — the `C-c a` main transient.

### `my-org-autoswitch.el`
Global minor mode that keeps `my/org-current-project` in sync with the
selected window's git context, plus the modeline segment and the
minimal modeline format used system-wide.

- `my/org-project-autoswitch-mode` — installs handlers on
  `window-buffer-change-functions` and
  `window-selection-change-functions`. On each buffer change, computes
  `(repo, branch)`, looks it up via `my/org-project-find-by-context`,
  and sets/clears `my/org-current-project` accordingly. Unmapped
  buffers clear the current project. A cached `last-context` skips the
  work when nothing has changed.
- `my/org-current-project-mode-line-segment` — `[proj: <slug>]`
  segment, risky-local so `:eval` is allowed.
- `my/projectile-mode-line-segment` — `<projectile-name>` when
  `projectile-mode` is on and the current buffer is inside a project.
- `my/org-minimal-mode-line-format` — the full minimal format
  installed with
  `(setq-default mode-line-format my/org-minimal-mode-line-format)`:
  `buffer-id  L%l  (major-mode) <projectile> [proj: org]`.

## Keybindings

### Global

| Binding | Command                      | What it does |
|---------|------------------------------|--------------|
| `C-c c` | `org-capture`                | Standard org capture menu. |
| `C-c a` | `my/org-agenda-transient`    | Agenda dispatcher (everything / category / project). |
| `C-c v` | `my/org-project-capture`     | Capture into the current project; prompts for project and mapping if none is set. |
| `M-j`   | `my/org-project-transient`   | Project management transient. |

### `my/org-project-transient` (`M-j`)

| Column           | Key | Command                               |
|------------------|-----|---------------------------------------|
| Projects         | `g` | `my/org-project-goto` (active only, then `[r]oot`/`[w]hiteboard`) |
|                  | `G` | `my/org-project-goto-all` (incl. archived, same kind prompt) |
|                  | `n` | `my/org-project-new`                  |
|                  | `a` | `my/org-project-archive`              |
|                  | `l` | `my/org-project-list` (open index)    |
| Current project  | `s` | `my/org-project-set-current`          |
|                  | `c` | `my/org-project-clear-current`        |
| Clock            | `i` | `my/org-project-clock-in`             |
|                  | `o` | `my/org-project-clock-out`            |
|                  | `I` | `my/org-project-clock-in-last`        |
|                  | `j` | `my/org-project-clock-goto`           |
| Mappings         | `M` | `my/org-project-mapping-add-here`     |
|                  | `R` | `my/org-project-mapping-remove-here`  |
|                  | `T` | `my/org-project-autoswitch-mode` toggle |
| Goto file        | `f` | `my/org-goto-toplevel-file`           |

### `my/org-agenda-transient` (`C-c a`)

| Column     | Key | Command                               |
|------------|-----|---------------------------------------|
| Everything | `a` | `my/org-agenda-everything-week`       |
|            | `t` | `my/org-agenda-everything-todo`       |
| Filtered   | `c` | category weekly agenda sub-transient  |
|            | `C` | category TODO list sub-transient      |
|            | `p` | project TODO list sub-transient       |
| Raw        | `d` | `my/org-agenda-dispatch`              |

### `my/org-interview-mode` (buffer-local, auto-enabled)

| Binding     | Command                       |
|-------------|-------------------------------|
| `C-<return>`| `my/org-interview-c-return`   |

### Org capture template keys

Default categories `w`/`p`/`t`/`d` (Work/Personal/Talos/Debate), each
carrying the full set of kinds from `my/org-capture-category`:

| Suffix | Kind            | Target                              |
|--------|-----------------|-------------------------------------|
| `t`    | Thought         | `<cat>/journal.org`                 |
| `j`    | Journal         | `<cat>/journal.org` (daily datetree)|
| `d`    | Deadline        | `<cat>/inbox.org`                   |
| `m`    | Meeting notes   | `<cat>/notes.org` (weekly datetree) |
| `i`    | Interview notes | `<cat>/notes.org` (weekly datetree) |
| `w`    | Whiteboard      | `<cat>/whiteboard.org` (daily datetree, `HH:MM` headline, cursor in body) |
| `x`    | Miscellaneous   | `<cat>/inbox.org` under *Miscellaneous* |

Project-specific keys live under the `j` prefix:

| Key        | What it opens                                     |
|------------|---------------------------------------------------|
| `j1`…`j9`  | Digit slot for the N-th active project            |
| `j<letter>`| Letter shortcut for a project that got one        |
| `jXt`      | Todo under that project's *Tasks*                 |
| `jXr`      | Reference under that project's *Reference*        |
| `jXp`      | Pointer (captures `%a` link) under *Pointers*     |
| `jXw`      | Whiteboard entry in `<project>/whiteboard.org`    |

The current project is reachable under the `.` prefix:

| Key  | What it opens                                       |
|------|-----------------------------------------------------|
| `.t` | Todo in the current project                         |
| `.r` | Reference in the current project                    |
| `.p` | Pointer in the current project                      |
| `.w` | Whiteboard entry in the current project              |

Top-level catch-all:

| Key | What it opens                                       |
|-----|-----------------------------------------------------|
| `x` | Miscellaneous → `~/org/src/orgfiles/inbox.org` *To file* |

## Storage conventions

### `projects/index.org`
One level-1 heading per project. Properties used:

- `:STATUS:` — `active` or `archived`. Default `active`.
- `:CREATED:` — inactive date, set by `my/org-project-new`.
- `:ARCHIVED_AT:` — inactive timestamp, set by `my/org-project-archive`.
- `:REPOS:` — space-separated multi-value. Each value is `REPO` or
  `REPO@BRANCH`. Bare `REPO` matches any branch. Repo paths containing
  spaces are not supported.

`my/org-project-clock-in` also clocks on this heading, so each project
accumulates a `:LOGBOOK:` drawer of CLOCK entries here. The drawer sits
alongside `:PROPERTIES:` and the index regex walker tolerates it.

### `projects/<slug>/root.org`
Three fixed subtrees: `Tasks`, `Reference`, `Pointers`. Capture
templates under `j`/`.` target these by headline.

### `projects/<slug>/whiteboard.org`
Freeform scratch file, seeded with just a `#+title:` line. Capture
templates `jXw` and `.w` land in a daily datetree with an auto
`HH:MM` headline — the cursor starts in the body so you can just
begin typing. Created by `my/org-project-new`; for projects that
predate the feature, the file is created lazily the first time
something is captured into it.

### `<category>/whiteboard.org`
Analogous freeform scratch file at the category level, reached via the
`w` suffix under the category prefix (e.g. `ww` for Work whiteboard).
Same daily-datetree + auto-`HH:MM`-headline shape as the project
whiteboards. Created lazily by org-capture on first use.

### `my/org-interview-property`
Subtree property `:INTERVIEW_MODE: t`, written by the interview capture
template onto the *Raw notes* subheading. Used with org's inherited
property lookup so the mode works inside nested subheadings too.
