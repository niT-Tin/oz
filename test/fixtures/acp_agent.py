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
        elif mode == 'permission':
            pending = rid
            send({'jsonrpc': '2.0', 'id': 'permission/string-id', 'method': 'session/request_permission', 'params': {'sessionId': 's1', 'toolCall': {'title': 'fixture command'}, 'options': [{'optionId': 'yes', 'kind': 'allow_once'}, {'optionId': 'no', 'kind': 'reject_once'}]}})
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
