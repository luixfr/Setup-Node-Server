const http = require("http");

const domain = process.env.DOMAIN || "your server";
const port   = parseInt(process.env.PORT || "3000", 10);

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Server Ready</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      background: #0f172a;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      color: #e2e8f0;
    }
    .card {
      text-align: center;
      padding: 3rem 4rem;
      border: 1px solid #334155;
      border-radius: 12px;
      background: #1e293b;
      max-width: 480px;
      width: 90%;
    }
    .dot {
      width: 14px; height: 14px;
      background: #22c55e;
      border-radius: 50%;
      display: inline-block;
      margin-bottom: 1.5rem;
      box-shadow: 0 0 0 4px rgba(34,197,94,0.2);
      animation: pulse 2s infinite;
    }
    @keyframes pulse {
      0%, 100% { box-shadow: 0 0 0 4px rgba(34,197,94,0.2); }
      50%       { box-shadow: 0 0 0 8px rgba(34,197,94,0.05); }
    }
    h1 { font-size: 1.5rem; margin-bottom: .75rem; color: #f8fafc; }
    p  { font-size: .9rem; color: #94a3b8; line-height: 1.6; }
    .domain { color: #38bdf8; }
    .stack  { margin-top: 2rem; display: flex; gap: 1rem; justify-content: center; flex-wrap: wrap; }
    .badge  {
      font-size: .75rem; padding: .25rem .75rem;
      border-radius: 999px; border: 1px solid #334155; color: #64748b;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="dot"></div>
    <h1>Server is ready</h1>
    <p>
      <span class="domain">${domain}</span><br/>
      Coming soon.
    </p>
  </div>
</body>
</html>`;

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(html);
});

server.listen(port, () => {
  console.log(`Placeholder server running on port ${port}`);
});
