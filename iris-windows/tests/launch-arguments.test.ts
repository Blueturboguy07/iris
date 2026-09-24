import { describe, expect, it } from "vitest";
import {
  SQUIRREL_HOOK_TIMEOUT_MS,
  SQUIRREL_SHORTCUT_LOCATIONS,
  relaunchIntentFromArgv,
  squirrelEventFromArgv,
  squirrelStartupPlan,
  squirrelUpdateExePath,
} from "../src/services/launch-arguments";

/**
 * The two launch decisions behind "there is no desktop icon, and opening Iris
 * takes many steps" (a paying subscriber's report, 2026-09-24): what a
 * Squirrel.Windows install hook must do, and what a second launch of a running
 * Iris must show. Both are argv-only and pure, so every branch is pinned here;
 * the real installer is exercised by the "Installer shortcuts" step in
 * iris-windows.yml on windows-latest.
 */

const INSTALLED_EXE = "C:\\Users\\richard\\AppData\\Local\\Iris\\app-0.9.15\\iris.exe";

describe("squirrelEventFromArgv", () => {
  it.each([
    ["--squirrel-install", "install"],
    ["--squirrel-updated", "updated"],
    ["--squirrel-uninstall", "uninstall"],
    ["--squirrel-obsolete", "obsolete"],
    ["--squirrel-firstrun", "firstrun"],
  ] as const)("reads %s as the %s hook", (flag, event) => {
    // Squirrel passes the version after install/updated/uninstall/obsolete.
    expect(squirrelEventFromArgv([INSTALLED_EXE, flag, "0.9.15"])).toBe(event);
  });

  it("is null for an ordinary launch from a shortcut", () => {
    expect(squirrelEventFromArgv([INSTALLED_EXE])).toBeNull();
  });

  it("is null for a deep-link launch", () => {
    expect(squirrelEventFromArgv([INSTALLED_EXE, "iris://guide/openascii?version=1"])).toBeNull();
  });

  it("ignores the exe path itself, even if it looked like a flag", () => {
    expect(squirrelEventFromArgv(["--squirrel-install"])).toBeNull();
  });

  it("finds the flag after the app path in a development launch", () => {
    expect(
      squirrelEventFromArgv(["C:\\electron\\electron.exe", "C:\\src\\iris-windows", "--squirrel-uninstall"])
    ).toBe("uninstall");
  });

  it("does not treat a near-miss or a flag with a value glued on as a hook", () => {
    expect(squirrelEventFromArgv([INSTALLED_EXE, "--squirrel-installer"])).toBeNull();
    expect(squirrelEventFromArgv([INSTALLED_EXE, "--squirrel-install=0.9.15"])).toBeNull();
    expect(squirrelEventFromArgv([INSTALLED_EXE, "--SQUIRREL-INSTALL"])).toBeNull();
  });
});

describe("squirrelStartupPlan", () => {
  it("creates the Desktop and Start Menu shortcuts on install, then quits", () => {
    expect(squirrelStartupPlan("install", "iris.exe")).toEqual({
      kind: "runUpdateExeThenQuit",
      updateExeArguments: ["--createShortcut=iris.exe", "--shortcut-locations=Desktop,StartMenu"],
    });
  });

  it("does the same on update, so an update restores a missing shortcut", () => {
    expect(squirrelStartupPlan("updated", "iris.exe")).toEqual(squirrelStartupPlan("install", "iris.exe"));
  });

  it("removes the same shortcuts on uninstall, then quits", () => {
    expect(squirrelStartupPlan("uninstall", "iris.exe")).toEqual({
      kind: "runUpdateExeThenQuit",
      updateExeArguments: ["--removeShortcut=iris.exe", "--shortcut-locations=Desktop,StartMenu"],
    });
  });

  it("quits at once when an old version is being cleaned up", () => {
    expect(squirrelStartupPlan("obsolete", "iris.exe")).toEqual({ kind: "quitImmediately" });
  });

  it("starts the app normally on the first launch after installing", () => {
    expect(squirrelStartupPlan("firstrun", "iris.exe")).toEqual({ kind: "startAsFirstRun" });
  });

  it("names the running exe, whatever it is called", () => {
    const plan = squirrelStartupPlan("install", "Iris Beta.exe");
    expect(plan.kind === "runUpdateExeThenQuit" && plan.updateExeArguments[0]).toBe(
      "--createShortcut=Iris Beta.exe"
    );
  });

  it("promises exactly the two places the first-run notice names", () => {
    expect(SQUIRREL_SHORTCUT_LOCATIONS).toBe("Desktop,StartMenu");
  });

  it("gives up on Update.exe before Squirrel's own 15-second hook limit", () => {
    expect(SQUIRREL_HOOK_TIMEOUT_MS).toBeGreaterThan(0);
    expect(SQUIRREL_HOOK_TIMEOUT_MS).toBeLessThan(15_000);
  });
});

describe("squirrelUpdateExePath", () => {
  it("is Update.exe in the Squirrel root, one folder above the versioned app folder", () => {
    expect(squirrelUpdateExePath(INSTALLED_EXE)).toBe("C:\\Users\\richard\\AppData\\Local\\Iris\\Update.exe");
  });
});

describe("relaunchIntentFromArgv", () => {
  it("opens the chat for a plain launch from the Desktop or Start Menu shortcut", () => {
    expect(relaunchIntentFromArgv([INSTALLED_EXE])).toEqual({ kind: "openChat" });
  });

  it("opens the chat when only Chromium switches came along", () => {
    expect(
      relaunchIntentFromArgv([INSTALLED_EXE, "--allow-file-access-from-files", "--user-data-dir=C:\\scratch"])
    ).toEqual({ kind: "openChat" });
  });

  it("opens the chat for a Squirrel first-run launch that arrives second", () => {
    expect(relaunchIntentFromArgv([INSTALLED_EXE, "--squirrel-firstrun"])).toEqual({ kind: "openChat" });
  });

  it("keeps a guide link on the deep-link path", () => {
    const url = "iris://guide/openascii?version=1&branch=windows:desktop";
    expect(relaunchIntentFromArgv([INSTALLED_EXE, url])).toEqual({ kind: "deepLinks", urls: [url] });
  });

  it("keeps a sign-in callback on the deep-link path", () => {
    const url = "iris://auth-callback#access_token=abc";
    expect(relaunchIntentFromArgv([INSTALLED_EXE, "--user-data-dir=C:\\scratch", url])).toEqual({
      kind: "deepLinks",
      urls: [url],
    });
  });

  it("does not mistake another scheme for an Iris link", () => {
    expect(relaunchIntentFromArgv([INSTALLED_EXE, "https://publikhq.com/iris"])).toEqual({ kind: "openChat" });
    expect(relaunchIntentFromArgv([INSTALLED_EXE, "irisx://guide/openascii"])).toEqual({ kind: "openChat" });
  });
});
