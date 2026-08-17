import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  InMemoryInstallProvenancePersistence,
  InstallProvenanceStore,
  decideInstallProvenance,
  gitDirectoryExists,
} from "../src/services/maintain/install-provenance";

/**
 * The D4 gate: unknown provenance, a signed download, or a guide-source clone
 * whose `.git` has since vanished, must all fail closed. `localPatchingIsPermitted`
 * is the one function every downstream maintain-mode module checks before
 * touching a file, so it gets the most direct coverage here.
 */

describe("decideInstallProvenance — the pure install-finish decision", () => {
  it("records a guide-source clone for a desktop app that cloned, carrying repo + commit + clone path", () => {
    expect(
      decideInstallProvenance({
        outputType: "desktop_app",
        clonedARepo: true,
        clonePath: "C:\\Users\\test\\publikclip",
        canonicalRepo: "Blueturboguy07/publikclip",
        pinnedCommit: "a53a359b985b1d2d666266062936cc186f02340b",
      })
    ).toEqual({
      kind: "guide_source_clone",
      clonePath: "C:\\Users\\test\\publikclip",
      canonicalRepo: "Blueturboguy07/publikclip",
      pinnedCommit: "a53a359b985b1d2d666266062936cc186f02340b",
    });
  });

  it("records a signed download for a desktop app that did not clone", () => {
    expect(
      decideInstallProvenance({
        outputType: "desktop_app",
        clonedARepo: false,
        clonePath: undefined,
        canonicalRepo: undefined,
        pinnedCommit: undefined,
      })
    ).toEqual({ kind: "signed_app_download" });
  });

  it("fails closed to a signed download when a clone is claimed but no clone path landed", () => {
    // A guide_source_clone whose path we cannot pin is unpatchable — the D4
    // gate's "unknown = signed = don't touch it" instinct applies here too.
    expect(
      decideInstallProvenance({
        outputType: "desktop_app",
        clonedARepo: true,
        clonePath: undefined,
        canonicalRepo: "Blueturboguy07/publikclip",
        pinnedCommit: "abc",
      })
    ).toEqual({ kind: "signed_app_download" });
  });

  it("nulls a missing repo/commit rather than recording undefined", () => {
    expect(
      decideInstallProvenance({
        outputType: "desktop_app",
        clonedARepo: true,
        clonePath: "C:\\clone",
        canonicalRepo: undefined,
        pinnedCommit: undefined,
      })
    ).toEqual({ kind: "guide_source_clone", clonePath: "C:\\clone", canonicalRepo: null, pinnedCommit: null });
  });

  it("records nothing for a local_web install — a dev server has no binary to patch", () => {
    expect(
      decideInstallProvenance({
        outputType: "local_web",
        clonedARepo: true,
        clonePath: "C:\\Users\\test\\OpenASCII",
        canonicalRepo: "Blueturboguy07/OpenASCII",
        pinnedCommit: "8fc32ce",
      })
    ).toEqual({ kind: "none" });
  });

  it("records nothing for a credential or none install", () => {
    expect(
      decideInstallProvenance({ outputType: "credential", clonedARepo: false, clonePath: undefined, canonicalRepo: undefined, pinnedCommit: undefined })
    ).toEqual({ kind: "none" });
    expect(
      decideInstallProvenance({ outputType: "none", clonedARepo: false, clonePath: undefined, canonicalRepo: undefined, pinnedCommit: undefined })
    ).toEqual({ kind: "none" });
  });
});

describe("recording provenance", () => {
  it("records a guide-source clone with every field the guide-completion moment supplies", () => {
    const store = new InstallProvenanceStore({
      persistence: new InMemoryInstallProvenancePersistence(),
      nowIso: () => "2026-08-15T00:00:00.000Z",
    });

    store.recordGuideSourceClone({
      appSlug: "cue",
      clonePath: "C:\\Users\\test\\iris-apps\\cue",
      pinnedCommit: "abc123",
      canonicalRepo: "Blueturboguy07/cue",
    });

    expect(store.provenanceForAppSlug("cue")).toEqual({
      appSlug: "cue",
      provenance: "guide_source_clone",
      clonePath: "C:\\Users\\test\\iris-apps\\cue",
      pinnedCommit: "abc123",
      canonicalRepo: "Blueturboguy07/cue",
      recordedAt: "2026-08-15T00:00:00.000Z",
    });
  });

  it("records a signed download with null clone/commit/repo fields", () => {
    const store = new InstallProvenanceStore({
      persistence: new InMemoryInstallProvenancePersistence(),
      nowIso: () => "2026-08-15T00:00:00.000Z",
    });

    store.recordSignedDownload("cue");

    expect(store.provenanceForAppSlug("cue")).toEqual({
      appSlug: "cue",
      provenance: "signed_app_download",
      clonePath: null,
      pinnedCommit: null,
      canonicalRepo: null,
      recordedAt: "2026-08-15T00:00:00.000Z",
    });
  });

  it("overwrites an older record for the same app slug on a re-install, rather than merging", () => {
    const store = new InstallProvenanceStore({ persistence: new InMemoryInstallProvenancePersistence() });

    store.recordGuideSourceClone({ appSlug: "cue", clonePath: "C:\\old", pinnedCommit: "old-sha", canonicalRepo: "x/y" });
    store.recordSignedDownload("cue");

    expect(store.provenanceForAppSlug("cue")?.provenance).toBe("signed_app_download");
    expect(store.provenanceForAppSlug("cue")?.clonePath).toBeNull();
  });

  it("returns null for an app with no recorded provenance", () => {
    const store = new InstallProvenanceStore({ persistence: new InMemoryInstallProvenancePersistence() });
    expect(store.provenanceForAppSlug("never-installed")).toBeNull();
  });
});

describe("localPatchingIsPermitted — the D4 gate, fails closed on every path", () => {
  it("refuses when there is no record at all", () => {
    const store = new InstallProvenanceStore({ persistence: new InMemoryInstallProvenancePersistence() });
    expect(store.localPatchingIsPermitted("cue")).toBe(false);
  });

  it("refuses a signed download unconditionally, even if a git check would somehow say yes", () => {
    const store = new InstallProvenanceStore({
      persistence: new InMemoryInstallProvenancePersistence(),
      checkGitDirectoryExists: () => true,
    });
    store.recordSignedDownload("cue");
    expect(store.localPatchingIsPermitted("cue")).toBe(false);
  });

  it("permits a guide-source clone whose .git the check confirms still exists", () => {
    const store = new InstallProvenanceStore({
      persistence: new InMemoryInstallProvenancePersistence(),
      checkGitDirectoryExists: (clonePath) => clonePath === "C:\\Users\\test\\cue",
    });
    store.recordGuideSourceClone({
      appSlug: "cue",
      clonePath: "C:\\Users\\test\\cue",
      pinnedCommit: "abc",
      canonicalRepo: "x/y",
    });
    expect(store.localPatchingIsPermitted("cue")).toBe(true);
  });

  it("refuses a guide-source clone whose .git the check says is gone — the record outlived the folder", () => {
    const store = new InstallProvenanceStore({
      persistence: new InMemoryInstallProvenancePersistence(),
      checkGitDirectoryExists: () => false,
    });
    store.recordGuideSourceClone({ appSlug: "cue", clonePath: "C:\\deleted", pinnedCommit: "abc", canonicalRepo: "x/y" });
    expect(store.localPatchingIsPermitted("cue")).toBe(false);
  });

  it("refuses a guide-source clone record with an empty clone path without ever calling the git check", () => {
    let checkWasCalled = false;
    const store = new InstallProvenanceStore({
      persistence: new InMemoryInstallProvenancePersistence(),
      checkGitDirectoryExists: () => {
        checkWasCalled = true;
        return true;
      },
    });
    store.recordGuideSourceClone({ appSlug: "cue", clonePath: "", pinnedCommit: null, canonicalRepo: null });
    expect(store.localPatchingIsPermitted("cue")).toBe(false);
    expect(checkWasCalled).toBe(false);
  });
});

describe("gitDirectoryExists — the real, default git check", () => {
  let tempDir: string | undefined;

  afterEach(() => {
    if (tempDir) rmSync(tempDir, { recursive: true, force: true });
    tempDir = undefined;
  });

  it("is true for a clone with a real .git directory", () => {
    tempDir = mkdtempSync(join(tmpdir(), "iris-maintain-provenance-"));
    const clonePath = join(tempDir, "cue");
    mkdirSync(join(clonePath, ".git"), { recursive: true });

    expect(gitDirectoryExists(clonePath)).toBe(true);
  });

  it("is true for a git worktree, whose .git is a plain file, not a directory — matching Swift's fileExists check", () => {
    tempDir = mkdtempSync(join(tmpdir(), "iris-maintain-provenance-"));
    const clonePath = join(tempDir, "worktree");
    mkdirSync(clonePath, { recursive: true });
    writeFileSync(join(clonePath, ".git"), "gitdir: ../main/.git/worktrees/worktree\n");

    expect(gitDirectoryExists(clonePath)).toBe(true);
  });

  it("is false when the clone path does not exist at all", () => {
    tempDir = mkdtempSync(join(tmpdir(), "iris-maintain-provenance-"));
    expect(gitDirectoryExists(join(tempDir, "never-existed"))).toBe(false);
  });

  it("is false, not throwing, for an unreadable/invalid path", () => {
    expect(gitDirectoryExists("\0invalid")).toBe(false);
  });
});
