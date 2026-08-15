/**
 * install-provenance.ts
 *
 * The Windows port of
 * `iris-macos/leanring-buddy/InstallProvenanceStore.swift`.
 *
 * How did this app get onto this machine? Maintain mode's whole permission to
 * touch code hangs on the answer: a guide-built source clone may be patched
 * locally (the user already runs an unsigned local build — patching changes
 * nothing about the trust boundary), a signed download is NEVER patched (Iris
 * invalidating a notarized/signed binary would be vandalism), and unknown
 * provenance is treated as signed, because failing closed is the only honest
 * default for a question this consequential.
 *
 * Provenance is RECORDED at guide completion, not inferred later — the same
 * "never guess" invariant the macOS `AppInventoryService` holds for bundle
 * identity, and the same one this file holds for install identity.
 *
 * INTERLOCK (not this task's file, flagged per the porting spec's ground
 * rules): recording a `guide_source_clone` provenance needs `canonicalRepo`
 * and the pinned-commit at recipe completion, which
 * `services/autopilot/recipe.ts`'s `InstallRecipe`/`RecipeOutput` do not
 * currently carry, and `main/autopilot-controller.ts` does not yet call this
 * store on a successful `RunnerStatus.finished`. Whoever wires that up calls
 * `InstallProvenanceStore.recordGuideSourceClone` at that moment; nothing in
 * this file assumes it has already happened.
 *
 * This file is pure: like `install-identity.ts`, it never imports `electron`.
 * The one filesystem check it needs — "does `<clonePath>/.git` exist?" — is a
 * plain `node:fs` call, which is not Electron-specific and already runs
 * identically on the Mac dev machine and on windows-latest CI, so it is
 * provided here as the real default rather than pushed into `main/`; it is
 * still injectable (mirroring `checkResponsive` in the porting spec's
 * `hang-probe.ts`) so a test can fake a repo that was deleted out from under a
 * recorded provenance without touching a real disk.
 */

import { existsSync } from "node:fs";
import { join } from "node:path";

import { maintainTrace } from "./trace";

/**
 * How this install arrived on the machine.
 *
 *   - `guide_source_clone`: a guide cloned the repo and built it here; the
 *     pinned commit and the clone path were written down at completion time.
 *   - `signed_app_download`: a signed executable/installer arrived by
 *     download. Local patching is off the table.
 *
 * Snake_case values (not the `guideSourceClone`/`signedAppDownload` case
 * names Swift's enum uses) per the porting spec's type table for this
 * module — this store's JSON is local-only, never sent over the wire to a
 * pool route, so there is no cross-system format this has to match; the
 * snake_case is simply this file's own on-disk vocabulary.
 */
export type InstallProvenance = "guide_source_clone" | "signed_app_download";

export interface RecordedInstallProvenance {
  readonly appSlug: string;
  readonly provenance: InstallProvenance;
  /** Absolute path of the clone. Present for `guide_source_clone` only. */
  readonly clonePath: string | null;
  /** The guide's pinned source commit at install time — the base fixes diff
   *  against until the patch queue advances it. `guide_source_clone` only. */
  readonly pinnedCommit: string | null;
  /** "owner/name" of the canonical repo — what the fork backup forks.
   *  `guide_source_clone` only. */
  readonly canonicalRepo: string | null;
  /** ISO-8601, matching the JSON-file convention `settings.ts`/`secrets.ts`
   *  already use elsewhere in this app (plain, bug-report-safe text). */
  readonly recordedAt: string;
}

/**
 * The persistence seam. Swift keeps this dictionary behind `UserDefaults`;
 * this file's real backing store is `userData/maintain.json`, owned by
 * `main/maintain/state-store.ts` (a separate porting task, per the porting
 * spec's `MaintainStateStore`) — this module depends only on this narrow
 * read/write-the-whole-map interface, never on `electron` or that file
 * directly, so it stays testable without either.
 */
export interface InstallProvenancePersistence {
  readAllProvenanceRecords(): Readonly<Record<string, RecordedInstallProvenance>>;
  writeAllProvenanceRecords(records: Readonly<Record<string, RecordedInstallProvenance>>): void;
}

/** Small in-memory implementation for tests and for any caller without a
 *  real `userData`-backed store wired up yet — mirrors `MockShell` in
 *  `services/autopilot/shell.ts` and `InMemoryInstallIdentityPersistence` in
 *  `install-identity.ts`. */
export class InMemoryInstallProvenancePersistence implements InstallProvenancePersistence {
  private records: Record<string, RecordedInstallProvenance> = {};

  readAllProvenanceRecords(): Readonly<Record<string, RecordedInstallProvenance>> {
    return this.records;
  }

  writeAllProvenanceRecords(records: Readonly<Record<string, RecordedInstallProvenance>>): void {
    this.records = { ...records };
  }
}

/**
 * Does `<clonePath>/.git` exist? The real, default implementation of the
 * injected check `InstallProvenanceStore.localPatchingIsPermitted` needs.
 *
 * Named to match the porting spec's table (`gitDirectoryExists(path):
 * boolean`), but — matching Swift's own `FileManager.default.fileExists`
 * check exactly — this only tests *existence*, not that `.git` is a
 * directory. A git worktree's `.git` is a plain file (a `gitdir: ...`
 * pointer), and Swift's `fileExists(atPath:isDirectory:)` call treats that as
 * present too: the `isDirectory` out-parameter is populated but never
 * inspected by the caller. Reproducing that here, rather than "fixing" it to
 * require a directory, keeps this a real behavioral port rather than an
 * accidental tightening of the D4 gate.
 */
export function gitDirectoryExists(clonePath: string): boolean {
  try {
    return existsSync(join(clonePath, ".git"));
  } catch {
    return false;
  }
}

/**
 * Where an install came from, and the fail-closed D4 gate
 * (`localPatchingIsPermitted`) that everything downstream in maintain mode
 * checks before touching a single file on disk.
 */
export class InstallProvenanceStore {
  private readonly persistence: InstallProvenancePersistence;
  private readonly checkGitDirectoryExists: (path: string) => boolean;
  private readonly nowIso: () => string;

  constructor(options: {
    persistence: InstallProvenancePersistence;
    /** Injected so `localPatchingIsPermitted` is testable without a real
     *  clone on disk. Defaults to the real `node:fs` check above. */
    checkGitDirectoryExists?: (path: string) => boolean;
    nowIso?: () => string;
  }) {
    this.persistence = options.persistence;
    this.checkGitDirectoryExists = options.checkGitDirectoryExists ?? gitDirectoryExists;
    this.nowIso = options.nowIso ?? (() => new Date().toISOString());
  }

  /**
   * Called from guide completion, the one moment every fact is in hand.
   * Overwrites an older record for the same app: a re-install is a new
   * provenance, not an update to the old one.
   */
  recordGuideSourceClone(options: {
    appSlug: string;
    clonePath: string;
    pinnedCommit: string | null;
    canonicalRepo: string | null;
  }): void {
    this.write(options.appSlug, {
      appSlug: options.appSlug,
      provenance: "guide_source_clone",
      clonePath: options.clonePath,
      pinnedCommit: options.pinnedCommit,
      canonicalRepo: options.canonicalRepo,
      recordedAt: this.nowIso(),
    });
    maintainTrace(`provenance recorded: ${options.appSlug} is a guide-source clone at ${options.clonePath}`);
  }

  recordSignedDownload(appSlug: string): void {
    this.write(appSlug, {
      appSlug,
      provenance: "signed_app_download",
      clonePath: null,
      pinnedCommit: null,
      canonicalRepo: null,
      recordedAt: this.nowIso(),
    });
    maintainTrace(`provenance recorded: ${appSlug} is a signed download — local patching stays off`);
  }

  provenanceForAppSlug(appSlug: string): RecordedInstallProvenance | null {
    return this.persistence.readAllProvenanceRecords()[appSlug] ?? null;
  }

  /**
   * The D4 gate, in one place. Unknown = signed = no local patching. Fails
   * closed on every path: no record, wrong provenance, a `guide_source_clone`
   * record missing its clone path, or a clone path whose `.git` no longer
   * exists (the record can outlive the clone — the user deleted the folder,
   * or a wipe took it — at which point a recorded path that no longer holds a
   * git repo is unknown provenance again, exactly like Swift).
   */
  localPatchingIsPermitted(appSlug: string): boolean {
    const record = this.provenanceForAppSlug(appSlug);
    if (record === null || record.provenance !== "guide_source_clone" || !record.clonePath) {
      return false;
    }
    const permitted = this.checkGitDirectoryExists(record.clonePath);
    if (!permitted) {
      maintainTrace(`local patching blocked for ${appSlug}: recorded clone at ${record.clonePath} has no .git anymore`);
    }
    return permitted;
  }

  private write(appSlug: string, record: RecordedInstallProvenance): void {
    const all = { ...this.persistence.readAllProvenanceRecords() };
    all[appSlug] = record;
    this.persistence.writeAllProvenanceRecords(all);
  }
}
