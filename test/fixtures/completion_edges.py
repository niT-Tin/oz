#!/usr/bin/env python3
"""Local LSP peer for completion identity, refresh and native-memory regressions."""
import json
import os
from pathlib import Path
import select

scenario = os.environ["OZ_COMPLETION_FIXTURE"]
buffer = bytearray()
held = []
resolves = 0
completions = 0


def reply(request_id, value):
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": value}).encode()
    frame = ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body
    while frame:
        frame = frame[os.write(1, frame):]


def candidate(label, doc=None, data=None):
    item = {"label": label, "kind": 3, "detail": "fn duplicate() void"}
    if doc is not None:
        item["documentation"] = {"kind": "plaintext", "value": doc}
    if data is not None:
        item["data"] = data
    return item


while True:
    # A deterministic barrier: the PTY test releases A only after B's own
    # initial docs are visible. No timing assumption about rendering speed.
    if held and Path("release-resolve").exists():
        for request_id, item in held:
            reply(request_id, dict(item, documentation="A_LATE_DOC"))
        held.clear()
        Path("resolve-delivered").write_text("done")
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
                  "completionProvider": {"resolveProvider": True}}})
        elif method == "textDocument/completion":
            completions += 1
            if scenario.startswith("duplicate"):
                data_a = {"id": "A"} if scenario == "duplicate" else None
                data_b = {"id": "B"} if scenario == "duplicate" else None
                items = [candidate("duplicate", data=data_a),
                         candidate("duplicate", "B_INITIAL_DOC", data_b)]
            elif scenario == "refresh":
                items = [candidate("duplicate", data={"id": "A"})]
            elif scenario == "edits":
                end = message["params"]["position"]["character"]
                items = []
                for i in range(2):
                    item = candidate("duplicate%d" % i, "EDIT_DOC_%d_GEN_%d" % (i, completions), {"id": i})
                    item["textEdit"] = {"newText": item["label"], "range": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": end}}}
                    items.append(item)
            else:
                items = [candidate("duplicate%d" % i, "DOC_%d" % i) for i in range(8)]
            reply(request_id, items)
        elif method == "completionItem/resolve":
            item = message["params"]
            if scenario.startswith("duplicate"):
                held.append((request_id, item))
            else:
                resolves += 1
                reply(request_id, dict(item, documentation="REFRESH_DOC_%d" % resolves))
        elif method == "exit":
            raise SystemExit
        elif request_id is not None:
            reply(request_id, None)
