import { describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  InMemoryInstallProvenancePersistence,
  InstallProvenanceStore,
  gitDirectoryExists,
} from "../src/services/maintain/install-provenance";

function storeWithFakeGitCheck(existingClonePaths: Set<string>) {
  const persistence = new InMemoryInstallProvenancePersistence();
  const store = new InstallProvenanceStore({
    persistence,
    checkGitDirectoryExists: (clonePath) => existingClonePaths.has(clonePath),
    nowIso: () => "2026-08-15T00:00:00.000Z",
  });
  return { store, persistence };
}

describe("InstallProvenanceStore — recording", () => {
  it("records a guide-source clone with every field, and it round-trips", () => {
    const { store } = storeWithFakeGitCheck(new Set(["/clones/cue"]));
    store.recordGuideSourceClone({
      appSlug: "cue",
      clonePath: "/clones/cue",
      pinnedCommit: "abc1234",
      canonicalRepo: "owner/cue",
    });

    const record = store.provenanceForAppSlug("cue");
    expect(record).toEqual({
      appSlug: "cue",
      provenance: "guide_source_clone",
      clonePath: "/clones/cue",
      pinnedCommit: "abc1234",
      canonicalRepo: "owner/cue",
      recordedAt: "2026-08-15T00:00:00.000Z",
    });
  });

  it("records a signed download with every provenance field nulled out", () => {
    const { store } = storeWithFakeGitCheck(new Set());
    store.recordSignedDownload("nut-ai");

    expect(store.provenanceForAppSlug("nut-ai")).toEqual({
      appSlug: "nut-ai",
      provenance: "signed_app_download",
      clonePath: null,
      pinnedCommit: null,
      canonicalRepo: null,
      recordedAt: "2026-08-15T00:00:00.000Z",
    });
  });

  it("a re-install overwrites the earlier record for the same app", () => {
    const { store } = storeWithFakeGitCheck(new Set(["/clones/cue-v2"]));
    store.recordSignedDownload("cue");
    store.recordGuideSourceClone({
      appSlug: "cue",
      clonePath: "/clones/cue-v2",
      pinnedCommit: null,
      canonicalRepo: null,
    });

    expect(store.provenanceForAppSlug("cue")?.provenance).toBe("guide_source_clone");
    expect(store.provenanceForAppSlug("cue")?.clonePath).toBe("/clones/cue-v2");
  });

  it("returns null for an app with no recorded provenance at all", () => {
    const { store } = storeWithFakeGitCheck(new Set());
    expect(store.provenanceForAppSlug("never-installed")).toBeNull();
  });

  it("keeps each app's provenance independent of every other app's", () => {
    const { store } = storeWithFakeGitCheck(new Set(["/clones/a"]));
    store.recordGuideSourceClone({ appSlug: "a", clonePath: "/clones/a", pinnedCommit: null, canonicalRepo: null });
    store.recordSignedDownload("b");

    expect(store.provenanceForAppSlug("a")?.provenance).toBe("guide_source_clone");
    expect(store.provenanceForAppSlug("b")?.provenance).toBe("signed_app_download");
  });
});

describe("InstallProvenanceStore — the D4 gate (localPatchingIsPermitted)", () => {
  it("fails closed with no record at all", () => {
    const { store } = storeWithFakeGitCheck(new Set());
    expect(store.localPatchingIsPermitted("unknown-app")).toBe(false);
  });

  it("fails closed for a signed download — never patched, no matter what", () => {
    const { store } = storeWithFakeGitCheck(new Set());
    store.recordSignedDownload("cue");
    expect(store.localPatchingIsPermitted("cue")).toBe(false);
  });

  it("permits a guide-source clone whose .git still exists", () => {
    const { store } = storeWithFakeGitCheck(new Set(["/clones/cue"]));
    store.recordGuideSourceClone({ appSlug: "cue", clonePath: "/clones/cue", pinnedCommit: null, canonicalRepo: null });
    expect(store.localPatchingIsPermitted("cue")).toBe(true);
  });

  it("fails closed when the recorded clone's .git no longer exists (folder deleted or wiped)", () => {
    const { store } = storeWithFakeGitCheck(new Set()); // nothing exists
    store.recordGuideSourceClone({ appSlug: "cue", clonePath: "/clones/cue", pinnedCommit: null, canonicalRepo: null });
    expect(store.localPatchingIsPermitted("cue")).toBe(false);
  });

  it("fails closed for a guide_source_clone record that is somehow missing its clone path", () => {
    const persistence = new InMemoryInstallProvenancePersistence();
    persistence.writeAllProvenanceRecords({
      cue: {
        appSlug: "cue",
        provenance: "guide_source_clone",
        clonePath: null,
        pinnedCommit: null,
        canonicalRepo: null,
        recordedAt: "2026-08-15T00:00:00.000Z",
      },
    });
    const store = new InstallProvenanceStore({ persistence, checkGitDirectoryExists: () => true });
    expect(store.localPatchingIsPermitted("cue")).toBe(false);
  });
});

describe("gitDirectoryExists (the real default check)", () => {
  it("is true for a directory that actually holds a .git", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "iris-provenance-"));
    fs.mkdirSync(path.join(tmp, ".git"));
    try {
      expect(gitDirectoryExists(tmp)).toBe(true);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("is true even when .git is a plain file (a git worktree's gitdir pointer), matching Swift's fileExists check", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "iris-provenance-worktree-"));
    fs.writeFileSync(path.join(tmp, ".git"), "gitdir: /somewhere/else/.git/worktrees/x\n");
    try {
      expect(gitDirectoryExists(tmp)).toBe(true);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("is false for a directory with no .git at all", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "iris-provenance-empty-"));
    try {
      expect(gitDirectoryExists(tmp)).toBe(false);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("is false for a clone path that does not exist on disk at all", () => {
    expect(gitDirectoryExists("/definitely/not/a/real/path/on/this/machine")).toBe(false);
  });
});
