from jinja_shadow_lsp.config import parse


def test_parse_none_is_empty():
    cfg = parse(None)
    assert cfg.servers == {}
    assert cfg.extension_languages == {}
    assert cfg.server_for("python") is None


def test_parse_server_as_dict_with_command():
    cfg = parse({"servers": {"python": {"command": ["zuban", "server"]}}})
    srv = cfg.server_for("python")
    assert srv is not None
    assert srv.command == ["zuban", "server"]
    assert srv.language_id == "python"


def test_parse_server_as_list_shorthand():
    cfg = parse({"servers": {"python": ["pylsp"]}})
    srv = cfg.server_for("python")
    assert srv.command == ["pylsp"]
    assert srv.language_id == "python"


def test_parse_explicit_language_id():
    cfg = parse(
        {"servers": {"python": {"command": ["x"], "languageId": "python3"}}}
    )
    assert cfg.server_for("python").language_id == "python3"


def test_parse_empty_command_is_ignored():
    cfg = parse({"servers": {"python": {"command": []}}})
    assert cfg.server_for("python") is None


def test_forward_diagnostics_off_by_default():
    assert parse(None).forward_diagnostics is False
    assert parse({}).forward_diagnostics is False


def test_forward_diagnostics_opt_in():
    assert parse({"forwardDiagnostics": True}).forward_diagnostics is True


def test_parse_extension_overrides_normalised():
    cfg = parse({"extensions": {"sql": "sql", ".TSX": "typescriptreact"}})
    assert cfg.extension_languages[".sql"] == "sql"
    assert cfg.extension_languages[".tsx"] == "typescriptreact"
