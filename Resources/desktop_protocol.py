"""Read a local Codex protocol manifest as data; never execute bundled JavaScript."""
import json
import os
from pathlib import Path
import re
import struct

UPDATE = 'thread-follower-update-thread-settings'
OWNER = 'thread-owner-discovery'
FOLLOW = 'thread-stream-following-changed'


class DialError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def version_table(source):
    # Names/hashes of bundled JS files and minified variables are not contracts.
    matches = re.findall(r'\{(?:"[a-z][a-z0-9-]*":\d+,?)+\}', source)
    candidates = [json.loads(value) for value in matches if '"' + UPDATE + '"' in value]
    candidates = [value for value in candidates if all(key in value for key in (OWNER, FOLLOW, UPDATE))]
    if not candidates or any(value != candidates[0] for value in candidates[1:]):
        return None
    return candidates[0]


def settings_contract(source):
    # Accept renamed minified locals, not changed control flow or extra arguments.
    # This is the verified v2 handler; a future version using this same handler
    # can use its advertised version without a Dial rebuild.
    match = re.search(r'case`' + UPDATE + r'`:return ([\w$]+)\.params\.activeTurnId==null', source)
    if not match:
        return False
    request = match.group(1)
    tail = source[match.start():match.start() + 1200]
    receiver = re.search(r'await ([\w$]+)\.updateThreadSettingsForNextTurn\(', tail)
    if not receiver:
        return False
    manager = receiver.group(1)
    expected = ('case`' + UPDATE + '`:return R.params.activeTurnId==null?'
                '{method:R.method,result:{applied:await M.updateThreadSettingsForNextTurn('
                'R.params.conversationId,R.params.threadSettings,R.params.condition)}}:'
                '(await M.updateThreadPermissions(R.params.conversationId,R.params.threadSettings,'
                'R.params.activeTurnId),{method:R.method,result:{applied:!0}})')
    expected = expected.replace('R.', request + '.').replace('M.', manager + '.')
    return tail.startswith(expected + '}')


class Protocol:
    def __init__(self):
        self.identity = None
        self.versions = {}
        self.contract = False

    def refresh(self):
        root = os.environ.get('CODEX_APP_PATH')
        roots = [Path(root)] if root else [Path('/Applications/ChatGPT.app'), Path('/Applications/Codex.app')]
        archive = next((p / 'Contents/Resources/app.asar' for p in roots
                        if (p / 'Contents/Resources/app.asar').is_file()), None)
        if archive is None:
            raise DialError('incompatible', '找不到当前 Codex 的接口信息。请先启动 Codex。')
        info = archive.stat()
        identity = (str(archive), info.st_ino, info.st_size, info.st_mtime_ns)
        if self.identity == identity:
            return False
        with archive.open('rb') as stream:
            prefix = stream.read(16)
            if len(prefix) != 16:
                raise DialError('incompatible', 'Codex 接口信息不完整，请完成客户端更新后重试。')
            size = struct.unpack_from('<I', prefix, 12)[0]
            if not 0 < size < 32 * 1024 * 1024:
                raise DialError('incompatible', '无法识别当前 Codex 的资源格式。')
            header = json.loads(stream.read(size))
            base = 8 + struct.unpack_from('<I', prefix, 4)[0]
            def entries(files, prefix=''):
                for name, value in files.items():
                    path = prefix + '/' + name
                    if 'files' in value:
                        yield from entries(value['files'], path)
                    elif path.startswith('/.vite/build/') and path.endswith('.js') and 'offset' in value:
                        yield path, value
            tables, contract = [], False
            for path, value in entries(header['files']):
                if value['size'] > 48 * 1024 * 1024:
                    continue
                stream.seek(base + int(value['offset']))
                source = stream.read(value['size']).decode('utf-8')
                table = version_table(source)
                if table:
                    tables.append(table)
                contract = contract or settings_contract(source)
            if not tables or any(table != tables[0] for table in tables[1:]):
                raise DialError('incompatible', '当前 Codex 接口无法确认，尚未更改会话。')
            after = archive.stat()
            if (after.st_ino, after.st_size, after.st_mtime_ns) != (info.st_ino, info.st_size, info.st_mtime_ns):
                raise DialError('incompatible', 'Codex 正在更新，请更新完成后重试。')
        self.versions, self.contract, self.identity = tables[0], contract, identity
        return True

    def version(self, method):
        if method == 'initialize':
            return 0
        if method not in self.versions:
            raise DialError('incompatible', '当前 Codex 不提供所需接口：' + method)
        return self.versions[method]

    def check_write(self):
        version = self.version(UPDATE)
        # v1 is the original verified model/effort contract. Later versions must
        # still expose the exact known optional-condition handler above.
        if version != 1 and not self.contract:
            raise DialError('incompatible', 'Codex 设置接口已变化（v%d），无法确认参数兼容，尚未更改会话。' % version)
