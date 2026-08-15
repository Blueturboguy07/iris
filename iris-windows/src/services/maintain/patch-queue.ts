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
  /// ISO 8601. A string, not a `Date`, so a queued patch round-trips through
  /// `JSON.stringify`/`JSON.parse` with no custom codec — the same reason
  /// `account-service.ts`'s stored session fields are strings.
  readonly appliedAt: string;
}

/// One queued patch's outcome after its app's clone moved to a new upstream
/// commit. Mirrors Swift's `PatchReplayDisposition` enum — no associated
/// values, so a plain string union is the idiomatic TS shape.
export type PatchReplayDisposition =
  /// Re-applied on the new base; the caller re-runs verification.
  | "replayed"
  /// Upstream now contains the change — dropped, supersession filed.
  | "supersededByUpstream"
  /// Three-way replay conflicted. The patch stays queued, unapplied; the
  /// caller surfaces it.
  | "conflicted";

/// The storage seam `PatchQueue` is written against — one JSON record per
/// `(appSlug, recipeId)`. `list` returns the recipe ids known for an app in no
/// particular order; `PatchQueue` sorts by `appliedAt` itself.
export interface PatchQueueStorage {
  list(appSlug: string): readonly string[];
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

  list(appSlug: string): readonly string[] {
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

  list(appSlug: string): readonly string[] {
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
  patchesForAppSlug(appSlug: string): readonly QueuedPatch[] {
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
  ): Promise<readonly { readonly patch: QueuedPatch; readonly disposition: PatchReplayDisposition }[]> {
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
      await tryRun(runner, "git checkout -- . && git clean -fd --quiet", { deadlineMs: 120_000 });
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
