#!/usr/bin/env python3
"""Local LSP peer for passive signature lifecycle timing.

The peer only releases a held SIG_A response when the PTY test creates
`release-A` in OZ_SIG_ROOT. No unrelated request or cancel notification
releases it. This is the protocol barrier used by the formal tests.
"""
import json
import os
import select
from pathlib import Path

root = Path(os.environ["OZ_SIG_ROOT"])
mode = os.environ.get("OZ_SIG_MODE", "normal")
buffer = bytearray()
held = None
signature_count = 0


def reply(request_id, value):
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": value}).encode()
    frame = ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body
    while frame:
        frame = frame[os.write(1, frame):]


def marker(name):
    (root / name).write_text("1")


def signature_value(label):
    return {"signatures": [{"label": label}]}


def completion_item(label, detail, doc):
    return {
        "label": label,
        "kind": 3,
        "detail": detail,
        "documentation": {"kind": "markdown", "value": doc},
    }


while True:
    # File barrier: only this explicit signal releases A, even if the client
    # sent more requests, didChange, formatting, or cancellation.
    if held is not None and (root / "release-A").exists():
        reply(held, signature_value("SIG_A"))
        held = None
        marker("response-A")
    if not select.select([0], [], [], 0.02)[0]:
        continue
    chunk = os.read(0, 65536)
    if not chunk:
        break
    buffer.extend(chunk)
    while True:
        split = buffer.find(b"\r\n\r\n")
        if split < 0:
            break
        size = int(bytes(buffer[:split]).split(b":", 1)[1])
        if len(buffer) < split + 4 + size:
            break
        message = json.loads(buffer[split + 4:split + 4 + size])
        del buffer[:split + 4 + size]
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            reply(request_id, {"capabilities": {
                "textDocumentSync": 2,
                "signatureHelpProvider": {"triggerCharacters": ["("]},
                "completionProvider": {"triggerCharacters": ["."]},
            }})
        elif method == "textDocument/signatureHelp":
            signature_count += 1
            if mode in ("hold", "hold_ab") and signature_count == 1:
                held = request_id
                marker("request-1")
            elif mode == "hold_ab":
                reply(request_id, signature_value("SIG_B"))
                marker("response-B")
            elif mode == "null":
                reply(request_id, None)
                marker("response-null")
            elif mode == "error":
                body = json.dumps({"jsonrpc": "2.0", "id": request_id,
                                   "error": {"code": -32603, "message": "SIG_ERROR"}}).encode()
                frame = ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body
                while frame:
                    frame = frame[os.write(1, frame):]
                marker("response-error")
            elif mode == "ignore":
                marker("request-ignored")
            elif mode == "timeout":
                marker("request-timeout")
            else:
                label = "SIG_A" if signature_count == 1 else "SIG_B"
                reply(request_id, signature_value(label))
                marker("response-1" if signature_count == 1 else "response-2")
        elif method == "textDocument/completion":
            reply(request_id, [
                completion_item("stat", "fn stat() void", "STAT_DOC"),
                completion_item("close", "fn close() void", "CLOSE_DOC"),
                completion_item("sync", "fn sync() void", "SYNC_DOC"),
                completion_item("isTty", "fn isTty() bool", "ISTTY_DOC"),
            ])
        elif method == "exit":
            raise SystemExit
        elif request_id is not None:
            reply(request_id, None)
