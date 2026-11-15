#!/usr/bin/env python3
"""Local LSP peer with file barriers for completion request lifecycle tests.

Environment:
  OZ_GATE_DIR   directory for barrier files (required)
  OZ_GATE_MODE  "single"  -> hold every completion request; ``release-all``
                             replies to all held requests, then ``delivered-1``
                 "ablate"  -> hold A (oldest) and B (newest); ``release-b``
                             replies to the newest request (B), then
                             ``delivered-B``; ``release-a`` replies to the
                             remaining older requests (A), then ``delivered-A``

Requests are numbered on arrival: ``received-1``, ``received-2``, ...
The labels are distinct per scenario so a frame assertion can prove which
response produced the visible list. This peer is deliberately slow: it never
answers a completion request until the test opens the matching gate, which is
the production event chain (request -> user movement -> response) without any
test sleep.
"""
import json
import os
from pathlib import Path
import select

gate = Path(os.environ["OZ_GATE_DIR"])
mode = os.environ.get("OZ_GATE_MODE", "single")
gate.mkdir(parents=True, exist_ok=True)
buffer = bytearray()
held = []  # [(request_id, items)]
count = 0


def reply(request_id, value):
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": value}).encode()
    frame = ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body
    while frame:
        frame = frame[os.write(1, frame):]


def item(label, insert, doc, ident):
    return {
        "label": label,
        "kind": 3,
        "detail": "fn %s() void" % label,
        "insertText": insert,
        "documentation": {"kind": "plaintext", "value": doc},
        "data": {"id": ident},
    }


def items_for(n):
    if mode == "ablate" and n >= 3:
        return [item("gaB_ONE", "B_one_insert", "B_ONE_DOC", "B1"),
                item("gaB_TWO", "B_two_insert", "B_TWO_DOC", "B2")]
    return [item("gaGATED_A_ONE", "A_one_insert", "GATED_A_DOC_ONE", "A1"),
            item("gaGATED_A_TWO", "A_two_insert", "GATED_A_DOC_TWO", "A2")]


def flush_ready_immediate():
    # Requests that arrive AFTER the gate was opened must not hang forever.
    if mode == "single" and (gate / "release-all").exists() and held:
        for request_id, value in held:
            reply(request_id, value)
        held.clear()
        (gate / "delivered-1").write_text("done")
    if mode == "ablate":
        if (gate / "release-b").exists() and not (gate / "delivered-B").exists() and held:
            request_id, value = held[-1]
            reply(request_id, value)
            held.remove((request_id, value))
            (gate / "delivered-B").write_text("done")
        if (gate / "release-a").exists() and not (gate / "delivered-A").exists():
            for request_id, value in list(held):
                reply(request_id, value)
            held.clear()
            (gate / "delivered-A").write_text("done")


while True:
    flush_ready_immediate()
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
            reply(request_id, {"capabilities": {"textDocumentSync": 2,
                                                "completionProvider": {"resolveProvider": False}}})
        elif method == "textDocument/completion":
            count += 1
            (gate / ("received-%d" % count)).write_text("done")
            held.append((request_id, items_for(count)))
            flush_ready_immediate()
        elif method == "shutdown":
            reply(request_id, None)
        elif method == "exit":
            raise SystemExit
        elif request_id is not None:
            reply(request_id, None)
