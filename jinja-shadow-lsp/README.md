# jinja-shadow-lsp

A language server for Jinja templates built on the **shadow buffer** technique
(the architecture used by Vue's Volar and the Svelte/Astro tools): the Jinja
layer is host-agnostic, and for host-language intelligence the template is
compiled into a virtual host-language file (the "shadow") that is forwarded to
a downstream host language server, whose results are mapped back onto the
template.

## What it does

- **Jinja syntax diagnostics** (host-agnostic). On open/change the buffer is
  parsed with the real Jinja2 parser (with the common extensions: i18n, do,
  loopcontrols, debug) and any `TemplateSyntaxError` is published. Works for
  any `.j2` regardless of templated language.
- **Forwarded host diagnostics** (opt-in, **off by default**). The shadow is
  not valid-structured host source -- jinja becomes placeholder identifiers
  (`_eN`) and generation-time names are unknown -- so the downstream server's
  diagnostics are mostly false positives. They're suppressed unless you set
  `forwardDiagnostics: true`. Jinja syntax diagnostics are always shown.
- **Forwarded host requests** (when configured): `textDocument/definition`,
  `hover`, and `completion` are proxied to the downstream server. The request
  position is mapped template → shadow; the response (definition `Location`s,
  hover range, completion edit ranges) is mapped shadow → template. Requests
  on a position that isn't host code (e.g. on a jinja tag, or inside a
  `{{ }}` expression) return nothing.

It does **not** format anything.

## Configuration (caller-provided downstream servers)

Downstream servers are not hardcoded — the editor declares them via LSP
`initializationOptions`:

```json
{
  "servers": { "python": { "command": ["zuban", "server"] } },
  "extensions": { ".sql": "sql" },
  "requestTimeout": 6,
  "forwardDiagnostics": false
}
```

- `servers`: host language id → command to launch its language server.
  A bare list (`"python": ["pylsp"]`) is shorthand for `{"command": [...]}`.
- `extensions`: extends/overrides the inner-extension → language table
  (defaults cover `.py`/`.pyi` → `python`).
- `requestTimeout` (seconds, default 6): max time to wait on a forwarded
  request (definition/hover/completion). The editor's request to us blocks
  until we answer, so this bounds any UI freeze when the downstream is slow
  or cold-starting — on timeout we return nothing rather than hang.
- `forwardDiagnostics` (default false): surface the downstream server's
  diagnostics on the template. Off because the shadow produces mostly false
  positives (see above); turn on only for templates close to valid host code.

Host language is inferred from the extension beneath the jinja suffix:
`foo.py.j2` → `.py` → `python`.

## The shadow transform (Python host)

A jinja tag is treated as *structure* only when it is the sole tag on its line
and preceded by whitespace alone. Line-leading block openers become Python
suite headers so nesting is explicit; each meaningful template line gets a
marker comment giving a shadow-line → template-line correspondence.

| Template | Shadow (virtual Python) |
| --- | --- |
| `{{ expr }}` | `_eN` placeholder |
| `{# comment #}` | dropped |
| `{% for x in xs %}` | `for _vN in _iN:` |
| `{% if c %}` / `{% elif %}` / `{% else %}` | `if _cN:` / `elif _cN:` / `else:` |
| `{% macro f(..) %}` | `def _mN(*_a, **_k):` |
| `{% set x %}…{% endset %}`, block/with/filter/call/autoescape | `if True:  # <kind>` |
| `{% raw %}` / `{% trans %}` bodies | opaque (`pass`); tags not interpreted |
| `{% extends/include/import/from/do/debug/break/continue %}` | statement, no nesting |
| `{% endfor %}` etc. | no line; indentation is structural |

## Mapping fidelity

The transform records a **character-level** source map as it builds the
shadow (we control the shadow, so Jinja2's lack of column offsets doesn't
matter -- we know where every copied character lands):

- **Verbatim host code** maps character-for-character, preserving the real
  template column even though the shadow re-indents the line.
- **`{{ expr }}` placeholders** snap to the whole `{{...}}` span (the
  expression is replaced by one identifier, so sub-positions aren't meaningful).
- **Generated scaffolding** (indentation, suite headers, markers, `pass`)
  has no segment: a diagnostic there falls back to whole-line, and one on a
  line with no template origin at all is dropped.

## Known limitations (honest)

- **Jinja expressions are not the host language.** `{{ x|upper }}` is Jinja,
  not Python, so `{{ }}` contents are replaced with placeholders; the
  downstream server checks the *structure* of the generated code, not the
  Jinja expressions themselves.
- **No project context for the shadow.** The shadow is written to a temp file,
  so a downstream server won't resolve your project's imports — expect some
  false "undefined name" diagnostics until project-aware virtual files land.

## Develop

Uses [`uv`](https://docs.astral.sh/uv/).

```sh
uv sync --extra dev          # create .venv and install deps + pytest
uv run pytest                # run the test suite (incl. stub-downstream proxy test)
uv run jinja-shadow-lsp      # start the server on stdio (for an editor)
```

## Editor (Emacs / eglot)

`.j2` buffers use `jinja2-mode` and attach to this server. The downstream
Python server (zuban) is passed via `:initializationOptions` in
`eglot-server-programs` — see the `jinja` / `eglot` sections of the dotfiles
`init.org`.
