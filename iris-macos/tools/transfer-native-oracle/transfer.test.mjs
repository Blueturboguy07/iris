import { createRequire } from "node:module";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
import { transferNativeOracleCases } from "./cases.mjs";

// An installed oracle lives below an explicitly approved target. Refuse to
// guess a user profile or silently use the developer's application data.
const labTarget = process.env.IRIS_NITROAI_TARGET_ROOT;
if (!labTarget || !path.isAbsolute(labTarget)) {
  throw new Error("IRIS_NITROAI_TARGET_ROOT must name an explicit approved fixture root.");
}
const hasRuntime = (root) => fsSync.existsSync(path.join(root, "package.json")) &&
  fsSync.existsSync(path.join(root, "node_modules/electron"));
let target = null;
for (let root = import.meta.dirname; root !== path.dirname(root); root = path.dirname(root)) {
  if (hasRuntime(root)) {
    target = root;
    break;
  }
}
target ??= labTarget;
const { describe, expect, it } = await import(
  pathToFileURL(path.join(target, "node_modules/vitest/dist/index.js")).href,
);
const electron = createRequire(path.join(target, "package.json"))("electron");
const fixture = path.join(import.meta.dirname, "transfer-fixture.mjs");
const cases = new Map(transferNativeOracleCases.cases.map((entry) => [entry.id, entry]));

function caseOf(id) {
  const value = cases.get(id);
  if (!value) throw new Error(`Missing transfer case ${id}.`);
  return value;
}

function variantOf(caseId, variantId) {
  const value = (caseOf(caseId).variants ?? []).find((entry) => entry.id === variantId);
  if (!value) throw new Error(`Missing transfer variant ${caseId}/${variantId}.`);
  return value;
}

const clone = (value) => JSON.parse(JSON.stringify(value));

function withoutViewTimestamp(note) {
  const value = clone(note);
  delete value.lastOpenedAt;
  return value;
}

function comparableEnvelope(envelope) {
  const value = clone(envelope);
  value.folders.sort((left, right) => left.id.localeCompare(right.id));
  value.notes.sort((left, right) => left.id.localeCompare(right.id));
  value.notes = value.notes.map(withoutViewTimestamp);
  return value;
}

async function readEnvelope(filePath) {
  const value = JSON.parse(await fs.readFile(filePath, "utf8"));
  if (value?.format !== "nitroai-library" || value.version !== 1 ||
      !Array.isArray(value.notes) || !Array.isArray(value.folders)) {
    throw new Error("Transfer export is not a NitroAI library envelope v1.");
  }
  return value;
}

async function writeEnvelope(directory, name, value) {
  const filePath = path.join(directory, name);
  await fs.writeFile(filePath, JSON.stringify(value), "utf8");
  return filePath;
}

async function writeRaw(directory, name, value) {
  const filePath = path.join(directory, name);
  await fs.writeFile(filePath, value, "utf8");
  return filePath;
}

async function launch(profile, action, args = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env };
    delete env.ELECTRON_RUN_AS_NODE;
    const child = spawn(electron, [fixture, profile, action, JSON.stringify(args)], { env });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`Transfer fixture timed out during ${action}: ${stderr}`));
    }, 22000);
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => { clearTimeout(timer); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timer);
      const line = stdout.split(/\r?\n/).find((entry) => entry.startsWith("NITROAI_TRANSFER_RESULT "));
      if (code !== 0 || !line) {
        reject(new Error(`No transfer result for ${action}, exit ${code}: ${stderr}\n${stdout}`));
        return;
      }
      try {
        const result = JSON.parse(line.slice("NITROAI_TRANSFER_RESULT ".length));
        if (result.status !== "ok") {
          reject(new Error(`${action} ${result.status}: ${result.error}; profile: ${profile}`));
          return;
        }
        resolve(result.result);
      } catch (error) {
        reject(new Error(`Invalid ${action} result: ${error.message}`));
      }
    });
  });
}

describe("NitroAI native library transfer oracle", () => {
  it("readiness: seeds and reopens a real note and folder without transfer controls", async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "iris-transfer-readiness-"));
    let passed = false;
    try {
      const result = await launch(root, "readiness");
      expect(result.mode).toBe("readiness");
      expect(result.snapshot.notes).toHaveLength(1);
      expect(result.snapshot.notes[0].text).toContain("hidden native fixture");
      expect(result.snapshot.folderViews[0].visibleTitles).toEqual(["Transfer readiness note"]);
      passed = true;
    } finally {
      if (passed) await fs.rm(root, { recursive: true, force: true });
      else console.error(`Readiness failure artifacts retained: ${root}`);
    }
  }, 30000);

  it("preserves semantics, identities, folder membership, restart state, and atomic failure", async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "iris-transfer-oracle-"));
    let passed = false;
    const source = path.join(root, "source");
    const destination = path.join(root, "destination");
    const scratch = path.join(root, "scratch");
    await Promise.all([fs.mkdir(source), fs.mkdir(destination), fs.mkdir(scratch)]);

    try {
      const equalCase = caseOf("distinct-equal-name-time-folders");
      const collisionCase = caseOf("destination-folder-id-collision");
      const repeatCase = caseOf("same-content-reimport-after-open");
      const abortCase = caseOf("partial-transaction-abort");
      const invalidCase = caseOf("malformed-or-unsupported-envelope");
      const duplicateCase = variantOf("untrusted-duplicate-and-dangling-relationship", "duplicate-folder-id");
      const danglingCase = variantOf("untrusted-duplicate-and-dangling-relationship", "dangling-folder-reference");

      const sourceSeed = {
        noteTitle: "Transfer round-trip fixture",
        body: "Move this test note with its folder. Keep the original and preserve this exact text.",
        folderName: "Transfer acceptance folder",
      };
      const sourceRun = await launch(source, "seed-export", {
        seed: sourceSeed,
        exportPath: path.join(scratch, "source.json"),
      });
      const sourceEnvelope = await readEnvelope(sourceRun.export.path);
      expect(sourceEnvelope.notes).toHaveLength(1);
      expect(sourceEnvelope.folders).toHaveLength(1);

      const destinationRun = await launch(destination, "seed-export", {
        seed: { noteTitle: "Destination note", body: "Destination content must remain.", folderName: "Destination folder" },
        exportPath: path.join(scratch, "destination-before.json"),
      });
      const destinationBefore = await readEnvelope(destinationRun.export.path);
      expect(destinationBefore.notes).toHaveLength(1);
      expect(destinationBefore.folders).toHaveLength(1);

      const repeatPath = await writeEnvelope(scratch, "repeat.json", clone(repeatCase.input));
      const equalPath = await writeEnvelope(scratch, "equal-name-time.json", clone(equalCase.input));
      const abortPath = await writeEnvelope(scratch, "abort.json", clone(abortCase.input));
      const collisionInput = clone(collisionCase.input);
      collisionInput.folders[0].id = destinationBefore.folders[0].id;
      collisionInput.notes[0].folderId = destinationBefore.folders[0].id;
      const collisionPath = await writeEnvelope(scratch, "folder-id-collision.json", collisionInput);
      const malformedPath = await writeRaw(scratch, "malformed.json", invalidCase.rawInputs[0]);
      const wrongFormatPath = await writeRaw(scratch, "wrong-format.json", invalidCase.rawInputs[1]);
      const unsupportedVersionPath = await writeRaw(scratch, "unsupported-version.json", invalidCase.rawInputs[2]);
      const duplicatePath = await writeEnvelope(scratch, "duplicate-folder-id.json", clone(duplicateCase.input));
      const danglingPath = await writeEnvelope(scratch, "dangling-folder-reference.json", clone(danglingCase.input));

      // The fixture keeps this sequence in one Electron process: import once,
      // open, repeat, exercise invalid inputs, snapshot, abort, and snapshot.
      const journey = await launch(destination, "transfer-journey", {
        firstImport: [
          { path: sourceRun.export.path, expected: "accepted" },
          { path: repeatPath, expected: "accepted" },
        ],
        open: { titles: [repeatCase.input.notes[0].title], folders: [repeatCase.input.folders[0].name] },
        secondImport: [
          { path: repeatPath, expected: "accepted" },
          { path: collisionPath, expected: "accepted" },
          { path: equalPath, expected: "accepted" },
          { path: malformedPath, expected: "rejected" },
          { path: wrongFormatPath, expected: "rejected" },
          { path: unsupportedVersionPath, expected: "rejected" },
          { path: duplicatePath, expected: "rejected" },
          { path: danglingPath, expected: "rejected" },
        ],
        abortPath,
        beforeAbortPath: path.join(scratch, "destination-before-abort.json"),
        afterAbortPath: path.join(scratch, "destination-after-abort.json"),
        read: {
          titles: [sourceSeed.noteTitle, "Stable note", "Incoming note", "Same title", "Destination note"],
          folders: [sourceSeed.folderName, "Stable", "Incoming", "Research"],
        },
      });
      expect(journey.firstImports.map((entry) => entry.outcome)).toEqual(["accepted", "accepted"]);
      expect(journey.opened.notes).toHaveLength(1);
      expect(journey.opened.notes[0].text).toContain(repeatCase.input.notes[0].sourceText);
      expect(journey.secondImports.map((entry) => entry.outcome)).toEqual([
        "accepted", "accepted", "accepted", "rejected", "rejected", "rejected", "rejected", "rejected",
      ]);
      expect(journey.failed.imports[0].outcome).toBe("rejected");
      expect(journey.failed.imports[0].abort).toMatchObject({ triggered: true });
      expect(journey.failed.imports[0].abort.writes).toBeGreaterThanOrEqual(1);

      const beforeAbort = await readEnvelope(journey.beforeAbort.path);
      const afterAbort = await readEnvelope(journey.afterAbort.path);
      expect(beforeAbort.notes).toHaveLength(6);
      expect(beforeAbort.folders).toHaveLength(6);
      expect(comparableEnvelope(afterAbort)).toEqual(comparableEnvelope(beforeAbort));
      expect(withoutViewTimestamp(afterAbort.notes.find((note) => note.id === destinationBefore.notes[0].id)))
        .toEqual(withoutViewTimestamp(destinationBefore.notes[0]));
      expect(afterAbort.folders.find((folder) => folder.id === destinationBefore.folders[0].id))
        .toEqual(destinationBefore.folders[0]);
      // Re-export comparison covers sourceKind, sourceText, sourceMeta, every
      // block, timestamps, and IDs; only the view timestamp is intentionally ignored.
      const sourceNote = sourceEnvelope.notes[0];
      const importedSourceNote = beforeAbort.notes.find((note) => note.id === sourceNote.id);
      expect(importedSourceNote).toBeDefined();
      expect(withoutViewTimestamp(importedSourceNote)).toEqual(withoutViewTimestamp(sourceNote));
      expect(beforeAbort.folders.find((folder) => folder.id === sourceEnvelope.folders[0].id))
        .toEqual(sourceEnvelope.folders[0]);

      const stableId = repeatCase.input.notes[0].id;
      expect(beforeAbort.notes.filter((note) => note.id === stableId)).toHaveLength(1);
      expect(withoutViewTimestamp(beforeAbort.notes.find((note) => note.id === stableId)))
        .toEqual(withoutViewTimestamp(repeatCase.input.notes[0]));
      const equalFolders = beforeAbort.folders.filter((folder) =>
        folder.name === equalCase.input.folders[0].name && folder.createdAt === equalCase.input.folders[0].createdAt,
      );
      expect(equalFolders).toHaveLength(equalCase.input.folders.length);
      for (const folder of equalFolders) {
        const notes = beforeAbort.notes.filter((note) => note.folderId === folder.id);
        expect(notes).toHaveLength(1);
        const original = equalCase.input.notes.find((note) => note.folderId === folder.id);
        expect(original).toBeDefined();
        expect(withoutViewTimestamp(notes[0])).toEqual(withoutViewTimestamp(original));
      }

      const incomingNote = beforeAbort.notes.find((note) =>
        note.title === collisionInput.notes[0].title && note.sourceText === collisionInput.notes[0].sourceText,
      );
      expect(incomingNote).toBeDefined();
      if (!incomingNote) throw new Error("Collision note was not exported.");
      expect(incomingNote.folderId).not.toBe(destinationBefore.folders[0].id);
      expect(beforeAbort.folders.find((folder) => folder.id === incomingNote.folderId))
        .toMatchObject({ name: collisionInput.folders[0].name });
      for (const rejectedTitle of ["Abort A", "Abort B", "First", "Second", "Untrusted"]) {
        expect(beforeAbort.notes.some((note) => note.title === rejectedTitle)).toBe(false);
      }
      for (const rejectedFolder of ["Abort A", "Abort B", "First", "Second", "Known"]) {
        expect(beforeAbort.folders.some((folder) => folder.name === rejectedFolder)).toBe(false);
      }

      // A retained conflict must remain recognizable after the receiving
      // library itself travels onward, not only within its first profile.
      const onward = await launch(path.join(root, "onward"), "import-roundtrip", {
        libraryPath: journey.afterAbort.path,
        originalPath: collisionPath,
        beforePath: path.join(scratch, "onward-before-repeat.json"),
        afterPath: path.join(scratch, "onward-after-repeat.json"),
      });
      expect(comparableEnvelope(await readEnvelope(onward.before.path)))
        .toEqual(comparableEnvelope(afterAbort));
      expect(comparableEnvelope(await readEnvelope(onward.after.path)))
        .toEqual(comparableEnvelope(await readEnvelope(onward.before.path)));

      // Equal folder labels do not erase identity. Reordering an otherwise
      // unchanged file must not remap notes or manufacture duplicate copies.
      const equalRelated = clone(afterAbort);
      equalRelated.folders.forEach((folder) => {
        folder.name = "Same folder label";
        folder.createdAt = 1;
      });
      const reorderedRelated = clone(equalRelated);
      reorderedRelated.folders.reverse();
      reorderedRelated.notes.reverse();
      const orderedPath = await writeEnvelope(scratch, "equal-related-folders.json", equalRelated);
      const reorderedPath = await writeEnvelope(scratch, "reordered-related-folders.json", reorderedRelated);
      const reordered = await launch(path.join(root, "reordered-folders"), "import-roundtrip", {
        libraryPath: orderedPath, originalPath: reorderedPath,
        beforePath: path.join(scratch, "before-reordered-repeat.json"),
        afterPath: path.join(scratch, "after-reordered-repeat.json"),
      });
      expect(comparableEnvelope(await readEnvelope(reordered.before.path)))
        .toEqual(comparableEnvelope(equalRelated));
      expect(comparableEnvelope(await readEnvelope(reordered.after.path)))
        .toEqual(comparableEnvelope(equalRelated));

      // Reopen the receiving profile before repeating a retained conflict.
      // Then change an existing ID's content: ID-only skipping must not pass.
      const changedRepeat = clone(repeatCase.input);
      const changedNote = changedRepeat.notes[0];
      changedNote.sourceText = "Updated on the other computer";
      changedNote.blocks[0].text = changedNote.sourceText;
      changedNote.sourceMeta = { filename: "updated-on-other-computer.txt" };
      changedNote.updatedAt += 1000;
      const changedRepeatPath = await writeEnvelope(scratch, "changed-existing-note.json", changedRepeat);
      const restartedOnward = await launch(path.join(root, "onward"), "import-roundtrip", {
        libraryPath: collisionPath,
        originalPath: changedRepeatPath,
        beforePath: path.join(scratch, "onward-after-restart-repeat.json"),
        afterPath: path.join(scratch, "onward-after-changed-note.json"),
      });
      const afterRestartRepeat = await readEnvelope(restartedOnward.before.path);
      expect(comparableEnvelope(afterRestartRepeat)).toEqual(comparableEnvelope(afterAbort));
      const afterChangedNote = await readEnvelope(restartedOnward.after.path);
      expect(afterChangedNote.notes).toHaveLength(afterRestartRepeat.notes.length + 1);
      expect(comparableEnvelope(afterChangedNote).folders)
        .toEqual(comparableEnvelope(afterRestartRepeat).folders);
      for (const existingNote of afterRestartRepeat.notes) {
        expect(withoutViewTimestamp(afterChangedNote.notes.find((note) => note.id === existingNote.id)))
          .toEqual(withoutViewTimestamp(existingNote));
      }
      const retainedChangedNote = afterChangedNote.notes.find((note) =>
        note.sourceText === changedNote.sourceText,
      );
      expect(retainedChangedNote).toBeDefined();
      expect(retainedChangedNote.id).not.toBe(changedNote.id);
      expect(withoutViewTimestamp(retainedChangedNote)).toMatchObject({
        ...withoutViewTimestamp(changedNote), id: retainedChangedNote.id,
      });

      const restartedDestination = await launch(destination, "restart-snapshot", {
        exportPath: path.join(scratch, "destination-after-restart.json"),
        read: {
          titles: [sourceSeed.noteTitle, "Stable note", "Incoming note", "Same title", "Destination note"],
          folders: [sourceSeed.folderName, "Stable", "Incoming", "Research"],
        },
      });
      const afterRestart = await readEnvelope(restartedDestination.export.path);
      expect(comparableEnvelope(afterRestart)).toEqual(comparableEnvelope(beforeAbort));
      expect(restartedDestination.visible.notes.filter((note) => note.title === "Stable note")).toHaveLength(1);
      expect(restartedDestination.visible.folderViews.filter((folder) => folder.name === "Research"))
        .toHaveLength(2);

      const restartedSource = await launch(source, "restart-snapshot", {
        exportPath: path.join(scratch, "source-after-restart.json"),
        read: { titles: [sourceSeed.noteTitle], folders: [sourceSeed.folderName] },
      });
      const sourceAfterRestart = await readEnvelope(restartedSource.export.path);
      expect(comparableEnvelope(sourceAfterRestart)).toEqual(comparableEnvelope(sourceEnvelope));
      expect(restartedSource.visible.notes).toHaveLength(1);
      expect(restartedSource.visible.notes[0].text).toContain(sourceSeed.body);
      expect(restartedSource.visible.folderViews[0].visibleTitles).toEqual([sourceSeed.noteTitle]);
      passed = true;
    } finally {
      if (passed) await fs.rm(root, { recursive: true, force: true });
      else console.error(`Transfer failure artifacts retained: ${root}`);
    }
  }, 120000);
});
