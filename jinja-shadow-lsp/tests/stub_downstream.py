"""A minimal stand-in for a real downstream host language server.

On open/change it publishes one diagnostic per line of the received document
(message ``stub@<line>``). The proxy should remap those that fall on
template-mapped shadow lines and drop those on generated scaffolding. This
lets us integration-test the proxy without depending on zuban/pyright.
"""

import os
import time

from lsprotocol import types
from pygls.lsp.server import LanguageServer

stub = LanguageServer("stub-downstream", "0.0.0")

# Records the root_uri the proxy forwarded to us, so a test can assert that
# project context is propagated.
_received = {"root_uri": None}


@stub.feature(types.INITIALIZE)
def initialize(*args):
    params = next(a for a in args if isinstance(a, types.InitializeParams))
    _received["root_uri"] = params.root_uri


def _emit(ls: LanguageServer, uri: str, text: str) -> None:
    diags = [
        types.Diagnostic(
            range=types.Range(
                start=types.Position(line=i, character=0),
                end=types.Position(line=i, character=1),
            ),
            message=f"stub@{i}",
            severity=types.DiagnosticSeverity.Warning,
            source="stub",
        )
        for i in range(len(text.split("\n")))
    ]
    ls.text_document_publish_diagnostics(
        types.PublishDiagnosticsParams(uri=uri, diagnostics=diags)
    )


@stub.feature(types.TEXT_DOCUMENT_DID_OPEN)
def did_open(ls: LanguageServer, params: types.DidOpenTextDocumentParams) -> None:
    _emit(ls, params.text_document.uri, params.text_document.text)


@stub.feature(types.TEXT_DOCUMENT_DID_CHANGE)
def did_change(ls: LanguageServer, params: types.DidChangeTextDocumentParams) -> None:
    doc = ls.workspace.get_text_document(params.text_document.uri)
    _emit(ls, params.text_document.uri, doc.source)


def _span_at(params) -> types.Range:
    # A 6-char span starting at the requested position, in the doc it received
    # (the shadow). The proxy must map this back to template coordinates.
    p = params.position
    return types.Range(
        start=types.Position(line=p.line, character=p.character),
        end=types.Position(line=p.line, character=p.character + 6),
    )


@stub.feature(types.TEXT_DOCUMENT_DEFINITION)
def definition(ls: LanguageServer, params: types.DefinitionParams):
    # Optionally simulate a slow/stuck downstream server (blocks this stub's
    # loop) so a test can verify the proxy's request timeout kicks in.
    delay = float(os.environ.get("STUB_DEFINITION_DELAY", "0"))
    if delay:
        time.sleep(delay)
    return types.Location(uri=params.text_document.uri, range=_span_at(params))


@stub.feature(types.TEXT_DOCUMENT_HOVER)
def hover(ls: LanguageServer, params: types.HoverParams):
    # Echo the forwarded root_uri so a test can confirm project context.
    return types.Hover(
        contents=f"root={_received['root_uri']}", range=_span_at(params)
    )


if __name__ == "__main__":
    stub.start_io()
