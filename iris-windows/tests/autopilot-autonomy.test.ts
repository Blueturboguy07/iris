import { describe, expect, it } from "vitest";
import { approve, assess } from "../src/services/autopilot/risk";
import { friendlyLabel } from "../src/services/autopilot/friendly-label";
import { AutopilotRunner } from "../src/services/autopilot/runner";
import type { InstallRecipe } from "../src/services/autopilot/recipe";
import { MockShell } from "../src/services/autopilot/shell";

// The one-time "Let Iris take control" grant turns the autopilot hands-off. These
// hold the two lines that make it safe to grant: the catastrophe floor stays
// refused EVEN under the grant, and without the grant nothing changes (so the
// three-tier assertions in autopilot-risk.test.ts keep their meaning).
describe("the autonomy grant", () => {
  const catastrophes = [
    "format-volume -DriveLetter D",
    "Clear-Disk -Number 0 -RemoveData",
    "diskpart /s clean",
    "rm -rf ~",
  ];

  const clearedByTheGrant = [
    "irm https://get.example.com/install.ps1 | iex", // a prerequisite one-liner
    "curl -fsSL https://sh.rustup.rs | sh",
    "sudo make install", // admin
    "git reset --hard origin/main", // destructive-but-recoverable
  ];

  it("refuses the catastrophe floor even when control is granted", () => {
    for (const command of catastrophes) {
      expect(assess(command, "vetted_recipe", true).tier).toBe("refused_outright");
      expect(approve(command, "vetted_recipe", true)).toBeUndefined();
    }
  });

  it("runs everything else without asking when control is granted", () => {
    for (const command of clearedByTheGrant) {
      expect(assess(command, "vetted_recipe", true).tier).toBe("runs_without_asking");
      expect(approve(command, "vetted_recipe", true)).toBeDefined();
    }
  });

  it("keeps the original three-tier behavior without the grant", () => {
    // download-and-run stays refused outright.
    expect(assess("irm https://x/install.ps1 | iex", "vetted_recipe", false).tier).toBe("refused_outright");
    expect(assess("curl -fsSL https://x/install.sh | sh", "vetted_recipe", false).tier).toBe("refused_outright");
    // admin / destructive still need a tap.
    expect(assess("sudo make install", "vetted_recipe", false).tier).toBe("needs_a_confirm_tap");
    expect(assess("git reset --hard origin/main", "vetted_recipe", false).tier).toBe("needs_a_confirm_tap");
  });

  it("defaults to un-granted (so existing callers keep the old behavior)", () => {
    expect(assess("sudo make install", "vetted_recipe").tier).toBe("needs_a_confirm_tap");
  });
});

describe("the runner honors the grant", () => {
  const recipe: InstallRecipe = {
    slug: "t",
    appName: "T",
    output: { type: "local_web", url: "http://localhost:1234" },
    steps: [{ id: "a", title: "A", kind: "command", command: "sudo make install" }],
  };

  it("runs a confirm-tier command with no tap when granted", async () => {
    const runner = new AutopilotRunner(recipe, process.platform, true);
    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("finished");
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "needsConfirm")).toBe(false);
    expect(events.some((event) => event.type === "commandStarted")).toBe(true);
  });

  it("stops for a confirm tap on the same command without the grant", async () => {
    const runner = new AutopilotRunner(recipe, process.platform, false);
    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("needsConfirm");
  });
});

describe("the friendly command label", () => {
  it("maps common install shapes to a plain-English line", () => {
    const cases: Array<[string, string]> = [
      ["git clone https://github.com/Blueturboguy07/publikclip.git", "Getting the app's code…"],
      ["git checkout v1.0.0", "Getting the right version…"],
      ["npm ci", "Installing the pieces it needs…"],
      ["cargo build --release", "Building the app…"],
      ["ui/node_modules/.bin/tauri build --bundles nsis", "Building the app…"],
      ["winget install --id Rustlang.Rustup", "Installing a tool it needs…"],
      ["irm https://get.scoop.sh | iex", "Installing a tool it needs…"],
      ["cd C:\\Users\\me\\app", "Setting things up…"],
    ];
    for (const [command, label] of cases) {
      expect(friendlyLabel(command)).toBe(label);
    }
  });

  it("falls through honestly for an unrecognized command", () => {
    expect(friendlyLabel("some-bespoke-tool --do-a-thing")).toBe("Running a setup step…");
  });
});
