"""Desktop IPC adapter. Only identity, state following and model settings methods."""
import asyncio,json,os,pathlib,sqlite3,stat,struct,sys,uuid,time,datetime
from desktop_protocol import DialError, Protocol, UPDATE, OWNER, FOLLOW
CODEX_DIR=pathlib.Path(os.environ.get('CODEX_HOME',str(pathlib.Path.home()/'.codex')))
_metadata_cache = None
_metadata_time = 0
_message_cache = {}
def latest_message(path):
    try:
        p=pathlib.Path(path)
        info=p.stat(); key=(info.st_mtime_ns,info.st_size)
        cached=_message_cache.get(path)
        if cached and cached[0]==key:return cached[1]
        # Read backwards; never load a whole conversation into memory.
        with p.open('rb') as f:
            position=info.st_size; remainder=b''; consumed=0
            while position>0 and consumed<2*1024*1024:
                size=min(65536,position);position-=size;consumed+=size
                f.seek(position);parts=(f.read(size)+remainder).split(b'\n')
                remainder=parts[0] if position else b''
                for line in reversed(parts[1:] if position else parts):
                    try:item=json.loads(line)
                    except (ValueError,UnicodeDecodeError):continue
                    payload=item.get('payload',{});text=None
                    if item.get('type')=='event_msg' and payload.get('type') in ('user_message','agent_message'):
                        text=payload.get('message')
                    elif item.get('type')=='response_item' and payload.get('type')=='message' and payload.get('role') in ('user','assistant'):
                        text=' '.join(c.get('text','') for c in payload.get('content',[]) if c.get('type') in ('input_text','output_text','text'))
                    if not isinstance(text,str) or not text.strip():continue
                    timestamp=item.get('timestamp')
                    try:stamp=datetime.datetime.fromisoformat(timestamp.replace('Z','+00:00')).timestamp()
                    except (AttributeError,TypeError,ValueError):stamp=None
                    result=(' '.join(text.split())[:280],stamp)
                    _message_cache[path]=(key,result)
                    return result
        result=(None,None);_message_cache[path]=(key,result);return result
    except OSError:return (None,None)
def threads():
    global _metadata_cache, _metadata_time
    if _metadata_cache is not None and time.monotonic()-_metadata_time < 10:return _metadata_cache
    files=list(CODEX_DIR.glob('state_*.sqlite'))+list((CODEX_DIR/'sqlite').glob('state_*.sqlite'))
    failures=[]
    for p in files:
        try:
            with sqlite3.connect(p.as_uri()+'?mode=ro',uri=True,timeout=1) as db:
                deadline=time.monotonic()+2
                db.set_progress_handler(lambda: int(time.monotonic()>deadline),1000)
                indexes={r[1] for r in db.execute('PRAGMA index_list(threads)')}
                if 'idx_threads_updated_at' not in indexes:raise RuntimeError('会话库缺少更新时间索引')
                rows=db.execute('SELECT id,substr(title,1,256),rollout_path,updated_at FROM threads INDEXED BY idx_threads_updated_at WHERE archived=0 ORDER BY updated_at DESC,id DESC LIMIT 100').fetchall()
            items=[]
            for i,t,path,updated in rows:
                message,stamp=latest_message(path)
                items.append({'id':i,'title':t or i,'latestMessage':message,'messageTime':stamp,'updatedAt':stamp if stamp is not None else updated})
            items.sort(key=lambda item:(item['updatedAt'],item['id']),reverse=True)
            _metadata_cache=items;_metadata_time=time.monotonic()
            return _metadata_cache
        except (sqlite3.Error,RuntimeError) as e:failures.append(str(e))
    raise RuntimeError('读取会话列表失败：'+('; '.join(failures) or '未找到会话数据库'))
def resolve_title(p):
    # Resolve independently from the preview list and its latest-100 limit.
    titles={str(t).strip() for t in p.get('titles',[]) if isinstance(t,str) and t.strip()}
    window=p.get('title','').strip()
    for suffix in (' — Codex',' - Codex',' — ChatGPT'):
        if window.endswith(suffix):window=window[:-len(suffix)]
    if window and window not in ('Codex','ChatGPT'):titles.add(window)
    if not titles:raise RuntimeError('当前窗口未提供会话标识或当前项标题。请展开 Codex 侧栏后重新读取。')
    files=list(CODEX_DIR.glob('state_*.sqlite'))+list((CODEX_DIR/'sqlite').glob('state_*.sqlite'))
    matches={}
    for path in files:
        with sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=1) as db:
            deadline=time.monotonic()+2
            db.set_progress_handler(lambda:int(time.monotonic()>deadline),1000)
            marks=','.join('?' for _ in titles)
            for tid,title in db.execute('SELECT id,title FROM threads WHERE archived=0 AND title IN ('+marks+')',tuple(titles)):
                matches[tid]={'id':tid,'title':title}
    if len(matches)!=1:raise RuntimeError('当前项标题未匹配到唯一会话，暂不切换。')
    return next(iter(matches.values()))
class ConnectionFailure(DialError):
    def __init__(self, message):
        super().__init__('disconnected', message)


class Desktop:
    def __init__(self):
        self.protocol = Protocol()
        self.pending = {}
        self.w = self.task = None
        self.client = 'initializing-client'
        self.states = {}
        self.owner = self.following = self.read_error = None

    async def connect(self):
        paths = [CODEX_DIR / 'ipc/ipc.sock',
                 pathlib.Path('/private/tmp/codex-ipc') / ('ipc-' + str(os.getuid()) + '.sock')]
        for path in paths:
            try:
                info = path.stat()
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                    continue
                self.r, self.w = await asyncio.wait_for(asyncio.open_unix_connection(str(path)), 2)
                self.task = asyncio.create_task(self.read())
                reply = await self.request('initialize', {'clientType': 'codex-dial'})
                self.client = reply['result']['clientId']
                return
            except (OSError, asyncio.TimeoutError, DialError):
                await self.close()
        raise ConnectionFailure('无法连接 Codex。请确认客户端已启动，完成更新后再重试。')

    async def send(self, message):
        if self.read_error:
            raise self.read_error
        if self.w is None or self.w.is_closing():
            raise ConnectionFailure('Codex 连接已断开。')
        data = json.dumps(message).encode()
        try:
            self.w.write(struct.pack('<I', len(data)) + data)
            await asyncio.wait_for(self.w.drain(), 1)
        except (OSError, asyncio.TimeoutError) as error:
            raise ConnectionFailure('Codex 连接已断开。') from error

    async def request(self, method, params, target=None):
        version = self.protocol.version(method)
        rid = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        message = dict(type='request', requestId=rid, sourceClientId=self.client,
                       method=method, params=params, version=version, timeoutMs=4000)
        if target:
            message['targetClientId'] = target
        try:
            await self.send(message)
            reply = await asyncio.wait_for(future, 5)
        except asyncio.TimeoutError as error:
            raise DialError('timeout', 'Codex 响应超时，请稍后重新读取。') from error
        finally:
            self.pending.pop(rid, None)
            if not future.done():
                future.cancel()
        if reply.get('resultType') != 'success':
            detail = str(reply.get('error', 'unknown'))
            if 'version' in detail:
                raise DialError('incompatible', 'Codex 接口版本不兼容，请完成客户端更新后重试。')
            if any(key in detail for key in ('no-client-found', 'client-not-found', 'client-disconnected')):
                raise DialError('owner_missing', '未找到负责此会话的 Codex 连接，请打开目标会话后重试。')
            if 'timeout' in detail.lower():
                raise DialError('timeout', 'Codex 响应超时，请稍后重新读取。')
            raise DialError('request_failed', 'Codex 未完成请求：' + detail)
        return reply

    async def broadcast(self, method, params, target):
        await self.send(dict(type='broadcast', method=method, sourceClientId=self.client,
                            version=self.protocol.version(method), params=params, targetClientIds=[target]))

    async def read(self):
        try:
            while True:
                length = struct.unpack('<I', await self.r.readexactly(4))[0]
                if length > 256 * 1024 * 1024:
                    raise DialError('incompatible', 'Codex 返回的会话状态超出可读取范围。')
                message = json.loads(await self.r.readexactly(length))
                if message.get('type') == 'response':
                    future = self.pending.get(message.get('requestId'))
                    if future and not future.done():
                        future.set_result(message)
                elif message.get('type') == 'client-discovery-request':
                    await self.send(dict(type='client-discovery-response', requestId=message['requestId'],
                                         response={'canHandle': False}))
                elif message.get('type') == 'broadcast' and message.get('method') == 'thread-stream-state-changed':
                    params = message.get('params', {})
                    tid = params.get('conversationId')
                    if tid != self.following or message.get('sourceClientId') != self.owner:
                        continue
                    change = params.get('change', {})
                    if change.get('type') == 'snapshot':
                        state = change.get('conversationState', {})
                        settings = state.get('latestThreadSettings') or {}
                        self.states[tid] = dict(model=settings.get('model', state.get('latestModel')),
                                                reasoningEffort=settings.get('effort', state.get('latestReasoningEffort')))
                    elif change.get('type') == 'patches':
                        state = self.states.get(tid)
                        if state is None:
                            continue
                        for patch in change.get('patches', []):
                            path = patch.get('path', [])
                            if isinstance(path, str):
                                path = path.strip('/').split('/')
                            value = patch.get('value')
                            if path in (['latestModel'], ['latestThreadSettings', 'model']):
                                state['model'] = value
                            elif path in (['latestReasoningEffort'], ['latestThreadSettings', 'effort']):
                                state['reasoningEffort'] = value
                            elif path == ['latestThreadSettings'] and isinstance(value, dict):
                                state.update(model=value.get('model'), reasoningEffort=value.get('effort'))
        except Exception as error:
            self.read_error = error if isinstance(error, DialError) else ConnectionFailure('Codex 接收连接中断。')
            self.states.clear()
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(self.read_error)

    async def state(self, tid):
        reply = await self.request(OWNER, {'hostId': 'local', 'conversationId': tid})
        self.owner = reply.get('handledByClientId')
        if not self.owner:
            raise DialError('owner_missing', '未找到负责此会话的 Codex 连接。')
        self.following = tid
        await self.broadcast(FOLLOW, {'hostId': 'local', 'conversationId': tid, 'following': True}, self.owner)
        for _ in range(40):
            if self.read_error:
                raise self.read_error
            state = self.states.get(tid)
            if state is not None:
                if not all(isinstance(state.get(key), str) and state[key] for key in ('model', 'reasoningEffort')):
                    raise DialError('incompatible', 'Codex 返回的档位信息格式无法识别，尚未更改会话。')
                return state
            await asyncio.sleep(.05)
        raise DialError('state_timeout', '已找到会话，但未收到档位信息。请回到目标会话后重新读取。')

    async def prepare(self, tid):
        for attempt in range(2):
            try:
                await self.connect()
                return await self.state(tid)
            except DialError as error:
                await self.close()
                if attempt or error.code not in ('disconnected', 'timeout', 'state_timeout', 'owner_missing'):
                    raise
                print(json.dumps({'method': 'transport/stage', 'stage': '重新连接当前会话'}), flush=True)

    async def handle(self, method, params):
        if method == 'desktop/list':
            global _metadata_time
            _metadata_time = 0
            return {'data': await asyncio.to_thread(threads)}
        if method == 'desktop/resolve':
            if params.get('id'):
                return {'id': params['id'], 'title': params.get('title') or params['id']}
            return await asyncio.to_thread(resolve_title, params)
        if method not in ('thread/read', 'thread/settings/update'):
            raise DialError('request_failed', '不支持的请求。')
        tid = params.get('threadId', '')
        try:
            uuid.UUID(tid)
        except (ValueError, TypeError, AttributeError):
            raise DialError('session_missing', '未识别到目标会话，请回到 Codex 会话后重新读取。')
        try:
            try:
                await asyncio.to_thread(self.protocol.refresh)
            except DialError:
                raise
            except (OSError, ValueError, KeyError, TypeError, struct.error) as error:
                raise DialError('incompatible', '无法读取 Codex 接口信息，请完成客户端更新后重试。') from error
            if method == 'thread/settings/update':
                self.protocol.check_write()
                if not isinstance(params.get('model'), str) or not params['model'] or params.get('effort') not in ('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'):
                    raise DialError('request_failed', '档位参数无效，尚未更改会话。')
            state = await self.prepare(tid)
            if method == 'thread/read':
                return {'thread': dict(state, id=tid, status={'type': 'idle'}),
                        'protocolVersion': self.protocol.version(UPDATE)}
            try:
                reply = await self.request(UPDATE, {'conversationId': tid, 'threadSettings':
                                           {'model': params['model'], 'effort': params['effort']}}, target=self.owner)
            except DialError as error:
                if error.code in ('timeout', 'disconnected'):
                    raise DialError('unconfirmed', '未收到切换确认，设置可能已生效。请重新读取；不会重复发送切换。') from error
                raise
            if reply.get('result', {}).get('applied') is False:
                raise DialError('not_applied', 'Codex 未应用这个档位，请重新读取后重试。')
            for _ in range(40):
                actual = self.states.get(tid, {})
                if actual.get('model') == params['model'] and actual.get('reasoningEffort') == params['effort']:
                    return {}
                if self.read_error:
                    break
                await asyncio.sleep(.05)
            raise DialError('unconfirmed', '已发送切换，但尚未确认新的档位。请重新读取；不会重复发送切换。')
        finally:
            await self.close()

    async def close(self):
        if self.following and self.w and not self.w.is_closing() and not self.read_error:
            try:
                await self.broadcast(FOLLOW, {'hostId': 'local', 'conversationId': self.following, 'following': False}, self.owner)
            except Exception:
                pass
        if self.w:
            self.w.close()
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except (Exception, asyncio.CancelledError):
                pass
        if self.w:
            try:
                await asyncio.wait_for(self.w.wait_closed(), .5)
            except (Exception, asyncio.CancelledError):
                pass
        self.w = self.task = None
        self.client = 'initializing-client'
        self.owner = self.following = self.read_error = None
        self.states.clear()


async def main():
    desktop = Desktop()
    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line:
                break
            request = json.loads(line)
            print(json.dumps({'method': 'transport/stage', 'stage': request['method']}), flush=True)
            try:
                reply = {'id': request['id'], 'result': await desktop.handle(request['method'], request['params'])}
            except Exception as error:
                reply = {'id': request['id'], 'error': {'code': getattr(error, 'code', 'request_failed'),
                                                       'message': str(error) or type(error).__name__}}
            print(json.dumps(reply), flush=True)
    finally:
        await desktop.close()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except Exception as error:
        print(str(error) or type(error).__name__, file=sys.stderr, flush=True)
        sys.exit(1)
