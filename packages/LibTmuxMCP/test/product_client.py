"""Outer test of the installed launcher against an already-owned tmux server."""
import json
import os
import selectors
import subprocess
import sys
import time


def main():
    launcher, socket, tmux, pane, profile = sys.argv[1:]
    assert profile in ('2026-07-28', '2025-11-25')
    started = time.perf_counter()
    child = subprocess.Popen(
        [launcher, '--socket', socket, '--tmux', tmux, '--caller-pane', pane,
         '--allow-pane', pane, '--tool', 'list_panes', '--tool', 'capture_pane',
         '--tool', 'send_keys', '--tool', 'create_session', '--tool', 'teardown_session',
         '--tool', 'run_operations', '--tool', 'wait_for_text', '--tool', 'send_keys_and_wait', '--allow-create'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ, 'stdout')
    selector.register(child.stderr, selectors.EVENT_READ, 'stderr')
    pending, diagnostics = bytearray(), bytearray()

    def send(identity, method, params=None):
        values = dict(params or {})
        if profile == '2026-07-28':
            values['_meta'] = {'io.modelcontextprotocol/protocolVersion': profile,
                               'io.modelcontextprotocol/clientCapabilities': {},
                               **values.get('_meta', {})}
        data = {'jsonrpc': '2.0', 'method': method, 'params': values}
        if identity is not None:
            data['id'] = identity
        child.stdin.write(json.dumps(data).encode() + b'\n')

    def receive():
        deadline = time.perf_counter() + 45
        while b'\n' not in pending:
            remaining = deadline - time.perf_counter()
            assert remaining > 0, 'installed launcher response exceeded outer startup budget'
            for key, _ in selector.select(remaining):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    if key.data == 'stdout':
                        raise AssertionError('launcher exited before response: ' + diagnostics.decode(errors='replace'))
                elif key.data == 'stdout':
                    pending.extend(chunk)
                    assert len(pending) <= 8 * 1024 * 1024
                else:
                    diagnostics.extend(chunk)
                    assert len(diagnostics) <= 1024 * 1024
        line, _, rest = pending.partition(b'\n')
        pending[:] = rest
        return json.loads(line)

    def call(identity, name, arguments=None):
        send(identity, 'tools/call', {'name': name, 'arguments': arguments or {}})
        response = receive()
        assert response['id'] == identity and 'result' in response, response
        return response['result']

    try:
        if profile == '2026-07-28':
            send(1, 'server/discover')
            assert receive()['result']['supportedVersions'] == ['2026-07-28', '2025-11-25']
        else:
            send(1, 'initialize', {'protocolVersion': profile, 'capabilities': {},
                 'clientInfo': {'name': 'libtmux-public-consumer', 'version': '1'}})
            assert receive()['result']['protocolVersion'] == profile
            send(None, 'notifications/initialized')
        send(2, 'tools/list')
        listed = receive()['result']['tools']
        assert {tool['name'] for tool in listed} == {
            'list_panes', 'capture_pane', 'send_keys', 'create_session', 'teardown_session',
            'run_operations', 'wait_for_text', 'send_keys_and_wait'}
        assert all('inputSchema' in tool and 'outputSchema' in tool for tool in listed)
        listing = call(3, 'list_panes')
        assert not listing.get('isError', False), listing
        row, = listing['structuredContent']['panes']
        assert row['target']['paneId'] == pane and row['caller']
        capture = call(4, 'capture_pane')
        assert not capture.get('isError', False), capture
        assert capture['structuredContent']['terminalContent'] == 'data'
        sent = call(5, 'send_keys', {'keys': ['literal client input'], 'literal': True})
        assert not sent.get('isError', False), sent
        denied = call(6, 'capture_pane', {'target': {'paneId': '%999999', 'generation': row['target']['generation']}})
        assert denied['isError'] and denied['structuredContent']['error']['code'] == 'target_denied', denied
        sent_and_observed = call('echo', 'send_keys_and_wait',
                                 {'keys': ['observed-marker'], 'literal': True, 'text': 'observed-marker'})
        assert not sent_and_observed.get('isError', False), sent_and_observed
        assert sent_and_observed['structuredContent']['source'] == 'output'
        send('waiting', 'tools/call', {'name': 'wait_for_text',
             'arguments': {'text': 'never-produced-marker'},
             '_meta': {'progressToken': 'waiting'}})
        progress = receive()
        assert progress['method'] == 'notifications/progress', progress
        send('concurrent', 'tools/list')
        assert receive()['id'] == 'concurrent'
        send(None, 'notifications/cancelled', {'requestId': 'waiting'})
        created = call(7, 'create_session', {'name': 'client-owned', 'command': ['/bin/cat']})
        assert not created.get('isError', False), created
        send(8, 'server/discover' if profile == '2026-07-28' else 'ping')
        alive = receive()
        assert alive['id'] == 8 and 'result' in alive and 'error' not in alive, alive
        if profile == '2026-07-28':
            assert alive['result']['supportedVersions'] == ['2026-07-28', '2025-11-25']
        child.stdin.close()
        child.wait(timeout=10)
        assert child.returncode == 0, diagnostics.decode(errors='replace')
        assert not pending and not child.stdout.read(), 'unexpected late protocol output'
        diagnostics.extend(child.stderr.read())
        assert not diagnostics, diagnostics.decode(errors='replace')
        print(f'PASS installed MCP {profile} discovery/catalog/policy/tools/observation/cancel/EOF {time.perf_counter()-started:.3f}s')
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        selector.close()
        for pipe in (child.stdin, child.stdout, child.stderr):
            pipe.close()


if __name__ == '__main__':
    main()
