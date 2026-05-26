"""Caller configuration, parsed from LSP ``initializationOptions``.

The downstream host servers are not hardcoded: the editor declares them.
Example ``initializationOptions``::

    {
      "servers": {
        "python": {"command": ["zuban", "server"]}
      },
      "extensions": {".sql": "sql"}
    }

``servers`` maps a host language id to the command that launches its language
server (optionally with an explicit ``languageId`` to advertise to it).
``extensions`` extends/overrides the inner-extension -> language table.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class DownstreamServer:
    command: list[str]
    language_id: str


_DEFAULT_REQUEST_TIMEOUT = 6.0


@dataclass
class Config:
    servers: dict[str, DownstreamServer] = field(default_factory=dict)
    extension_languages: dict[str, str] = field(default_factory=dict)
    # Max seconds to wait on a forwarded downstream request (definition/
    # hover/completion) before giving up. Bounds editor UI freezes, since
    # the editor's request to us blocks until we answer.
    request_timeout: float = _DEFAULT_REQUEST_TIMEOUT
    # Whether to surface the downstream server's diagnostics on the template.
    # Off by default: the shadow isn't valid-structured host source (jinja
    # becomes placeholder identifiers, generation-time names are unknown), so
    # those diagnostics are mostly false positives. Jinja syntax diagnostics
    # are always shown regardless.
    forward_diagnostics: bool = False

    def server_for(self, language: str) -> DownstreamServer | None:
        return self.servers.get(language)


def parse(initialization_options: object) -> Config:
    """Build a :class:`Config` from ``initializationOptions`` (or None)."""
    opts = initialization_options if isinstance(initialization_options, dict) else {}

    servers: dict[str, DownstreamServer] = {}
    raw_servers = opts.get("servers")
    if isinstance(raw_servers, dict):
        for language, spec in raw_servers.items():
            command: list[str] = []
            language_id = language
            if isinstance(spec, list):
                command = [str(x) for x in spec]
            elif isinstance(spec, dict):
                cmd = spec.get("command")
                if isinstance(cmd, list):
                    command = [str(x) for x in cmd]
                language_id = str(spec.get("languageId") or language)
            if command:
                servers[language] = DownstreamServer(command, language_id)

    extensions: dict[str, str] = {}
    raw_ext = opts.get("extensions")
    if isinstance(raw_ext, dict):
        for ext, lang in raw_ext.items():
            key = ext if ext.startswith(".") else f".{ext}"
            extensions[key.lower()] = str(lang)

    timeout = _DEFAULT_REQUEST_TIMEOUT
    raw_timeout = opts.get("requestTimeout")
    if isinstance(raw_timeout, (int, float)) and raw_timeout > 0:
        timeout = float(raw_timeout)

    return Config(
        servers=servers,
        extension_languages=extensions,
        request_timeout=timeout,
        forward_diagnostics=bool(opts.get("forwardDiagnostics", False)),
    )
