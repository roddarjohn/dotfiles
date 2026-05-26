"""Compile a Jinja template into a virtual host-language ('shadow') file.

The shadow is *line-correspondent*: every template line that carries
meaning produces one virtual line tagged with a marker comment that
encodes the originating template line. We can therefore format the
shadow with a real host formatter, then read each marker line's
indentation back and apply it to the matching template line.

Why line-level and not character-level? Jinja2's parser exposes line
numbers but not column offsets, so a precise character source-map isn't
available from the library. Line-level correspondence is exactly what
indentation transfer needs, and it is robust.

This module is host-pluggable but v1 only implements Python. The Python
emission rules:

* ``{{ expr }}``           -> a placeholder identifier ``_eN``
* ``{# comment #}``        -> dropped
* line-leading ``{% for x in xs %}``    -> ``for _vN in _iN:``  (suite opener)
* line-leading ``{% if c %}``           -> ``if _cN:``
* ``{% elif %}`` / ``{% else %}``       -> ``elif _cN:`` / ``else:``
* ``{% macro f(..) %}``                 -> ``def _mN(*_a, **_k):``
* other block openers (block/with/...)  -> ``if True:``  (a generic suite)
* ``{% endfor %}`` etc.                 -> no virtual line; indentation is
  taken structurally (aligns with its opener)

A jinja tag only counts as *structure* when it is the sole tag on the
line and is preceded by whitespace alone -- matching the rule that
"a tag preceded by no other character is at the top level". Inline or
multiple tags are treated as opaque host content.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# --- token patterns ---------------------------------------------------------

# Any inline jinja token: an expression {{ }}, a comment {# #}, or a
# statement {% %}. Used to split a host line into verbatim runs and tokens.
_TOKEN_RE = re.compile(r"\{\{.*?\}\}|\{#.*?#\}|\{%.*?%\}")
# First block tag on a line: optional whitespace-control marker, then keyword.
_TAG_KW_RE = re.compile(r"\{%[-+]?\s*(\w+)")
_LINE_STRUCT_RE = re.compile(r"^(\s*)\{%[-+]?\s*(\w+)\b(.*?)[-+]?%\}\s*$")
_LEADING_WS_RE = re.compile(r"^[ \t]*")

# A block opener keyword -> a template producing a Python suite header.
# ``{n}`` is filled with a fresh integer to keep identifiers unique.
_OPENERS: dict[str, str] = {
    "for": "for _v{n} in _i{n}:",
    "if": "if _c{n}:",
    "macro": "def _m{n}(*_a, **_k):",
    "block": "if True:  # block",
    "filter": "if True:  # filter",
    "call": "if True:  # call",
    "with": "if True:  # with",
    "autoescape": "if True:  # autoescape",
    "set": "if True:  # set-block",  # only the block form (no '=')
    "trans": "if True:  # trans",  # i18n extension
    "raw": "if True:  # raw",  # body is opaque literal text
}
_MIDS: dict[str, str] = {
    "elif": "elif _c{n}:",
    "else": "else:",
    "pluralize": "else:",  # inside a {% trans %} block
}
_CLOSERS = {
    "endfor", "endif", "endmacro", "endblock", "endfilter",
    "endcall", "endwith", "endautoescape", "endset",
    "endtrans", "endraw",
}

# Single-line statement tags that never change nesting. They are treated as
# opaque host content (the tag is stripped from the shadow). Listed for
# documentation; classification falls through to the host branch for any
# keyword not in the opener/mid/closer tables.
_STATEMENTS = frozenset(
    {"extends", "include", "import", "from", "do", "debug", "break", "continue"}
)

MARKER_PREFIX = "__JSL_SRC_"
_MARKER_RE = re.compile(re.escape(MARKER_PREFIX) + r"(\d+)__")


def marker(src_line: int) -> str:
    return f"# {MARKER_PREFIX}{src_line}__"


def marker_of(text: str) -> int | None:
    m = _MARKER_RE.search(text)
    return int(m.group(1)) if m else None


def leading_ws(text: str) -> str:
    return _LEADING_WS_RE.match(text).group(0)


@dataclass
class LineInfo:
    """Per template-line classification produced by :func:`transform`."""

    kind: str  # 'host' | 'open' | 'mid' | 'close' | 'blank'
    depth: int  # structural nesting depth to use for this line


@dataclass
class Segment:
    """A character-range correspondence between shadow and template.

    Verbatim host text maps exactly (``exact=True``): a shadow column maps to
    ``template_start + (col - shadow_start)``. A ``{{ expr }}`` placeholder
    maps atomically (``exact=False``): the whole ``{{...}}`` template span.
    Generated scaffolding (indentation, suite headers, markers, ``pass``) has
    no segment -- positions there fall back to whole-line mapping or drop.
    """

    shadow_line: int
    shadow_start: int
    shadow_end: int
    template_line: int
    template_start: int
    template_end: int
    exact: bool


@dataclass
class TransformResult:
    virtual_src: str
    line_info: list[LineInfo]
    # Character-level shadow<->template correspondences (verbatim + placeholder).
    source_map: list[Segment] = field(default_factory=list)
    # Block openers that we could not pair with a closer (unbalanced input).
    unbalanced: bool = False


@dataclass
class _Block:
    body_emitted: bool = False


def _is_block_set(tag_body: str) -> bool:
    """A ``{% set x %}`` (no '=') opens a block; ``{% set x = 1 %}`` does not."""
    return "=" not in tag_body


def transform(source: str, indent_width: int = 4) -> TransformResult:
    lines = source.split("\n")
    vlines: list[str] = []
    info: list[LineInfo] = []
    segments: list[Segment] = []
    stack: list[_Block] = []
    depth = 0
    expr_counter = 0
    block_counter = 0
    unbalanced = False
    in_raw = False  # inside a {% raw %} ... {% endraw %} block
    in_trans = False  # inside a {% trans %} ... {% endtrans %} block

    def indent(d: int) -> str:
        return " " * (indent_width * d)

    def mark_parent_body() -> None:
        if stack:
            stack[-1].body_emitted = True

    def emit_host(text: str, d: int, src_line: int) -> None:
        # Scan the ORIGINAL template line so we can record character-level
        # segments. Leading whitespace is replaced by the structural indent;
        # ``{{ }}`` -> a placeholder; ``{# #}`` / inline ``{% %}`` are dropped.
        nonlocal expr_counter
        shadow_line = len(vlines)
        indent_str = indent(d)
        lstripped = text.lstrip(" \t")
        lead = len(text) - len(lstripped)
        pieces: list[str] = []
        line_segments: list[Segment] = []
        col = len(indent_str)
        pos = 0

        def add_verbatim(start: int, end: int) -> None:
            nonlocal col
            chunk = lstripped[start:end]
            if not chunk:
                return
            line_segments.append(
                Segment(shadow_line, col, col + len(chunk),
                        src_line, lead + start, lead + end, True)
            )
            pieces.append(chunk)
            col += len(chunk)

        for m in _TOKEN_RE.finditer(lstripped):
            add_verbatim(pos, m.start())
            if m.group(0).startswith("{{"):
                ident = f"_e{expr_counter}"
                expr_counter += 1
                line_segments.append(
                    Segment(shadow_line, col, col + len(ident),
                            src_line, lead + m.start(), lead + m.end(), False)
                )
                pieces.append(ident)
                col += len(ident)
            # {# #} comments and inline {% %} statements are dropped.
            pos = m.end()
        add_verbatim(pos, len(lstripped))

        content = "".join(pieces)
        if content.strip() == "":
            # Comment-/statement-only line that collapsed away; emit a neutral
            # statement so the shadow stays valid Python (no segments).
            vlines.append(f"{indent_str}pass  {marker(src_line)}")
        else:
            vlines.append(f"{indent_str}{content}  {marker(src_line)}")
            segments.extend(line_segments)
        mark_parent_body()

    def emit_opaque(src_line: int) -> None:
        # A body line of an opaque text block (raw/trans): emit a neutral
        # statement so the shadow stays valid Python and the marker records
        # an indentation, without interpreting the literal text.
        vlines.append(f"{indent(depth)}pass  {marker(src_line)}")
        mark_parent_body()
        info.append(LineInfo("host", depth))

    def do_open(kw: str, src_line: int) -> None:
        nonlocal depth, block_counter
        header = _OPENERS[kw].format(n=block_counter)
        block_counter += 1
        vlines.append(f"{indent(depth)}{header}  {marker(src_line)}")
        mark_parent_body()  # the opener is a statement inside its parent
        stack.append(_Block())
        info.append(LineInfo("open", depth))
        depth += 1

    def do_mid(kw: str, src_line: int) -> None:
        nonlocal block_counter
        # emit a 'pass' if the preceding branch had no body, then place the
        # mid keyword at the opener's depth (depth - 1).
        if stack and not stack[-1].body_emitted:
            vlines.append(f"{indent(depth)}pass")
        opener_depth = max(depth - 1, 0)
        header = _MIDS[kw].format(n=block_counter)
        block_counter += 1
        vlines.append(f"{indent(opener_depth)}{header}  {marker(src_line)}")
        if stack:
            stack[-1].body_emitted = False
        info.append(LineInfo("mid", opener_depth))

    def do_close() -> None:
        nonlocal depth, unbalanced
        if stack and not stack[-1].body_emitted:
            vlines.append(f"{indent(depth)}pass")
        if stack:
            stack.pop()
            depth = max(depth - 1, 0)
        else:
            unbalanced = True
        info.append(LineInfo("close", depth))

    for i, line in enumerate(lines):
        single = _LINE_STRUCT_RE.match(line) if line.count("{%") == 1 else None
        skw = single.group(2) if single else None

        # Inside {% raw %}: literal text, tags are NOT interpreted. Only a
        # line-leading {% endraw %} ends it.
        if in_raw:
            if skw == "endraw":
                do_close()
                in_raw = False
            else:
                emit_opaque(i)
            continue

        # Inside {% trans %}: literal text too, but {% pluralize %} and
        # {% endtrans %} are still interpreted.
        if in_trans:
            if skw == "pluralize":
                do_mid("pluralize", i)
            elif skw == "endtrans":
                do_close()
                in_trans = False
            else:
                emit_opaque(i)
            continue

        if line.strip() == "":
            info.append(LineInfo("blank", depth))
            continue

        # Classify a line-leading single tag as structure.
        is_structural = False
        if single:
            if skw in _OPENERS and not (
                skw == "set" and not _is_block_set(single.group(3))
            ):
                is_structural = "open"
            elif skw in _MIDS:
                is_structural = "mid"
            elif skw in _CLOSERS:
                is_structural = "close"

        if not is_structural:
            # Plain host content (possibly with {{ }} / {# #} / inline {% %}).
            emit_host(line, depth, i)
            info.append(LineInfo("host", depth))
        elif is_structural == "open":
            do_open(skw, i)
            if skw == "raw":
                in_raw = True
            elif skw == "trans":
                in_trans = True
        elif is_structural == "mid":
            do_mid(skw, i)
        else:
            do_close()

    if stack:
        unbalanced = True

    return TransformResult(
        "\n".join(vlines) + "\n", info, source_map=segments, unbalanced=unbalanced
    )
