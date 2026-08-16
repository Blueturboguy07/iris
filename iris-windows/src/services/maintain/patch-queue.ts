//
// Local fixes against a moving upstream, without divergence hell. A fix Iris
// applied is not "the diff currently on disk" — it is a NAMED patch keyed to
// its recipe and signature, recorded here the moment it lands, so that when
// the app updates the queue can be popped, upstream pulled, and every named
// patch replayed one at a time. A conflict then belongs to ONE patch, not to
// an opaque merge — quilt's model, because forty years of distro packaging
// found nothing better.
//
// Two rules the replay honors, both paid for elsewhere first:
//   - a clean textual merge proves nothing; the verification gate re-runs
//     after every replay, unconditionally (the caller's job, not this file's —
//     see `verification-harness.ts`).
//   - when upstream lands its own version of a patch, the local one is
//     DROPPED and the supersession reported to the pool — fork hygiene and a
//     high-value signal ("stop proposing this, it's upstream now").
//
// Ported from `PatchQueue.swift`. Swift talks to `FileManager` directly, with
// only the base directory injected; this port keeps that shape but names the
// seam (`PatchQueueStorage`) rather than reaching for `node:fs` inline, so the
// class matches this codebase's "every OS-touching capability is an injected
// parameter with a real implementation and an explicit test fake" convention
// (see `autopilot/shell.ts`'s `ShellSession`/`MockShell`). `node:fs` is not a
// Windows-only API — it is used directly inside `FileSystemPatchQueueStorage`
// below, the same way `verification-commands.ts`'s real file-existence checks
// do — so this module still runs the real implementation on any host; the seam
// exists for testability and symmetry with the rest of `services/maintain/`,
// not because `fs` needs hiding from Windows.
//

import * as fs from "node:fs";
import * as path from "node:path";
import { maintainTrace } from "./trace";
import { tryRun, type MaintainShellRunner } from "./maintain-shell-runner";

/// One fix, as applied to a clone's working tree. Recorded the moment the fix
/// lands so a future upstream pull can pop it, replay it, and re-verify.
/// `appliedAt` is an ISO 8601 string, not a `Date` — this crosses a JSON file
/// boundary (`FileSystemPatchQueueStorage`), and `Date.parse` on read is
/// cheaper than a custom (de)serializer for one field.
export interface QueuedPatch {
  readonly recipeId: string;
  readonly signatureId: string;
  readonly appSlug: string;
  /// The branch the fix lives on in the clone.
  readonly branchName: string;
  /// The unified diff as applied, for replay after upstream moves.
  readonly patchText: string;
  /// The clone commit the patch was applied on top of.
  readonly baseCommit?: string;
  readonly appliedAt: string;
}

/// What replaying one queued patch against a moved-forward clone produced.
export type PatchReplayDisposition =
  /// Re-applied on the new base; the caller re-runs verification.
  | "replayed"
  /// Upstream now contains the change — dropped, supersession filed.
  | "supersededByUpstream"
  /// Three-way replay conflicted. The patch stays queued, unapplied; the
  /// caller surfaces it.
  | "conflicted";

/// The persistence seam: one queued patch per `(appSlug, recipeId)`. Narrow on
/// purpose — `PatchQueue` never touches a filesystem or a database directly,
/// only this interface, so it is testable with `InMemoryPatchQueueStorage` and
/// backed for real by `FileSystemPatchQueueStorage`.
export interface PatchQueueStorage {
  /// Every recipe id queued for one app, in whatever order the storage
  /// happens to enumerate them — `PatchQueue.patchesForAppSlug` is what
  /// imposes the applied-order sort, not this.
  list(appSlug: string): string[];
  read(appSlug: string, recipeId: string): QueuedPatch | undefined;
  write(patch: QueuedPatch): void;
  remove(appSlug: string, recipeId: string): void;
}

/// The real implementation: one JSON file per `(appSlug, recipeId)` under
/// `<baseDirectoryPath>/<appSlug>/<recipeId>.json`, matching Swift's
/// `Application Support/Iris/patch-queue` layout. The caller (`main/maintain/`)
/// passes `path.join(app.getPath("userData"), "patch-queue")` as the base —
/// this module never touches Electron itself, so it stays testable on any host
/// by pointing it at a temp directory.
export class FileSystemPatchQueueStorage implements PatchQueueStorage {
  constructor(private readonly baseDirectoryPath: string) {}

  list(appSlug: string): string[] {
    const directory = path.join(this.baseDirectoryPath, appSlug);
    let entries: string[];
    try {
      entries = fs.readdirSync(directory);
    } catch {
      return [];
    }
    return entries.filter((name) => name.endsWith(".json")).map((name) => name.slice(0, -".json".length));
  }

  read(appSlug: string, recipeId: string): QueuedPatch | undefined {
    try {
      const raw = fs.readFileSync(this.filePath(appSlug, recipeId), "utf-8");
      return JSON.parse(raw) as QueuedPatch;
    } catch {
      return undefined;
    }
  }

  write(patch: QueuedPatch): void {
    const directory = path.join(this.baseDirectoryPath, patch.appSlug);
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(this.filePath(patch.appSlug, patch.recipeId), JSON.stringify(patch, null, 2), "utf-8");
  }

  remove(appSlug: string, recipeId: string): void {
    try {
      fs.unlinkSync(this.filePath(appSlug, recipeId));
    } catch {
      // Already gone — removing a patch that was never queued is not an error.
    }
  }

  private filePath(appSlug: string, recipeId: string): string {
    return path.join(this.baseDirectoryPath, appSlug, `${recipeId}.json`);
  }
}

/// An in-memory fake for the vitest suite: no disk, so tests that only care
/// about queueing/sorting/removal logic never pay for real file I/O.
export class InMemoryPatchQueueStorage implements PatchQueueStorage {
  private readonly patchesByAppSlug = new Map<string, Map<string, QueuedPatch>>();

  list(appSlug: string): string[] {
    return Array.from(this.patchesByAppSlug.get(appSlug)?.keys() ?? []);
  }

  read(appSlug: string, recipeId: string): QueuedPatch | undefined {
    return this.patchesByAppSlug.get(appSlug)?.get(recipeId);
  }

  write(patch: QueuedPatch): void {
    const patchesForThisApp = this.patchesByAppSlug.get(patch.appSlug) ?? new Map<string, QueuedPatch>();
    patchesForThisApp.set(patch.recipeId, patch);
    this.patchesByAppSlug.set(patch.appSlug, patchesForThisApp);
  }

  remove(appSlug: string, recipeId: string): void {
    this.patchesByAppSlug.get(appSlug)?.delete(recipeId);
  }
}

export class PatchQueue {
  constructor(private readonly storage: PatchQueueStorage) {}

  // MARK: - Recording

  record(patch: QueuedPatch): void {
    this.storage.write(patch);
    maintainTrace(`patch queued for ${patch.appSlug} (recipe ${patch.recipeId})`);
  }

  /// Every patch queued for one app, oldest-applied first — the order replay
  /// walks the queue in.
  patchesForAppSlug(appSlug: string): QueuedPatch[] {
    return this.storage
      .list(appSlug)
      .map((recipeId) => this.storage.read(appSlug, recipeId))
      .filter((patch): patch is QueuedPatch => patch !== undefined)
      .sort((a, b) => Date.parse(a.appliedAt) - Date.parse(b.appliedAt));
  }

  remove(appSlug: string, recipeId: string): void {
    this.storage.remove(appSlug, recipeId);
  }

  // MARK: - Replay across an upstream update

  /// Replays every queued patch for one app after its clone moved to a new
  /// upstream commit. The caller has already popped the working tree back to
  /// clean upstream state; this walks the queue oldest-first, exactly as
  /// `patchesForAppSlug` orders it.
  async replayAll(
    appSlug: string,
    runner: MaintainShellRunner,
  ): Promise<{ readonly patch: QueuedPatch; readonly disposition: PatchReplayDisposition }[]> {
    const results: { patch: QueuedPatch; disposition: PatchReplayDisposition }[] = [];
    for (const patch of this.patchesForAppSlug(appSlug)) {
      const disposition = await this.replay(patch, runner);
      results.push({ patch, disposition });
    }
    return results;
  }

  private async replay(patch: QueuedPatch, runner: MaintainShellRunner): Promise<PatchReplayDisposition> {
    const patchFileName = `.iris-replay-${patch.recipeId}.patch`;
    const patchFilePath = path.join(runner.repoRootPath, patchFileName);
    try {
      try {
        fs.writeFileSync(patchFilePath, patch.patchText, "utf-8");
      } catch {
        return "conflicted";
      }

      // Already upstream? `--reverse --check` succeeding means the tree
      // ALREADY CONTAINS the patch — upstream landed an equivalent change.
      const reverseCheck = await tryRun(runner, `git apply --reverse --check ${patchFileName}`, {
        deadlineMs: 60_000,
      });
      if (reverseCheck?.succeeded === true) {
        this.remove(patch.appSlug, patch.recipeId);
        maintainTrace(`patch ${patch.recipeId} superseded by upstream — dropped`);
        return "supersededByUpstream";
      }

      const applied = await tryRun(runner, `git apply --3way ${patchFileName}`, { deadlineMs: 60_000 });
      if (applied?.succeeded === true) {
        return "replayed";
      }

      // Leave conflict markers out of the tree: a conflicted 3way can
      // half-land; reset so the tree stays honestly upstream.
      //
      // `git reset --hard HEAD`, not `git checkout -- .`: a failed `--3way`
      // apply leaves the conflicted path with THREE unmerged stages in the
      // index (`git apply --3way` implies `--index`), and `git checkout --
      // <path>` refuses to touch a path in that state ("error: path
      // 'feature.js' is unmerged") — it silently no-ops on exactly the file
      // this step exists to clean up, leaving the `<<<<<<< ours` / `=======`
      // / `>>>>>>> theirs` markers sitting in the working tree. This is a
      // real, proven divergence from the literal command text ported from
      // `PatchQueue.swift` / the recovered `dist/patch-queue.js`
      // (`"git checkout -- . && git clean -fd --quiet"`, byte-identical in
      // both) — caught by this file's own real-git-backed conflict test, not
      // a hypothetical. `git reset --hard HEAD` is the one command that
      // actually clears an unmerged index and restores the tracked file to
      // HEAD, so it is what the comment above (and Swift's own stated
      // intent — "the tree stays honestly upstream") actually requires. Per
      // the porting ground rules, this is BEHAVIOR parity: the documented
      // intent is preserved exactly; the literal command text is not.
      await tryRun(runner, "git reset --hard HEAD && git clean -fd --quiet", { deadlineMs: 120_000 });
      maintainTrace(`patch ${patch.recipeId} conflicted on replay — kept queued, tree reset`);
      return "conflicted";
    } finally {
      try {
        fs.unlinkSync(patchFilePath);
      } catch {
        // Best-effort cleanup, mirrors Swift's `try? FileManager...removeItem`.
      }
    }
  }
}
