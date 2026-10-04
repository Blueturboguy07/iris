import {
  CONTRACT_VERSION,
  createRevisionIdentity,
  sha256Digest,
} from "../../contracts/index.js";
import { PACKAGE_FORMAT, bytesToBase64 } from "../runtime.mjs";

export const DEMO_APP_ID = "iris.notes-demo";
export const DEMO_PROJECT_ID = "iris.notes-demo.mobile";

const ENCODER = new TextEncoder();

const V1_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Iris Notes Demo</title>
  <style>
    :root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#17181d;background:#f5f6fa}
    *{box-sizing:border-box}body{margin:0;padding:24px}main{max-width:540px;margin:0 auto}small{color:#6b6f7b;text-transform:uppercase;letter-spacing:.08em;font-weight:700}
    h1{margin:8px 0 6px;font-size:32px;letter-spacing:-.04em}p{margin:0 0 20px;color:#626672;line-height:1.5}
    textarea{width:100%;min-height:180px;padding:14px;border:1px solid #d8dbe4;border-radius:14px;background:white;color:#17181d;font:inherit;line-height:1.5;resize:vertical}
    button{width:100%;min-height:44px;margin-top:10px;border:0;border-radius:12px;background:#17181d;color:white;font:inherit;font-weight:700}
    #status{min-height:20px;margin-top:10px;color:#6b6f7b;font-size:12px}
  </style>
</head>
<body>
  <main>
    <small>Local demo · revision 1</small>
    <h1>A tiny offline note.</h1>
    <p>This note is stored by Iris outside the app revision, so a content update or rollback keeps it.</p>
    <textarea id="note" aria-label="Demo note" placeholder="Write something…"></textarea>
    <button id="save" type="button">Save on this device</button>
    <div id="status" role="status"></div>
  </main>
  <script>
    const note = document.querySelector('#note');
    const status = document.querySelector('#status');
    const save = document.querySelector('#save');
    IrisApp.storage.get('note').then((value) => { if (typeof value === 'string') note.value = value; }).catch((error) => { status.textContent = error.message; });
    save.addEventListener('click', async () => {
      try { await IrisApp.storage.set('note', note.value); status.textContent = 'Saved locally.'; }
      catch (error) { status.textContent = error.message; }
    });
  </script>
</body>
</html>`;

const V2_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Iris Notes Demo</title>
  <style>
    :root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#17181d;background:#eef1ff}
    *{box-sizing:border-box}body{margin:0;padding:24px}main{max-width:540px;margin:0 auto;padding:20px;border-radius:22px;background:#fff;box-shadow:0 12px 34px rgba(31,38,74,.10)}
    small{color:#6f70a4;text-transform:uppercase;letter-spacing:.08em;font-weight:700}h1{margin:8px 0 6px;font-size:32px;letter-spacing:-.04em}p{margin:0 0 20px;color:#626672;line-height:1.5}
    textarea{width:100%;min-height:180px;padding:14px;border:1px solid #d8dbe4;border-radius:14px;background:#fafaff;color:#17181d;font:inherit;line-height:1.5;resize:vertical}
    button{width:100%;min-height:44px;margin-top:10px;border:0;border-radius:12px;background:#5d6eea;color:white;font:inherit;font-weight:700}
    #status{min-height:20px;margin-top:10px;color:#656b85;font-size:12px}
  </style>
</head>
<body>
  <main>
    <small>Local demo · revision 2</small>
    <h1>Your note, clearer.</h1>
    <p>The app content changed. The note below still comes from the same Iris user-data namespace.</p>
    <textarea id="note" aria-label="Demo note" placeholder="Write something…"></textarea>
    <button id="save" type="button">Save note</button>
    <div id="status" role="status"></div>
  </main>
  <script>
    const note = document.querySelector('#note');
    const status = document.querySelector('#status');
    const save = document.querySelector('#save');
    IrisApp.storage.get('note').then((value) => { if (typeof value === 'string') note.value = value; }).catch((error) => { status.textContent = error.message; });
    save.addEventListener('click', async () => {
      try { await IrisApp.storage.set('note', note.value); status.textContent = 'Saved. This data survives version changes.'; }
      catch (error) { status.textContent = error.message; }
    });
  </script>
</body>
</html>`;

function manifest() {
  return {
    kind: "iris.mobile-shell.manifest",
    version: CONTRACT_VERSION,
    appId: DEMO_APP_ID,
    projectId: DEMO_PROJECT_ID,
    displayName: "Iris Notes Demo",
    runtime: {
      type: "web",
      entrypoint: "index.html",
      minShellVersion: "1.0.0",
    },
    capabilities: ["web.storage"],
    data: {
      namespace: DEMO_APP_ID,
      updatePolicy: "preserve",
    },
  };
}

async function buildRevision({ html, baseRevisionId, createdAt }) {
  const bytes = ENCODER.encode(html);
  const files = [
    {
      path: "index.html",
      sha256: await sha256Digest(bytes),
      bytes: bytes.byteLength,
      mediaType: "text/html",
    },
  ];
  const appManifest = manifest();
  const identity = await createRevisionIdentity({
    appId: DEMO_APP_ID,
    projectId: DEMO_PROJECT_ID,
    baseRevisionId,
    manifest: appManifest,
    files,
  });
  return {
    revision: {
      kind: "iris.mobile-shell.revision",
      version: CONTRACT_VERSION,
      appId: DEMO_APP_ID,
      projectId: DEMO_PROJECT_ID,
      revisionId: identity.revisionId,
      baseRevisionId,
      manifestHash: identity.manifestHash,
      contentHash: identity.contentHash,
      createdAt,
      manifest: appManifest,
      files,
    },
    bytes,
  };
}

function wrapDelivery({ revision, bytes, label, nonceByte }) {
  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: CONTRACT_VERSION,
    approvalId: `approval_notes_${label}`,
    requestId: null,
    requestNonce: null,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    approvedRevisionId: revision.revisionId,
    approvedContentHash: revision.contentHash,
    approvedAt: revision.createdAt,
  };
  const envelope = {
    kind: "iris.mobile-shell.delivery-envelope",
    version: CONTRACT_VERSION,
    envelopeId: `delivery_notes_${label}`,
    deliveryNonce: nonceByte.repeat(64),
    approvalId: approval.approvalId,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    revisionId: revision.revisionId,
    contentHash: revision.contentHash,
    issuedAt: revision.createdAt,
    revision,
  };
  return {
    format: PACKAGE_FORMAT,
    approval,
    envelope,
    files: [
      {
        path: "index.html",
        mediaType: "text/html",
        contentBase64: bytesToBase64(bytes),
      },
    ],
  };
}

let cachedPackages;

export async function buildDemoPackages() {
  if (!cachedPackages) {
    cachedPackages = (async () => {
      const first = await buildRevision({
        html: V1_HTML,
        baseRevisionId: null,
        createdAt: "2026-09-16T23:20:00.000Z",
      });
      const second = await buildRevision({
        html: V2_HTML,
        baseRevisionId: first.revision.revisionId,
        createdAt: "2026-09-16T23:21:00.000Z",
      });
      return Object.freeze({
        v1: wrapDelivery({ ...first, label: "v1", nonceByte: "a" }),
        v2: wrapDelivery({ ...second, label: "v2", nonceByte: "b" }),
      });
    })();
  }
  return cachedPackages;
}
