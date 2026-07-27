import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

function readJson(path: string) {
  return JSON.parse(
    readFileSync(new URL(path, import.meta.url), "utf8")
  ) as Record<string, unknown>;
}

describe("Iris desktop window", () => {
  it("starts as a tiny pill and cannot become a dashboard", () => {
    const config = readJson("../iris-desktop/src-tauri/tauri.conf.json");
    const app = config.app as {
      windows: Array<Record<string, unknown>>;
      macOSPrivateApi: boolean;
    };
    const window = app.windows[0];

    expect(app.macOSPrivateApi).toBe(true);
    expect(window).toMatchObject({
      width: 292,
      height: 48,
      minWidth: 292,
      minHeight: 48,
      maxWidth: 336,
      maxHeight: 288,
      alwaysOnTop: true,
      acceptFirstMouse: true,
      center: false,
      decorations: false,
      resizable: false,
      transparent: true,
      visible: false,
    });
  });

  it("keeps arbitrary window resizing outside the webview capability", () => {
    const capability = readJson(
      "../iris-desktop/src-tauri/capabilities/main.json"
    ) as { permissions: string[] };

    expect(capability.permissions).not.toContain(
      "core:window:allow-set-size"
    );
  });
});
