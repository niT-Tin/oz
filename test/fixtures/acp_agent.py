"""Deterministic ACP v1 peer: no network, models or credentials."""
import json
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else 'normal'
turn = 0
pending = None

def send(v):
    data = json.dumps(v, ensure_ascii=False) + '\n'
    # Exercise arbitrary pipe boundaries, including multibyte UTF-8.
    raw = data.encode()
    for i in range(0, len(raw), 7):
        sys.stdout.buffer.write(raw[i:i+7])
        sys.stdout.buffer.flush()

def result(rid, value):
    send({'jsonrpc': '2.0', 'id': rid, 'result': value})

def update(text, session='s1'):
    send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': session, 'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': text}}}})

def finish(rid):
    update('ACP_REPLY_%d 中文' % turn)
    result(rid, {'stopReason': 'end_turn'})

for line in sys.stdin:
    v = json.loads(line)
    method = v.get('method')
    rid = v.get('id')
    if method == 'initialize':
        assert v['params']['clientCapabilities'] == {}
        result(rid, {'protocolVersion': 2 if mode == 'version' else 1, 'agentCapabilities': {}})
    elif method == 'session/new':
        assert v['params']['cwd'].startswith('/')
        assert v['params']['mcpServers'] == []
        result(rid, {'sessionId': 's1'})
    elif method == 'session/prompt':
        assert v['params']['sessionId'] == 's1'
        assert v['params']['prompt'][0]['type'] == 'text'
        turn += 1
        if mode == 'disconnect':
            sys.exit(0)
        if mode == 'hang':
            time.sleep(30)
        elif mode == 'error':
            send({'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32000, 'message': 'fixture auth required'}})
        elif mode == 'malformed':
            print('{broken', flush=True)
        elif mode == 'oversized':
            sys.stdout.write('x' * (8 * 1024 * 1024 + 1) + '\n')
            sys.stdout.flush()
        elif mode == 'tool-progress':
            def tool(**change):
                send({'jsonrpc': '2.0', 'method': 'session/update',
                      'params': {'sessionId': 's1', 'update': dict(toolCallId='t1', **change)}})
            tool(sessionUpdate='tool_call', title='Bash', status='pending', rawInput={'command': 'pwd'})
            for _ in range(20):
                tool(sessionUpdate='tool_call_update', status='in_progress')
            tool(sessionUpdate='tool_call_update', status='completed',
                 content=[{'type': 'content', 'content': {'type': 'text', 'text': 'PROGRESS_RESULT'}}])
            finish(rid)
        elif mode == 'barrier':
            from pathlib import Path
            root = Path(sys.argv[2])
            label = sys.argv[3]
            update('START_' + label + '_' + str(turn))
            (root / (label + '-ready-' + str(turn))).write_text('ready\n')
            if label == 'A':
                release = root / ('release-A-' + str(turn))
                deadline = time.monotonic() + 25
                while not release.exists():
                    if time.monotonic() > deadline:
                        raise RuntimeError('fixture release barrier timed out')
                    time.sleep(.01)
            update('FINISH_' + label + '_' + str(turn))
            result(rid, {'stopReason': 'end_turn'})
            (root / (label + '-done-' + str(turn))).write_text('done\n')
        elif mode.startswith('permission'):
            pending = rid
            call = {'title': 'fixture command'}
            if mode != 'permission':
                call = {'title': 'Inspect source' if mode == 'permission-read' else 'Change source',
                        'kind': 'read' if mode in ('permission-read', 'permission-disguised') else 'edit',
                        'rawInput': {'path': 'source.txt'} if mode == 'permission-read' else {'command': 'rm source.txt'}}
            if mode == 'permission-missing-input':
                call = {'title': 'Unspecified action', 'kind': 'read'}
            elif mode == 'permission-top-command':
                call = {'title': 'Read source', 'kind': 'read', 'rawInput': {'path': 'source.txt'}, 'command': 'rm source.txt'}
            send({'jsonrpc': '2.0', 'id': 'permission/string-id' , 'method': 'session/request_permission', 'params': {'sessionId': 's1', 'toolCall': call, 'options': [{'optionId': 'yes', 'kind': 'allow_once'}, {'optionId': 'no', 'kind': 'reject_once'}]}})
        else:
            if mode == 'edit':
                from pathlib import Path
                Path('acp.txt').write_text('ACP_DISK_CHANGED\n')
            update('WRONG_SESSION', 'other')
            send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': 's1', 'update': {'sessionUpdate': 'tool_call', 'toolCallId': 't1', 'title': 'read file', 'status': 'in_progress'}}})
            finish(rid)
    elif method is None and rid == 'permission/string-id':
        outcome = v['result']['outcome']
        update('PERMISSION_' + outcome.get('optionId', 'cancelled'))
        finish(pending)
