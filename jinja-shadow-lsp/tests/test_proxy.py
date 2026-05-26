"""End-to-end proxy tests: drive the real server over stdio, configured with a
stub downstream server, and assert that diagnostics are remapped and that
definition/hover requests are forwarded and mapped back to the template."""

import contextlib
import json
import os
import signal
import subprocess
import sys
import time

STUB = os.path.join(os.path.dirname(__file__), "stub_downstream.py")
ROOT_URI = "file:///proj/root"
TEMPLATE_URI = "file:///tmp/foo.py.j2"
# Line 1 ("result = compute(value)") is host code at template column 0.
TEMPLATE_TEXT = "{% for x in xs %}\nresult = compute(value)\n{% endfor %}\n"


def _frame(payload: dict) -> bytes:
    body = json.dumps(payload).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body


def _read_message(proc: subprocess.Popen) -> dict | None:
    headers: dict[bytes, bytes] = {}
    while True:
        line = proc.stdout.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        if b":" in line:
            key, value = line.split(b":", 1)
            headers[key.strip().lower()] = value.strip()
    return json.loads(proc.stdout.read(int(headers[b"content-length"])))


@contextlib.contextmanager
def _timeout(seconds: int):
    def _raise(*_):
        raise TimeoutError(f"no expected message within {seconds}s")

    old = signal.signal(signal.SIGALRM, _raise)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


def _send(proc, payload):
    proc.stdin.write(_frame(payload))
    proc.stdin.flush()


def _await_response(proc, request_id):
    while True:
        msg = _read_message(proc)
        assert msg is not None, f"no response for id {request_id}"
        if msg.get("id") == request_id:
            return msg


def _initialize_and_open(proc, request_timeout=None, forward_diagnostics=False):
    """initialize + initialized + didOpen. Returns once the document is open;
    the downstream is spawned lazily on the first forwarded request."""
    init_options = {"servers": {"python": {"command": [sys.executable, STUB]}}}
    if request_timeout is not None:
        init_options["requestTimeout"] = request_timeout
    if forward_diagnostics:
        init_options["forwardDiagnostics"] = True
    _send(
        proc,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "processId": None,
                "rootUri": ROOT_URI,
                "capabilities": {},
                "initializationOptions": init_options,
            },
        },
    )
    _await_response(proc, 1)
    _send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
    _send(
        proc,
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": TEMPLATE_URI,
                    "languageId": "jinja",
                    "version": 1,
                    "text": TEMPLATE_TEXT,
                }
            },
        },
    )


def _await_template_host_diagnostics(proc):
    """Wait for a publish carrying remapped host (stub@) diagnostics."""
    while True:
        msg = _read_message(proc)
        assert msg is not None, "downstream never produced diagnostics"
        if msg.get("method") != "textDocument/publishDiagnostics":
            continue
        params = msg["params"]
        if params["uri"] == TEMPLATE_URI and any(
            "stub@" in d["message"] for d in params["diagnostics"]
        ):
            return params["diagnostics"]


@contextlib.contextmanager
def _server(env=None):
    proc = subprocess.Popen(
        [sys.executable, "-m", "jinja_shadow_lsp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    try:
        yield proc
    finally:
        proc.stdin.close()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def test_proxy_forwards_and_remaps_downstream_diagnostics():
    with _server() as proc, _timeout(30):
        _initialize_and_open(proc, forward_diagnostics=True)
        diags = _await_template_host_diagnostics(proc)
        by_line = {d["range"]["start"]["line"]: d["message"] for d in diags}
        # for-opener (line 0) and body (line 1) are mapped; the trailing
        # scaffold shadow line is not, so its diagnostic is dropped.
        assert by_line == {0: "stub@0", 1: "stub@1"}


def test_proxy_forwards_definition_and_maps_location_back():
    with _server() as proc, _timeout(30):
        _initialize_and_open(proc)
        _send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "textDocument/definition",
                "params": {
                    "textDocument": {"uri": TEMPLATE_URI},
                    "position": {"line": 1, "character": 0},  # "result"
                },
            },
        )
        result = _await_response(proc, 2)["result"]
        # Location mapped from the shadow back to the template.
        assert result["uri"] == TEMPLATE_URI
        assert result["range"]["start"] == {"line": 1, "character": 0}
        assert result["range"]["end"] == {"line": 1, "character": 6}  # "result"


def test_proxy_forwards_hover_and_maps_range_back():
    with _server() as proc, _timeout(30):
        _initialize_and_open(proc)
        _send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "textDocument/hover",
                "params": {
                    "textDocument": {"uri": TEMPLATE_URI},
                    "position": {"line": 1, "character": 0},
                },
            },
        )
        result = _await_response(proc, 3)["result"]
        assert result["range"]["start"] == {"line": 1, "character": 0}
        assert result["range"]["end"] == {"line": 1, "character": 6}


def test_proxy_request_timeout_does_not_hang():
    # A stuck downstream (blocks for 5s) must not hang us: with a 0.3s request
    # timeout the proxy answers (null) promptly rather than waiting it out.
    env = {**os.environ, "STUB_DEFINITION_DELAY": "5"}
    with _server(env=env) as proc, _timeout(20):
        _initialize_and_open(proc, request_timeout=0.3)
        start = time.monotonic()
        _send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 9,
                "method": "textDocument/definition",
                "params": {
                    "textDocument": {"uri": TEMPLATE_URI},
                    "position": {"line": 1, "character": 0},
                },
            },
        )
        msg = _await_response(proc, 9)
        elapsed = time.monotonic() - start
        assert msg["result"] is None
        assert elapsed < 3, f"proxy waited {elapsed:.1f}s for a stuck downstream"


def test_proxy_forwards_root_uri_to_downstream():
    # The stub echoes the root_uri it was initialized with into its hover
    # contents, proving the editor's project context reaches the downstream.
    with _server() as proc, _timeout(30):
        _initialize_and_open(proc)
        _send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "textDocument/hover",
                "params": {
                    "textDocument": {"uri": TEMPLATE_URI},
                    "position": {"line": 1, "character": 0},
                },
            },
        )
        result = _await_response(proc, 4)["result"]
        assert f"root={ROOT_URI}" in result["contents"]
