"""Exhaustive coverage of Jinja2 control structures.

One plain test function per structure. Each asserts the three properties we
care about, inline:

* ``transform`` classifies every line's (kind, depth) correctly,
* the generated shadow is valid Python (``compile`` raises otherwise),
* a valid template produces no false diagnostics through the real server
  path (``_jinja_diagnostics``, which loads the common Jinja extensions).

Reference for the tag vocabulary: the Jinja template-designer docs
(for / if / set / macro / call / filter / block / extends / include /
import / with / autoescape / raw / trans, plus the do, loopcontrols, i18n
and debug extensions).
"""

from jinja_shadow_lsp.server import _jinja_diagnostics
from jinja_shadow_lsp.transform import transform


# --- for ------------------------------------------------------------------

def test_for():
    src = "{% for x in xs %}\nbody\n{% endfor %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_for_else():
    src = "{% for x in xs %}\na\n{% else %}\nb\n{% endfor %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("mid", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- if / elif / else ------------------------------------------------------

def test_if_elif_else():
    src = "{% if a %}\np\n{% elif b %}\nq\n{% else %}\nr\n{% endif %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("mid", 0), ("host", 1),
        ("mid", 0), ("host", 1), ("close", 0),
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- set -------------------------------------------------------------------

def test_set_inline_is_not_structure():
    src = "{% set x = 1 %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_set_block():
    src = "{% set nav %}\ncontent\n{% endset %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_set_block_with_filter():
    src = "{% set out | upper %}\nhi\n{% endset %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- macro / call ----------------------------------------------------------

def test_macro():
    src = "{% macro input(name) %}\nrender\n{% endmacro %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_call():
    src = "{% call render() %}\nbody\n{% endcall %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_call_with_args():
    src = "{% call(user) render() %}\nx\n{% endcall %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- filter ----------------------------------------------------------------

def test_filter():
    src = "{% filter upper %}\ntext\n{% endfilter %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- block -----------------------------------------------------------------

def test_block_with_named_close():
    src = "{% block content %}\nbody\n{% endblock content %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_block_scoped():
    src = "{% block content scoped %}\nb\n{% endblock %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- with ------------------------------------------------------------------

def test_with():
    src = "{% with %}\nb\n{% endwith %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_with_assignment():
    src = "{% with foo = 1 %}\nb\n{% endwith %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- autoescape ------------------------------------------------------------

def test_autoescape():
    src = "{% autoescape true %}\nb\n{% endautoescape %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- raw (opaque body) -----------------------------------------------------

def test_raw_body_is_opaque():
    # Tags inside raw are literal and must NOT be interpreted as structure.
    src = "{% raw %}\n{{ not_a_var }}\n{% if x %}literal{% endif %}\n{% endraw %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- trans / pluralize (i18n, opaque text body) ----------------------------

def test_trans_pluralize():
    src = (
        "{% trans count=count %}\n"
        "{{ count }} apple\n"
        "{% pluralize %}\n"
        "{{ count }} apples\n"
        "{% endtrans %}"
    )
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("mid", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- statement tags that never change nesting ------------------------------

def test_extends():
    src = "{% extends 'base.html' %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_include():
    src = "{% include 'x.html' %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_import_as():
    src = "{% import 'macros.html' as m %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_from_import():
    src = "{% from 'macros.html' import input %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_do_extension():
    src = "{% do items.append(1) %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_debug_extension():
    src = "{% debug %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- loop controls (must live inside a loop to be valid Jinja) -------------

def test_break_in_loop():
    src = "{% for x in xs %}\n{% if x %}\n{% break %}\n{% endif %}\n{% endfor %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("open", 1), ("host", 2), ("close", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_continue_in_loop():
    src = "{% for x in xs %}\n{% continue %}\n{% endfor %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- nesting ---------------------------------------------------------------

def test_nested_for_if():
    src = "{% for a in xs %}\n{% if a %}\nuse\n{% endif %}\n{% endfor %}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("open", 1), ("host", 2), ("close", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_deeply_nested():
    src = (
        "{% for a in xs %}\n"
        "{% if a %}\n"
        "{% for b in a %}\n"
        "x\n"
        "{% endfor %}\n"
        "{% endif %}\n"
        "{% endfor %}"
    )
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("open", 1), ("open", 2), ("host", 3),
        ("close", 2), ("close", 1), ("close", 0),
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- whitespace control & comments -----------------------------------------

def test_whitespace_control_tags():
    src = "{%- if a -%}\nx\n{%- endif -%}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [
        ("open", 0), ("host", 1), ("close", 0)
    ]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_expression_whitespace_control():
    src = "{{- x -}}"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


def test_comment_line():
    src = "{# a comment #}\nx"
    r = transform(src)
    assert [(li.kind, li.depth) for li in r.line_info] == [("host", 0), ("host", 0)]
    compile(r.virtual_src, "<shadow>", "exec")
    assert _jinja_diagnostics(src) == []


# --- malformed templates report diagnostics --------------------------------

def test_malformed_incomplete_for():
    diags = _jinja_diagnostics("{% for x in %}")
    assert diags and "Jinja syntax error" in diags[0].message


def test_malformed_missing_if_condition():
    diags = _jinja_diagnostics("{% if %}{% endif %}")
    assert diags and "Jinja syntax error" in diags[0].message


def test_malformed_unclosed_block():
    diags = _jinja_diagnostics("{% block %}")
    assert diags and "Jinja syntax error" in diags[0].message


def test_malformed_closer_without_opener():
    diags = _jinja_diagnostics("{% endfor %}")
    assert diags and "Jinja syntax error" in diags[0].message


def test_malformed_broken_expression():
    diags = _jinja_diagnostics("{{ 1 + }}")
    assert diags and "Jinja syntax error" in diags[0].message
