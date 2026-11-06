// check-app-opened.cjs — reads what telemetry-listener.cjs recorded and checks it
// against publik telemetry v1: one `app_opened` event with the right fields and
// no others. Used only by .github/workflows/publik-build.yml.
//
//   node check-app-opened.cjs <requests.jsonl> <lines to skip> <app version> <os>
//
// Exit 0: exactly one correct `app_opened` came after the skipped lines.
"use strict";

const fs = require("node:fs");

const [requestsFile, linesToSkip, wantVersion, wantOs] = process.argv.slice(2);
const allLines = fs.existsSync(requestsFile)
  ? fs.readFileSync(requestsFile, "utf8").split("\n").filter(Boolean)
  : [];
const lines = allLines.slice(Number(linesToSkip) || 0);

const allowedFields = new Set(["v", "app", "install_id", "event", "app_version", "os", "arch"]);
const uuidVersion4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const problems = [];
let opened = 0;

for (const text of lines) {
  const request = JSON.parse(text);
  let body;
  try {
    body = JSON.parse(request.body);
  } catch {
    problems.push("a request body is not JSON");
    continue;
  }
  console.log(`${request.method} ${request.path} authorization=${request.authorization} ${request.body}`);
  if (body.event !== "app_opened") {
    problems.push(`unexpected event "${body.event}"`);
    continue;
  }
  opened += 1;
  if (request.method !== "POST") problems.push(`method is ${request.method}`);
  if (request.path !== "/api/v1/telemetry") problems.push(`path is ${request.path}`);
  if (request.origin) problems.push("the request has an Origin header (it did not come from native code)");
  if (!String(request.contentType).startsWith("application/json")) problems.push(`content type is ${request.contentType}`);
  if (body.v !== 1) problems.push(`v is ${body.v}`);
  if (body.app !== "iris") problems.push(`app is ${body.app}`);
  if (body.app_version !== wantVersion) problems.push(`app_version is ${body.app_version}, expected ${wantVersion}`);
  if (body.os !== wantOs) problems.push(`os is ${body.os}, expected ${wantOs}`);
  if (!uuidVersion4.test(String(body.install_id))) problems.push("install_id is not a lowercase UUID v4");
  if (body.arch !== undefined && body.arch !== "arm64" && body.arch !== "x64") problems.push(`arch is ${body.arch}`);
  for (const field of Object.keys(body)) {
    if (!allowedFields.has(field)) problems.push(`extra field "${field}"`);
  }
}

if (opened !== 1) problems.push(`expected one app_opened, saw ${opened}`);

if (problems.length > 0) {
  console.log("FAIL: " + problems.join("; "));
  process.exit(1);
}
console.log(`PASS: one app_opened for iris ${wantVersion} on ${wantOs}`);
