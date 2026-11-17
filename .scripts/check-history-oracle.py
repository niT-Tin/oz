#!/usr/bin/env python3
"""Check committed text-operation expectations against nvim -u NONE.

Optional independent oracle, not a CI dependency or a golden updater. Fixtures
remain review-sensitive: a mismatch fails without modifying their expectations.
Oz's explicit Ctrl-c insert exits map to Esc for this text-only comparison.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
nvim = shutil.which("nvim")
if nvim is None:
    raise SystemExit("nvim is required for this optional differential check")
cases = json.loads((repo / "test/fixtures/history_text_cases.json").read_text())
with tempfile.TemporaryDirectory(prefix="oz-history-oracle-") as folder:
    root = Path(folder)
    source = root / "source.txt"
    script = root / "replay.vim"
    actions = root / "actions.json"
    script.write_text(
        "set nomore\nset nofixeol\n"
        "lua << ORACLE_LUA\n"
        f"local f = assert(io.open([=[{actions}]=], 'r'))\n"
        "local keys = vim.json.decode(f:read('*a')); f:close()\n"
        "vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)\n"
        "ORACLE_LUA\nwrite\nqa!\n"
    )
    env = dict(os.environ, NVIM_LOG_FILE=str(root / "nvim.log"))
    for case in cases:
        source.write_bytes(case["text"].encode())
        actions.write_text(json.dumps(case["keys"].replace("\x03", "<Esc>") + "<Esc>", ensure_ascii=False))
        result = subprocess.run(
            [nvim, "--headless", "-u", "NONE", "-i", "NONE", "-n", str(source), "-S", str(script)],
            capture_output=True, env=env, timeout=10,
        )
        if result.returncode:
            raise SystemExit(result.stderr.decode(errors="replace"))
        actual = source.read_bytes().decode()
        if actual != case["want"]:
            raise SystemExit(f"#{case['issue']} {case['label']}: expected {case['want']!r}, nvim produced {actual!r}")
print(f"Independent nvim text oracle: {len(cases)} cases passed")
