import { exec, execSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { describe, expect, it } from "vitest";

import {
  MockMaintainShellRunner,
  type MaintainCommandResult,
  type MaintainRunOptions,
  type MaintainShellRunner,
} from "../src/services/maintain/maintain-shell-runner";
import {
  FileSystemPatchQueueStorage,
  InMemoryPatchQueueStorage,
  PatchQueue,
  type QueuedPatch,
} from "../src/services/maintain/patch-queue";

/**
 * Same two-tier coverage as `maintain-verification-harness.test.ts`: a real
 * git repository in a temp directory for the replay dispositions git itself
 * decides (superseded vs. conflicted are genuinely about what `git apply`
 * makes of the tree), and a scripted runner for exact command-sequence and
 * ordering assertions that would be fragile to pin against real git output.
 */

class RealGitMaintainShellRunner implements MaintainShellRunner {
  constructor(readonly repoRootPath: string) {}

  run(command: string, opts?: MaintainRunOptions): Promise<MaintainCommandResult> {
    const cwd = opts?.inSubdirectory ? path.join(this.repoRootPath, opts.inSubdirectory) : this.repoRootPath;
    const timeout = opts?.deadlineMs ?? 60_000;
    return new Promise((resolve) => {
      exec(command, { cwd, timeout, maxBuffer: 10 * 1024 * 1024 }, (error, stdout, stderr) => {
        const outputTail = `${stdout}${stderr}`.slice(-16_384);
        if (error === null) {
          resolve({ succeeded: true, exitCode: 0, outputTail });
          return;
        }
        const exitCode = typeof error.code === "number" ? error.code : 1;
        resolve({ succeeded: false, exitCode, outputTail });
      });
    });
  }
}

function makeTempDir(prefix: string): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function makeTempGitRepoWithFile(fileName: string, contents: string): string {
  const repoRootPath = makeTempDir("iris-maintain-pq-repo-");
  execSync("git init -q", { cwd: repoRootPath });
  execSync('git config user.email "iris-test@publikhq.com"', { cwd: repoRootPath });
  execSync('git config user.name "Iris Test"', { cwd: repoRootPath });
  fs.writeFileSync(path.join(repoRootPath, fileName), contents, "utf-8");
  execSync("git add -A", { cwd: repoRootPath });
  execSync('git commit -q -m "initial"', { cwd: repoRootPath });
  return repoRootPath;
}

/// Generates a real unified diff (via real `git diff`) that turns `fileName`
/// from its committed content into `newContents`, then leaves the repo clean
/// (the edit is reverted) so the caller decides what tree to replay it onto.
function capturePatchText(repoRootPath: string, fileName: string, newContents: string): string {
  fs.writeFileSync(path.join(repoRootPath, fileName), newContents, "utf-8");
  const patchText = execSync("git diff", { cwd: repoRootPath, encoding: "utf-8" });
  execSync(`git checkout -- ${fileName}`, { cwd: repoRootPath });
  return patchText;
}

function makeQueuedPatch(overrides: Partial<QueuedPatch> = {}): QueuedPatch {
  return {
    recipeId: "recipe-1",
    signatureId: "sig-1",
    appSlug: "cue",
    branchName: "iris/fix-sig-1-20260101",
    patchText: "diff --git a/x b/x\n",
    appliedAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

describe("PatchQueue.replayAll against a real git repository", () => {
  it(
    "replays cleanly onto a base that hasn't moved",
    async () => {
      const baseRepoRootPath = makeTempGitRepoWithFile("greeting.txt", "hello\n");
      const patchText = capturePatchText(baseRepoRootPath, "greeting.txt", "hello world\n");

      const storage = new InMemoryPatchQueueStorage();
      const queue = new PatchQueue(storage);
      queue.record(makeQueuedPatch({ patchText, appSlug: "greeter" }));

      const runner = new RealGitMaintainShellRunner(baseRepoRootPath);
      const results = await queue.replayAll("greeter", runner);

      expect(results[0].disposition).toBe("replayed");
      expect(fs.readFileSync(path.join(baseRepoRootPath, "greeting.txt"), "utf-8")).toBe("hello world\n");
      // Replayed patches stay queued — a future upstream move may need them again.
      expect(queue.patchesForAppSlug("greeter")).toHaveLength(1);
    },
    30_000,
  );

  it(
    "drops the patch and reports supersession when upstream already contains the fix",
    async () => {
      const baseRepoRootPath = makeTempGitRepoWithFile("greeting.txt", "hello\n");
      const patchText = capturePatchText(baseRepoRootPath, "greeting.txt", "hello world\n");
      const upstreamAlreadyFixedRepoRootPath = makeTempGitRepoWithFile("greeting.txt", "hello world\n");

      const storage = new InMemoryPatchQueueStorage();
      const queue = new PatchQueue(storage);
      queue.record(makeQueuedPatch({ patchText, appSlug: "greeter" }));

      const runner = new RealGitMaintainShellRunner(upstreamAlreadyFixedRepoRootPath);
      const results = await queue.replayAll("greeter", runner);

      expect(results[0].disposition).toBe("supersededByUpstream");
      expect(queue.patchesForAppSlug("greeter")).toHaveLength(0);
    },
    30_000,
  );

  it(
    "resets the tree and keeps the patch queued when replay conflicts",
    async () => {
      const baseRepoRootPath = makeTempGitRepoWithFile("greeting.txt", "hello\n");
      const patchText = capturePatchText(baseRepoRootPath, "greeting.txt", "hello world\n");
      const conflictingRepoRootPath = makeTempGitRepoWithFile("greeting.txt", "hola\n");

      const storage = new InMemoryPatchQueueStorage();
      const queue = new PatchQueue(storage);
      queue.record(makeQueuedPatch({ patchText, appSlug: "greeter" }));

      const runner = new RealGitMaintainShellRunner(conflictingRepoRootPath);
      const results = await queue.replayAll("greeter", runner);

      expect(results[0].disposition).toBe("conflicted");
      // The tree is reset, not left with half-applied conflict markers.
      const status = execSync("git status --porcelain", { cwd: conflictingRepoRootPath, encoding: "utf-8" });
      expect(status.trim()).toBe("");
      expect(fs.readFileSync(path.join(conflictingRepoRootPath, "greeting.txt"), "utf-8")).toBe("hola\n");
      expect(queue.patchesForAppSlug("greeter")).toHaveLength(1);
      // The ephemeral replay file never lingers, win or lose.
      const leftovers = fs.readdirSync(conflictingRepoRootPath).filter((name) => name.startsWith(".iris-replay-"));
      expect(leftovers).toHaveLength(0);
    },
    30_000,
  );
});

describe("PatchQueue.replayAll against a scripted runner", () => {
  const succeeded = (outputTail = ""): MaintainCommandResult => ({ succeeded: true, exitCode: 0, outputTail });
  const failed = (outputTail = ""): MaintainCommandResult => ({ succeeded: false, exitCode: 1, outputTail });

  // The mock never actually runs `git apply`, but `PatchQueue.replay` still
  // writes the ephemeral `.iris-replay-<recipeId>.patch` file for real (it is
  // plain `node:fs`, not something the runner mediates) — so these tests still
  // need a real directory for that file to land in and be cleaned up from.
  function makeTempRepoRootPath(): string {
    return makeTempDir("iris-maintain-pq-mock-");
  }

  it("replays when the reverse-check fails but the three-way apply succeeds", async () => {
    const repoRootPath = makeTempRepoRootPath();
    const storage = new InMemoryPatchQueueStorage();
    const queue = new PatchQueue(storage);
    queue.record(makeQueuedPatch({ recipeId: "r1", appSlug: "cue" }));

    const runner = new MockMaintainShellRunner([failed(), succeeded()], repoRootPath);
    const results = await queue.replayAll("cue", runner);

    expect(results).toEqual([{ patch: expect.objectContaining({ recipeId: "r1" }), disposition: "replayed" }]);
    expect(runner.commandsRun).toEqual([
      "git apply --reverse --check .iris-replay-r1.patch",
      "git apply --3way .iris-replay-r1.patch",
    ]);
    expect(queue.patchesForAppSlug("cue")).toHaveLength(1);
    expect(fs.readdirSync(repoRootPath)).toEqual([]);
  });

  it("supersedes and removes the patch when the reverse-check already succeeds", async () => {
    const repoRootPath = makeTempRepoRootPath();
    const storage = new InMemoryPatchQueueStorage();
    const queue = new PatchQueue(storage);
    queue.record(makeQueuedPatch({ recipeId: "r1", appSlug: "cue" }));

    const runner = new MockMaintainShellRunner([succeeded()], repoRootPath);
    const results = await queue.replayAll("cue", runner);

    expect(results[0].disposition).toBe("supersededByUpstream");
    // Short-circuits — never attempts the three-way apply once superseded.
    expect(runner.commandsRun).toEqual(["git apply --reverse --check .iris-replay-r1.patch"]);
    expect(queue.patchesForAppSlug("cue")).toHaveLength(0);
  });

  it("resets the tree and keeps the patch when both the reverse-check and the apply fail", async () => {
    const repoRootPath = makeTempRepoRootPath();
    const storage = new InMemoryPatchQueueStorage();
    const queue = new PatchQueue(storage);
    queue.record(makeQueuedPatch({ recipeId: "r1", appSlug: "cue" }));

    const runner = new MockMaintainShellRunner([failed(), failed(), succeeded()], repoRootPath);
    const results = await queue.replayAll("cue", runner);

    expect(results[0].disposition).toBe("conflicted");
    expect(runner.commandsRun).toEqual([
      "git apply --reverse --check .iris-replay-r1.patch",
      "git apply --3way .iris-replay-r1.patch",
      "git checkout -- . && git clean -fd --quiet",
    ]);
    expect(queue.patchesForAppSlug("cue")).toHaveLength(1);
  });

  it("replays the whole queue oldest-applied first", async () => {
    const repoRootPath = makeTempRepoRootPath();
    const storage = new InMemoryPatchQueueStorage();
    const queue = new PatchQueue(storage);
    queue.record(makeQueuedPatch({ recipeId: "newer", appSlug: "cue", appliedAt: "2026-02-01T00:00:00.000Z" }));
    queue.record(makeQueuedPatch({ recipeId: "older", appSlug: "cue", appliedAt: "2026-01-01T00:00:00.000Z" }));

    // Both patches supersede — one command apiece — purely to keep this test
    // about ORDER, not about disposition branching (covered above).
    const runner = new MockMaintainShellRunner([succeeded(), succeeded()], repoRootPath);
    const results = await queue.replayAll("cue", runner);

    expect(results.map((result) => result.patch.recipeId)).toEqual(["older", "newer"]);
    expect(runner.commandsRun).toEqual([
      "git apply --reverse --check .iris-replay-older.patch",
      "git apply --reverse --check .iris-replay-newer.patch",
    ]);
  });
});

describe("PatchQueue over an in-memory store", () => {
  it("sorts queued patches oldest-applied first, scoped to one app", () => {
    const storage = new InMemoryPatchQueueStorage();
    const queue = new PatchQueue(storage);
    queue.record(makeQueuedPatch({ recipeId: "b", appSlug: "cue", appliedAt: "2026-02-01T00:00:00.000Z" }));
    queue.record(makeQueuedPatch({ recipeId: "a", appSlug: "cue", appliedAt: "2026-01-01T00:00:00.000Z" }));
    queue.record(
      makeQueuedPatch({ recipeId: "other-app", appSlug: "nutcracker", appliedAt: "2025-01-01T00:00:00.000Z" }),
    );

    expect(queue.patchesForAppSlug("cue").map((patch) => patch.recipeId)).toEqual(["a", "b"]);
    expect(queue.patchesForAppSlug("nutcracker").map((patch) => patch.recipeId)).toEqual(["other-app"]);
  });

  it("removes a specific patch without disturbing the rest of the queue", () => {
    const storage = new InMemoryPatchQueueStorage();
    const queue = new PatchQueue(storage);
    queue.record(makeQueuedPatch({ recipeId: "a", appSlug: "cue" }));
    queue.record(makeQueuedPatch({ recipeId: "b", appSlug: "cue" }));

    queue.remove("cue", "a");

    expect(queue.patchesForAppSlug("cue").map((patch) => patch.recipeId)).toEqual(["b"]);
  });

  it("returns nothing for an app that was never queued", () => {
    const queue = new PatchQueue(new InMemoryPatchQueueStorage());
    expect(queue.patchesForAppSlug("never-queued")).toEqual([]);
  });
});

describe("FileSystemPatchQueueStorage", () => {
  function makeTempQueueDir(): string {
    return makeTempDir("iris-maintain-pq-fs-");
  }

  it("round-trips a patch through real JSON files on disk", () => {
    const baseDirectoryPath = makeTempQueueDir();
    const storage = new FileSystemPatchQueueStorage(baseDirectoryPath);
    const patch = makeQueuedPatch({ appSlug: "cue", recipeId: "r1" });

    storage.write(patch);

    expect(fs.existsSync(path.join(baseDirectoryPath, "cue", "r1.json"))).toBe(true);
    expect(storage.list("cue")).toEqual(["r1"]);
    expect(storage.read("cue", "r1")).toEqual(patch);
  });

  it("returns an empty list and an undefined read for an app that was never queued", () => {
    const storage = new FileSystemPatchQueueStorage(makeTempQueueDir());
    expect(storage.list("never-queued")).toEqual([]);
    expect(storage.read("never-queued", "r1")).toBeUndefined();
  });

  it("removes a patch file, and a repeated removal is a harmless no-op", () => {
    const baseDirectoryPath = makeTempQueueDir();
    const storage = new FileSystemPatchQueueStorage(baseDirectoryPath);
    storage.write(makeQueuedPatch({ appSlug: "cue", recipeId: "r1" }));

    storage.remove("cue", "r1");

    expect(storage.read("cue", "r1")).toBeUndefined();
    expect(() => storage.remove("cue", "r1")).not.toThrow();
  });

  it("drives a real PatchQueue exactly like the in-memory store does", () => {
    const storage = new FileSystemPatchQueueStorage(makeTempQueueDir());
    const queue = new PatchQueue(storage);
    queue.record(makeQueuedPatch({ recipeId: "b", appSlug: "cue", appliedAt: "2026-02-01T00:00:00.000Z" }));
    queue.record(makeQueuedPatch({ recipeId: "a", appSlug: "cue", appliedAt: "2026-01-01T00:00:00.000Z" }));

    expect(queue.patchesForAppSlug("cue").map((patch) => patch.recipeId)).toEqual(["a", "b"]);
  });
});
