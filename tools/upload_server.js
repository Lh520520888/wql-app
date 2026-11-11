#!/usr/bin/env node
// WQL 上传接收端（本地验证用）
// 用法: node tools/upload_server.js [port]
// 手机端填: http://<电脑的局域网IP>:8080/upload
const http = require('http');
const fs = require('fs');
const path = require('path');

const port = parseInt(process.argv[2] || '8080', 10);
const outRoot = path.join(__dirname, '..', 'uploads');
fs.mkdirSync(outRoot, { recursive: true });

function safe(s) {
  return String(s || 'unknown').replace(/[^\w.\-]/g, '_');
}

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || !req.url.startsWith('/upload')) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('not found');
  }

  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const ct = req.headers['content-type'] || '';
    const m = /boundary=(.+)$/.exec(ct);
    if (!m) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      return res.end('no boundary');
    }

    const boundary = Buffer.from('--' + m[1]);
    const parts = [];
    let idx = body.indexOf(boundary);
    while (idx >= 0) {
      const next = body.indexOf(boundary, idx + boundary.length);
      if (next < 0) break;
      let part = body.slice(idx + boundary.length, next);
      if (part.slice(0, 2).toString() === '\r\n') part = part.slice(2);
      parts.push(part);
      idx = next;
    }

    const fields = {};
    let savedPath = null;
    let savedBytes = 0;

    for (const part of parts) {
      const sep = part.indexOf('\r\n\r\n');
      if (sep < 0) continue;
      const head = part.slice(0, sep).toString();
      let data = part.slice(sep + 4);
      if (data.slice(-2).toString() === '\r\n') data = data.slice(0, -2);

      const nameM = /name="([^"]+)"/.exec(head);
      const fileM = /filename="([^"]*)"/.exec(head);

      if (fileM) {
        const bundleDir = path.join(outRoot, safe(fields.bundle));
        const rel = String(fields.relative || fileM[1]).replace(/\\/g, '/');
        const dst = path.join(bundleDir, rel);
        fs.mkdirSync(path.dirname(dst), { recursive: true });
        fs.writeFileSync(dst, data);
        savedPath = dst;
        savedBytes = data.length;
      } else if (nameM) {
        fields[nameM[1]] = data.toString();
      }
    }

    const stamp = new Date().toISOString();
    console.log(`${stamp}  ${fields.bundle || '?'}  ${fields.relative || '?'}  ` +
                `${body.length} B  -> ${savedPath || '(no file)'}`);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, bytes: body.length, saved: savedPath }));
  });
});

server.listen(port, '0.0.0.0', () => {
  console.log(`WQL upload receiver listening on 0.0.0.0:${port}`);
  console.log(`POST http://<你的电脑局域网IP>:${port}/upload`);
  console.log(`落盘目录: ${outRoot}`);
});