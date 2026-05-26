from jinja_shadow_lsp.transform import marker_of, transform


def test_for_loop_structure():
    src = "{% for x in xs %}\nbody\n{% endfor %}\n"
    r = transform(src)
    kinds = [li.kind for li in r.line_info]
    depths = [li.depth for li in r.line_info]
    assert kinds == ["open", "host", "close", "blank"]
    assert depths == [0, 1, 0, 0]
    assert not r.unbalanced
    # The opener became a Python suite header carrying its source marker.
    assert "for _v0 in _i0:" in r.virtual_src
    assert marker_of(r.virtual_src.splitlines()[0]) == 0


def test_if_elif_else():
    src = "{% if a %}\np\n{% elif b %}\nq\n{% else %}\nr\n{% endif %}\n"
    r = transform(src)
    kinds = [li.kind for li in r.line_info]
    depths = [li.depth for li in r.line_info]
    assert kinds == [
        "open", "host", "mid", "host", "mid", "host", "close", "blank"
    ]
    # if / elif / else all sit at depth 0; their bodies at depth 1.
    assert depths == [0, 1, 0, 1, 0, 1, 0, 0]
    assert "if _c0:" in r.virtual_src
    assert "elif _c" in r.virtual_src
    assert "else:" in r.virtual_src


def test_nesting():
    src = "{% for a in xs %}\n{% if a %}\nuse(a)\n{% endif %}\n{% endfor %}\n"
    r = transform(src)
    assert [li.depth for li in r.line_info] == [0, 1, 2, 1, 0, 0]


def test_inline_set_is_not_structure():
    # {% set x = 1 %} is a statement, not a block: depth must not change.
    src = "{% set x = 1 %}\nfoo\n"
    r = transform(src)
    assert [li.kind for li in r.line_info] == ["host", "host", "blank"]
    assert [li.depth for li in r.line_info] == [0, 0, 0]


def test_block_set_is_structure():
    src = "{% set x %}\nbody\n{% endset %}\n"
    r = transform(src)
    assert [li.kind for li in r.line_info] == ["open", "host", "close", "blank"]
    assert [li.depth for li in r.line_info] == [0, 1, 0, 0]


def test_tag_not_line_leading_is_opaque():
    # Preceded by other characters -> opaque host, no structural nesting.
    src = "x = {% if y %}\n"
    r = transform(src)
    assert r.line_info[0].kind == "host"
    assert r.line_info[0].depth == 0


def test_expression_placeholders_are_valid_identifiers():
    src = "call({{ a }}, {{ b }})\n"
    r = transform(src)
    line = r.virtual_src.splitlines()[0]
    assert "_e0" in line and "_e1" in line
    assert "{{" not in line


def test_empty_suite_gets_pass():
    src = "{% if a %}\n{% endif %}\n"
    r = transform(src)
    assert "pass" in r.virtual_src


def test_unbalanced_flag():
    src = "{% for a in xs %}\nbody\n"  # missing endfor
    r = transform(src)
    assert r.unbalanced
