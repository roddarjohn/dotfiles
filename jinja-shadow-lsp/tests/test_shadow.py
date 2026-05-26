from lsprotocol import types

from jinja_shadow_lsp.shadow import generate, remap_diagnostic, supported_languages


def test_supported_languages():
    assert "python" in supported_languages()


def test_generate_unknown_language_is_none():
    assert generate("klingon", "{{ x }}") is None


def test_generate_builds_shadow_and_line_map():
    src = "{% for x in xs %}\nbody\n{% endfor %}"
    shadow = generate("python", src)
    assert shadow is not None
    # shadow must be valid Python
    compile(shadow.text, "<shadow>", "exec")
    # the 'for' opener (shadow line 0) maps to template line 0;
    # the body (shadow line 1) maps to template line 1.
    assert shadow.shadow_to_template[0] == 0
    assert shadow.shadow_to_template[1] == 1


def _diag_at(shadow_line: int) -> types.Diagnostic:
    return types.Diagnostic(
        range=types.Range(
            start=types.Position(line=shadow_line, character=4),
            end=types.Position(line=shadow_line, character=8),
        ),
        message="undefined name",
        severity=types.DiagnosticSeverity.Error,
        source="zuban",
    )


def _shadow_line_for_template(shadow, template_line):
    return next(s for s, t in shadow.shadow_to_template.items() if t == template_line)


def test_remap_diagnostic_exact_character_span():
    # Body has no leading whitespace; in the shadow it is indented by 4.
    src = "{% for x in xs %}\nsome_call(arg)\n{% endfor %}"
    template_lines = src.split("\n")
    shadow = generate("python", src)
    body = _shadow_line_for_template(shadow, 1)
    # Shadow cols 4..8 cover "some"; template has no indent, so cols 0..4.
    out = remap_diagnostic(_diag_at(body), shadow, template_lines)
    assert out is not None
    assert out.range.start.line == 1
    assert (out.range.start.character, out.range.end.character) == (0, 4)
    assert "undefined name" in out.message
    assert "shadow" in out.source


def test_remap_diagnostic_indented_template_offset():
    # Template body is itself indented; mapping must preserve the real column.
    src = "{% for x in xs %}\n    foo_bar(baz)\n{% endfor %}"
    template_lines = src.split("\n")
    shadow = generate("python", src)
    body = _shadow_line_for_template(shadow, 1)
    # "foo_bar" sits at template col 4; in the shadow at col 4 (depth-1 indent).
    diag = types.Diagnostic(
        range=types.Range(
            start=types.Position(line=body, character=4),
            end=types.Position(line=body, character=11),
        ),
        message="bad",
        severity=types.DiagnosticSeverity.Error,
        source="z",
    )
    out = remap_diagnostic(diag, shadow, template_lines)
    assert (out.range.start.character, out.range.end.character) == (4, 11)
    assert template_lines[1][4:11] == "foo_bar"


def test_remap_diagnostic_placeholder_maps_to_whole_expression():
    src = "x = {{ value }}"
    template_lines = [src]
    shadow = generate("python", src)
    # placeholder _e0 replaces {{ value }}; find its shadow column.
    line0 = shadow.text.split("\n")[0]
    pcol = line0.index("_e0")
    diag = types.Diagnostic(
        range=types.Range(
            start=types.Position(line=0, character=pcol),
            end=types.Position(line=0, character=pcol + len("_e0")),
        ),
        message="type error",
        severity=types.DiagnosticSeverity.Error,
        source="z",
    )
    out = remap_diagnostic(diag, shadow, template_lines)
    # Snaps to the whole {{ value }} span (cols 4..15).
    assert (out.range.start.character, out.range.end.character) == (
        src.index("{{"),
        src.index("}}") + 2,
    )


def test_remap_diagnostic_on_scaffolding_is_dropped():
    # Find a shadow line with no template marker (generated 'pass'/scaffold)
    # by using an empty-bodied block which injects a bare 'pass'.
    src = "{% if a %}\n{% endif %}"
    shadow = generate("python", src)
    template_lines = src.split("\n")
    scaffold_lines = [
        i
        for i in range(len(shadow.text.split("\n")))
        if i not in shadow.shadow_to_template
    ]
    assert scaffold_lines, "expected at least one generated scaffold line"
    out = remap_diagnostic(_diag_at(scaffold_lines[0]), shadow, template_lines)
    assert out is None
