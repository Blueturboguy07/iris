import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CATALOG_APP_STACKS_BY_SLUG,
  KnownPathInstalledCatalogAppResolver,
  WINDOWS_CATALOG_APPS,
  WindowsAppInventory,
  buildForegroundProcessCommand,
  expandWindowsEnvironmentTokens,
  fetchCatalogApps,
  parseForegroundProcessOutput,
  readForegroundProcessViaPowerShell,
  slugForProcessName,
  stackForSlug,
  windowsCatalogAppForSlug,
  type CatalogFetchLike,
  type ForegroundProcess,
  type InstalledCatalogAppResolving,
  type SpawnedProcessLike,
  type WindowsCatalogApp,
} from "../src/services/maintain/app-inventory";

/**
 * The Windows composition of macOS's AppInventoryService + matchCatalogApp:
 * who's installed, what stack a slug is on, and who's frontmost. Every real I/O
 * seam (catalog fetch, foreground read, installed-path check) is injected, so
 * the whole file is exercised on a Mac and on windows-latest alike.
 */

describe("the slug → stack dict (copied from macOS)", () => {
  it("carries every catalog app's stack, defaulting unknowns to other", () => {
    expect(CATALOG_APP_STACKS_BY_SLUG.publikclip).toBe("tauri");
    expect(CATALOG_APP_STACKS_BY_SLUG.cue).toBe("electron");
    expect(CATALOG_APP_STACKS_BY_SLUG.openascii).toBe("nextjs");
    expect(CATALOG_APP_STACKS_BY_SLUG.noscroll).toBe("other");
    expect(stackForSlug("publikclip")).toBe("tauri");
    expect(stackForSlug("not-a-catalog-app")).toBe("other");
  });
});

describe("exe → slug matching", () => {
  it("resolves the publikclip exe to its slug, case-insensitively and with or without .exe", () => {
    expect(slugForProcessName("publikclip-app.exe")).toBe("publikclip");
    expect(slugForProcessName("PUBLIKCLIP-APP.EXE")).toBe("publikclip");
    expect(slugForProcessName("publikclip-app")).toBe("publikclip");
  });

  it("returns undefined for anything not in the reviewed Windows roster", () => {
    expect(slugForProcessName("notepad.exe")).toBeUndefined();
    expect(slugForProcessName("publikclip.exe")).toBeUndefined(); // the catalog name, not the exe name
    expect(slugForProcessName("")).toBeUndefined();
  });

  it("exposes the reviewed roster with a real, verified publikclip entry", () => {
    const publikclip = windowsCatalogAppForSlug("publikclip");
    expect(publikclip?.exeName).toBe("publikclip-app.exe");
    expect(publikclip?.stack).toBe("tauri");
    expect(publikclip?.installedExePathTemplate).toContain("%LOCALAPPDATA%");
    expect(WINDOWS_CATALOG_APPS.every((app) => app.exeName.endsWith(".exe"))).toBe(true);
  });
});

describe("expandWindowsEnvironmentTokens", () => {
  it("expands known %VAR% tokens against the supplied environment", () => {
    expect(
      expandWindowsEnvironmentTokens("%LOCALAPPDATA%\\publikclip\\publikclip-app.exe", {
        LOCALAPPDATA: "C:\\Users\\test\\AppData\\Local",
      })
    ).toBe("C:\\Users\\test\\AppData\\Local\\publikclip\\publikclip-app.exe");
  });

  it("leaves an unknown token in place rather than blanking the path", () => {
    expect(expandWindowsEnvironmentTokens("%NOPE%\\x", {})).toBe("%NOPE%\\x");
  });
});

describe("KnownPathInstalledCatalogAppResolver", () => {
  const publikclip = windowsCatalogAppForSlug("publikclip") as WindowsCatalogApp;
  const tempDirs: string[] = [];
  afterEach(() => {
    for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  it("reports installed when the known exe path exists on disk", () => {
    // Point %APPBASE% at a real temp dir and drop a file where the template
    // resolves — proving the existence check without a real Windows install.
    // Uses a single-segment template so `join` behaves the same on any host.
    const tempDir = mkdtempSync(join(tmpdir(), "iris-installed-"));
    tempDirs.push(tempDir);
    writeFileSync(join(tempDir, "publikclip-app.exe"), "");
    const resolver = new KnownPathInstalledCatalogAppResolver({ APPBASE: tempDir });
    const app: WindowsCatalogApp = {
      ...publikclip,
      installedExePathTemplate: join("%APPBASE%", "publikclip-app.exe"),
    };
    expect(resolver.isInstalled(app)).toBe(true);
  });

  it("reports not installed when the path does not exist", () => {
    const resolver = new KnownPathInstalledCatalogAppResolver({ LOCALAPPDATA: join(tmpdir(), "iris-nope-does-not-exist") });
    expect(resolver.isInstalled(publikclip)).toBe(false);
  });
});

describe("the foreground-process one-liner", () => {
  it("builds a GetForegroundWindow P/Invoke that prints pid|exe", () => {
    const command = buildForegroundProcessCommand();
    expect(command).toContain("GetForegroundWindow");
    expect(command).toContain("GetWindowThreadProcessId");
    expect(command).toContain("Get-Process");
  });

  it("parses a well-formed pid|processName line", () => {
    expect(parseForegroundProcessOutput("4821|publikclip-app.exe\r\n")).toEqual({
      pid: 4821,
      processName: "publikclip-app.exe",
    });
  });

  it("takes the last non-empty line, ignoring noise before it", () => {
    expect(parseForegroundProcessOutput("warning: something\n\n77|notepad.exe\n")).toEqual({
      pid: 77,
      processName: "notepad.exe",
    });
  });

  it("returns undefined for empty output, a non-integer pid, or a missing separator", () => {
    expect(parseForegroundProcessOutput("")).toBeUndefined();
    expect(parseForegroundProcessOutput("\n \n")).toBeUndefined();
    expect(parseForegroundProcessOutput("abc|x.exe")).toBeUndefined();
    expect(parseForegroundProcessOutput("0|x.exe")).toBeUndefined();
    expect(parseForegroundProcessOutput("4821")).toBeUndefined();
    expect(parseForegroundProcessOutput("4821|")).toBeUndefined();
  });
});

/** A scripted `SpawnedProcessLike` that emits `stdout`, then closes — enough to
 *  drive `readForegroundProcessViaPowerShell` without a real process. */
class FakeSpawnedProcess implements SpawnedProcessLike {
  readonly stdout: { on(event: "data", listener: (chunk: string | Buffer) => void): void };
  private closeListener: ((exitCode: number | null) => void) | undefined;
  killed = false;

  constructor(private readonly stdoutText: string, private readonly emit: boolean = true) {
    this.stdout = {
      on: (_event, listener) => {
        if (this.emit && this.stdoutText.length > 0) listener(this.stdoutText);
      },
    };
  }
  on(event: "error" | "close", listener: (arg: never) => void): void {
    if (event === "close") this.closeListener = listener as (exitCode: number | null) => void;
  }
  fireClose(): void {
    this.closeListener?.(0);
  }
  kill(): void {
    this.killed = true;
  }
}

describe("readForegroundProcessViaPowerShell (with an injected spawn)", () => {
  it("resolves the parsed foreground process from the fake child's stdout", async () => {
    let child: FakeSpawnedProcess | undefined;
    const promise = readForegroundProcessViaPowerShell({
      spawnPowerShellOneLiner: () => {
        child = new FakeSpawnedProcess("4821|publikclip-app.exe\n");
        return child;
      },
    });
    child?.fireClose();
    await expect(promise).resolves.toEqual({ pid: 4821, processName: "publikclip-app.exe" });
  });

  it("resolves undefined when a spawn throws (no powershell.exe on this host)", async () => {
    await expect(
      readForegroundProcessViaPowerShell({
        spawnPowerShellOneLiner: () => {
          throw new Error("ENOENT powershell.exe");
        },
      })
    ).resolves.toBeUndefined();
  });

  it("times out to undefined and kills the child", async () => {
    vi.useFakeTimers();
    try {
      let child: FakeSpawnedProcess | undefined;
      const promise = readForegroundProcessViaPowerShell({
        timeoutMs: 10,
        spawnPowerShellOneLiner: () => {
          child = new FakeSpawnedProcess("", false); // never emits, never closes
          return child;
        },
      });
      await vi.advanceTimersByTimeAsync(11);
      await expect(promise).resolves.toBeUndefined();
      expect(child?.killed).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("fetchCatalogApps (injected fetch)", () => {
  const okFetch = (body: string): CatalogFetchLike =>
    vi.fn(async () => ({ ok: true, status: 200, text: async () => body }));

  it("parses the apps array from a 200 body", async () => {
    const apps = await fetchCatalogApps({
      fetchImplementation: okFetch(
        JSON.stringify({ apps: [{ slug: "publikclip", name: "publikclip", macBundleId: null, latestReleaseTag: null }] })
      ),
    });
    expect(apps).toEqual([{ slug: "publikclip", name: "publikclip", macBundleId: null, latestReleaseTag: null }]);
  });

  it("hits {base}/api/iris/apps with a GET", async () => {
    const fetchImplementation = okFetch(JSON.stringify({ apps: [] }));
    await fetchCatalogApps({ publikBaseUrl: "https://example.test", fetchImplementation });
    expect(fetchImplementation).toHaveBeenCalledWith("https://example.test/api/iris/apps", {
      method: "GET",
      headers: { Accept: "application/json" },
    });
  });

  it("returns an empty list on a non-ok status, a throw, or malformed JSON — never throws", async () => {
    await expect(
      fetchCatalogApps({ fetchImplementation: vi.fn(async () => ({ ok: false, status: 503, text: async () => "" })) })
    ).resolves.toEqual([]);
    await expect(
      fetchCatalogApps({
        fetchImplementation: vi.fn(async () => {
          throw new Error("network down");
        }),
      })
    ).resolves.toEqual([]);
    await expect(
      fetchCatalogApps({ fetchImplementation: okFetch("not json at all") })
    ).resolves.toEqual([]);
  });
});

/** An installed resolver that says exactly the given slugs are present. */
function fakeInstalledResolver(installedSlugs: readonly string[]): InstalledCatalogAppResolving {
  return { isInstalled: (app) => installedSlugs.includes(app.slug) };
}

describe("WindowsAppInventory", () => {
  it("matches a crashed publikclip exe to its slug + stack (the CrashArtifactAppMatching seam)", () => {
    const inventory = new WindowsAppInventory();
    expect(inventory.catalogApp("publikclip-app.exe")).toEqual({ slug: "publikclip", stack: "tauri" });
    expect(inventory.catalogApp("notepad.exe")).toBeUndefined();
  });

  it("resolves the frontmost catalog app, carrying the pid the hang probe needs", async () => {
    const foreground: ForegroundProcess = { pid: 4821, processName: "publikclip-app.exe" };
    const inventory = new WindowsAppInventory({ readForegroundProcess: async () => foreground });
    await expect(inventory.frontmostCatalogApp()).resolves.toEqual({
      slug: "publikclip",
      appName: "publikclip",
      pid: 4821,
      stack: "tauri",
    });
  });

  it("returns no frontmost catalog app when what's in front is not one of ours, or cannot be read", async () => {
    await expect(
      new WindowsAppInventory({ readForegroundProcess: async () => ({ pid: 10, processName: "notepad.exe" }) }).frontmostCatalogApp()
    ).resolves.toBeUndefined();
    await expect(
      new WindowsAppInventory({ readForegroundProcess: async () => undefined }).frontmostCatalogApp()
    ).resolves.toBeUndefined();
  });

  it("reports the installed roster from the installed-resolution seam", () => {
    const installed = new WindowsAppInventory({ installedResolver: fakeInstalledResolver(["publikclip"]) });
    expect(installed.installedCatalogSlugs()).toEqual(new Set(["publikclip"]));
    expect(installed.isInstalled("publikclip")).toBe(true);

    const none = new WindowsAppInventory({ installedResolver: fakeInstalledResolver([]) });
    expect(none.installedCatalogSlugs().size).toBe(0);
    expect(none.isInstalled("publikclip")).toBe(false);
    expect(none.isInstalled("not-a-catalog-app")).toBe(false);
  });

  it("prefers a fetched catalog display name after refreshCatalog, falling back to the roster otherwise", async () => {
    const inventory = new WindowsAppInventory({
      fetchCatalogApps: async () => [{ slug: "publikclip", name: "Publik Clip", macBundleId: null, latestReleaseTag: "v0.1.0" }],
    });
    expect(inventory.appNameForSlug("publikclip")).toBe("publikclip"); // roster fallback before refresh
    await inventory.refreshCatalog();
    expect(inventory.appNameForSlug("publikclip")).toBe("Publik Clip");
    expect(inventory.appNameForSlug("unknown-slug")).toBe("unknown-slug");
  });
});
