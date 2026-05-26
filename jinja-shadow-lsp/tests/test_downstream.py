"""Regression test for the downstream converter.

Real servers (e.g. zuban) advertise `notebookDocumentSync` in their
ServerCapabilities. lsprotocol's default converter can't structure that
option's selector union, which makes the entire `initialize` response fail
to parse -- so the client's `initialize_async` never resolves and every
forwarded request hangs. `_downstream_converter` must tolerate it.
"""

from lsprotocol import types

from jinja_shadow_lsp.downstream import _downstream_converter

# A representative initialize result carrying a notebookDocumentSync option
# with a non-trivial selector (the shape that trips lsprotocol's converter).
_INITIALIZE_RESULT = {
    "capabilities": {
        "notebookDocumentSync": {
            "notebookSelector": [
                {"notebook": {"scheme": "file"}, "cells": [{"language": "python"}]}
            ]
        }
    }
}


def test_converter_structures_notebook_sync_capabilities():
    converter = _downstream_converter()
    result = converter.structure(_INITIALIZE_RESULT, types.InitializeResult)
    # The point is that this doesn't raise; we accept the option opaquely.
    assert result.capabilities.notebook_document_sync is not None


def test_converter_still_parses_ordinary_capabilities():
    converter = _downstream_converter()
    result = converter.structure(
        {"capabilities": {"definitionProvider": True, "hoverProvider": True}},
        types.InitializeResult,
    )
    assert result.capabilities.definition_provider is True
    assert result.capabilities.hover_provider is True
