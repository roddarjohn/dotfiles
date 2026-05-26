"""Forward shadows to caller-configured downstream host language servers.

Each host language gets at most one downstream server process (e.g. zuban,
pyright, pylsp). We act as an LSP *client* to it: spawn it, initialize, open
the shadow as a virtual document, and receive its ``publishDiagnostics``
notifications -- which we hand back to the registered callback keyed by the
virtual document URI. The proxy server (see :mod:`server`) owns the mapping
from virtual URI back to the template.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import Callable

from lsprotocol import types
from pygls.lsp.client import LanguageClient
from pygls.protocol import default_converter

from . import hosts
from .config import Config

DiagnosticsCallback = Callable[[str, list[types.Diagnostic]], None]


def _downstream_converter():
    """A cattrs converter tolerant of the messages real servers send us.

    Servers like zuban advertise ``notebookDocumentSync`` in their
    ServerCapabilities (and may register it dynamically). lsprotocol can't
    structure that option's selector union, which makes the whole
    ``initialize`` response fail to parse -- so ``initialize_async`` never
    resolves and every later request hangs. We don't use notebooks, so
    accept those options as opaque (empty selector).
    """
    converter = default_converter()
    for cls in (
        types.NotebookDocumentSyncOptions,
        types.NotebookDocumentSyncRegistrationOptions,
    ):
        converter.register_structure_hook(
            cls, lambda _value, _type, _cls=cls: _cls(notebook_selector=[])
        )
    return converter


class _Connection:
    """A single downstream server process for one host language."""

    def __init__(
        self,
        command: list[str],
        language_id: str,
        on_diagnostics: DiagnosticsCallback,
        *,
        root_uri: str | None = None,
        workspace_folders: list[types.WorkspaceFolder] | None = None,
        cwd: str | None = None,
    ) -> None:
        self._command = command
        self._language_id = language_id
        self._on_diagnostics = on_diagnostics
        self._root_uri = root_uri
        self._workspace_folders = workspace_folders
        self._cwd = cwd
        self._client: LanguageClient | None = None
        self._opened: set[str] = set()
        self._start_lock = asyncio.Lock()

    async def _ready(self) -> LanguageClient:
        if self._client is not None:
            return self._client
        async with self._start_lock:
            if self._client is not None:
                return self._client
            client = LanguageClient(
                "jinja-shadow-downstream", "0.0.0",
                converter_factory=_downstream_converter,
            )

            @client.feature(types.TEXT_DOCUMENT_PUBLISH_DIAGNOSTICS)
            def _forward(params: types.PublishDiagnosticsParams) -> None:
                self._on_diagnostics(params.uri, params.diagnostics)

            # Answer the server->client requests real servers make during
            # startup, so they don't block waiting on us.
            @client.feature(types.CLIENT_REGISTER_CAPABILITY)
            def _register(_params):
                return None

            @client.feature(types.CLIENT_UNREGISTER_CAPABILITY)
            def _unregister(_params):
                return None

            @client.feature(types.WORKSPACE_CONFIGURATION)
            def _configuration(params: types.ConfigurationParams):
                return [None for _ in params.items]

            @client.feature(types.WINDOW_WORK_DONE_PROGRESS_CREATE)
            def _work_done(_params):
                return None

            start_kwargs = {"cwd": self._cwd} if self._cwd else {}
            await client.start_io(self._command[0], *self._command[1:], **start_kwargs)
            await client.initialize_async(
                types.InitializeParams(
                    capabilities=types.ClientCapabilities(
                        text_document=types.TextDocumentClientCapabilities(
                            definition=types.DefinitionClientCapabilities(),
                            hover=types.HoverClientCapabilities(),
                            completion=types.CompletionClientCapabilities(),
                        )
                    ),
                    process_id=os.getpid(),
                    root_uri=self._root_uri,
                    workspace_folders=self._workspace_folders,
                )
            )
            client.initialized(types.InitializedParams())
            self._client = client
            return client

    async def definition(self, params: types.DefinitionParams):
        client = await self._ready()
        return await client.text_document_definition_async(params)

    async def hover(self, params: types.HoverParams):
        client = await self._ready()
        return await client.text_document_hover_async(params)

    async def completion(self, params: types.CompletionParams):
        client = await self._ready()
        return await client.text_document_completion_async(params)

    async def sync(self, virtual_uri: str, text: str, version: int) -> None:
        client = await self._ready()
        if virtual_uri in self._opened:
            client.text_document_did_change(
                types.DidChangeTextDocumentParams(
                    text_document=types.VersionedTextDocumentIdentifier(
                        uri=virtual_uri, version=version
                    ),
                    content_changes=[
                        types.TextDocumentContentChangeWholeDocument(text=text)
                    ],
                )
            )
        else:
            client.text_document_did_open(
                types.DidOpenTextDocumentParams(
                    text_document=types.TextDocumentItem(
                        uri=virtual_uri,
                        language_id=self._language_id,
                        version=version,
                        text=text,
                    )
                )
            )
            self._opened.add(virtual_uri)

    async def close(self, virtual_uri: str) -> None:
        if self._client is not None and virtual_uri in self._opened:
            self._client.text_document_did_close(
                types.DidCloseTextDocumentParams(
                    text_document=types.TextDocumentIdentifier(uri=virtual_uri)
                )
            )
            self._opened.discard(virtual_uri)

    async def shutdown(self) -> None:
        if self._client is None:
            return
        client, self._client = self._client, None
        try:
            await client.shutdown_async(None)
            client.exit(None)
        except Exception:  # noqa: BLE001 - best-effort teardown
            pass
        try:
            await client.stop()
        except Exception:  # noqa: BLE001
            pass


class DownstreamRegistry:
    """Lazily-spawned downstream connections, one per configured language."""

    def __init__(self, on_diagnostics: DiagnosticsCallback) -> None:
        self._on_diagnostics = on_diagnostics
        self._config = Config()
        self._connections: dict[str, _Connection] = {}
        self._root_uri: str | None = None
        self._workspace_folders: list[types.WorkspaceFolder] | None = None

    def configure(self, config: Config) -> None:
        self._config = config

    def set_workspace(
        self,
        root_uri: str | None,
        workspace_folders: list[types.WorkspaceFolder] | None,
    ) -> None:
        self._root_uri = root_uri
        self._workspace_folders = workspace_folders

    def has_server(self, language: str) -> bool:
        return self._config.server_for(language) is not None

    def _connection(self, language: str) -> _Connection | None:
        server = self._config.server_for(language)
        if server is None:
            return None
        conn = self._connections.get(language)
        if conn is None:
            # Spawn in the project dir so e.g. `uv run` finds the venv, but
            # only when it actually exists (a stale/synthetic root must not
            # break process spawning).
            cwd = hosts.fs_path(self._root_uri)
            if cwd is not None and not os.path.isdir(cwd):
                cwd = None
            conn = _Connection(
                server.command,
                server.language_id,
                self._on_diagnostics,
                root_uri=self._root_uri,
                workspace_folders=self._workspace_folders,
                cwd=cwd,
            )
            self._connections[language] = conn
        return conn

    async def sync(
        self, language: str, virtual_uri: str, text: str, version: int
    ) -> bool:
        """Push the shadow to the language's downstream server.

        Returns False if no server is configured for ``language``.
        """
        conn = self._connection(language)
        if conn is None:
            return False
        await conn.sync(virtual_uri, text, version)
        return True

    async def definition(self, language: str, params: types.DefinitionParams):
        conn = self._connection(language)
        return await conn.definition(params) if conn else None

    async def hover(self, language: str, params: types.HoverParams):
        conn = self._connection(language)
        return await conn.hover(params) if conn else None

    async def completion(self, language: str, params: types.CompletionParams):
        conn = self._connection(language)
        return await conn.completion(params) if conn else None

    async def close(self, language: str, virtual_uri: str) -> None:
        conn = self._connections.get(language)
        if conn is not None:
            await conn.close(virtual_uri)

    async def shutdown_all(self) -> None:
        for conn in self._connections.values():
            await conn.shutdown()
        self._connections.clear()
