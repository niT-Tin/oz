#!/usr/bin/env python3
"""Local LSP peer for completion identity, refresh, lifecycle and native-memory
regressions.

Selected with OZ_COMPLETION_FIXTURE=<scenario> (the e2e helper passes the text
after the "edge:" prefix). Existing scenarios: duplicate*, refresh, edits and
the default rich list. Gated scenarios added for the insert-completion request
lifecycle/form:

  gated      Hold every textDocument/completion response. The test creates
             "release-completion" in the process cwd to release all held
             responses; the peer then writes "completion-delivered". Each
             arrival is marked with "completion-received-<n>". Items are
             gated_alpha/gated_beta, so type a prefix they match ("gated").
  gated-ab   Hold A (first request) and B (second request) separately. The
             test creates "release-b-completion" to release the newest
             request (marker "completion-delivered-b") and later
             "release-a-completion" for the oldest (marker
             "completion-delivered-a"). A items are gatedA_alpha/gatedA_beta,
             B items are gatedB_alpha/gatedB_beta (all start with "gated").
             $/cancelRequest is deliberately not honored, like servers that
             do not implement cancellation, so the late A response is actually
             sent and the client must discard it.
"""
import json
import os
from pathlib import Path
import select

scenario = os.environ["OZ_COMPLETION_FIXTURE"]
buffer = bytearray()
held = []
completion_held = []
resolves = 0
completions = 0


def reply(request_id, value):
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": value}).encode()
    frame = ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body
    while frame:
        frame = frame[os.write(1, frame):]


def gated_completion_items(n):
    """Items for the gated scenarios, or None for the existing scenarios."""
    if scenario == "gated":
        return [candidate("gated_alpha", "GATED_ALPHA_DOC", {"id": "GA"}),
                candidate("gated_beta", "GATED_BETA_DOC", {"id": "GB"})]
    if scenario == "gated-ab":
        if n == 1:
            return [candidate("gatedA_alpha", "GATED_A_ALPHA_DOC", {"id": "A1"}),
                    candidate("gatedA_beta", "GATED_A_BETA_DOC", {"id": "A2"})]
        return [candidate("gatedB_alpha", "GATED_B_ALPHA_DOC", {"id": "B1"}),
                candidate("gatedB_beta", "GATED_B_BETA_DOC", {"id": "B2"})]
    return None


def candidate(label, doc=None, data=None):
    item = {"label": label, "kind": 3, "detail": "fn duplicate() void"}
    if doc is not None:
        item["documentation"] = {"kind": "plaintext", "value": doc}
    if data is not None:
        item["data"] = data
    return item


while True:
    # Gated completion responses (lifecycle scenarios): release by file
    # barrier only. Nothing here depends on rendering speed.
    if completion_held and scenario == "gated" and Path("release-completion").exists():
        for request_id, items in completion_held:
            reply(request_id, items)
        completion_held.clear()
        Path("completion-delivered").write_text("done")
    if scenario == "gated-ab":
        if len(completion_held) >= 2 and Path("release-b-completion").exists() and not Path("completion-delivered-b").exists():
            reply(completion_held[-1][0], completion_held[-1][1])
            Path("completion-delivered-b").write_text("done")
        if completion_held and Path("release-a-completion").exists() and not Path("completion-delivered-a").exists():
            reply(completion_held[0][0], completion_held[0][1])
            Path("completion-delivered-a").write_text("done")
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
            gated = gated_completion_items(completions)
            if gated is not None:
                completion_held.append((request_id, gated))
                Path("completion-received-%d" % completions).write_text("done")
            elif scenario.startswith("duplicate"):
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
            if gated is None:
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
