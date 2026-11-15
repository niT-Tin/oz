#!/usr/bin/env python3
"""Local LSP peer with a file barrier for inlayHint responses.

Used by the undo/inlay regression: the first inlayHint request is answered
immediately (": eol"), every later request is HELD until the test creates
``<OZ_INLAY_BARRIER_DIR>/release-<n>``. Request/delivery markers
(``request-<n>`` / ``delivered-<n>``) give the PTY test a protocol barrier
instead of an arbitrary sleep. The released response uses ": fresh-<n>" so
the test can prove the stored hints were atomically replaced.
"""
import json
import os
from pathlib import Path
import select

barrier = Path(os.environ["OZ_INLAY_BARRIER_DIR"])
barrier.mkdir(parents=True, exist_ok=True)
anchor = os.environ.get("OZ_INLAY_ANCHOR", "")
buffer = bytearray()
held = []
count = 0
document = ""


def reply(request_id, value):
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": value}).encode()
    frame = ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body
    while frame:
        frame = frame[os.write(1, frame):]


def hint(count_value):
    line = 0
    character = 0
    if anchor == "target" and "target" in document:
        # Anchor after the `target` token on its current line. The peer sees
        # didChange, so this survives the test's insert/undo/redo sequence.
        for index, text in enumerate(document.split("\n")):
            pos = text.find("target")
            if pos >= 0:
                line = index
                character = pos + len("target")
                break
    return {
        "position": {"line": line, "character": character},
        "label": ": eol" if count_value == 1 else ": fresh-%d" % count_value,
    }


while True:
    # Release held responses in arrival order once the test writes the
    # matching barrier file. Polling is the peer's own timing, not the test's.
    for request_id, n in list(held):
        if (barrier / ("release-%d" % n)).exists():
            reply(request_id, [hint(n)])
            (barrier / ("delivered-%d" % n)).write_text("done")
            held.remove((request_id, n))

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
            reply(request_id, {"capabilities": {"textDocumentSync": 2, "inlayHintProvider": True}})
        elif method == "textDocument/didOpen":
            document = message["params"]["textDocument"].get("text", "")
        elif method == "textDocument/didChange":
            changes = message["params"].get("contentChanges", [])
            if changes:
                document = changes[0].get("text", document)
        elif method == "textDocument/inlayHint":
            count += 1
            (barrier / ("request-%d" % count)).write_text("done")
            if count == 1:
                reply(request_id, [hint(1)])
                (barrier / "delivered-1").write_text("done")
            else:
                held.append((request_id, count))
        elif method == "shutdown":
            reply(request_id, None)
        elif method == "exit":
            raise SystemExit
        elif request_id is not None:
            reply(request_id, None)
