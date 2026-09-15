"""Isolated local IPC tests. Never connect to or modify a real Codex session."""
import asyncio
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Resources'))
from desktop_protocol import Protocol, DialError, OWNER, FOLLOW, UPDATE, settings_contract
import desktop_transport as transport

HANDLER = ('case`' + UPDATE + '`:return t.params.activeTurnId==null?'
           '{method:t.method,result:{applied:await e.updateThreadSettingsForNextTurn('
           't.params.conversationId,t.params.threadSettings,t.params.condition)}}:'
           '(await e.updateThreadPermissions(t.params.conversationId,t.params.threadSettings,'
           't.params.activeTurnId),{method:t.method,result:{applied:!0}})}')


def archive(root, version=2, handler=HANDLER):
    versions = {OWNER: 1, FOLLOW: 1, UPDATE: version}
    content = (json.dumps(versions, separators=(',', ':')) + ';' + handler).encode()
    header = json.dumps({'files': {'.vite': {'files': {'build': {'files': {
        'renamed-bundle.js': {'offset': '0', 'size': len(content)}
    }}}}}}).encode()
    path = root / 'Contents/Resources/app.asar'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack('<IIII', 4, 8 + len(header), 4 + len(header), len(header)) + header + content)


class ProtocolTests(unittest.TestCase):
    def test_current_contract_and_renamed_locals(self):
        self.assertTrue(settings_contract(HANDLER))
        self.assertTrue(settings_contract(HANDLER.replace('t.', 'request$3.').replace('e.', 'manager.')))
        self.assertFalse(settings_contract(HANDLER.replace('t.params.condition', 't.params.otherCondition')))

    def test_upgrade_invalidates_cache_and_compatible_future_version(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'CODEX_APP_PATH': folder}):
            root = Path(folder)
            archive(root, 1)
            protocol = Protocol()
            self.assertTrue(protocol.refresh())
            self.assertFalse(protocol.refresh())
            self.assertEqual(protocol.version(UPDATE), 1)
            for version in (2, 3, 4):
                archive(root, version)
                self.assertTrue(protocol.refresh())
                protocol.check_write()
                self.assertEqual(protocol.version(UPDATE), version)

    def test_changed_future_contract_stops_write(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'CODEX_APP_PATH': folder}):
            archive(Path(folder), 4, HANDLER.replace('t.params.threadSettings', 't.params.settingsV4'))
            protocol = Protocol()
            protocol.refresh()
            with self.assertRaises(DialError) as caught:
                protocol.check_write()
            self.assertEqual(caught.exception.code, 'incompatible')

    def test_unreadable_bundle_is_incompatible(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'CODEX_APP_PATH': folder}):
            with self.assertRaises(DialError) as caught:
                Protocol().refresh()
            self.assertEqual(caught.exception.code, 'incompatible')


class FakeProtocol:
    def refresh(self):
        return False

    def version(self, method):
        return {OWNER: 1, FOLLOW: 1, UPDATE: 2, 'initialize': 0}[method]

    def check_write(self):
        pass


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='dial-')
        root = Path(self.folder.name)
        (root / 'ipc').mkdir()
        self.root_patch = patch.object(transport, 'CODEX_DIR', root)
        self.root_patch.start()
        self.desktop = transport.Desktop()
        self.desktop.protocol = FakeProtocol()
        self.messages = []
        self.connections = 0
        self.open_writers = set()
        self.settings = {}
        self.fail_discovery_once = False
        self.update_error = None
        self.disconnect_on_update = False
        self.server = await asyncio.start_unix_server(self.serve, path=str(root / 'ipc/ipc.sock'))

    async def asyncTearDown(self):
        await self.desktop.close()
        self.server.close()
        await self.server.wait_closed()
        for writer in list(self.open_writers):
            writer.close()
            await writer.wait_closed()
        self.root_patch.stop()
        self.folder.cleanup()

    async def serve(self, reader, writer):
        self.connections += 1
        owner = 'owner-' + str(self.connections)
        self.open_writers.add(writer)
        async def send(value):
            data = json.dumps(value).encode()
            writer.write(struct.pack('<I', len(data)) + data)
            await writer.drain()
        async def snapshot(tid):
            await send({'type': 'broadcast', 'method': 'thread-stream-state-changed', 'sourceClientId': owner,
                        'params': {'conversationId': tid, 'change': {'type': 'snapshot',
                        'conversationState': {'latestThreadSettings': self.settings.setdefault(tid, {'model': 'model-a', 'effort': 'medium'})}}}})
        try:
            while True:
                length = struct.unpack('<I', await reader.readexactly(4))[0]
                message = json.loads(await reader.readexactly(length))
                self.messages.append(message)
                method = message.get('method')
                params = message.get('params', {})
                if message['type'] == 'broadcast':
                    if method == FOLLOW and params['following']:
                        await snapshot(params['conversationId'])
                    continue
                reply = {'type': 'response', 'requestId': message['requestId'], 'resultType': 'success', 'result': {}}
                if method == 'initialize':
                    reply['result'] = {'clientId': 'dial-client'}
                elif method == OWNER:
                    if self.fail_discovery_once:
                        self.fail_discovery_once = False
                        reply.update(resultType='error', error='no-client-found')
                    else:
                        reply['handledByClientId'] = owner
                elif method == UPDATE:
                    if self.disconnect_on_update:
                        break
                    if self.update_error:
                        reply.update(resultType='error', error=self.update_error)
                    else:
                        self.settings[params['conversationId']] = params['threadSettings']
                        reply['result'] = {'applied': True}
                await send(reply)
                if method == UPDATE and not self.update_error:
                    await snapshot(params['conversationId'])
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()
            await writer.wait_closed()
            self.open_writers.discard(writer)

    async def read_thread(self, tid):
        return await self.desktop.handle('thread/read', {'threadId': tid})

    async def update(self):
        return await self.desktop.handle('thread/settings/update', {'threadId': '00000000-0000-0000-0000-000000000001', 'model': 'model-b', 'effort': 'high'})

    async def test_a_b_a_rediscovery_and_no_idle_connection(self):
        for digit in ('1', '2', '1'):
            tid = '00000000-0000-0000-0000-00000000000' + digit
            result = await self.read_thread(tid)
            self.assertEqual(result['thread']['id'], tid)
            self.assertIsNone(self.desktop.w)
            self.assertIsNone(self.desktop.task)
        self.assertEqual(self.connections, 3)
        follows = [m['params']['following'] for m in self.messages if m.get('method') == FOLLOW]
        await asyncio.sleep(.01)
        follows = [m['params']['following'] for m in self.messages if m.get('method') == FOLLOW]
        self.assertEqual(follows, [True, False] * 3)

    async def test_owner_disappears_before_read_retries_once(self):
        self.fail_discovery_once = True
        await self.read_thread('00000000-0000-0000-0000-000000000001')
        self.assertEqual(self.connections, 2)

    async def test_negotiated_version_and_exact_owner_for_update(self):
        await self.update()
        updates = [m for m in self.messages if m.get('method') == UPDATE]
        self.assertEqual(len(updates), 1)
        self.assertEqual(updates[0]['version'], 2)
        self.assertEqual(updates[0]['targetClientId'], 'owner-1')
        self.assertIsNone(self.desktop.w)

    async def test_update_timeout_is_not_replayed(self):
        self.update_error = 'timeout'
        with self.assertRaises(DialError) as caught:
            await self.update()
        self.assertEqual(caught.exception.code, 'unconfirmed')
        self.assertEqual(len([m for m in self.messages if m.get('method') == UPDATE]), 1)

    async def test_disconnect_after_write_is_not_replayed(self):
        self.disconnect_on_update = True
        with self.assertRaises(DialError) as caught:
            await self.update()
        self.assertEqual(caught.exception.code, 'unconfirmed')
        self.assertEqual(self.connections, 1)

    async def test_incompatible_update_has_distinct_error(self):
        self.update_error = 'request-version-mismatch'
        with self.assertRaises(DialError) as caught:
            await self.update()
        self.assertEqual(caught.exception.code, 'incompatible')

    async def test_unknown_contract_sends_nothing(self):
        def reject():
            raise DialError('incompatible', 'changed schema')
        self.desktop.protocol.check_write = reject
        with self.assertRaises(DialError):
            await self.update()
        self.assertEqual(self.connections, 0)

    async def test_invalid_session_sends_nothing(self):
        with self.assertRaises(DialError) as caught:
            await self.read_thread('not-a-thread')
        self.assertEqual(caught.exception.code, 'session_missing')
        self.assertEqual(self.connections, 0)


if __name__ == '__main__':
    unittest.main()
