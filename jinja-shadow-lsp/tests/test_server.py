"""End-to-end smoke test: drive the server over stdio with raw JSON-RPC.

Launches the installed console script, performs the LSP handshake, opens a
malformed template, and asserts the server pushes a publishDiagnostics
notification back. This guards against LSP-API drift (e.g. pygls upgrades).
"""

import contextlib
import json
import signal
import subprocess
import sys


def _frame(payload: dict) -> bytes:
    body = json.dumps(payload).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body


def _read_message(proc: subprocess.Popen) -> dict | None:
    """Read one framed JSON-RPC message from proc.stdout (blocking)."""
    headers: dict[bytes, bytes] = {}
    while True:
        line = proc.stdout.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break  # blank line terminates the header block
        if b":" in line:
            key, value = line.split(b":", 1)
            headers[key.strip().lower()] = value.strip()
    length = int(headers[b"content-length"])
    return json.loads(proc.stdout.read(length))


@contextlib.contextmanager
def _timeout(seconds: int):
    def _raise(*_):
        raise TimeoutError(f"server did not respond within {seconds}s")

    old = signal.signal(signal.SIGALRM, _raise)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


def test_server_publishes_diagnostics_over_stdio():
    proc = subprocess.Popen(
        [sys.executable, "-m", "jinja_shadow_lsp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    try:
        with _timeout(20):
            proc.stdin.write(
                _frame(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "processId": None,
                            "rootUri": None,
                            "capabilities": {},
                        },
                    }
                )
            )
            proc.stdin.flush()

            # Drain until the initialize response (id == 1) arrives.
            while True:
                msg = _read_message(proc)
                assert msg is not None, "no initialize response"
                if msg.get("id") == 1:
                    assert "result" in msg
                    break

            proc.stdin.write(
                _frame({"jsonrpc": "2.0", "method": "initialized", "params": {}})
            )
            proc.stdin.write(
                _frame(
                    {
                        "jsonrpc": "2.0",
                        "method": "textDocument/didOpen",
                        "params": {
                            "textDocument": {
                                "uri": "file:///tmp/broken.py.j2",
                                "languageId": "jinja",
                                "version": 1,
                                "text": "{% for x in %}\n",
                            }
                        },
                    }
                )
            )
            proc.stdin.flush()

            # Expect a publishDiagnostics notification with a non-empty list.
            while True:
                msg = _read_message(proc)
                assert msg is not None, "no publishDiagnostics received"
                if msg.get("method") == "textDocument/publishDiagnostics":
                    diags = msg["params"]["diagnostics"]
                    assert diags, "expected a Jinja syntax diagnostic"
                    assert "Jinja syntax error" in diags[0]["message"]
                    break
    finally:
        proc.stdin.close()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
