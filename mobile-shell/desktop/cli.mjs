#!/usr/bin/env node

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

import {
  DurableReceiptStore,
  approveStagedRevision,
  createDeliveryPackage,
  handleEditRequest,
  stageRevision,
} from "./index.mjs";

function usage() {
  return `Usage:
  node mobile-shell/desktop/cli.mjs stage --registration FILE --review FILE --root DIR --current-base REVISION|null --out FILE
  node mobile-shell/desktop/cli.mjs approve --registration FILE --stage FILE --current-base REVISION|null --receipts FILE [--request FILE] --approve --out FILE
  node mobile-shell/desktop/cli.mjs deliver --registration FILE --approved FILE --current-base REVISION|null --receipts FILE [--delivery-nonce NONCE] --out FILE
  node mobile-shell/desktop/cli.mjs request --registration FILE --request FILE --current-base REVISION --receipts FILE
`;
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index];
    if (!token.startsWith("--")) throw new TypeError(`unexpected argument: ${token}`);
    const name = token.slice(2);
    if (name === "approve") {
      options.approve = true;
      continue;
    }
    const value = rest[index + 1];
    if (value === undefined || value.startsWith("--")) throw new TypeError(`missing value for --${name}`);
    options[name] = value;
    index += 1;
  }
  return { command, options };
}

function requireOption(options, name) {
  const value = options[name];
  if (typeof value !== "string" || !value) throw new TypeError(`--${name} is required`);
  return value;
}

function parseBase(value) {
  return value === "null" ? null : value;
}

async function readJson(path) {
  return JSON.parse(await readFile(resolve(path), "utf8"));
}

async function writeJsonAtomic(path, value) {
  const output = resolve(path);
  await mkdir(dirname(output), { recursive: true });
  const temp = `${output}.tmp-${process.pid}`;
  await writeFile(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temp, output);
}

async function main() {
  const { command, options } = parseArgs(process.argv.slice(2));
  if (!command || command === "help" || command === "--help") {
    process.stdout.write(usage());
    return;
  }
  const registration = await readJson(requireOption(options, "registration"));
  const currentRevisionId = parseBase(requireOption(options, "current-base"));

  if (command === "stage") {
    const review = await readJson(requireOption(options, "review"));
    const staged = await stageRevision({
      registration,
      buildOutputRoot: resolve(requireOption(options, "root")),
      review,
      currentRevisionId,
    });
    await writeJsonAtomic(requireOption(options, "out"), staged);
    process.stdout.write(`${JSON.stringify({ status: "staged", stageId: staged.stageId, revisionId: staged.revision.revisionId })}\n`);
    return;
  }

  if (command === "approve") {
    const stage = await readJson(requireOption(options, "stage"));
    const receiptStore = new DurableReceiptStore(resolve(requireOption(options, "receipts")));
    const editRequest = options.request ? await readJson(options.request) : null;
    const approved = await approveStagedRevision({
      registration,
      stage,
      currentRevisionId,
      receiptStore,
      editRequest,
      localApproval: options.approve === true,
    });
    await writeJsonAtomic(requireOption(options, "out"), approved);
    process.stdout.write(`${JSON.stringify({ status: "approved", approvalId: approved.approval.approvalId })}\n`);
    return;
  }

  if (command === "deliver") {
    const approvedStage = await readJson(requireOption(options, "approved"));
    const receiptStore = new DurableReceiptStore(resolve(requireOption(options, "receipts")));
    const pkg = await createDeliveryPackage({
      registration,
      approvedStage,
      currentRevisionId,
      receiptStore,
      ...(options["delivery-nonce"] ? { deliveryNonce: options["delivery-nonce"] } : {}),
    });
    await writeJsonAtomic(requireOption(options, "out"), pkg);
    process.stdout.write(`${JSON.stringify({ status: "packaged", envelopeId: pkg.envelope.envelopeId, revisionId: pkg.envelope.revisionId })}\n`);
    return;
  }

  if (command === "request") {
    const request = await readJson(requireOption(options, "request"));
    const receiptStore = new DurableReceiptStore(resolve(requireOption(options, "receipts")));
    const result = await handleEditRequest({ registration, request, currentRevisionId, receiptStore });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    if (result.status === "unsupported") process.exitCode = 2;
    return;
  }

  throw new TypeError(`unknown command: ${command}`);
}

main().catch((error) => {
  process.stderr.write(`${error?.code ? `${error.code}: ` : ""}${error?.message || String(error)}\n`);
  process.exitCode = 1;
});

