const http = require('node:http');

function createServer() {
  return http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    if (req.method === 'GET' && (pathname === '/' || pathname === '/health')) {
      const payload = JSON.stringify({
        status: 'ok',
        service: 'siphon-companion',
        timestamp: new Date().toISOString()
      });
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      });
      res.end(payload);
      return;
    }

    const notFoundPayload = JSON.stringify({ error: 'Not Found' });
    res.writeHead(404, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(notFoundPayload)
    });
    res.end(notFoundPayload);
  });
}

if (require.main === module) {
  const port = parseInt(process.env.PORT, 10) || 3000;
  const host = '0.0.0.0';
  const server = createServer();

  server.listen(port, host, () => {
    console.log(`Siphon companion service running on http://${host}:${port}`);
  });

  const shutdown = () => {
    console.log('Received shutdown signal, closing server...');
    server.close(() => {
      console.log('Server closed successfully.');
      process.exit(0);
    });
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

module.exports = { createServer };
