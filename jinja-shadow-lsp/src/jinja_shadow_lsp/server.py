"""LSP server entry point -- a host-agnostic Jinja front-end that proxies to
caller-configured downstream host language servers.

Capabilities over stdio:

* **Jinja syntax diagnostics** (host-agnostic): the buffer is parsed with the
  real Jinja2 parser on open/change; any ``TemplateSyntaxError`` is published.
* **Forwarded host diagnostics** (when configured): for a template whose host
  language has a downstream server configured in ``initializationOptions``, we
  generate a host-language *shadow*, forward it to that server as a virtual
  document, map its diagnostics back onto the template (dropping ones on
  generated scaffolding), and merge them with the Jinja diagnostics.

The downstream servers are **not hardcoded** -- the caller declares them::

    "initializationOptions": {
      "servers": {"python": {"command": ["zuban", "server"]}},
      "extensions": {".sql": "sql"}
    }

This server does not format anything.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

from jinja2 import Environment
from jinja2.exceptions import TemplateSyntaxError
from lsprotocol import types
from pygls.lsp.server import LanguageServer

from . import __version__, hosts
from . import shadow as shadow_mod
from .config import Config, parse as parse_config
from .downstream import DownstreamRegistry

server = LanguageServer("jinja-shadow-lsp", __version__)

# Parse with the commonly-enabled Jinja extensions loaded, so templates that
# use them (i18n {% trans %}, {% do %}, {% break %}/{% continue %},
# {% debug %}) don't produce false syntax-error diagnostics.
_JINJA_EXTENSIONS = [
    "jinja2.ext.i18n",
    "jinja2.ext.do",
    "jinja2.ext.loopcontrols",
    "jinja2.ext.debug",
]


def _jinja_diagnostics(source: str) -> list[types.Diagnostic]:
    try:
        Environment(extensions=_JINJA_EXTENSIONS).parse(source)
    except TemplateSyntaxError as exc:
        line = max((exc.lineno or 1) - 1, 0)
        return [
            types.Diagnostic(
                range=types.Range(
                    start=types.Position(line=line, character=0),
                    end=types.Position(line=line, character=0),
                ),
                message=f"Jinja syntax error: {exc.message}",
                severity=types.DiagnosticSeverity.Error,
                source="jinja-shadow-lsp",
            )
        ]
    except Exception:  # noqa: BLE001 - never let diagnostics crash the server
        return []
    return []


# --- proxy state ----------------------------------------------------------


@dataclass
class _VirtualDoc:
    template_uri: str
    language: str
    shadow: shadow_mod.Shadow
    template_lines: list[str]
    jinja_diags: list[types.Diagnostic]


@dataclass
class _Proxy:
    config: Config = field(default_factory=Config)
    by_virtual: dict[str, _VirtualDoc] = field(default_factory=dict)
    by_template: dict[str, str] = field(default_factory=dict)


_proxy = _Proxy()


def _on_host_diagnostics(virtual_uri: str, host_diags: list[types.Diagnostic]) -> None:
    """Downstream pushed diagnostics for a shadow: remap, filter, merge, publish.

    Off by default (see Config.forward_diagnostics): the shadow isn't
    valid-structured host source, so these are mostly false positives.
    """
    if not _proxy.config.forward_diagnostics:
        return
    vdoc = _proxy.by_virtual.get(virtual_uri)
    if vdoc is None:
        return
    remapped = [
        m
        for d in host_diags
        if (m := shadow_mod.remap_diagnostic(d, vdoc.shadow, vdoc.template_lines))
        is not None
    ]
    server.text_document_publish_diagnostics(
        types.PublishDiagnosticsParams(
            uri=vdoc.template_uri, diagnostics=[*vdoc.jinja_diags, *remapped]
        )
    )


_registry = DownstreamRegistry(_on_host_diagnostics)


def _publish(uri: str, diags: list[types.Diagnostic]) -> None:
    server.text_document_publish_diagnostics(
        types.PublishDiagnosticsParams(uri=uri, diagnostics=diags)
    )


async def _process(uri: str, source: str, version: int) -> None:
    jinja = _jinja_diagnostics(source)
    language = hosts.language_for_uri(uri, _proxy.config.extension_languages)

    if language and _registry.has_server(language):
        sh = shadow_mod.generate(language, source)
        if sh is not None:
            # Use an in-project virtual URI (the template path with the jinja
            # suffix stripped) so the downstream server resolves the shadow
            # within the project for correct import resolution. Content is
            # supplied via didOpen overlay -- no file is written to disk.
            virtual_uri = hosts.shadow_uri(uri)
            prev = _proxy.by_virtual.get(virtual_uri)
            _proxy.by_virtual[virtual_uri] = _VirtualDoc(
                template_uri=uri,
                language=language,
                shadow=sh,
                template_lines=source.split("\n"),
                jinja_diags=jinja,
            )
            _proxy.by_template[uri] = virtual_uri
            # Show Jinja diagnostics immediately; host diagnostics merge in
            # asynchronously when the downstream server responds.
            _publish(uri, jinja)
            # Skip the downstream round-trip (and its re-analysis) when the
            # shadow is byte-identical to what we last sent -- many template
            # edits (inside tags, comments, whitespace) don't change it.
            if prev is None or prev.shadow.text != sh.text:
                try:
                    await _registry.sync(language, virtual_uri, sh.text, version)
                except Exception:  # noqa: BLE001 - downstream failure mustn't crash us
                    pass
            return

    _publish(uri, jinja)


@server.feature(types.INITIALIZE)
def on_initialize(*args) -> None:
    # pygls may call this as (params,) or (ls, params); find the params.
    params = next(a for a in args if isinstance(a, types.InitializeParams))
    _proxy.config = parse_config(params.initialization_options)
    _registry.configure(_proxy.config)
    # Forward the editor's project context so downstream servers resolve
    # imports against the real project (venv, sys.path, configs).
    _registry.set_workspace(params.root_uri, params.workspace_folders)


@server.feature(types.TEXT_DOCUMENT_DID_OPEN)
async def did_open(ls: LanguageServer, params: types.DidOpenTextDocumentParams) -> None:
    await _process(
        params.text_document.uri,
        params.text_document.text,
        params.text_document.version,
    )


@server.feature(types.TEXT_DOCUMENT_DID_CHANGE)
async def did_change(
    ls: LanguageServer, params: types.DidChangeTextDocumentParams
) -> None:
    doc = ls.workspace.get_text_document(params.text_document.uri)
    await _process(params.text_document.uri, doc.source, params.text_document.version or 0)


@server.feature(types.TEXT_DOCUMENT_DID_CLOSE)
async def did_close(
    ls: LanguageServer, params: types.DidCloseTextDocumentParams
) -> None:
    virtual_uri = _proxy.by_template.pop(params.text_document.uri, None)
    if virtual_uri is None:
        return
    vdoc = _proxy.by_virtual.pop(virtual_uri, None)
    if vdoc is not None:
        await _registry.close(vdoc.language, virtual_uri)


@server.feature(types.SHUTDOWN)
async def on_shutdown(*args) -> None:
    await _registry.shutdown_all()


# --- request forwarding (definition / hover / completion) -----------------


def _forward_target(
    template_uri: str, position: types.Position
) -> tuple[str, _VirtualDoc, types.Position] | None:
    """Resolve (virtual_uri, vdoc, shadow_position) for a request, or None.

    None when the file has no shadow or the position isn't in host code that
    maps into the shadow (e.g. on a jinja tag).
    """
    virtual_uri = _proxy.by_template.get(template_uri)
    if virtual_uri is None:
        return None
    vdoc = _proxy.by_virtual.get(virtual_uri)
    if vdoc is None:
        return None
    spos = shadow_mod.shadow_position(vdoc.shadow, position.line, position.character)
    if spos is None:
        return None
    return virtual_uri, vdoc, spos


def _map_location(loc, virtual_uri: str, vdoc: _VirtualDoc):
    """Map a downstream Location/LocationLink back to the template.

    Targets inside the shadow are rewritten to the template; targets in other
    real files pass through unchanged.
    """
    if isinstance(loc, types.LocationLink):
        target_uri = loc.target_uri
        target_range = loc.target_range
        target_sel = loc.target_selection_range
        if target_uri == virtual_uri:
            tr = shadow_mod.template_range_of(vdoc.shadow, loc.target_range, vdoc.template_lines)
            ts = shadow_mod.template_range_of(vdoc.shadow, loc.target_selection_range, vdoc.template_lines)
            if tr is None:
                return None
            target_uri, target_range, target_sel = vdoc.template_uri, tr, (ts or tr)
        origin = loc.origin_selection_range
        if origin is not None:
            origin = shadow_mod.template_range_of(vdoc.shadow, origin, vdoc.template_lines)
        return types.LocationLink(
            target_uri=target_uri,
            target_range=target_range,
            target_selection_range=target_sel,
            origin_selection_range=origin,
        )
    # plain Location
    if loc.uri == virtual_uri:
        tr = shadow_mod.template_range_of(vdoc.shadow, loc.range, vdoc.template_lines)
        if tr is None:
            return None
        return types.Location(uri=vdoc.template_uri, range=tr)
    return loc


@server.feature(types.TEXT_DOCUMENT_DEFINITION)
async def definition(ls: LanguageServer, params: types.DefinitionParams):
    target = _forward_target(params.text_document.uri, params.position)
    if target is None:
        return None
    virtual_uri, vdoc, spos = target
    try:
        result = await asyncio.wait_for(
            _registry.definition(
                vdoc.language,
                types.DefinitionParams(
                    text_document=types.TextDocumentIdentifier(uri=virtual_uri),
                    position=spos,
                ),
            ),
            timeout=_proxy.config.request_timeout,
        )
    except Exception:  # noqa: BLE001 - incl. TimeoutError; never hang the editor
        return None
    if result is None:
        return None
    if isinstance(result, list):
        mapped = [m for x in result if (m := _map_location(x, virtual_uri, vdoc))]
        return mapped or None
    return _map_location(result, virtual_uri, vdoc)


@server.feature(types.TEXT_DOCUMENT_HOVER)
async def hover(ls: LanguageServer, params: types.HoverParams):
    target = _forward_target(params.text_document.uri, params.position)
    if target is None:
        return None
    virtual_uri, vdoc, spos = target
    try:
        result = await asyncio.wait_for(
            _registry.hover(
                vdoc.language,
                types.HoverParams(
                    text_document=types.TextDocumentIdentifier(uri=virtual_uri),
                    position=spos,
                ),
            ),
            timeout=_proxy.config.request_timeout,
        )
    except Exception:  # noqa: BLE001 - incl. TimeoutError; never hang the editor
        return None
    if result is None:
        return None
    rng = result.range
    if rng is not None:
        rng = shadow_mod.template_range_of(vdoc.shadow, rng, vdoc.template_lines)
    return types.Hover(contents=result.contents, range=rng)


def _map_completion_edits(item: types.CompletionItem, vdoc: _VirtualDoc) -> None:
    """Rewrite an item's edit ranges from shadow into template coords, in place."""

    def remap(rng):
        return shadow_mod.template_range_of(vdoc.shadow, rng, vdoc.template_lines)

    edit = item.text_edit
    if isinstance(edit, types.TextEdit) and (r := remap(edit.range)) is not None:
        edit.range = r
    elif isinstance(edit, types.InsertReplaceEdit):
        if (ri := remap(edit.insert)) is not None:
            edit.insert = ri
        if (rr := remap(edit.replace)) is not None:
            edit.replace = rr
    if item.additional_text_edits:
        for extra in item.additional_text_edits:
            if (r := remap(extra.range)) is not None:
                extra.range = r


@server.feature(types.TEXT_DOCUMENT_COMPLETION)
async def completion(ls: LanguageServer, params: types.CompletionParams):
    target = _forward_target(params.text_document.uri, params.position)
    if target is None:
        return None
    virtual_uri, vdoc, spos = target
    try:
        result = await asyncio.wait_for(
            _registry.completion(
                vdoc.language,
                types.CompletionParams(
                    text_document=types.TextDocumentIdentifier(uri=virtual_uri),
                    position=spos,
                ),
            ),
            timeout=_proxy.config.request_timeout,
        )
    except Exception:  # noqa: BLE001 - incl. TimeoutError; never hang the editor
        return None
    if result is None:
        return None
    items = result.items if isinstance(result, types.CompletionList) else result
    for item in items:
        _map_completion_edits(item, vdoc)
    return result


def main() -> None:
    server.start_io()


if __name__ == "__main__":
    main()
