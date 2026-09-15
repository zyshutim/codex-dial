"""Desktop IPC adapter. Only identity, state following and model settings methods."""
import asyncio,json,os,pathlib,sqlite3,stat,struct,sys,uuid,time,datetime
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
class ConnectionFailure(RuntimeError):pass
class Desktop:
    def __init__(self):self.pending={};self.client='initializing-client';self.states={};self.owner=None;self.following=None;self.read_error=None
    async def connect(self):
        self.client='initializing-client';self.read_error=None;self.owner=None;self.following=None;self.states.clear()
        paths=[CODEX_DIR/'ipc/ipc.sock',pathlib.Path('/private/tmp/codex-ipc')/('ipc-'+str(os.getuid())+'.sock')]
        failures=[]
        for p in paths:
            try:
                s=p.stat()
                if not stat.S_ISSOCK(s.st_mode) or s.st_uid!=os.getuid():continue
                self.r,self.w=await asyncio.wait_for(asyncio.open_unix_connection(str(p)),2);break
            except (OSError,asyncio.TimeoutError) as e:failures.append(str(p)+': '+str(e))
        else:raise RuntimeError('连接地址不可用。'+ '; '.join(failures))
        self.task=asyncio.create_task(self.read())
        try:r=await self.request('initialize',{'clientType':'codex-dial'},version=0)
        except Exception as e:raise RuntimeError('IPC 注册失败：'+(str(e) or type(e).__name__))
        self.client=r['result']['clientId']
    async def send(self,m):
        b=json.dumps(m).encode();self.w.write(struct.pack('<I',len(b))+b);await self.w.drain()
    async def request(self,method,params,target=None,version=1):
        if self.read_error is not None:raise ConnectionFailure('桌面连接已断开：'+str(self.read_error))
        rid=str(uuid.uuid4());f=asyncio.get_running_loop().create_future();self.pending[rid]=f
        m={'type':'request','requestId':rid,'sourceClientId':self.client,'method':method,'params':params,'version':version,'timeoutMs':5000}
        if target:m['targetClientId']=target
        try:
            await self.send(m)
            r=await asyncio.wait_for(f,6)
        except asyncio.TimeoutError as e:
            raise ConnectionFailure('桌面请求超时：'+method) from e
        except (OSError,asyncio.IncompleteReadError) as e:
            raise ConnectionFailure('桌面连接中断：'+method) from e
        finally:self.pending.pop(rid,None)
        if r.get('resultType')!='success':raise RuntimeError('桌面接口未完成请求：'+str(r.get('error','unknown')))
        return r
    async def broadcast(self,method,params,target):
        await self.send({'type':'broadcast','method':method,'sourceClientId':self.client,'version':1,'params':params,'targetClientIds':[target]})
    async def read(self):
        try:
            while True:
                n=struct.unpack('<I',await self.r.readexactly(4))[0]
                if n>64*1024*1024:raise RuntimeError('桌面状态过大')
                m=json.loads(await self.r.readexactly(n))
                if m.get('type')=='response':
                    f=self.pending.get(m.get('requestId'))
                    if f and not f.done():f.set_result(m)
                elif m.get('type')=='client-discovery-request':
                    await self.send({'type':'client-discovery-response','requestId':m['requestId'],'response':{'canHandle':False}})
                elif m.get('type')=='broadcast' and m.get('method')=='thread-stream-state-changed':
                    p=m.get('params',{});tid=p.get('conversationId');change=p.get('change',{})
                    if tid!=self.following or m.get('sourceClientId')!=self.owner:continue
                    if change.get('type')=='snapshot':
                        state=change.get('conversationState',{});settings=state.get('latestThreadSettings') or {}
                        self.states[tid]={'model':settings.get('model',state.get('latestModel')),'reasoningEffort':settings.get('effort',state.get('latestReasoningEffort'))}
                    elif change.get('type')=='patches':
                        state=self.states.get(tid)
                        if state is None:continue
                        for patch in change.get('patches',[]):
                            path=patch.get('path',[])
                            if isinstance(path,str):path=path.strip('/').split('/')
                            v=patch.get('value')
                            if path==['latestModel'] or path==['latestThreadSettings','model']:state['model']=v
                            elif path==['latestReasoningEffort'] or path==['latestThreadSettings','effort']:state['reasoningEffort']=v
                            elif path==['latestThreadSettings'] and isinstance(v,dict):state.update(model=v.get('model'),reasoningEffort=v.get('effort'))
        except Exception as error:
            self.read_error=error
            self.states.clear()
            for f in self.pending.values():
                if not f.done():f.set_exception(ConnectionFailure('桌面接收连接中断：'+type(error).__name__))
    async def state(self,tid):
        r=await self.request('thread-owner-discovery',{'hostId':'local','conversationId':tid});owner=r['handledByClientId']
        if self.following!=tid or self.owner!=owner or tid not in self.states:
            if self.following:
                await self.broadcast('thread-stream-following-changed',{'hostId':'local','conversationId':self.following,'following':False},self.owner)
            self.following=tid;self.owner=owner;self.states.clear()
            await self.broadcast('thread-stream-following-changed',{'hostId':'local','conversationId':tid,'following':True},owner)
        for _ in range(40):
            if tid in self.states:return self.states[tid]
            await asyncio.sleep(.05)
        raise RuntimeError('已找到会话，但桌面未返回档位状态。请切回该会话后重试。')
    async def handle(self,method,p):
        if method=='desktop/list':
            global _metadata_time
            _metadata_time=0
            return {'data':await asyncio.to_thread(threads)}
        if method=='desktop/resolve':
            if p.get('id'):return {'id':p['id'],'title':p.get('title') or p['id']}
            return await asyncio.to_thread(resolve_title,p)
        tid=p['threadId']
        if method=='thread/read':
            try:state=await self.state(tid)
            except ConnectionFailure:
                # Only retry reads. A timed-out settings update may already have applied.
                print(json.dumps({'method':'transport/stage','stage':'读取连接失效，自动重连'}),flush=True)
                await self.close();await self.connect()
                state=await self.state(tid)
            return {'thread':dict(state,id=tid,status={'type':'idle'})}
        if method=='thread/settings/update':
            await self.state(tid)
            await self.request('thread-follower-update-thread-settings',{'conversationId':tid,'threadSettings':{'model':p['model'],'effort':p['effort']}},target=self.owner)
            for _ in range(40):
                state=self.states.get(tid,{})
                if state.get('model')==p['model'] and state.get('reasoningEffort')==p['effort']:return {}
                await asyncio.sleep(.05)
            raise RuntimeError('桌面已接受设置，但尚未收到一致的状态回显；请重新读取。')
        raise RuntimeError('Unsupported method')
    async def close(self):
        if self.following:
            try:await self.broadcast('thread-stream-following-changed',{'hostId':'local','conversationId':self.following,'following':False},self.owner)
            except:pass
        self.w.close()
        self.task.cancel()
        try:await self.task
        except (Exception,asyncio.CancelledError):pass
        try:await asyncio.wait_for(self.w.wait_closed(),.5)
        except (Exception,asyncio.CancelledError):pass
async def main():
    d=Desktop()
    try:
        print(json.dumps({'method':'transport/stage','stage':'IPC 连接及注册'}),flush=True)
        await d.connect()
        while True:
            line=await asyncio.to_thread(sys.stdin.readline)
            if not line:break
            r=json.loads(line)
            print(json.dumps({'method':'transport/stage','stage':r['method']}),flush=True)
            try:result={'id':r['id'],'result':await d.handle(r['method'],r['params'])}
            except Exception as e:result={'id':r['id'],'error':{'message':str(e) or type(e).__name__}}
            print(json.dumps(result),flush=True)
    finally:
        if hasattr(d,'w'):
            try:await d.close()
            except Exception:pass
try:asyncio.run(main())
except Exception as e:print(str(e) or type(e).__name__,file=sys.stderr,flush=True);sys.exit(1)
