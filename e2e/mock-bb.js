// A tiny stand-in for a bb server, for driving the app end to end in a simulator.
// Serves a page that imitates the `handsfree` plugin's button, the slice of
// /api/v1 the app calls, and /ws change notifications. No dependencies.
//
//   node e2e/mock-bb.js [port]      POST /mock/reply makes the agent answer.

const { Buffer } = require('buffer');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');

const PORT = Number(process.argv[2] ?? 38886);
const THREAD = 'thr_mock';
const LOG = process.env.MOCK_LOG;
const events = [];
const sockets = new Set();
let active = false;

const log = (line) => {
  console.log(line);
  if (LOG) fs.appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`);
};

const thread = () => ({ id: THREAD, title: 'Mock thread', titleFallback: null, status: active ? 'active' : 'idle', projectId: 'prj_mock', updatedAt: Date.now() });

function push(type, data) {
  events.push({ seq: events.length + 1, type, data });
}

function notify() {
  const payload = Buffer.from(JSON.stringify({ type: 'changed', entity: 'thread', id: THREAD }));
  const frame = Buffer.concat([Buffer.from([0x81, payload.length]), payload]); // payloads stay < 126 bytes
  for (const s of sockets) s.write(frame);
}

function reply(text) {
  const id = `item_${events.length + 1}`;
  active = true;
  push('turn/started', {});
  push('item/completed', { item: { id, type: 'agentMessage', text } });
  push('turn/completed', {});
  active = false;
  notify();
}

const PAGE = `<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>
  body { background:#161616; color:#eee; font:17px -apple-system, system-ui; margin:0; padding:20px; }
  button { display:block; width:100%; margin:12px 0; padding:16px; font-size:18px; border:0; border-radius:10px; background:#2b2b2b; color:#fff; }
  #state { color:#7fd6a6; }
</style></head>
<body>
  <h2>Mock bb thread</h2>
  <p id="state">voice state: none</p>
  <button id="toggle">Talk hands-free</button>
  <button id="settings">Voice settings</button>
  <button id="reply">Simulate agent reply</button>
<script>
  const post = (msg) => window.ReactNativeWebView.postMessage(JSON.stringify(msg));
  document.getElementById('toggle').onclick = () => post({ type: 'bbvoice.toggle', threadId: '${THREAD}' });
  document.getElementById('settings').onclick = () => post({ type: 'bbvoice.settings' });
  document.getElementById('reply').onclick = () => fetch('/mock/reply', { method: 'POST' });
  const render = () => {
    const s = window.__BB_VOICE__ && window.__BB_VOICE__.state;
    document.getElementById('state').textContent = 'voice state: ' + (s ? s.phase : 'off');
  };
  window.addEventListener('bbvoice:state', render);
  render();
</script></body></html>`;

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  log(`${req.method} ${url.pathname}${url.search}`);
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const p = url.pathname;
    if (p === '/' || p.startsWith('/threads')) {
      res.writeHead(200, { 'content-type': 'text/html' });
      return res.end(PAGE);
    }
    if (p === '/mock/reply' && req.method === 'POST') {
      reply('Hello from the mock agent. The build passed and all tests are green. Let me know what to do next.');
      return json(res, 200, { ok: true });
    }
    if (p === '/api/v1/projects') return json(res, 200, [{ id: 'prj_mock', name: 'mock' }]);
    if (p === '/api/v1/threads') return json(res, 200, [thread()]);
    if (p === `/api/v1/threads/${THREAD}`) return json(res, 200, thread());
    if (p === `/api/v1/threads/${THREAD}/events`) {
      const limit = Number(url.searchParams.get('limit') ?? 100);
      const after = Number(url.searchParams.get('afterSeq') ?? 0);
      const rows = url.searchParams.get('order') === 'desc' ? [...events].reverse() : events.filter((e) => e.seq > after);
      return json(res, 200, rows.slice(0, limit));
    }
    if (p === `/api/v1/threads/${THREAD}/send` && req.method === 'POST') {
      log(`send ${body}`);
      return json(res, 200, { ok: true, delivery: 'sent' });
    }
    if (p === `/api/v1/threads/${THREAD}/stop`) return json(res, 200, { ok: true });
    json(res, 404, { message: 'not found' });
  });
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  log('ws open');
  sockets.add(socket);
  socket.on('data', (d) => {
    if ((d[0] & 0x0f) === 0x8) socket.end(); // close frame
  });
  socket.on('close', () => sockets.delete(socket));
  socket.on('error', () => sockets.delete(socket));
});

server.listen(PORT, () => log(`mock bb on :${PORT}`));
