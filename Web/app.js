'use strict';
const $ = id => document.getElementById(id);
const terminals = new Set();
let signedIn = false, poll;
async function api(path, body) {
  const options = {credentials:'same-origin', cache:'no-store'};
  if (body !== undefined) { options.method='POST'; options.headers={'Content-Type':'application/json'}; options.body=JSON.stringify(body); }
  const response = await fetch(path, options);
  if (!response.ok) { if(response.status===401 && path!=='/api/login') lock(); throw new Error(await response.text()); }
  return response.headers.get('content-type')?.includes('application/json') ? response.json() : response.text();
}
function node(tag, text, className) { const element=document.createElement(tag); if(text!==undefined) element.textContent=text; if(className) element.className=className; return element; }
function lock() { signedIn=false; clearInterval(poll); for(const close of [...terminals]) close(); $('login').hidden=false; $('dashboard').hidden=true; $('connection').textContent='Locked'; }
async function refresh() {
  const data=await api('/api/status');
  $('expiry').textContent=data.teleport || 'Unavailable'; $('version').textContent=`v${data.version || ''}`;
  const listeners=data.listeners || [];
  $('listener-count').textContent=listeners.filter(x=>x.listening).length;
  $('socket-count').textContent=listeners.reduce((sum,x)=>sum+x.sessions,0);
  $('listeners').replaceChildren(...listeners.map(x=>{const row=node('div',undefined,'row'); row.append(node('span',`${x.listening?'●':'○'} ${x.name}`),node('small',`localhost:${x.port} · ${x.sessions} sessions`));return row;}));
  $('sharing').replaceChildren(...(data.sharing || []).map(address=>{const row=node('div',undefined,'row'); row.append(node('span',address));return row;}));
  if(!data.sharing?.length) $('sharing').append(node('small','Local access only. Enable a provider in the Mac app’s Inbound tab.'));
  $('session-count').textContent=`${data.sessions.length} active`;
  $('sessions').replaceChildren(...data.sessions.map(session=>{const row=node('div',undefined,'row');row.append(node('span',`Terminal ${session.id.slice(0,8)}`));const end=node('button','End session','secondary');end.addEventListener('click',async()=>{try{await api('/api/stop',{id:session.id});await refresh();}catch(e){$('status').textContent=e.message;}});row.append(end);return row;}));
  if(!data.sessions.length) $('sessions').append(node('small','Start a terminal to work on this Mac.'));
}
async function unlock() { await refresh(); signedIn=true; $('login').hidden=true; $('dashboard').hidden=false; $('connection').textContent='Authenticated'; clearInterval(poll); poll=setInterval(()=>refresh().catch(e=>{$('status').textContent=e.message;}),5000); }
$('login-form').addEventListener('submit',async event=>{event.preventDefault();const key=$('access-key').value; $('access-key').value='';try{await api('/api/login',{key});$('login-error').textContent='';await unlock();}catch(e){$('login-error').textContent=e.message;}});
$('logout').addEventListener('click',async()=>{try{await api('/api/logout',{});}finally{lock();}});
$('new-terminal').addEventListener('click',async()=>{
  $('new-terminal').disabled=true;
  try {
    const {ticket}=await api('/api/ticket',{});
    const card=node('section',undefined,'card terminal-card'); const title=node('div',undefined,'section-title');const heading=node('h2','Connecting terminal…'); const end=node('button','Close'); title.append(heading,end); const surface=node('div',undefined,'terminal'); card.append(title,surface);$('terminals').append(card);
    const terminal=new Terminal({cursorBlink:true,linkHandler:{activate:()=>{}},scrollback:2000,fontSize:14,theme:{background:'#0d1117',foreground:'#e6edf4'}});const fit=new FitAddon.FitAddon();terminal.loadAddon(fit);terminal.open(surface);
    // No link/clipboard add-ons: remote terminal escape sequences cannot open URLs or modify the clipboard.
    terminal.parser.registerOscHandler(52,()=>true);
    const socket=new WebSocket(`${location.protocol==='https:'?'wss:':'ws:'}//${location.host}/terminal`,['infraproxy',ticket]);socket.binaryType='arraybuffer';
    let closed=false;
    const send=value=>{if(socket.readyState===WebSocket.OPEN) socket.send(JSON.stringify(value));};
    const resize=()=>{fit.fit();send({type:'resize',cols:Math.min(500,Math.max(2,terminal.cols)),rows:Math.min(500,Math.max(2,terminal.rows))});};
    const observer=new ResizeObserver(resize);observer.observe(surface);
    const close=()=>{if(closed)return;closed=true;observer.disconnect();socket.close();terminal.dispose();card.remove();terminals.delete(close);};terminals.add(close);end.addEventListener('click',close);
    socket.onopen=()=>{heading.textContent='Interactive terminal · this Mac';resize();terminal.focus();refresh().catch(()=>{});};
    socket.onmessage=event=>terminal.write(new Uint8Array(event.data));
    socket.onclose=()=>{heading.textContent='Terminal ended';observer.disconnect();$('status').textContent='Terminal disconnected. Create a new terminal to reconnect.';if(signedIn)refresh().catch(()=>{});};
    socket.onerror=()=>{$('status').textContent='Terminal connection failed. Sign in again or check the tunnel.';};
    terminal.onData(data=>{for(let start=0;start<data.length;start+=4096)send({type:'input',data:data.slice(start,start+4096)});});
  } catch(e) { $('status').textContent=e.message; } finally { $('new-terminal').disabled=false; }
});
(async()=>{
  const fragment=new URLSearchParams(location.hash.slice(1));let key=fragment.get('key');history.replaceState(null,'',location.pathname);
  try {if(key){await api('/api/login',{key});key=null;}await unlock();}catch(e){lock();if(fragment.has('key'))$('login-error').textContent='The access key expired. Open the browser again from InfraProxy.';}
})();
