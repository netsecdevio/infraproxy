import platform, base64, http.client, json, os, pathlib, re, socket, struct, subprocess, sys, tempfile, time
root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='infraproxy-browser-test-',dir='/tmp') as temp:
    temp = pathlib.Path(temp)
    (temp/'main.swift').write_bytes((root/'Tests/BrowserHarness.swift').read_bytes())
    subprocess.run(['swiftc','-target',f'{platform.machine()}-apple-macosx15.5',str(root/'Sources/BrowserServer.swift'),str(root/'Sources/TerminalSession.swift'),str(root/'Sources/OperationsCommand.swift'),str(root/'Sources/BrowserKeys.swift'),str(root/'Sources/AgentAccess.swift'),str(temp/'main.swift'),'-o',str(temp/'server')], check=True)
    probe = socket.socket(); probe.bind(('127.0.0.1',0)); port = probe.getsockname()[1]; probe.close()
    (temp/'tmux').mkdir(mode=0o700)
    test_env=os.environ.copy();test_env['TMUX_TMPDIR']=str(temp/'tmux')
    process = subprocess.Popen([str(temp/'server'),str(root/'InfraProxy.app/Contents/Resources/Web'),str(root/'InfraProxy.app/Contents/MacOS/TerminalHost'),str(port),str(temp/'ready.json')], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=test_env)
    sockets=[]
    try:
        deadline=time.time()+10
        while not (temp/'ready.json').exists() and time.time()<deadline: time.sleep(.05)
        credentials=json.loads((temp/'ready.json').read_text()); key=credentials['key']
        host=f'127.0.0.1:{port}'; origin=f'http://{host}'
        def request(path, method='GET', body=None, cookie=None, extra=None):
            headers={'Host':host}
            if method=='POST': headers.update({'Origin':origin,'Content-Type':'application/json'})
            if cookie: headers['Cookie']=cookie
            if extra: headers.update(extra)
            c=http.client.HTTPConnection('127.0.0.1',port,timeout=3)
            c.request(method,path,body=json.dumps(body) if body is not None else None,headers=headers)
            r=c.getresponse(); result=(r.status,dict(r.getheaders()),r.read());c.close();return result
        assert request('/api/status')[0]==401
        assert request('/',extra={'Host':'attacker.example'})[0]==403
        page=request('/'); assert page[0]==200 and "frame-ancestors 'none'" in page[1]['Content-Security-Policy']
        assert request('/../Info.plist')[0]==401
        assert request('/api/login','POST',{'key':key},extra={'Origin':'https://attacker.example'})[0]==403
        assert request('/api/login','POST',{'key':'invalid'})[0]==401
        login=request('/api/login','POST',{'key':key});assert login[0]==200
        cookie=login[1]['Set-Cookie'].split(';')[0]
        assert 'HttpOnly' in login[1]['Set-Cookie'] and 'SameSite=Strict' in login[1]['Set-Cookie']
        secure=request('/api/login','POST',{'key':key},extra={'Host':'browser-test.example','Origin':'https://browser-test.example'})
        assert secure[0]==200 and 'Secure' in secure[1]['Set-Cookie']
        assert request('/api/login','POST',{'key':key},extra={'Host':'browser-test.example','Origin':'http://browser-test.example'})[0]==403
        assert request('/api/status',cookie=cookie)[0]==200
        assert request('/api/ticket','POST',{},cookie,{'Origin':'null'})[0]==403
        def ticket(session_id=None): return json.loads(request('/api/ticket','POST',{'id':session_id} if session_id else {},cookie)[2])['ticket']
        def websocket(ticket_value, with_cookie=True):
            s=socket.create_connection(('127.0.0.1',port),timeout=3);sockets.append(s)
            text=f'GET /terminal HTTP/1.1\r\nHost: {host}\r\nOrigin: {origin}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}\r\nSec-WebSocket-Protocol: infraproxy, {ticket_value}\r\n'
            if with_cookie: text+=f'Cookie: {cookie}\r\n'
            s.sendall((text+'\r\n').encode());headers=b''
            while not headers.endswith(b'\r\n\r\n'): headers+=s.recv(1)
            return s, headers
        denied,headers=websocket('forged');assert b'403' in headers;denied.close()
        denied,headers=websocket(ticket(),False);assert b'401' in headers;denied.close()
        token=ticket();ws,headers=websocket(token);assert b'101 Switching Protocols' in headers
        replay,headers=websocket(token);assert b'403' in headers;replay.close()
        def send(ws,value):
            payload=json.dumps(value).encode();mask=os.urandom(4)
            length=bytes([0x80|len(payload)]) if len(payload)<126 else bytes([0x80|126])+struct.pack('!H',len(payload))
            ws.sendall(b'\x81'+length+mask+bytes(c^mask[i%4] for i,c in enumerate(payload)))
        def read_exact(ws,n):
            result=b''
            while len(result)<n:
                chunk=ws.recv(n-len(result))
                if not chunk: raise EOFError()
                result+=chunk
            return result
        def until(ws,marker,seconds=6):
            received=b'';deadline=time.time()+seconds
            while marker not in received and time.time()<deadline:
                header=read_exact(ws,2);length=header[1]&127
                if length==126:length=struct.unpack('!H',read_exact(ws,2))[0]
                if length==127:length=struct.unpack('!Q',read_exact(ws,8))[0]
                received+=read_exact(ws,length)
            assert marker in received, 'Expected terminal output not received'
            return received
        send(ws,{'type':'input','data':"printf '\\137\\137IP_OK\\137\\137\\n'; tty\r"})
        output=until(ws,b'__IP_OK__');output+=until(ws,b'/dev/ttys') if b'/dev/ttys' not in output else b''
        assert b'/dev/ttys' in output
        send(ws,{'type':'resize','cols':100,'rows':35});send(ws,{'type':'input','data':'stty size\r'});until(ws,b'35 100')
        send(ws,{'type':'input','data':'sleep 10\r'});time.sleep(.2);send(ws,{'type':'input','data':'\x03'});send(ws,{'type':'input','data':"printf '\\137\\137INT_OK\\137\\137\\n'\r"});until(ws,b'__INT_OK__')
        send(ws,{'type':'input','data':"head -c 200000 /dev/zero | tr '\\0' x; printf '\\n\\137\\137BULK_OK\\137\\137\\n'\r"})
        until(ws,b'__BULK_OK__')
        assert len(json.loads(request('/api/status',cookie=cookie)[2])['sessions'])==1
        # Browser disconnect detaches, then a fresh ticket reconnects to the same PTY.
        session_id=json.loads(request('/api/status',cookie=cookie)[2])['sessions'][0]['id']
        ws.close();time.sleep(.1)
        assert json.loads(request('/api/status',cookie=cookie)[2])['sessions'][0]['state']=='running'
        ws,headers=websocket(ticket(session_id));assert b'101' in headers
        send(ws,{'type':'input','data':"printf '\\137\\137RESUME_OK\\137\\137\\n'\r"});until(ws,b'__RESUME_OK__')
        # tmux uses an isolated test socket directory; never touches user sessions.
        tmux_info=json.loads(request('/api/tmux','POST',{},cookie)[2])
        if tmux_info['available']:
            created=request('/api/sessions','POST',{'name':'tmux fixture','kind':'tmux'},cookie)
            assert created[0]==200
            created_id=json.loads(created[2])['id'];time.sleep(.3)
            available=json.loads(request('/api/tmux','POST',{},cookie)[2])['sessions'];assert len(available)==1
            attached=request('/api/sessions','POST',{'name':'tmux attached','kind':'tmux-attach','target':available[0]['id']},cookie)
            assert attached[0]==200
            request('/api/stop','POST',{'id':created_id},cookie)
            request('/api/stop','POST',{'id':json.loads(attached[2])['id']},cookie)
            print('PASS: isolated tmux discovery, creation, attachment, and detach')
        # Browser Ed25519 proof is authorized, origin-bound, and single-use.
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        private=Ed25519PrivateKey.from_private_bytes(base64.b64decode(credentials['privateKey']))
        challenge=json.loads(request('/api/key-challenge','POST',{})[2])
        signed={'id':challenge['id'],'publicKey':credentials['publicKey'],'signature':base64.b64encode(private.sign(base64.b64decode(challenge['challenge']))).decode()}
        assert request('/api/key-login','POST',signed)[0]==200
        assert request('/api/key-login','POST',signed)[0]==401
        def mcp(token,name,args=None):
            rpc={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':name,'arguments':args or {}}}
            status,_,body=request('/mcp','POST',rpc,extra={'Authorization':'Bearer '+token})
            assert status==200
            result=json.loads(body)['result'];return result,json.loads(result['content'][0]['text'])
        read=credentials['readToken'];control=credentials['controlToken']
        assert mcp(read,'device_info')[1]['scope']=='device-discovery'
        # Optional compatibility check with the official MCP Python SDK.
        import importlib.util
        if importlib.util.find_spec('mcp'):
            import asyncio, httpx2
            from mcp import ClientSession
            from mcp.client.streamable_http import streamable_http_client
            async def check_sdk():
                async with httpx2.AsyncClient(headers={'Authorization':'Bearer '+read}) as client:
                    async with streamable_http_client(origin+'/mcp',http_client=client) as streams:
                        async with ClientSession(*streams,read_timeout_seconds=5) as session:
                            initialized=await session.initialize()
                            assert initialized.serverInfo.name=='infravibe'
                            tools=await session.list_tools()
                            assert any(tool.name=='device_info' for tool in tools.tools)
                            result=await session.call_tool('device_info',{})
                            assert not result.isError
            asyncio.run(check_sdk())
            print('PASS: official MCP SDK initialize, tool discovery, and invocation')
        assert mcp(read,'session_create',{'name':'denied'})[0]['isError']
        assert mcp(read,'terminal_control_request')[1]['status']=='pending-local-approval'
        assert mcp(read,'session_create',{'name':'still denied'})[0]['isError']
        agent_session=mcp(control,'session_create',{'name':'Agent test'})[1]['id']
        assert mcp(control,'session_read',{'id':session_id})[0]['isError']
        mcp(control,'session_input',{'id':agent_session,'data':"printf '__AGENT_OK__\\n'\r"})
        time.sleep(.2)
        assert '__AGENT_OK__' in mcp(control,'session_read',{'id':agent_session})[1]['output']
        assert mcp(read,'sessions_list')[1]['sessions']==[]
        process.stdin.write(b'revoke-agent\n');process.stdin.flush();time.sleep(.1)
        assert request('/mcp','POST',{'jsonrpc':'2.0','id':1,'method':'ping'},extra={'Authorization':'Bearer '+control})[0]==401
        records=json.loads(request('/api/status',cookie=cookie)[2])['sessions']
        assert next(s for s in records if s['id']==agent_session)['state']=='exited'
        # Exited output survives cleanup of the browser socket and is retrievable.
        send(ws,{'type':'input','data':'exit\r'});time.sleep(.3)
        saved=json.loads(request('/api/output?id='+session_id,cookie=cookie)[2])
        assert saved['state']=='exited' and b'__RESUME_OK__' in base64.b64decode(saved['output'])
        process.stdin.write(b'rotate\n');process.stdin.flush();time.sleep(.15)
        assert request('/api/status',cookie=cookie)[0]==401
        ws.settimeout(3)
        while ws.recv(65536): pass
        # Deny duplicate framing headers rather than accepting an ambiguous request.
        s=socket.create_connection(('127.0.0.1',port));s.sendall(f'POST /api/login HTTP/1.1\r\nHost: {host}\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\nx'.encode());assert b'400' in s.recv(512);s.close()
        for _ in range(10): status=request('/api/login','POST',{'key':'invalid'})[0]
        assert status==429
        print('PASS: loopback server, host/origin protection, authentication cookies, CSRF, one-use WebSocket tickets, real PTY I/O, tty, resize, Ctrl-C, key revocation, malformed HTTP, login rate limit, reconnectable sessions, exited output, SSH challenge replay, scoped MCP tools, local approval, cross-session denial, and agent revocation')
    finally:
        for s in sockets:s.close()
        tmux=next((p for p in ['/opt/homebrew/bin/tmux','/usr/local/bin/tmux'] if pathlib.Path(p).exists()),None)
        if tmux: subprocess.run([tmux,'kill-server'],env=test_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        process.stdin.write(b'stop\n');process.stdin.flush();time.sleep(.15);process.terminate();process.wait(timeout=5)
