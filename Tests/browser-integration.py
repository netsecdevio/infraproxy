import platform, base64, http.client, json, os, pathlib, re, socket, struct, subprocess, sys, tempfile, time
root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='infraproxy-browser-test-') as temp:
    temp = pathlib.Path(temp)
    (temp/'main.swift').write_bytes((root/'Tests/BrowserHarness.swift').read_bytes())
    subprocess.run(['swiftc','-target',f'{platform.machine()}-apple-macosx15.5',str(root/'Sources/BrowserServer.swift'),str(temp/'main.swift'),'-o',str(temp/'server')], check=True)
    probe = socket.socket(); probe.bind(('127.0.0.1',0)); port = probe.getsockname()[1]; probe.close()
    process = subprocess.Popen([str(temp/'server'),str(root/'InfraProxy.app/Contents/Resources/Web'),str(root/'InfraProxy.app/Contents/MacOS/TerminalHost'),str(port),str(temp/'ready.json')], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sockets=[]
    try:
        deadline=time.time()+10
        while not (temp/'ready.json').exists() and time.time()<deadline: time.sleep(.05)
        key=json.loads((temp/'ready.json').read_text())['key']
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
        def ticket(): return json.loads(request('/api/ticket','POST',{},cookie)[2])['ticket']
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
        process.stdin.write(b'rotate\n');process.stdin.flush();time.sleep(.15)
        assert request('/api/status',cookie=cookie)[0]==401
        ws.settimeout(3)
        while ws.recv(65536): pass
        # Deny duplicate framing headers rather than accepting an ambiguous request.
        s=socket.create_connection(('127.0.0.1',port));s.sendall(f'POST /api/login HTTP/1.1\r\nHost: {host}\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\nx'.encode());assert b'400' in s.recv(512);s.close()
        for _ in range(10): status=request('/api/login','POST',{'key':'invalid'})[0]
        assert status==429
        print('PASS: loopback server, host/origin protection, authentication cookies, CSRF, one-use WebSocket tickets, real PTY I/O, tty, resize, Ctrl-C, key revocation, malformed HTTP, and login rate limit')
    finally:
        for s in sockets:s.close()
        process.stdin.write(b'stop\n');process.stdin.flush();time.sleep(.15);process.terminate();process.wait(timeout=5)
