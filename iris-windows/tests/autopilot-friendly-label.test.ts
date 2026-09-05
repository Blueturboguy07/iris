import { describe, expect, it } from "vitest";
import {
  commandLaunchesAGuiInstaller,
  friendlyLabel,
} from "../src/services/autopilot/friendly-label";

/**
 * The plain-English line the autopilot terminal shows above each running command.
 * The behaviour under test here is the interactive-installer cue (finding: a
 * freshly-built GUI installer wizard, launched by `Start-Process … -Wait`, ran as
 * a silent `command` step with no cue that a window was waiting on the reader).
 */

describe("commandLaunchesAGuiInstaller", () => {
  it("recognises the shared `install-app` wizard shape (Start-Process … -Wait on a setup exe)", () => {
    const command =
      "$setup = Get-ChildItem src-tauri\\target\\release\\bundle\\nsis -Filter *-setup.exe | Select-Object -First 1\n" +
      "Start-Process -FilePath $setup.FullName -Wait";
    expect(commandLaunchesAGuiInstaller(command)).toBe(true);
  });

  it("recognises a hardcoded installer path with -Wait", () => {
    expect(
      commandLaunchesAGuiInstaller('Start-Process -FilePath "C:\\Users\\me\\Downloads\\Foo-setup.exe" -Wait'),
    ).toBe(true);
  });

  it("does NOT flag a fire-and-forget launch (Start-Process with no -Wait) — that is the app opening, not a wizard", () => {
    expect(commandLaunchesAGuiInstaller('Start-Process "$env:LOCALAPPDATA\\PlantGPT\\PlantGPT.exe"')).toBe(false);
  });

  it("does NOT flag ordinary commands", () => {
    expect(commandLaunchesAGuiInstaller("npm.cmd install")).toBe(false);
    expect(commandLaunchesAGuiInstaller("git clone https://github.com/x/y.git")).toBe(false);
    expect(commandLaunchesAGuiInstaller("winget install --id Foo.Bar -e")).toBe(false);
  });
});

describe("friendlyLabel for an interactive installer", () => {
  it("asks the reader to click through the window rather than narrating silently", () => {
    const command =
      "$setup = Get-ChildItem .\\nsis -Filter *-setup.exe | Select-Object -First 1\n" +
      "Start-Process -FilePath $setup.FullName -Wait";
    const label = friendlyLabel(command);
    expect(label).toMatch(/installer window/i);
    expect(label).toMatch(/click through/i);
    // It must NOT fall through to the generic catch-all that gives no cue.
    expect(label).not.toBe("Running a setup step…");
  });

  it("still labels ordinary commands as before", () => {
    expect(friendlyLabel("git clone https://github.com/x/y.git")).toBe("Getting the app's code…");
    expect(friendlyLabel("npm install")).toBe("Installing the pieces it needs…");
  });
});
