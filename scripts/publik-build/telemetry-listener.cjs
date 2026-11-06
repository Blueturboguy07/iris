// telemetry-listener.cjs — a local stand-in for publik's telemetry endpoint.
//
// Used only by .github/workflows/publik-build.yml. The build is started on the
// runner with PUBLIK_TELEMETRY_URL pointed here, so the check never reaches
// publikhq.com. Each request becomes one JSON line in the output file. A key is
// never written: the line records only whether an Authorization header came.
//
//   node telemetry-listener.cjs <requests.jsonl> <port file> <seconds to live>
"use strict";

const fs = require("node:fs");
const http = require("node:http");

const [requestsFile, portFile, secondsToLive] = process.argv.slice(2);
if (!requestsFile || !portFile) {
  console.error("usage: telemetry-listener.cjs <requests.jsonl> <port file> <seconds to live>");
  process.exit(2);
}

const server = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    const line = {
      method: request.method,
      path: request.url,
      contentType: request.headers["content-type"] || null,
      origin: request.headers.origin || null,
      authorization: request.headers.authorization ? "present" : "absent",
      body: Buffer.concat(chunks).toString("utf8"),
    };
    fs.appendFileSync(requestsFile, JSON.stringify(line) + "\n");
    response.writeHead(204);
    response.end();
  });
});

// Port 0: the system picks a free port. The caller reads it from the port file.
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});

setTimeout(() => process.exit(0), (Number(secondsToLive) || 120) * 1000);
