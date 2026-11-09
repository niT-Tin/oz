#!/usr/bin/env python3
"""Opt-in real DeepSeek profile + oz PTY regression; no remote model calls.
Usage: python3 test/deepseek_smoke.py /path/to/deepseek-harness
Requires that checkout's pnpm dependencies, native addon and Typert artifacts.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import selectors
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

REPO = Path(sys.argv[1]).resolve()
OZ = Path(__file__).resolve().parents[1]


def wait_bytes(fd, marker, timeout=45):
    data = bytearray()
    sel = selectors.DefaultSelector()
    sel.register(fd, selectors.EVENT_READ)
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not sel.select(0.2):
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                raise RuntimeError('process disconnected')
            data.extend(chunk)
            if b'\x1b[6n' in chunk:
                os.write(fd, b'\x1b[1;1R')
            if marker in data:
                return
            if b'AcpRemoteError' in data or b'ACP error:' in data:
                raise RuntimeError('ACP failure: ' + repr(bytes(data[-3000:])))
        raise TimeoutError('waiting for ' + marker.decode() + '; terminal tail: ' + repr(bytes(data[-3000:])))
    finally:
        sel.close()


def wait_editor_exit(editor, master, timeout):
    # Continue draining the PTY while waiting: terminal cleanup can otherwise
    # block on a full output pipe even after :qa! was accepted.
    data = bytearray()
    deadline = time.monotonic() + timeout
    while editor.poll() is None and time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
                data.extend(chunk)
                if b"\x1b[5n" in data[-len(chunk)-8:]:
                    os.write(master, b"\x1b[0n")
            except OSError:
                pass
    return editor.wait(timeout=1)


with tempfile.TemporaryDirectory(prefix='oz-deepseek-smoke-') as temp:
    root = Path(temp)
    home = root / 'home'
    work = root / 'workspace'
    (root / 'package.json').write_text(json.dumps({'type': 'module'}))
    home.mkdir()
    work.mkdir()
    (work / 'acp.txt').write_text('OZ_DSH_EDITOR_CONTEXT\n')
    provider = root / 'provider.ts'
    llm = REPO / 'packages/llm/llm/src/index.ts'
    provider.write_text('''
import { LlmAdapter } from IMPORT;
class Fixture extends LlmAdapter {
  providerInfo(provider) { return { id: provider, name: 'oz local smoke' }; }
  async listModels(provider) { return [{ provider, id: 'local', name: 'local', inputModalities: ['text'] }]; }
  async resolveModel(provider, model) { return { provider, id: model, name: model, inputModalities: ['text'], context: { contextWindow: 131072 } }; }
  async *stream(options) {
    const input = options.messages.flatMap(m => m.content).filter(b => b.type === 'text').map(b => b.text).join('');
    if (!input.includes('OZ_DSH_EDITOR_CONTEXT')) throw new Error('editor context missing');
    const text = input.includes('TURN_TWO') ? 'OZ_DSH_REPLY_TWO' : 'OZ_DSH_REPLY_ONE';
    yield { type: 'block-start', index: 0, blockType: 'text' };
    yield { type: 'text-delta', index: 0, text };
    yield { type: 'block-end', index: 0, block: { type: 'text', text } };
    yield { type: 'usage', usage: { inputTokens: 100, outputTokens: 10 } };
    yield { type: 'finish', reason: { kind: 'stop' } };
  }
}
export const name = 'oz-local-smoke';
export const inject = ['llm'];
export function apply(ctx) { ctx.llm.registerAdapter(['oz-local'], new Fixture()); }
'''.replace('IMPORT', json.dumps(str(llm))))
    patch = [
        {'id': 'llm-deepseek', 'disabled': True},
        {'id': 'llm-deepseek-account', 'disabled': True},
        {'id': 'acp', 'config': {'provider': 'oz-local', 'model': 'local'}},
        {'id': 'session-persistence-jsonl', 'config': {'root': str(root / 'sessions'), 'compression': 'none'}},
        {'insert': [{'id': 'oz-local-smoke', 'name': str(provider)}]},
    ]
    (home / 'cordis.patch.yml').write_text(json.dumps(patch))
    env = dict(os.environ, DSH_HOME=str(home), DSH_AGENTS_HOME=str(root / 'agents'), DSH_TELEMETRY_DISABLED='1')
    for key in ('OZ_ACP_COMMAND', 'OZ_AI_MOCK_DIR', 'DEEPSEEK_API_KEY', 'DEEPSEEK_BASE_URL'):
        env.pop(key, None)
    log = root / 'stderr.log'
    with log.open('w') as stderr:
        agent = subprocess.Popen(['pnpm', '--silent', 'dsh', '--profile', 'acp'], cwd=REPO, env=env,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, start_new_session=True)
        selector = selectors.DefaultSelector()
        selector.register(agent.stdout, selectors.EVENT_READ)
        pending = bytearray()

        def rpc(i, method, params):
            agent.stdin.write((json.dumps({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params}) + '\n').encode())
            agent.stdin.flush()
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if b'\n' not in pending:
                    if not selector.select(0.2):
                        continue
                    chunk = os.read(agent.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError('DSH disconnected: ' + log.read_text()[-3000:])
                    pending.extend(chunk)
                    continue
                line, _, rest = pending.partition(b'\n')
                pending[:] = rest
                value = json.loads(line)  # Runner banners must fail here.
                assert value.get('jsonrpc') == '2.0'
                if value.get('id') == i:
                    assert 'error' not in value, str(value.get('error')) + '\n' + log.read_text()[-4000:]
                    return value['result']
            raise TimeoutError(method)

        try:
            assert rpc(1, 'initialize', {'protocolVersion': 1, 'clientCapabilities': {}})['protocolVersion'] == 1
            session = rpc(2, 'session/new', {'cwd': str(work), 'mcpServers': []})['sessionId']
            assert session
            assert rpc(3, 'session/prompt', {'sessionId': session, 'prompt': [{'type': 'text', 'text': 'OZ_DSH_EDITOR_CONTEXT TURN_ONE'}]})['stopReason'] == 'end_turn'
            rpc(4, 'session/close', {'sessionId': session})
            print('PASS: real DSH initialize/new/prompt/close and stdout purity', flush=True)
        finally:
            selector.close()
            os.killpg(agent.pid, signal.SIGKILL)
            agent.wait()

    env.update(OZ_ACP_AGENT='deepseek', OZ_ACP_CWD=str(REPO), TERM='xterm-256color', COLORTERM='truecolor')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
    editor = subprocess.Popen([str(OZ / 'zig-out/bin/oz'), str(work / 'acp.txt')], cwd=work, env=env,
                              stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
                              preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    os.close(slave)
    try:
        wait_bytes(master, b'NORMAL')
        os.write(master, b' a')
        wait_bytes(master, b'AGENTS')
        os.write(master, b'TURN_ONE\r')
        wait_bytes(master, b'OZ_DSH_REPLY_ONE')
        os.write(master, b'TURN_TWO\r')
        wait_bytes(master, b'OZ_DSH_REPLY_TWO')
        os.write(master, b'\x1b')
        time.sleep(0.3)
        os.write(master, b':qa!\r')
        assert wait_editor_exit(editor, master, 15) == 0
        print('PASS: oz DeepSeek preset, context delivery and two real harness turns', flush=True)
    finally:
        if editor.poll() is None:
            os.write(master, b'\x03\x1b')
            time.sleep(0.3)
            os.write(master, b':qa!\r')
            try:
                wait_editor_exit(editor, master, 10)
            except subprocess.TimeoutExpired:
                os.killpg(editor.pid, signal.SIGKILL)
                editor.wait()
        os.close(master)
