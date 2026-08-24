"""Route a two-server Python LSP between BasedPyright and Zuban.

Server order is part of the contract: BasedPyright is first and owns
completion (including resolve/auto-import data); Zuban is second and owns all
diagnostics.  Rassumfrassum streams Zuban pull diagnostics, and the callback
below translates that extension into the push notification understood by
Emacs 30's Eglot.
"""

from rassumfrassum.frassum import LspLogic
from rassumfrassum.json import write_message


class PythonRoutingLogic(LspLogic):
    """Enforce the BasedPyright/Zuban ownership split."""

    def __init__(
        self,
        servers,
        notify_client,
        request_client,
        request_server,
        notify_server,
        opts,
    ):
        if len(servers) != 2:
            raise RuntimeError(
                f"PythonRoutingLogic requires exactly two servers, got {len(servers)}"
            )
        if not opts.stream_diagnostics:
            raise RuntimeError(
                "PythonRoutingLogic requires rass --stream-diagnostics"
            )

        self.completion_server = servers[0]
        self.diagnostic_server = servers[1]
        self._notify_eglot = notify_client
        self._request_server = request_server

        super().__init__(
            servers,
            self._notify_eglot_compat,
            request_client,
            self._request_server_current_document,
            notify_server,
            opts,
        )

    async def _request_server_current_document(self, server, method, params):
        """Turn a pull for a replaced DocumentState into unchanged."""
        uri = (
            params.get("textDocument", {}).get("uri")
            if method == "textDocument/diagnostic"
            else None
        )
        captured_state = self.document_state.get(uri) if uri else None
        is_error, payload = await self._request_server(server, method, params)
        if uri and self.document_state.get(uri) is not captured_state:
            return False, {
                "kind": "unchanged",
                "resultId": payload.get("resultId") if payload else None,
            }
        return is_error, payload

    async def on_client_notification(self, method, params):
        """Forward exit directly because Rass 0.3.4 suppresses it after shutdown."""
        if method == "exit":
            message = {"jsonrpc": "2.0", "method": method, "params": params}
            writers = [server.cookie.stdin for server in self.servers.values()]
            for writer in writers:
                await write_message(writer, message)
            # Rass's client loop will also close these after client EOF, but
            # Emacs 30 waits only 100ms before force-deleting Rass. Closing now
            # lets both children consume exit and terminate without that race.
            for writer in writers:
                writer.close()
                await writer.wait_closed()
            return_codes = [
                await server.cookie.process.wait()
                for server in self.servers.values()
            ]
            # Upstream keeps its client read loop alive after exit, while Emacs
            # waits just 100ms before killing Rass. Both children are now clean,
            # so terminate this multiplexer process successfully as LSP exit
            # requires instead of waiting for client EOF that never arrives.
            raise SystemExit(next((code for code in return_codes if code), 0))
        await super().on_client_notification(method, params)

    async def on_client_request(self, method, params, servers):
        """Route owned requests without bypassing Rass's completion stash."""
        if method in ("textDocument/completion", "completionItem/resolve"):
            return await super().on_client_request(
                method, params, [self.completion_server]
            )
        if method == "textDocument/diagnostic":
            return await super().on_client_request(
                method, params, [self.diagnostic_server]
            )
        if method == "workspace/diagnostic":
            return [self.diagnostic_server]
        return await super().on_client_request(method, params, servers)

    async def on_server_response(
        self, method, request_params, payload, is_error, server
    ):
        """Remove conflicting capabilities before Rass records or merges them."""
        if method == "initialize" and not is_error:
            expected_name = (
                "basedpyright"
                if server is self.completion_server
                else "zuban" if server is self.diagnostic_server else None
            )
            actual_name = payload.get("serverInfo", {}).get("name")
            if expected_name is None or not isinstance(actual_name, str):
                raise RuntimeError(
                    "Python LSP server identity is missing or from an unknown server"
                )
            if actual_name.casefold() != expected_name:
                raise RuntimeError(
                    "Python LSP server order mismatch: "
                    f"expected {expected_name}, got {actual_name}"
                )

            capabilities = payload.get("capabilities", {})
            if server is self.completion_server:
                capabilities.pop("diagnosticProvider", None)
            else:
                capabilities.pop("completionProvider", None)

        await super().on_server_response(
            method, request_params, payload, is_error, server
        )

    async def on_server_notification(self, method, params, source):
        """Suppress BasedPyright diagnostics; let Zuban stream through Rass."""
        if (
            method == "textDocument/publishDiagnostics"
            and source is self.completion_server
        ):
            return
        await super().on_server_notification(method, params, source)

    async def _notify_eglot_compat(self, method, params):
        """Translate Rass streaming diagnostics to Emacs 30 push diagnostics."""
        if method == "$/streamDiagnostics":
            # An unchanged pull must retain the diagnostics already in Flymake.
            if params.get("kind") == "unchanged":
                return

            uri = params.get("uri")
            version = params.get("version")
            state = self.document_state.get(uri)

            # Emacs 30's push handler does not reject stale document versions.
            if state is None or state.docver != version:
                return

            method = "textDocument/publishDiagnostics"
            params = {
                "uri": uri,
                "version": version,
                # A full empty result intentionally clears old diagnostics.
                "diagnostics": params.get("diagnostics", []),
            }

        await self._notify_eglot(method, params)
