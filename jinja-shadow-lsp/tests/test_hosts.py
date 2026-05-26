from jinja_shadow_lsp.hosts import inner_extension, language_for_uri


def test_inner_extension_py_j2():
    assert inner_extension("file:///x/foo.py.j2") == ".py"
    assert inner_extension("file:///x/foo.py.jinja") == ".py"
    assert inner_extension("file:///x/foo.py.jinja2") == ".py"


def test_inner_extension_other_hosts():
    assert inner_extension("file:///x/q.sql.j2") == ".sql"
    assert inner_extension("file:///x/c.tsx.j2") == ".tsx"


def test_inner_extension_none_when_no_jinja_suffix():
    assert inner_extension("file:///x/foo.py") is None


def test_inner_extension_none_when_no_inner_ext():
    assert inner_extension("file:///x/justfile.j2") is None
    assert inner_extension("file:///x/template.j2") is None
    assert inner_extension("file:///x/.env.j2") is None  # dotfile, not an ext


def test_language_for_uri_defaults():
    assert language_for_uri("file:///x/foo.py.j2") == "python"
    assert language_for_uri("file:///x/foo.sql.j2") is None  # no default mapping


def test_language_for_uri_with_overrides():
    assert language_for_uri("file:///x/q.sql.j2", {".sql": "sql"}) == "sql"
    # override wins over default
    assert language_for_uri("file:///x/f.py.j2", {".py": "python3"}) == "python3"
