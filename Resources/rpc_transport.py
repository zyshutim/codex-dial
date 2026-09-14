import asyncio,json,os,pathlib,tempfile,time,base64,hashlib,struct
BASE=pathlib.Path(__file__).resolve().parent
class Client:
 async def connect(self,path):
  self.r,self.w=await asyncio.open_unix_connection(path);self.i=0;self.pending={};self.events=[]
  key=base64.b64encode(os.urandom(16)).decode()
  self.w.write(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Version: 13\r\n\r\n').encode());await self.w.drain()
  h=await asyncio.wait_for(self.r.readuntil(b'\r\n\r\n'),5)
  assert b'101 Switching Protocols' in h,h
  accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
  assert accept.lower() in h.lower()
  self.task=asyncio.create_task(self.read())
  await self.call('initialize',{'clientInfo':{'name':'dial_socket_test','version':'0.1'},'capabilities':{'experimentalApi':True}})
  await self.send({'method':'initialized'})
 async def send(self,msg):
  b=json.dumps(msg).encode();n=len(b);mask=os.urandom(4)
  head=bytes([129,128|n]) if n<126 else bytes([129,254])+struct.pack('!H',n)
  self.w.write(head+mask+bytes(v^mask[i%4] for i,v in enumerate(b)));await self.w.drain()
 async def read(self):
  try:
   while True:
    h=await self.r.readexactly(2);n=h[1]&127
    if n==126:n=struct.unpack('!H',await self.r.readexactly(2))[0]
    elif n==127:n=struct.unpack('!Q',await self.r.readexactly(8))[0]
    mask=await self.r.readexactly(4) if h[1]&128 else None
    b=await self.r.readexactly(n)
    if mask:b=bytes(v^mask[i%4] for i,v in enumerate(b))
    if h[0]&15==8:return
    if h[0]&15!=1:continue
    m=json.loads(b)
    if 'id'in m and 'method'not in m:
     f=self.pending.get(m['id'])
     if f and not f.done():f.set_result(m)
    else:
     self.events.append(m)
     if m.get("method")=="thread/settings/updated":print(json.dumps(m),flush=True)
  except asyncio.IncompleteReadError:pass
 async def call(self,method,params):
  assert method in ['initialize','thread/read','thread/settings/update','thread/loaded/list']
  self.i+=1;f=asyncio.get_running_loop().create_future();self.pending[self.i]=f
  await self.send(dict(id=self.i,method=method,params=params));return await asyncio.wait_for(f,10)
 async def close(self):
  self.w.close();await self.w.wait_closed();self.task.cancel()
async def main():
 import sys
 client=Client()
 try:
  await client.connect(sys.argv[1])
  while True:
   line=await asyncio.to_thread(sys.stdin.readline)
   if not line:break
   request=json.loads(line)
   try:
    response=await client.call(request['method'],request['params'])
    response['id']=request['id'];print(json.dumps(response),flush=True)
   except Exception as error:
    print(json.dumps({'id':request['id'],'error':{'message':str(error) or type(error).__name__}}),flush=True)
 finally:
  if hasattr(client,'w'):await client.close()
try:asyncio.run(main())
except Exception as error:
 import sys
 print(str(error) or type(error).__name__,file=sys.stderr)
 sys.exit(1)
