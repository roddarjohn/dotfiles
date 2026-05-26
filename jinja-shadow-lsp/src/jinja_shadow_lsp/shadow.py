"""Generate a host-language shadow from a template and map positions back.

A shadow is the virtual host source produced by a per-language generator
(currently only Python, via :mod:`transform`). Each meaningful template line
yields one shadow line tagged with a marker comment, giving a shadow-line ->
template-line correspondence. Downstream (host) diagnostics arrive in shadow
coordinates; :func:`remap_diagnostic` maps them back to the template and
drops any that land on generated scaffolding (a shadow line with no marker).
"""

from __future__ import annotations

from dataclasses import dataclass

from lsprotocol import types

from .transform import Segment, marker_of, transform


# language id -> generator(source) -> TransformResult-like (text + maps)
_GENERATORS = {"python": transform}


def supported_languages() -> set[str]:
    return set(_GENERATORS)


@dataclass
class Shadow:
    text: str
    # shadow line index (0-based) -> template line index (0-based)
    shadow_to_template: dict[int, int]
    # character-level shadow<->template correspondences
    segments: list[Segment]


def generate(language: str, source: str) -> Shadow | None:
    """Build the shadow for ``language``, or None if there's no generator."""
    gen = _GENERATORS.get(language)
    if gen is None:
        return None
    result = gen(source)
    mapping: dict[int, int] = {}
    for i, line in enumerate(result.virtual_src.split("\n")):
        t = marker_of(line)
        if t is not None:
            mapping[i] = t
    return Shadow(result.virtual_src, mapping, result.source_map)


def _map_position(
    shadow: Shadow, line: int, col: int, *, is_end: bool, template_lines: list[str]
) -> tuple[int, int] | None:
    """Map a shadow (line, col) to a template (line, col).

    Prefers an exact character-level segment; falls back to the start/end of
    the originating template line when the position sits on generated text but
    the shadow line still has a template marker; returns None for pure
    scaffolding (no segment and no marker).
    """
    for seg in shadow.segments:
        if seg.shadow_line != line:
            continue
        within = (
            seg.shadow_start < col <= seg.shadow_end
            if is_end
            else seg.shadow_start <= col < seg.shadow_end
        )
        if not within:
            continue
        if seg.exact:
            return seg.template_line, seg.template_start + (col - seg.shadow_start)
        # placeholder: atomic -> snap to the {{...}} span boundary
        return seg.template_line, (seg.template_end if is_end else seg.template_start)

    tline = shadow.shadow_to_template.get(line)
    if tline is None or tline >= len(template_lines):
        return None
    return tline, (len(template_lines[tline]) if is_end else 0)


def shadow_position(
    shadow: Shadow, template_line: int, template_col: int
) -> types.Position | None:
    """Map a template (line, col) into the shadow, or None if not in host code.

    Used to forward a request (definition/hover/completion) the editor made at
    a template position to the downstream server's shadow coordinates. Only
    positions inside verbatim host text (or a ``{{ }}`` placeholder) map.
    """
    for seg in shadow.segments:
        if seg.template_line != template_line:
            continue
        if seg.template_start <= template_col < seg.template_end:
            if seg.exact:
                col = seg.shadow_start + (template_col - seg.template_start)
            else:
                col = seg.shadow_start  # placeholder: snap to its start
            return types.Position(line=seg.shadow_line, character=col)
    return None


def template_range_of(
    shadow: Shadow, rng: types.Range, template_lines: list[str]
) -> types.Range | None:
    """Map a shadow range (from a downstream response) back to the template."""
    start = _map_position(
        shadow, rng.start.line, rng.start.character, is_end=False,
        template_lines=template_lines,
    )
    if start is None:
        return None
    end = _map_position(
        shadow, rng.end.line, rng.end.character, is_end=True,
        template_lines=template_lines,
    )
    if end is None or end < start:
        end = (start[0], len(template_lines[start[0]]))
    return types.Range(
        start=types.Position(line=start[0], character=start[1]),
        end=types.Position(line=end[0], character=end[1]),
    )


def remap_diagnostic(
    diag: types.Diagnostic, shadow: Shadow, template_lines: list[str]
) -> types.Diagnostic | None:
    """Map a downstream diagnostic (shadow coords) onto the template.

    Uses character-level segments for an exact span; falls back to whole-line
    when a position lands on generated text; returns None when the diagnostic
    lands on pure scaffolding (no template origin at all) -- those are
    artifacts of the shadow, not real template problems.
    """
    start = _map_position(
        shadow,
        diag.range.start.line,
        diag.range.start.character,
        is_end=False,
        template_lines=template_lines,
    )
    if start is None:
        return None
    end = _map_position(
        shadow,
        diag.range.end.line,
        diag.range.end.character,
        is_end=True,
        template_lines=template_lines,
    )
    if end is None or end < start:
        end = (start[0], len(template_lines[start[0]]))

    return types.Diagnostic(
        range=types.Range(
            start=types.Position(line=start[0], character=start[1]),
            end=types.Position(line=end[0], character=end[1]),
        ),
        message=diag.message,
        severity=diag.severity,
        code=diag.code,
        source=f"{diag.source or 'host'} (shadow)",
    )
