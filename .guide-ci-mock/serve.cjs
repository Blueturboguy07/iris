// Verify branch only: serve the not-yet-deployed nut-ai guide v16 (publik
// db6541c3, dumped with getIrisGuide exactly as the route serves config
// guides) on loopback, so guide-ci can run it before the publik deploy.
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const port = Number(process.argv[2] || 3999);
const files = {
  "/api/iris/apps": path.join(__dirname, "apps.json"),
  "/api/iris/guides/nut-ai": path.join(__dirname, "nut-ai.json"),
};
http
  .createServer((req, res) => {
    const p = new URL(req.url, "http://x").pathname;
    const f = files[p];
    console.log(new Date().toISOString(), req.method, req.url, f ? 200 : 404);
    if (!f) {
      res.writeHead(404, { "content-type": "application/json" });
      return res.end('{"error":"Guide not found."}');
    }
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    res.end(fs.readFileSync(f));
  })
  .listen(port, "127.0.0.1", () => console.log("serving on", port));
